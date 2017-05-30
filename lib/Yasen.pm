use strict;
use warnings;
use v5.16;

package Yasen;
use base 'Yasen::Base';

our $VERSION = '0.01';

=head1 NAME

Yasen - helps build async API servers

=head1 DESCRIPTION



=cut

use Scalar::Util qw(blessed);

sub init {
    my $self = shift;

    $Yase::Base::app = $self;

    $self->{config} ||= $self->load_config_file(
        $self->{config_file} ||= 'etc/config.json'
    );
    return $self;
}

sub load_config_file {
    my $self = shift;
    my $file = shift;
    open my $fh, '<:raw', $file
        or die "Couldn't open config file ". $file .": $!";
    return $self->json->decode( do { local $/; <$fh> } );
}

sub app { return $_[0] }

sub config {
    return $_[0]->{config};
}

sub request_class {
    return (ref($_[0])||$_[0]) .'::Request';
}

sub handle_request {
    my $self = shift;
    my $env = shift;
    my $ctx = $self->ctx->new;
    my $request = $ctx->{request} = $self->request_class->new( app => $self );
    return $request->handle( $env );
}

sub router {
    my $self = shift;
    return $self->{router} if $self->{router};

    require Router::Simple;
    my $res = Router::Simple->new;
    foreach my $rule ( $self->routes ) {
        my %opt;
        $opt{'method'} = $rule->{'method'} if $rule->{'method'};
        $opt{'host'} = $rule->{'host'} if $rule->{'host'};

        $res->connect( $rule->{'name'}? ($rule->{'name'}): (), $rule->{'path'}, $rule, \%opt );
    }

    return $self->{router} = $res;
}

sub routes {
    return ();

}

sub psgi_server {
    my $self = shift;
    return sub {
        my $env = shift;

        return $self->psgi_socket_request( $env )
            if $env->{'PATH_INFO'} eq '/socket';

        my $promise = $self->handle_request($env);
        return $promise unless blessed $promise && $promise->isa('Promises::Promise');
        return sub {
            my $responder = shift;
            $promise->done(
                sub { $responder->( $_[0] ) },
                sub { $responder->( $_[0] || [500, ['content-type' => 'text/plain'], ['internal server error']] ) },
            );
        }
    }
}

sub uwsgi_server {
    my $self = shift;
    return sub {
        my $env = shift;

        return $self->uwsgi_socket_request( $env )
            if $env->{'PATH_INFO'} eq '/socket';

        my $promise = $self->handle_request($env);
        return $promise unless blessed $promise && $promise->isa('Promises::Promise');
        my $cv = AnyEvent->condvar;
        $promise->done(
            sub { $cv->send( $_[0] ) },
            sub { $cv->send( $_[0] || [500, ['content-type' => 'text/plain'], ['internal server error']] ) },
        );
        return $cv->recv;
    }
}

sub error_server {
    my $class = shift;

    my $error = shift ."";
    chomp $error;

    my $msg = "\n\n[ERROR] couldn't start regular server because of errors: $error. Starting error server.\n";
    print STDERR $msg;
    return sub {
        my $env = shift;
        $msg =  "\n\n[ERROR] Couldn't start regular server because of errors: $error\n\nThis is error server.\n";
        eval { ($env->{'psgi.errors'} || \*STDERR)->print($msg); };

        return [500, ['content-type' => 'text/plain'], [$msg]];
    }
}

my %sockets;
sub psgi_socket_request {
    my $self = shift;
    my $env = shift;

    unless (
        lc($env->{HTTP_CONNECTION}//'') eq 'upgrade'
        && lc($env->{HTTP_UPGRADE}//'') eq 'websocket'
    ) {
        return [400, ['Content-Type' => 'text/plain'], ["Not WebSocket request"] ];
    }

    return sub {
        my $respond = shift;

        # XXX: we could use $respond to send handshake response
        # headers, but 101 status message should be 'Web Socket
        # Protocol Handshake' rather than 'Switching Protocols'
        # and we should send HTTP/1.1 response which Twiggy
        # doesn't implement yet.

        my @handshake = (
            "HTTP/1.1 101 Web Socket Protocol Handshake",
            "Upgrade: WebSocket",
            "Connection: Upgrade",
            "WebSocket-Origin: $env->{HTTP_ORIGIN}",
            "WebSocket-Location: ws://$env->{HTTP_HOST}$env->{SCRIPT_NAME}$env->{PATH_INFO}",
        );
        $self->log->debug("Request for a new socket");

        use Digest::SHA1 qw(sha1_base64);
        if ( my $key = $env->{HTTP_SEC_WEBSOCKET_KEY} ) {
            push @handshake, "Sec-WebSocket-Accept: ". sha1_base64( $key . "258EAFA5-E914-47DA-95CA-C5AB0DC85B11" ) .'=';
        }

        my $fh = $env->{'psgix.io'}
            or return $respond->([ 501, [ "Content-Type", "text/plain" ], [ "This server does not support psgix.io extension" ] ]);

        my $h = AnyEvent::Handle->new( fh => $fh );
        my ($ping_guard, $ping_timeout_guard);
        my $closer = sub {
            my $gracefuly = shift;

            undef $ping_guard;
            undef $ping_timeout_guard;

            if ( $gracefuly ) {
                my $frame = Protocol::WebSocket::Frame->new( type => 'close' );
                $h->push_write( $frame->to_bytes );
            }

            my $s = delete $sockets{ fileno($fh) };
            $s->close if $s;

            undef $h;
        };
        $h->on_error(sub {
            warn 'err: ', $_[2];
            $closer->();
        });

        $h->push_write(join "\015\012", @handshake, '', '');

        # connection ready
        my $writer = sub {
            my $msg = shift;
            my $frame = Protocol::WebSocket::Frame->new( $msg );
            my $data = $frame->to_bytes;
            $self->log->debug("Writing to the socket");
            $h->push_write( $data );
        };
        my $s = $sockets{ fileno($fh) } = GGWP::Socket->new( app => $self, writer => $writer, handle => $h );

        use Protocol::WebSocket::Frame;
        my $frame = Protocol::WebSocket::Frame->new;

        $h->on_read(sub {
            $frame->append( $_[0]->{rbuf} );
            while ( my $payload = $frame->next_bytes ) {
                if ( $frame->is_pong ) {
                    $ping_timeout_guard = undef;
                }
                elsif ( $frame->is_close ) {
                    $self->log->debug("Closing socket per client request" );
                    $closer->();
                }
                else {
                    $self->log->debug("A new message on the socket of code ". $frame->opcode );
                    $s->message( $payload );
                }
            }
        });

        $ping_guard = AnyEvent->timer( after => 5, interval => 5, cb => sub {
            my $frame = Protocol::WebSocket::Frame->new( buffer => 'pong', type => 'ping' );
            $h->push_write( $frame->to_bytes );
            $ping_timeout_guard = AnyEvent->timer( after => 3, cb => sub {
                $closer->( 'send' );
            } );
        });
    };
}

=head1 AUTHOR

Ruslan Zakirov E<lt>ruslan.zakirov@gmail.comE<gt>

=head1 LICENSE

Under the same terms as perl itself.

=cut

1;
