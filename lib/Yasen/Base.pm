use strict;
use warnings;
use v5.16;

package Yasen::Base;
use base 'Japster::Base';

use Yasen::Logger;

use AnyEvent;
use Async::ContextSwitcher qw(context cb_w_context);
use Scalar::Util qw(refaddr);
BEGIN {
    no strict 'refs';
    *{'AnyEvent::CondVar::Base::(bool'} = sub { 1 }; # bool
    *{'AnyEvent::CondVar::Base::(""'} = sub { "".refaddr($_[0]) };
    *{'AnyEvent::CondVar::Base::(=='} = sub { "$_[0]" eq "$_[1]" };
};
use AnyEvent::Redis;

our $app;
sub app {
    require Yasen;
    return $app ||= Yasen->new;
}

sub ctx { return context }

use JSON;
sub json {
    return state $r = JSON->new->utf8->pretty->allow_nonref;
}

use Data::Dumper::Concise;
sub dump {shift; return Dumper(@_)};

sub config {
    my $self = shift;
    return (ref $self? $self->{config} : undef) || $self->app->config;
}

sub log {
    my $self = shift;
    return $self->ctx->{logger} ||= Yasen::Logger->new;
}

1;
