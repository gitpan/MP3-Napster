package MP3::Napster::Listener;
# file: MP3/Napster/Listener.pm

# This object listens for incoming connections.

use strict;
use Errno qw(:POSIX);
use IO::Socket;

use MP3::Napster::PeerToPeer;
use base 'MP3::Napster::IOEvent';
use vars qw($VERSION);

$VERSION = '0.04';

sub new {
  my $class          = shift;
  my ($server,$port) = @_;
  my $listen = $class->make_listen_port($port)
    or return $server->error("couldn't create listen socket: $!");

  warn "listener(): local port = ",$listen->sockport if $server->debug > 0;
  $class->SUPER::new(
		     in        => $listen,
		     out       => undef,
		     eventloop => $server
		    );
}

sub make_listen_port {
  my $self = shift;
  my $port = shift;
  return if defined $port && $port == 0;  # won't listen if port is zero

  my @args = (Listen    => 20,
	      Proto     => 'tcp',
	      Reuse     => 1);
  push @args,(LocalPort => $port) if $port > 0;
  return IO::Socket::INET->new(@args);
}

sub port {
  my $self = shift;
  return 0 unless $self->infh;
  return $self->infh->sockport;
}

sub change_port {
  my $self = shift;
  my $port = shift;
  return unless $self->infh;
  my $listen = $self->make_listen_port($port);
  return $self->eventloop->error("can't change listen port: $!") unless $listen;
  warn "MP3::Napster::Listener->change_port($port)" if $self->server->debug;
  $self->do_close;  # close and get rid of old listener
  $self->{in} = $listen;
  $self->adjust_io;
}

# override the in() routine so that we call accept() on incoming connections
# this just enqueues a new Connection object
sub in {
  my $self = shift;
  return '0E0' unless $self->can_read();  # ???
  my $sock = $self->infh->accept;
  if (!$sock) {
    return '0E0' if $!{EAGAIN};
    $self->eof(1);
  } else { # we have an incoming connection
    my $connected = MP3::Napster::PeerToPeer->new($sock,$self->eventloop);
    $connected->write('1');  # garbage byte for stupid Napster clients
  }
  return $sock;
}

1;
