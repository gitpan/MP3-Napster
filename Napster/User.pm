package MP3::Napster::User;

# user object
use strict;
use MP3::Napster();

use overload
  '""'       => 'name',
  'cmp'      => 'cmp';

sub new {
  my $pack = shift;
  my ($server,$name,$link_type) = @_;
  $link_type ||= MP3::Napster->LINK_UNKNOWN();
  return bless {name=>$name,link=>$link_type,server=>$server},$pack;
}

sub new_from_user_entry {
  my $pack = shift;
  my ($server,$message) = @_;
  my ($channel,$name,$sharing,$link_type) = split /\s+/,$message;
  return bless { name            => $name,
		 sharing         => $sharing,
		 link            => $link_type,
		 current_channel => MP3::Napster::Channel->new($server,$channel),
		 server          => $server },$pack;
}

sub new_from_whois {
  my $pack = shift;
  my ($server,$message) = @_;
  my ($nick,$level,$time,$channels,$status,$sharing,$downloads,$uploads,$link_type,$client) = 
    $message =~ /^(\S+) "([^\"]+)" (\d+) "([^\"]*)" "([^\"]+)" (\d+) (\d+) (\d+) (\d+) "([^\"]+)"/;
  return bless {name=>$nick,link=>$link_type,server=>$server,
		time=>$time,channels=>[split /\s+/,$channels],status=>$status,
		sharing=>$sharing,downloads=>$downloads,uploads=>$uploads,
		level=>$level,client=>$client
	       },$pack;  
}

sub new_from_whowas {
  my $pack = shift;
  my ($server,$message) = @_;
  my ($nick,$level,$last_seen) =  $message =~ /^(\S+) (\S+) (\d+)/;
  return bless {name=>$nick,level=>$level,last_seen=>$last_seen,status=>'Offline'},$pack;  
}

sub name   {
  shift->{name};
}
sub cmp {
  my ($a,$b,$reversed) = @_;
  return $reversed ? $b cmp $a->name
                   : $a->name cmp $b;
}
sub link  {
  my $l = $MP3::Napster::LINK{shift->link_code};
  $l =~ s/LINK_//;
  $l;
}
sub sharing   {
  $_[0]->_fill('sharing')
}
sub link_code  { 
  $_[0]->_fill('link')
}
sub server  {
  shift->{server}
}
sub current_channel   {
    my $self = shift;
    return $self->{current_channel} if $self->{current_channel};
    return ($self->channels)[0];
  }
sub time   {
  $_[0]->_fill('time')
}
sub channels  {
  $_[0]->_fill('channels');
  @{$_[0]->{channels}}
}
sub uploads   {
  $_[0]->_fill('uploads')
}
sub downloads  {
  $_[0]->_fill('downloads')
}
sub client    { 
  ;$_[0]->_fill('client')
}
sub status  { 
  $_[0]->_fill('status')
}
sub level   {
  $_[0]->_fill('level')
}
sub last_seen  { 
  $_[0]->_fill('last_seen')
}
sub login_time { 
  my $self = shift; 
  $self->_fill; 
  $self->nice_time($self->time); }
sub nice_time {
  my $self = shift;
  my $time = shift;
  return "$time sec" if $time < 60;
  $time /= 60;
  return sprintf "%2.1f min",$time if $time < 60;
  $time /= 60;
  return sprintf "%2.1f hr",$time if $time < 24;
  $time /= 24;
  return sprintf "%2.1f day",$time if $time < 7;
  $time /= 7;
  return sprintf "%2.1f wk",$time;
}
sub ping   { 
  my $self = shift;
  $self->server->ping($self->name,@_);
}
sub msg {
  my $self = shift;
  my $message = shift;
  $self->server->private_message($message);
}
sub browse {
  my $self = shift;
  $self->server->browse($self);
}
sub profile {
  my $self = shift;
  return join("\n",
	      "Name:      $self",
	      "Status:    Offline",
	      "Last seen: ".localtime($self->last_seen)
	     )
    if $self->status eq 'Offline';

  return join ("\n",
	       "Name:      $self",
	       "Status:    ".$self->status,
	       "Sharing:   ".$self->sharing,
	       "Link:      ".$self->link,
	       "Level:     ".$self->level,
	       "Time:      ".$self->nice_time($self->time),
	       "Channels:  ".join(',',$self->channels),
	       "Uploads:   ".$self->uploads,
	       "Downloads: ".$self->downloads,
	       "Client:    ".$self->client);
}

sub update  {
  my $self = shift;
  undef $self->{status};
  $self->_fill;
}
# populate empty user objects by doing a whois
sub _fill  {
  my $self = shift;
  my $field = shift;
  return $self->{$field} if defined $self->{$field};
  my $sib = $self->server->whois($self->{name});
  %$self = %$sib if $sib;  # copy values
  return $self->{$field};
}
1;

=head1 NAME

MP3::Napster::User - Object-oriented access to Napster users

=head1 SYNOPSIS

  $user = $nap->whois('glimitz');
  print $user->name,"\n";
  print $user->sharing,"\n";
  print $user->link,"\n";
  print $user->link_code,"\n";
  print $user->server,"\n";
  print $user->current_channel,"\n";
  print join ' ',$user->channels,"\n";
  print $user->login_time,"\n";
  print $user->time,"\n";
  print $user->channels,"\n";
  print $user->uploads,"\n";
  print $user->downloads,"\n";
  print $user->level,"\n";
  print $user->last_seen,"\n";
  print $user->profile,"\n";

  $user->ping || warn "$user is unreachable";
  $user->msg('Hello there!');

=head1 DESCRIPTION

MP3::Napster::User provides object-oriented access to other users on
the Napster service.

=head2 OBJECT CONSTRUCTION

User objects are normally not constructed I<de novo>, but are returned
by the MPEG::Napster whois() and users() methods, as well as by
several of the callbacks involving the Napster chat channels,
specifically USER_JOINS and USER_DEPARTS.

=head2 OBJECT METHODS

Object methods provide access to various attributes of the User
object, allow you to send private messages to users, to browse their
files, and to ping them to determine if they are online.

=over 4

=item B<Accessors>

The accessors provide read-only access to the following User attributes.

  Accessor                Description
  --------                -----------
  $user->name             User's (nick)name 
  $user->link             User's link speed as a string
  $user->link_code        User's link speed as a numeric code
  $user->sharing          Number of files user is sharing
  $user->current_channel  User's current channel
  $user->channels         List of channels that user is subscribed to
  $user->uploads          Number of uploads the user is currently performing
  $user->downloads        Number of downloads the user is currently performing
  $user->level            The user's "level", one of "User" or "Admin"
  $user->status           One of "Offline", "Active" or "Inactive"
  $user->last_seen        The time the user was last seen, in seconds since the epoch
  $user->time             The number of seconds that the user has been logged in
  $user->login_time       The same, in a nice human-readable form
  $user->client           The version of the user's Napster client
  $user->server           The MP3::Napster that this User is attached to

=item B<$result = $user-E<gt>ping([$timeout])>

The ping() method returns true if the user is reachable by a PING
command.  The default timeout for a positive response is defined by
MP3::Napster, currently 5 seconds by default.

=item B<@songs = $user-E<gt>browse>

Browse the user's shared files, returning an array of
MP3::Napster::Song objects.

=item B<$user-E<gt>update>

Update the user's attributes from the most current versions on the
server.  Withoug calling update() the values are always those present
when the object was first created.

=item B<$user-E<gt>msg("text")>

Send a private message to the user.

=item B<$profile = $user-E<gt>profile>

Return a human readable profile like this one:

  Name:      OddBall187
  Status:    Active
  Sharing:   62
  Link:      CABLE
  Level:     User
  Time:      53.5 min
  Channels:  Themes,Alternative,Rap,Rock
  Uploads:   5
  Downloads: 1
  Client:    v2.0

=item B<String Overloading>

If used in a string context, MPEG::Napster::User objects will invoke
the name() method, allowing the objects to be directly interpolated
into strings, printed, and pattern matched.

=back

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Napster>, L<MP3::Napster::Song>, 
L<MP3::Napster::Channel>, and L<MPEG::Napster::Transfer>

=cut

