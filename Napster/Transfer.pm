package MP3::Napster::Transfer;
# upload/download support

use strict;
use base 'MP3::Napster::IOEvent';
use Carp 'croak';
use constant MAX_BUFFER => 5120;

sub config {
  my $self = shift;
  my $args = shift;
  my $r = $args->{request};
  $self->request($r);
  $r->io_object($self);
  $self->{prior} = [0,0];
}

# return the transfer request object
sub request {
  my $self = shift;
  my $d = $self->{request};
  $self->{request} = shift if @_;
  $d;
}

sub do_close {
  my $self = shift;
  $self->SUPER::do_close(@_);
  if (my $r = $self->request) {
    $r->io_object(undef);
    $r->done(1);
  }
  $self->request(undef);
}

# modify can_read() to be true when the outbuffer is less than MAX_BUFFER
sub can_read {
  my $self = shift;
  $self->SUPER::can_read && length($self->outbuffer) <= MAX_BUFFER;
}

# modify incoming_data so that it is immediately written out
sub incoming_data {
  my $self = shift;
  $self->write($self->inbuffer);
  $self->{inbuffer} = '';
}

# modify outgoing_data so as to update the request object
sub outgoing_data {
  my $self = shift;
  my $bytes = shift;
  my $request = $self->request
    or croak "outgoing_data called without transfer_request object";
  $request->increment($bytes);
}

sub DESTROY {
  my $self = shift;
  warn "DESTROY $self" if $self->eventloop 
    && $self->eventloop->debug;
  if (my $r = $self->request) {
    $self->request(undef);
  }
}

1;

__END__
