#!perl
use Config;
use File::Basename qw(&basename &dirname);
use Cwd;

$origdir = cwd;
chdir dirname($0);
$file = basename($0, '.PLS');
$file .= $^O eq 'VMS' ? '.com' : '.pl';

open OUT,">$file" or die "Can't create $file: $!";

print "Extracting $file (with variable substitutions)\n";

print OUT <<"!GROK!THIS!";
$Config{startperl} -w
!GROK!THIS!

# In the following, perl variables are not expanded during extraction.

print OUT <<'!NO!SUBS!';
use lib './blib/lib','../blib/lib';
use MP3::Napster;
use strict;

my $username = shift || die "Usage: $0 <nickname> <password>\n";
my $password = shift || die "Usage: $0 <nickname> <password>\n";

warn "Connecting...\n";
my $nap = MP3::Napster->new || die "Can't connect ",MP3::Napster->error;

# log in as "username" "password" using a T1 line
warn "Logging in...\n";
$nap->login($username,$password,LINK_T1) || die "Can't log in ",$nap->error;

# listen for incoming transfer requests on port 6699
$nap->listen(6699) || die "can't listen: ",$nap->error;

# set the download directory to "/tmp/songs"
mkdir '/tmp/songs',0777;
$nap->download_dir('/tmp/songs');

# progress reports
$nap->callback(TRANSFER_IN_PROGRESS,
	       sub { my ($nap,$code,$transf) = @_;
		     warn "\t[ ",$transf->song,": ", $transf->bytes,"/",$transf->expected_size," ]\n";
		   });
# arrange for incomplete downloads to be unlinked
$nap->callback(TRANSFER_DONE,
	       sub { my ($nap,$code,$transf) = @_;
		     return unless $transf->direction eq 'download';
		     if ($transf->status eq 'transfer complete') {
		       warn "\tDONE: ",$transf->song,"\n";
		     } else {
		       warn "\tINCOMPLETE: ",$transf->song," (UNLINKING)\n";
		       unlink $transf->local_path; 
		     }
		   } );

# search for songs by the Beatles that are on a cable modem or better
# and have a bitrate of at least 128 kbps
warn "Searching for Beatles tunes...\n";
my @songs = $nap->search(artist=>'beatles',linespeed=>LINK_CABLE,bitrate=>128);

# initiate downloads on the first four songs
my ($count,%seen_song,%seen_owner);

foreach my $s (@songs) {

  next if $seen_song{$s}++;  # already saw this song
  next if $seen_owner{$s->owner}++;  # already saw this owner

  # try to initiate download
  next unless $s->download;  
  print "\tDownloading $s, size = ",$s->size,"\n";
  last if ++$count >= 3;  # download no more than four
}

# wait for transfers to complete
warn "waiting for downloads to complete...\n";
$nap->wait_for_downloads;

__END__
!NO!SUBS!
close OUT or die "Can't close $file: $!";
chmod 0755, $file or die "Can't reset permissions for $file: $!\n";
exec("$Config{'eunicefix'} $file") if $Config{'eunicefix'} ne ':';
chdir $origdir;
