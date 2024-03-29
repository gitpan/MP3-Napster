package MP3::Napster::IOEvent;
# file: MP3/Napster/IOEvent.pm
# $Id: IOEvent.pm,v 1.1 2000/11/10 20:53:09 lstein Exp $

use strict;
use Carp;
use Errno qw(:POSIX);
use MP3::Napster::IOLoop;

use constant READSIZE => 1024 * 2;  # 2 k per read

my %FH;

# Low-level IO class for nonblocking connections
# interface has two main methods:
#
#     in() and out()
#
# in() reads some data into inbuffer, and then invokes its incoming_data() method to handle it
# out() writes buffered data from outbuffer, and invokes outgoing_data() to get some more when
# empty

sub new {
  my $class  = shift;
  my %args;
  my ($infh,$outfh,$eventloop);
  if (@_ == 1) {
    $args{in} = $args{out} = shift;
  } elsif (@_ == 3) {
    $args{in}        = shift;
    $args{out}       = shift;
    $args{eventloop} = shift;
  } else {
    %args = @_;
  }

  $args{in}->blocking(0)  if defined $args{in};    # nonblocking mode
  $args{out}->blocking(0) if defined $args{out};   # nonblocking mode
  binmode($args{out})     if defined $args{out};   # fix msdos problems
  my $self = bless {
		    in        => $args{in},
		    out       => $args{out},
		    inbuffer  => '',
		    outbuffer => '',
		    loop      => $args{eventloop},
		    eof       => 0,
		    closing   => 0,
		    prior     => [0,0], # read and write status
		   },$class;

  # process additional arguments
  delete $args{$_} foreach qw(in out eventloop);
  $self->config(\%args);

  # register the filenumbers for use later
  $FH{fileno($self->infh)}  = $self if defined $self->infh;
  $FH{fileno($self->outfh)} = $self if defined $self->outfh;

  # adjust the event loop to accept reads and/or writes on our handles
  $self->adjust_io;

  return $self;
}

# process additional arguments
sub config {
  my $self = shift;  # do nothing
}

sub lookup_fh {
  shift;
  my $fn = fileno($_[0]);
  return unless defined $fn;
  $FH{$fn} || '';
}

sub infh  {
  my $self = shift;
  my $in = $self->{in};  # workaround self-inflicted wounds from Tk::Event::IO
  $in;
#  return tied(*$in) ? tied(*$in)->handle : $in;
}
sub outfh {
  my $self = shift;
  my $out = $self->{out};  # workaround self-inflicted wounds from Tk::Event::IO
  $out;
#  return tied(*$out) ? tied(*$out)->handle : $out;
}
sub inbuffer   { shift->{inbuffer} }
sub outbuffer  { shift->{outbuffer} }
sub can_write  { length($_[0]->{outbuffer}) }
sub can_read   { !$_[0]->eof }
sub buffered   { length shift->{outbuffer} }
sub server     { shift->{loop} }

sub eventloop  { 
  my $self = shift;
  my $d = $self->{loop};
  $self->{loop} = shift if @_;
  $d;
}

sub write      {
  my $self = shift;
  $self->{outbuffer} .= $_ foreach @_;
  $self->out;  # try to write immediately
}

sub data {
  my $self = shift;
  my $d = $self->{inbuffer};
  $self->{inbuffer} = shift if @_;
  $d;
}

sub adjust_io {
  my $self = shift;
  my $l = $self->eventloop or return;
  warn "adjust_io\n" if $self->eventloop->debug > 2;

  my $r = $self->can_read  ? 1 : 0;
  my $w = $self->can_write ? 1 : 0;

  if ($self->{prior}[0] != $r) {
    my $in  = $self->infh;
    $l->set_io_flags($in,read=>$r)   if defined $in;
    $self->{prior}[0] = $r;
  }

  if ($self->{prior}[1] != $w) {
    my $out  = $self->outfh;
    $l->set_io_flags($out,write=>$w)   if defined $out;
    $self->{prior}[1] = $w;
  }

}

sub eof {
  my $self = shift;
  my $r = $self->{eof};
  if (@_) {
    $self->handle_eof if $self->{eof} = shift;
  }
  $r;
}

sub close {
  my $self = shift;
  my $now = shift;
  $self->closing(1);
  if ($now || !$self->buffered) {
    $self->do_close;
    $self->eventloop(undef);
  }
}

sub closing {
  my $self = shift;
  my $d = $self->{closing};
  $self->{closing} = shift if @_;
  $d;
}

# this gets called when there is some data to read from handle
sub in {
  my $self = shift;
  my $bytes = sysread($self->infh,$self->{inbuffer},READSIZE,length $self->{inbuffer});
  warn "read ",$bytes+0," bytes from ",fileno($self->infh),"\n" if $self->eventloop->debug > 2;
  if (!$bytes) {
    $self->eof(1) unless $!{EAGAIN};   # end of file or error
    $self->adjust_io;
    return '0E0' ;    # this is OK
  }
  $self->incoming_data($bytes);
  $self->adjust_io;
  return $bytes;
}

# this gets called when it is OK to write to the handle
sub out {
  my $self = shift;
  local $SIG{PIPE} = 'IGNORE';
  my $bytes = syswrite($self->outfh,$self->{outbuffer});
  warn "wrote ",$bytes+0," bytes to ",fileno($self->outfh),"\n" if $self->eventloop->debug > 2;
  if (!defined $bytes) {
    $self->adjust_io;
    return '0E0' if $!{EAGAIN};
    $self->handle_pipe if $!{EPIPE};
    return;
  }
  substr($self->{outbuffer},0,$bytes) = '';
  $self->outgoing_data($bytes);
  $self->adjust_io;
  $self->do_close    if $self->closing and !$self->buffered;
  return $bytes;
}

sub do_close {
  my $self = shift;
  warn "do_close(): $self" if $self->eventloop && $self->eventloop->debug;
  my ($in,$out) = ($self->infh,$self->outfh);
  if (my $l = $self->eventloop) {
    $l->set_io_flags($in,read=>0)   if defined $in  && __PACKAGE__->lookup_fh($in) eq $self;
    $l->set_io_flags($out,write=>0) if defined $out && __PACKAGE__->lookup_fh($out) eq $self;
  }
  delete $FH{fileno($in)}  if defined $in  && __PACKAGE__->lookup_fh($in) eq $self;
  delete $FH{fileno($out)} if defined $out && __PACKAGE__->lookup_fh($out) eq $self;
  CORE::close $in if defined $in;
  CORE::close $out if defined $out;
  delete $self->{in};
  delete $self->{out};
}

# to be overriddden
sub incoming_data {
  my $self  = shift;
  my $bytes = shift;
}
sub outgoing_data { 
  my $self  = shift;
  my $bytes = shift;
}
sub handle_eof {
  my $self = shift;
  $self->close;
}

sub handle_pipe {
  my $self = shift;
  $self->{outbuffer} = '';  # can't write any longer
  $self->close;
}

1;

__END__

=head1 NAME

MP3::Napster::IOEvent

=head1 SYNOPSIS


=head1 DESCRIPTION

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO


=cut


