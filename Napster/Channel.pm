package MP3::Napster::Channel;
# channel object

use strict;
use MP3::Napster();
use MP3::Napster::Base;
use vars qw(@ISA %FIELDS %RDONLY);

@ISA = 'MP3::Napster::Base';
%FIELDS  = map {$_=>undef} qw();
%RDONLY =  map {$_=>undef} qw(server user_count topic);

use overload 
  '""'       => 'name',
  'cmp'      => 'cmp';

sub new {
  my $pack = shift;
  my ($server,$name) = @_;
  return bless { name       => $name,
		 user_count => undef,
		 topic      => undef,
		 server     => $server },$pack;
}

sub new_from_list {
  my $pack = shift;
  my $server = shift;
  my ($name,$users,$topic) = shift =~ /^(\S+) (\d+) (.*)/;
  return bless { name       => ucfirst lc $name,
		 user_count => $users,
		 topic      => $topic,
		 server     => $server },$pack;
}

sub name {
  shift->{name};
}

sub users {
  return unless my $server = $_[0]->server;
  return $server->users($_[0]->name);
}
sub cmp {
  my ($a,$b,$reversed) = @_;
  return $reversed ? $b cmp $a->name
                   : $a->name cmp $b;
}
sub join {
  my $self = shift;
  return unless my $nap = $self->{server};
  $nap->join_channel($self);
}
sub part {
  my $self = shift;
  return unless my $nap = $self->{server};
  $nap->part_channel($self);
}

sub DESTROY{
  my $self = shift;
}

1;

__END__

=head1 NAME

MP3::Napster::Channel - Object-oriented access to Napster channels

=head1 SYNOPSIS

  @channels = $nap->channels;
  foreach $chan (@channels) {
     print $chan->name,"\n";
     print $chan->topic,"\n";
     print $chan->user_count,"\n";
     print $chan->server,"\n";
     @users = $chan->users,"\n";
  }

  $chan->join && print "Welcome to $chan!\n";
  $chan->part && print "Goodbye!\n";

=head1 DESCRIPTION

MP3::Napster::Channel provides object-oriented access to discussion
channels on the Napster service.

=head2 OBJECT CONSTRUCTION

Channel objects are normally not constructed from scratch but are
returned by the MPEG::Napster channels() method.

=head2 OBJECT METHODS

Methods provide access to various attributes of the Channel object and
allow you to join and depart the channel.

=over 4

=item B<Accessors>

The accessors provide read-only access to the following Channel attributes.

  Accessor                Description
  --------                -----------
  $channel->name          Channel name
  $channel->user_count    Number of users enrolled in channel
  $channel->topic         Channel's topic (welcome banner)
  $channel->server        MP3::Napster object from which channel was derived

=item B<@users = $channel-E<gt>users>

This method returns the current list of users subscribed to the
channel.  The return value is an array of MP3::Napster::User objects.

=item B<$result = $channel-E<gt>join>

Attempt to join the channel, and return a true result if successful.

=item B<$result = $channel-E<gt>join>

Attempt to join the channel, returning a true result if successful.

=item B<$result = $channel-E<gt>part>

Attempt to depart from the channel, returning a true result if
successful.

=item B<String Overloading>

If used in a string context, MPEG::Napster::Channel objects will
invoke the name() method, allowing the objects to be directly
interpolated into strings, printed, and pattern matched.

=back

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Napster>, L<MP3::Napster::Song>, 
L<MP3::Napster::User>, and L<MPEG::Napster::Transfer>

=cut

