package MP3::Napster::Song;
# song object

use strict;
use MP3::Napster();
use MP3::Napster::User;
use MP3::Napster::Base;
use vars qw(@ISA %FIELDS %RDONLY);

@ISA = 'MP3::Napster::Base';

%FIELDS  = map {$_=>undef} qw();
%RDONLY =  map {$_=>undef} qw(server path hash size bitrate freq length owner address);

use overload 
  '""'   => 'name',
  'cmp'      => 'cmp';

sub new_from_search : locked {
  my $pack = shift;
  my ($server,$song_data) = @_;
  my ($path,$md5,$size,$bitrate,$freq,$length,$nick,$ip,$link) = 
    $song_data =~ /^"([^\"]+)" (\S+) (\d+) (\d+) (\d+) (\d+) (\S+) (\d+) (\d{1,2})$/;

  # extract name of file from path 
  # different logic for UNIX and Windows -- don't know about Macs
  my $name;
  if ($path =~ /^[a-zA-Z]:/) { # Windows path
    ($name) = $path =~ /([^\\]+)$/;
  } elsif ($path =~ m!^/!) {   # Unix path
    ($name) = $path =~ m!([^/]+)$!;
  } else {                     # don't know what it is, so get rid of all of [\/:]
    ($name) = $path =~ m!([^\\/:]+)$!;
  }

  # turn address into a dotted quad form
  $ip = join '.',unpack("C4",(pack "L",$ip));  

  # For some reason, the MD5 checksum occasionally ends with a hyphen
  # and the size repeated again
  $md5 =~ s/-\d+$//;

  return bless { 
		name    => $name,
		path    => $path,
		hash    => $md5,
		size    => $size,
		bitrate => $bitrate,
		freq    => $freq,
		owner   => MP3::Napster::User->new($server,$nick,$link),
		address => $ip,
		link    => $link,
		server  => $server,
		length  => $length,
	       },$pack;
}
sub new_from_browse : locked {
  my $pack = shift;
  my ($server,$song_data) = @_;
  my ($nick,$path,$md5,$size,$bitrate,$freq,$length) = 
    $song_data =~ /^(\S+) "([^\"]+)" (\S+) (\d+) (\d+) (\d+) (\d+)$/;

  # extract name of file from path 
  # different logic for UNIX and Windows -- don't know about Macs
  my $name;
  if ($path =~ /^[a-zA-Z]:/) { # Windows path
    ($name) = $path =~ /([^\\]+)$/;
  } elsif ($path =~ m!^/!) {   # Unix path
    ($name) = $path =~ m!([^/]+)$!;
  } else {                     # don't know what it is, so get rid of all of [\/:]
    ($name) = $path =~ m!([^\\/:]+)$!;
  }

  # For some reason, the MD5 checksum occasionally ends with a hyphen
  # and the size repeated again
  $md5 =~ s/-\d+$//;

  return bless { 
		name    => $name,
		path    => $path,
		hash    => $md5,
		size    => $size,
		bitrate => $bitrate,
		freq    => $freq,
		owner   => MP3::Napster::User->new($server,$nick,MP3::Napster->LINK_UNKNOWN),
		server  => $server,
		length  => $length,
	       },$pack;
}
sub name : locked method {
  $_[0]->{name} = $_[1] if defined $_[1];
  return $_[0]->{name};
}
sub title : locked method { 
  shift->{name} 
}
sub cmp {
  my ($a,$b,$reversed) = @_;
  return $reversed ? $a->name cmp $b
                   : $b cmp $a->name;
}
sub link : locked method { 
  return '' unless defined $_[0]->{link};
  $MP3::Napster::LINK{shift->{link}} 
}
sub link_code : locked method { 
  shift->{link}  
}
sub download : locked method {
  my $self = shift;
  my $default_path = join '/',$self->server->download_dir,$self->name;
  return $self->server->download($self,shift || $default_path);
}

1;

__END__

=head1 NAME

MP3::Napster::Song - Object-oriented access to Napster shared songs

=head1 SYNOPSIS

  @songs = $nap->browse('sexybabe');
  foreach $song (@songs) {
    print $song->name,"\n";
    print $song->size,"\n";
    print $song->bitrate,"\n";
    print $song->freq,"\n";
    print $song->owner,"\n";
    print $song->length,"\n";
    print $song->hash,"\n";
    print $song->address,"\n";
    print $song->link,"\n";
  }

  $songs[0]->download;  # download to local disk

=head1 DESCRIPTION

MP3::Napster::Song provides object-oriented access to shared MP3 files
that can be retrieved via the Napster network protocol.

=head2 OBJECT CONSTRUCTION

Song objects are normally not constructed I<de novo>, but are returned
by search() and browse() calls to MPEG::Napster objects.

=head2 OBJECT METHODS

Object methods provide access to various attributes of the sound file,
and allow you to download the file to disk or pass its data to a pipe.

=over 4

=item B<Accessors>

The accessors provide read-only access to the Song object's attributes.

  Accessor                Description
  --------                -----------
  $song->name             Title of the song, often including artist
  $song->title            Same as above
  $song->size             Physical size of file, in bytes
  $song->bitrate          Bit rate of MP3 data, in kilobits/sec
  $song->freq             Sampling frequency, in Hz
  $song->length           Duration of song, in seconds
  $song->owner            Owner of the song, as an MP3::Napster::User object
  $song->path             Physical path of the song, at the remote end
  $song->hash             MD5 hash of the first 300K of the song, for identification
  $song->address          IP address of the client that holds the song
  $song->link             The link speed of the owner, as a string (e.g. LINK_DSL)
  $song->link_code        The link speed of the owner, as a numeric code (e.g. 3)
  $song->server           The MP3::Napster object from which this song was retrieved

=item B<$transfer = $song-E<gt>download( [$path | $fh] )>

The download() method will initiate a download on the song.  The
method behaves like the MP3::Napster->download() method.  If no
argument is provided, the method will open up a file in the location
specified by the MP3::Napster object's download_dir() method.
Otherwise the song data will be written to the indicated path or
filehandle.

If successful, the method will return a MP3::Napster::Transfer object,
which can be used to monitor and control the download process.

=item B<String Overloading>

If used in a string context, MPEG::Napster::Song objects will invoke
the name() method.  This allows the objects to be directly
interpolated into strings, printed, and pattern matched.

=back

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Napster>, L<MP3::Napster::User>, 
L<MP3::Napster::Channel>, and L<MPEG::Napster::Transfer>

=cut

