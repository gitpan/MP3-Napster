package MP3::Napster::Server;
# file: MP3/Napster/Server.pm
# silly test class
# $Id: Server.pm,v 1.1 2000/11/10 20:53:09 lstein Exp $

use strict;
use Carp 'croak';
use IO::Socket;
use MP3::Napster::MessageCodes;
use base 'MP3::Napster::IOEvent';

# default server for best host
use constant SERVER_ADDR => "server.napster.com:8875";

# different call arguments:
# MP3::Napster::New->new($server_addr,$loop)
sub new {
  my $class = shift;
  my ($server,$loop,$metaserver) = @_;
  $server ||= eval { $class->get_best_server($metaserver) }
    or return $loop->error($@);
  my $sock = IO::Socket::INET->new(PeerAddr => $server,
				   Timeout  => 20)
    or return $loop->error("connection refused");
  my $self = $class->SUPER::new(
				in        => $sock,
				out       => $sock,
				eventloop => $loop);
}

sub config {
  my $self = shift;
  my $args = shift;
  $self->{events} = {};
  $self->{ec}     = undef;
}

sub eof {
  my $self = shift;
  $self->server->process_event(DISCONNECTED,$self)
    if defined $_[0] && $_[0];
  $self->SUPER::eof(@_);

}

# Discover which server is the "best" one for us to contact.
sub get_best_server {
  my $self = shift;
  my $metaserver = $_[0] || SERVER_ADDR;
  if (my $socket = IO::Socket::INET->new($metaserver)) {
    my $data;
    # fetch all the data available, usually a dozen bytes or so
    if (sysread($socket,$data,1024)) {
      my ($s) = $data =~ /^(\S+)/;
      die("server overloaded\n") if $s =~ /^127\.0\.0\.1:/;
      return $s;
    } else {
      die "no data returned from napster server\n";
    }
  }
  die "connection refused\n";
}

# each time we get some incoming data check whether it is a complete message
# if it is, fire off our callback
sub incoming_data {
  my $self = shift;
  my $body;

  warn $self->{inbuffer} if $self->server->debug > 3;

  while (length $self->{inbuffer} >= 4) { # message length
    my ($length,$event) = unpack("vv",$self->{inbuffer});
    croak "Invalid code from napster server: $event"
      unless $event >= 0 and $event <= 2000;

    if ($length > 0) { # try to get body
      last unless length $self->{inbuffer} >= 4+$length;
      $body = substr($self->{inbuffer},4,$length);
    } else {
      $body = '';
    }
    substr($self->{inbuffer},0,4+$length) = '';
    $self->eventloop->process_event($event,$body);
  }
}

sub send_command {
  my $self = shift;
  my ($event,$body) = @_;
  $body = '' unless defined $body;
  my $message = pack ("vv",length $body,$event);
  $self->write($message,$body);
}

1;

__END__

=head1 NAME

MP3::Napster::Echo

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

