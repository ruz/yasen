use strict;
use warnings;
use v5.16;

package Yasen::Logger;
use base qw(Yasen::Base);
use Digest::MD5 qw(md5_hex);

sub init {
    my $self = shift;
    $self->{token} ||= substr md5_hex($self.time.rand.$$), 0, 6;
    $self->{stream} ||= $self->ctx->{error_stream} || \*STDERR;
    return $self;
}

my @levels = qw(debug info warn warning error);
for ( @levels ) {
    no strict 'subs', 'refs';
    my $l = $_;
    *{$l} = sub { (shift)->send($l, join '', @_) };
}

sub send {
    my $self = shift;
    my ($level, $msg) = @_;
    $self->{stream}->print("[".$self->{token}."][\U$level\E] $msg\n");
}

1;
