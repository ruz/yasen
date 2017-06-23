use strict;
use warnings;
use v5.16;

package Yasen::Request;
use base 'Yasen::Base';

use Scalar::Util qw(blessed);
use Async::ContextSwitcher;

sub request { return $_[0] }

sub env { return $_[0]->{env} }

sub route { return $_[0]->{route} }

sub controller { return $_[0]->{controller} }

sub action { return $_[0]->{action} }

sub handle {
    my $self = shift;
    my ($env) = (@_);
    $self->{env} = $env;

    $self->log->debug("Request begin '". $env->{PATH_INFO} ."'");

    $self->lookup_route;
    $self->lookup_controller;
    $self->lookup_action;
    return $self->invoke_action;
}

sub lookup_route {
    my $self = shift;

    my $match = $self->app->router->match($self->env);
    die $self->exception('missing') unless $match;

    return $self->{route} = $match;
}

sub lookup_controller {
    my $self = shift;

    my $route = $self->route;
    my $class = $route->{controller}
        or die "Route ". ($route->{name} || $route->{path}) ." has no controller defined";

    my $controller = do {
        local $@;
        eval "use $class; 1" or die "Failed to load controller '$class': $@";
        $class->new( request => $self );
    };

    return $self->{controller} = $controller;
}

sub lookup_action {
    my $self = shift;

    my $http_method = uc $self->env->{REQUEST_METHOD} || 'GET';

    my $route = $self->route;
    my $match = $route->{methods}->{ $http_method };

    die $self->exception(
        # XXX: bad error format
        'bad_method', method => $http_method, allowed => [ sort keys %{ $match->{methods} } ],
    ) unless $match;

    my $action = $match->{action} || lc $http_method;

    my $controller = $self->controller;
    unless ( $controller->can($action) ) {
        $self->log->error("Controller '". $route->{controller} ."' has no action '$action'");
        die $self->exception('internal');
    }

    return $self->{action} = $action;
}

sub invoke_action {
    my $self = shift;

    my $route = $self->route;
    my %url_args = map { $_ => $route->{$_} } grep !/^(controller|methods)$/, keys %$route;

    my $args = $self->arguments;
    if ( keys %url_args ) {
        $args = { %url_args, %{ $args||{} } };
    }

    my $controller = $self->controller;
    my $action = $self->action;

    my $res;
    eval { $res = $controller->$action( $args ); 1 } or return $self->format_error( $@ );
    return $self->format_error( $res ) if blessed $res && $res->isa('Japster::Exception');
    return $res->catch(cb_w_context {die $self->format_error(shift)})
        if blessed $res && $res->isa('Promises::Promise');
    return $res;
}

sub plack {
    my $self = shift;

    use Plack::Request;
    return $self->{plackr} ||= Plack::Request->new($self->env);
}

sub cookie {
    my $self = shift;
    my $name = shift;
    return $self->{cookies}{lc $name} if $self->{cookies};

    my %cookies = %{ $self->plack->cookies };
    $cookies{ lc $_ } = delete $cookies{$_} foreach grep lc $_ ne $_, keys %cookies;
    $self->{cookies} = \%cookies;

    return $self->{cookies}{lc $name} if $self->{cookies};
}

sub arguments {
    my $self = shift;

    my $env = $self->env;
    my $plackr = $self->plack;

    my $res;
    if ( $env->{REQUEST_METHOD} eq 'GET' ) {
        $res = $plackr->query_parameters;
    }
    elsif ( ($env->{CONTENT_TYPE}||'') =~ m{^application/(json|[a-z.]+\+json|json\+[a-z.])$} ) {
        $res = $self->json->decode( $plackr->raw_body );
    }
    else {
        $res = $plackr->parameters;
    }
    return $res;
}

sub format_error {
    my $self = shift;
    my $err = shift;
    unless ( blessed $err && $err->isa('Japster::Exception') ) {
        $self->log->error($self->dump([$err, @_]));
        return $self->simple_psgi_response(500, text => 'internal server error');
    }

    return $err->format;
}

1;
