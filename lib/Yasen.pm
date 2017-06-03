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

    $Yasen::Base::app = $self;

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

=head1 AUTHOR

Ruslan Zakirov E<lt>ruslan.zakirov@gmail.comE<gt>

=head1 LICENSE

Under the same terms as perl itself.

=cut

1;
