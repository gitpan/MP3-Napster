package MP3::Napster::Registry;
# registry of local songs

use strict;
use IO::File;
use Digest::MD5;
use MP3::Napster();
use MP3::Napster::Song();
use MP3::Napster::MessageCodes qw(I_HAVE REMOVE_FILE REMOVE_ALL);
require MP3::Info;

use vars qw($VERSION);
$VERSION = '0.60';

use constant CACHE_DIR      => '.mp3-nap';
# use constant MAGIC_HASH_LEN => 300_000;  # number of bytes that the Linux nap client hashes (?)
# use constant MAGIC_HASH_LEN => 299_008;  # number of bytes recommended by the opennap spec (?)
use constant MAGIC_HASH_LEN => 300_032;    # number of bytes that the window nap client hashes (?)

sub new {
  my $pack   = shift;
  my $server = shift;
  return bless { server => $server },$pack;
}

sub server {  shift->{server} }

sub path {
  my $self = shift;
  my $sharename = shift;
  return $self->song($sharename)->path;
}

sub song {
  my $self = shift;
  my ($sharename,$song) = @_;
  return defined $song ? $self->{song}{$sharename} = $song
                       : $self->{song}{$sharename};
}

sub share_file {
  my $self = shift;
  my ($path,$cache) = @_;  # cache indicates whether to cache results (recommended)
  my ($md5,$size,$bitrate,$frequency,$duration,@tag) = $self->mp3info($path,$cache) 
      or return $self->server->error("couldn't get file info for $path");
  pop @tag if @tag%2;  # prevent "odd-numbered errors"
  my %tag = @tag;

  my $sharename = $self->sharename($path,\%tag);  # build a nice sharename
  my $message = qq("$sharename" $md5 $size $bitrate $frequency $duration);
  warn "I_HAVE $message\n" if $self->server->debug;
  return unless $self->server->send_command(I_HAVE,$message);

  warn "share_file(): mapping $sharename to $path\n" if $self->server->debug > 0;
  my $nick = $self->server->nickname;
  my $song = MP3::Napster::Song->new_from_browse($self->server,
						  qq($nick "$path" $md5 $size $bitrate $frequency $duration));
  $self->song($sharename => $song);
  $song->name($sharename);
  return $song;
}

sub unshare {
  my $self = shift;
  my $sharename = shift;
  $self->server->send_command(REMOVE_FILE,$sharename);
  delete $self->{song}{$sharename};
}

sub unshare_all {
  my $self = shift;
  $self->server->send_command(REMOVE_ALL);
  $self->{song} = {};
}

sub sharename {
  my $self = shift;
  my ($path,$tag) = @_;
  my $share;
  # have a title and artist
  if ($tag->{ARTIST} and $tag->{TITLE}) {
    $share = "$tag->{ARTIST} - $tag->{TITLE}.mp3";
    $share =~ s![/\\]!_!g; # nuke [back]slashes
  } else {
    # otherwise just return filename
    ($share) = $path =~ m!([^/\\]+)$!;
  }
  return "Z:\\nap\\$share";
}


# get the mp3 info on a file
sub mp3info {
  my $self = shift;
  my ($path,$cache) = @_;
  return unless -e $path;
  my $file_age = -M _;
  my $file_size = -s _;
  my $cname = CACHE_DIR;

  # first look for a .nap cache directory and file
  (my $cache_file = $path) =~ s!([^/\\]+)$!$cname/$1!;
  if (-e $cache_file and -M $cache_file <= $file_age) {
    if (my $c = IO::File->new($cache_file)) {
      my $data;
      read($c,$data,5000);  # read to end of file
      return split $;,$data;   # split into fields
    }
  }

  # no valid cache directory, so read from file
  # the md5 sum is taken from the first 300K of the file
  # after removing ID3v2 information
  return unless my $p = IO::File->new($path);
  return unless my $ctx = Digest::MD5->new;

  # examine first 3 bytes to see if we need to skip ID3v2 header
  my ($data,$read_total);
  read($p,$data,3);
  if ($data eq 'ID3') {
    skip_header($p);  # seek over the ID3v2 tag
  } else {
    seek($p,0,0);     # otherwise back to beginning
  }

  my $bytes_total = MAGIC_HASH_LEN;
  while ($bytes_total > 0) {
    my $bytes_to_read = $bytes_total > 10_000 ? 10_000 : $bytes_total;
    last unless my $bytes_read = read($p,$data,$bytes_to_read);
    $ctx->add($data);
    $bytes_total -= $bytes_read;
  }
  $p->close;
  my $md5 = $ctx->hexdigest;

  # now get the MP3 info for the file
  return unless my $mp3 = eval { MP3::Info::get_mp3info($path) };
  my $duration = $mp3->{MM}*60 + $mp3->{SS};  # total duration in seconds

  # and the ID tag info
  my $tag = eval { MP3::Info::get_mp3tag($path) } || {};

  # this prevents an uninitialized variable warning
  foreach (keys %$tag) { $tag->{$_} ||= '' }

  # have the result now
  my @result = ($md5,$file_size,$mp3->{BITRATE},$mp3->{FREQUENCY}*1000,$duration,%$tag);

  # cache if requested
  if ($cache) {
    (my $cache_dir = $cache_file) =~ s![/\\][^/\\]+$!!;
    mkdir($cache_dir,0777) unless -d $cache_dir;
    if (my $c = IO::File->new(">$cache_file")) {
      print $c join $;,@result;
    }
  }
  return @result;
}

# algorithm stolen out of MP3Info
# might break
sub skip_header {
  my $fh = shift;

  return unless defined &MP3::Info::_get_v2tag;
  my $tag = MP3::Info::_get_v2tag($fh);
  my $pos = tell($fh);
}

1;
__END__

=head1 NAME

MP3::Napster::Registry - Manage local songs shared by MP3::Napster

=head1 SYNOPSIS

None

=head1 DESCRIPTION

This class is used internally by MP3::Napster to manage the list of
local MP3 files that are shared with other users.  Documentation will
be added if and when it becomes useful to application developers.

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Napster>, L<MP3::Napster::Song>, and L<MPEG::Napster::Transfer>

=cut

