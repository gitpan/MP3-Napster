package MP3::Napster::PeerToPeer;
# file: MP3/Napster/PeerToPeer.pm
# This object is created to establish a connection between
# one peer and another.  It may be a new outgoing connection
# or a previously established incoming connection.
# In the former case, we have a Transfer_request object.
# In the latter case, we must look up the Transfer_request object.

use strict;
use base 'MP3::Napster::IOEvent';
use MP3::Napster::Transfer;

use IO::Socket;
use Errno ':POSIX';
use Carp 'croak';

# new() can be called with a filehandle, in which case we
# are the passive party, or it can be called with a transfer_request
# object, in which case we initiate an outgoing connection.
sub new {
  my $class = shift;
  my ($obj,$eventloop) = @_;

  # signal that the transfer is starting
  if ($obj->can('connected')) { # we already have a socket
    my $self = $class->SUPER::new($obj,$obj,$eventloop);
    return unless $self;
    $self->status('request_in');
    return $self;
  }

  if ($obj->isa('MP3::Napster::TransferRequest')) { # called with a transfer_request object
    my $transfer_request = $obj;
    $transfer_request->start;
    my $peer = $transfer_request->peer;
    warn "connecting to $peer" if $eventloop->debug;
    my $sock = $class->connect($peer);  # try to connect
    unless ($sock) {
      $transfer_request->status("can't connect: $!");
      return;
    }
    my $self = $class->SUPER::new($sock,$sock,$eventloop);
    return unless $self;
    $self->transfer_request($obj);                   # remember the transfer_request object
    $self->status('handshake1');
    $self->adjust_io;
    return $self;
  }

  croak "Usage: MP3::Napster::PeerToPeer->new(<sock or transfer_request>,eventloop)";
}

sub server { shift->eventloop }
sub config {
  my $self = shift;
  my $args = shift;
  $self->{status} = '';
}

# set the size or offset for the pending transfer
sub size {
  my $self = shift;
  my $d = $self->{size};
  $self->{size} = shift if @_;
  $d;
}

# keep a status message locally as well as in the transfer_request object
# if we have one.
sub status {
  my $self = shift;
  my $d = $self->{status};
  if (@_) {
    $self->{status} = shift;
    $self->transfer_request->status($self->{status}) if $self->transfer_request;
    warn "$self: $self->{status}\n" if $self->server->debug;
  }
  $d;
}

sub transfer_request {
  my $self = shift;
  my $d = $self->{transfer_request};
  $self->{transfer_request} = shift if @_;
  $d;
}

# This gets called to initiate an outgoing request.
# It initiates a nonblocking connect.
sub connect {
  my $self = shift;
  my $peer = shift;
  my ($inet,$port) = split ':',$peer;
  my $sock = IO::Socket::INET->new(Proto => 'tcp',
				   Type  => SOCK_STREAM) or die $@;
  $sock->blocking(0);
  my $addr = sockaddr_in($port,inet_aton($inet));
  my $result = $sock->connect($addr);
  return $sock if $result || $!{'EINPROGRESS'};
  return  # anything else is an error
}

# override the can_write() method so that we flag that
# we want to write if we are in a non-blocking connect
# or there's data in the out buffer
sub can_write {
  my $self = shift;
  my $status = $self->status;
  return 1 if $self->SUPER::can_write;
  return $status =~ /request_out|handshake sent/;
}

sub can_read {
  my $self = shift;
  my $status = $self->status;
  return if $status =~ /request_out|handshake sent|starting transfer/;
  return $self->SUPER::can_read;
}

# override the out() method so that we try to finish the nonblocking connect
# if socket is connected, then we send the request
sub out {
  my $self = shift;
  return $self->SUPER::out(@_) unless $self->status eq 'request_out1';

  # if we get here, check whether we connected successfully
  my $sock = $self->outfh;
  unless ($sock->connected) {
    $! = $sock->sockopt(SO_ERROR);
    return $self->abort($1);
  }

  $self->send_request;
}

# send an outgoing request
sub send_request {
  my $self = shift;
  my $transfer_request = $self->transfer_request 
    or croak "Expecting a transfer_request object";
  my $request;

  if ($self->status eq 'request_out1') {
    $request = $transfer_request->request_method;
    warn "transfer request method = $request" if $self->server->debug;
    $self->status('request_out2');

  } elsif ($self->status eq 'request_out2') {
    $request = $transfer_request->request_string;
    warn "transfer request string = $request" if $self->server->debug;
    $self->status('handshake2');
  } else {
    croak "Wrong status: ",$self->status;
  }

  $self->write($request);
}

# abort everything (needs work!!)
sub abort {
  my $self = shift;
  my $msg = shift;
  $self->status("aborted: $msg");
  $self->transfer_request->abort if $self->transfer_request;
  $self->close('now');
  return;
}

########### handle incoming data ###########

# This will be called when there's data in the inbuffer to read
# Only three states are possible.  All others are errors.
sub incoming_data {
  my $self = shift;
  return $self->handle_garbage   if $self->status eq 'handshake1';
  return $self->handle_handshake if $self->status eq 'handshake2';
  return $self->handle_request   if $self->status eq 'request_in';
#  die "bad status: ",$self->status;
}


sub outgoing_data {
  my $self = shift;
  warn "PeerToPeer: outgoing_data()" if $self->server->debug;
  if ($self->status eq 'handshake sent' and !$self->buffered) {
    $self->initiate_transfer($self->size);
  } elsif ($self->status eq 'request_out2') {
    $self->send_request;
  }
}

#############################################################
# Active requests expect a handshake
############################################################

sub handle_garbage {
  my $self = shift;
  # clients will send a byte of garbage on connects, which we just ignore
  warn "handle_garbage()" if $self->server->debug;
  substr($self->{inbuffer},0,1) = '';
  $self->status('request_out1');
}

# incoming data while we are waiting for the handshake
sub handle_handshake {
  my $self = shift;
  my $transfer_request = $self->transfer_request 
    or croak "handshake without transfer_request object";

  warn "handle_handshake()" if $self->server->debug;

  # may not be anything to read yet
  return unless length $self->{inbuffer} > 0;

  # handshake refused
  return $self->abort($self->{inbuffer}) if $self->{inbuffer} =~ /^(INVALID|FILE NOT FOUND)/; 

  return $self->abort("expected a size but got $self->{inbuffer}")
    unless $self->inbuffer =~ /^(\d+)/;  # not expected handshake format

  my $size_or_offset = $1;   # either the size of file on a download , or offset on an upload
  substr($self->{inbuffer},0,length $1) = '';  # truncate inbuffer
  warn "size/offset = $size_or_offset" if $self->server->debug;

  $self->size($size_or_offset);
  $self->initiate_transfer;
}

#############################################################
# Passive requests get a request and try to fetch a transfer
#############################################################

sub handle_request {
  my $self = shift;
  croak "asked to handle an incoming request, but already have a transfer request object"
    if $self->transfer_request;

  $self->inbuffer =~ /^((SEND|GET)(\S+) "([^\"]+)" (\d+))/ or return;  # maybe incomplete
  my ($direction,$nickname,$path,$size_or_offset) = ($2 eq 'GET' ? 'upload' : 'download',
						     $3,$4,$5);

  # truncate anything left over in buffer -- this shouldn't be necessary
  substr($self->{inbuffer},0,length $1) = '';

  # try to look up the transfer request, which should already be authorized by server!
  my $method = "${direction}s";
  my $transfer_request = $self->server->$method($nickname,$path);
  unless ($transfer_request) {  # invalid request
    $self->write('INVALID REQUEST');
    return $self->abort("$nickname made unauthorized request for $path");
  }

  $self->transfer_request($transfer_request);
  $self->size($size_or_offset);
  if ($transfer_request->direction eq 'upload') {
    $self->initiate_transfer;
  } else {
    $self->write($transfer_request->offset);
    $self->status('handshake sent');
  }
}

#############################################################
# Here's where we create the Transfer object
#############################################################
sub initiate_transfer {
  my $self = shift;
  my $transfer_request = $self->transfer_request;
  my $size_or_offset = $self->size;
  $transfer_request->set_size_or_offset($size_or_offset);
  $self->status('starting transfer');
  $self->adjust_io;

  ############## download requests #############
  if ($transfer_request->direction eq 'download') {
    my $transfer =
      MP3::Napster::Transfer->new(in        => $self->infh,
				  out       => $transfer_request->localfh,
				  eventloop => $self->eventloop,
				  request   => $transfer_request,
				 );
    $transfer or return $self->abort("failed to create download transfer object");

    # write out any additional music data
    $transfer->write($self->inbuffer) if length $self->inbuffer;
    return;
  }

  ############## upload requests #############
  if ($transfer_request->direction eq 'upload') {
    my $transfer =
      MP3::Napster::Transfer->new(in        => $transfer_request->localfh,
				  out       => $self->outfh,
				  eventloop => $self->eventloop,
				  request   => $transfer_request,
				 );
    $transfer or return $self->abort("failed to create upload transfer object");
    $transfer->write($transfer_request->song->size) unless $transfer_request->peer;
    return;
  }

}

sub DESTROY {
  my $self = shift;
  warn "DESTROY $self" if $self->eventloop && $self->eventloop->debug;
}

1;

