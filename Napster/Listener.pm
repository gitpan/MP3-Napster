package MP3::Napster::Listener;

# This object starts a thread that listens for incoming connections.
# It spawns off Transfer objects.

use strict;
use Thread qw(cond_wait cond_signal);
use IO::Select;
use IO::Socket;
use IO::File;
use Errno 'EWOULDBLOCK';
use MP3::Napster();
use MP3::Napster::Base;

use vars qw($VERSION @ISA %FIELDS %RDONLY);
@ISA = 'MP3::Napster::Base';

%FIELDS  = map {$_=>undef} qw(socket done);
%RDONLY =  map {$_=>undef} qw(server);

$VERSION = '0.03';

use constant TIMEOUT   => 1;

sub new : locked {
  my $pack   = shift;
  my $server = shift;
  my $self = bless { 
		server  =>  $server,
		socket  =>  undef,
	       },$pack;
  return $self;
}

sub port : locked method {
  my $self = shift;
  return 0 unless $self->socket;
  return $self->socket->sockport;
}

sub start : locked method {
  my $self = shift;
  my $port = shift;
  my @args = (Listen    => 20,
	      Proto     => 'tcp',
	      Reuse     => 1);
  return if defined $port && $port == 0;  # won't listen if port is zero
  push @args,(LocalPort=>$port) if defined $port and $port > 0;

  warn "start_sharing(): creating listen socket" if $MP3::Napster::DEBUG_LEVEL > 0;
  my $socket = IO::Socket::INET->new(@args) 
    || return $self->server->error("couldn't create listen socket: $!");

  $port = $socket->sockport;  # remember the socket we're listening on
  warn "listen_thread(): local port = $port" if $MP3::Napster::DEBUG_LEVEL > 0;
  $self->socket($socket);

  return unless my $t = Thread->new(\&listen_thread,$self,@_);
  $t;
}

# listen for incoming connections on the indicated port
# if no port specified, then just pick an unused one and return to caller
sub listen_thread {
  my $self = shift;
  return unless my $socket = $self->socket;
  return unless my $select = IO::Select->new($socket);
  $self->done(0);

  # check for interruptions at timeout intervals
  while (!$self->done) {
    next unless $select->can_read(TIMEOUT);
    next unless my $connected = $socket->accept;
    warn "listen_thread(): incoming connection from ",$connected->peerhost,"\n" 
      if $MP3::Napster::DEBUG_LEVEL > 0;
    $self->handle_connection($connected);
  }
  warn "listen_thread(): done\n" if $MP3::Napster::DEBUG_LEVEL > 0;
  $socket->close;
  $self->socket(undef);
  lock $self->{done};
  cond_signal $self->{done};
}

sub handle_connection {
  my $self = shift;
  my $sock = shift;
  my $t = Thread->new(\&_connection => $self,$sock);
  if ($MP3::Napster::DEBUG_LEVEL > 2) {
    $self->server->add_thread($t);
  } else {
    $t->detach;
  }
}

sub _connection {
  my $self = shift;
  my $sock = shift;

  # send a garbage byte to make stupid clients happy
  syswrite($sock,"1");

  # read the message and act on it
  my $data;
  sysread($sock,$data,3) || return $self->error("_connection(): couldn't read request:$!");
  warn "_connection(): got $data\n" if $MP3::Napster::DEBUG_LEVEL > 0;  

  $self->_handle_download($sock) if $data eq 'SEN';
  $self->_handle_upload($sock)   if $data eq 'GET';

  close $sock;
  warn "_connection(): done\n" if $MP3::Napster::DEBUG_LEVEL > 0;  
}

# a client is trying to push a download to us (passive download)
sub _handle_download {
  my $self = shift;
  my $sock = shift;
  my $data;

  # get the message
  sysread($sock,$data,1) 
    || return $self->error("_handle_download(): couldn't read leftover request byte");  # get rid of that extra byte of "D" from SEND

  # get the message
  sysread($sock,$data,1024) || return $self->error("_handle_download(): couldn't sysread message");
  warn "_handle_download(): SEND request: got ",length($data)," bytes of data $data\n" 
    if $MP3::Napster::DEBUG_LEVEL > 0;

  return $self->error("uninterpretable SEND request: $data\n")
    unless my ($nick,$path,$size) = $data =~ /^(\S+) "([^\"]+)" (\d+)/;

  # try to recover a matching download
  warn "_connection(): searching for a download matching $nick / $path\n" if $MP3::Napster::DEBUG_LEVEL > 0;

  return $self->server->error('unauthorized incoming download request. ignoring.') 
    unless my $download = $self->server->downloads($nick,$path);

  warn "_connection(): initiating download\n" if $MP3::Napster::DEBUG_LEVEL > 0;

  $download->socket($sock);
  $download->expected_size($size);

  warn "_connection(): calling passive_transfer\n" if $MP3::Napster::DEBUG_LEVEL > 0;
  $download->passive_transfer();
}

sub _handle_upload {
  my $self = shift;
  my $sock = shift;
  my $data;

  # read the request  ?? maybe we should timeout for broken clients ??
  warn "_connection(): reading request\n" if $MP3::Napster::DEBUG_LEVEL > 0;  
  sysread($sock,$data,1024) || return $self->error("_handle_upload(): couldn't get upload header data");
  warn "_connection(): got $data\n"  if $MP3::Napster::DEBUG_LEVEL > 0;   

  my ($nick,$sharename,$position) = $data=~/^(\S+) "([^\"]+)" (\d+)/;
  warn "_connection(): $nick wants to get $sharename, position=$position\n" if $MP3::Napster::DEBUG_LEVEL > 0;

  if (my $upload = $self->server->uploads($nick,$sharename)) {
    # set the socket
    $upload->position($position);
    $upload->socket($sock);
    $upload->passive_transfer;
  } else {
    warn "_handle_upload(): invalid request" if $MP3::Napster::DEBUG_LEVEL > 1;
    syswrite($sock,'INVALID REQUEST');
    close $sock;
  }

}

# sub DESTROY { warn "DESTROYING LISTEN OBJECT $_[0]" if $MP3::Napster::DEBUG_LEVEL > 0 } 

1;
