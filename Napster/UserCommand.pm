package MP3::Napster::UserCommand;
# file: MP3/Napster/UserCommand.pm
# callbacks for interactive commands, usually on STDIN
# $Id: UserCommand.pm,v 1.1 2000/11/10 20:53:09 lstein Exp $

use strict;
use Carp 'croak';
use IO::Socket;
use MP3::Napster::MessageCodes 'USER_COMMAND_DATA';
use base 'MP3::Napster::IOEvent';

sub config {
  my $self = shift;
  my $args = shift;
  my $cb   = $args->{callback} or return;
  $self->callback($cb);
  $self->eventloop->callback(USER_COMMAND_DATA,
			     sub {
			       my ($loop,$event,$data) = @_;
			       my $cb = $self->callback or return;
			       $cb->($loop,$data);
			       }
			    );
  $self->{in}->blocking(1) if -t $self->{in};  # special exception for ttys
}

sub callback {
  my $self = shift;
  my $cb = $self->{cb};
  $self->{cb} = shift if @_;
  return $cb;
}

# Each time we get some incoming data check whether it is a complete line-delimited command.
# If it is, fire off our callback
sub incoming_data {
  my $self = shift;
  my $line;
  while ($self->{inbuffer} =~ s/(.*?)\n//) {
    $self->process_command($1);
  }
}

sub process_command {
  my $self = shift;
  my $string = shift;
  my $server = $self->eventloop or return;
  $server->process_event(USER_COMMAND_DATA,$string);
}

sub handle_eof {
  my $self = shift;
  if (my $server = $self->eventloop) {
    $server->process_event(USER_COMMAND_DATA,undef);
  }
  $self->SUPER::handle_eof;
}

1;

__END__

=head1 NAME

MP3::Napster::UserCommand

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

