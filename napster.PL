#!perl
use Config;
use File::Basename qw(&basename &dirname);
use Cwd;

$origdir = cwd;
chdir dirname($0);
$file = basename($0, '.PL');
$file .= $^O eq 'VMS' ? '.com' : '.pl';

open OUT,">$file" or die "Can't create $file: $!";

print "Extracting $file (with variable substitutions)\n";

print OUT <<"!GROK!THIS!";
$Config{startperl} -w
!GROK!THIS!

# In the following, perl variables are not expanded during extraction.

print OUT <<'!NO!SUBS!';
use strict;
use lib './blib/lib';
use vars qw(@SEARCH $COUNTER %OPT);

BEGIN {
  use Getopt::Std;
  my $USAGE = <<USAGE;
Usage: $0 [options] [address]
Start a Napster session.
 Options:
     -r          register as a new user
     -l <speed>  link speed (see below)
     -d <path>   download directory [./songs]
     -u <path>   upload directory [same as download]
     -m <path>   command to launch MP3 player from STDIN
     -p <port>   port to listen on, use 0 with firewall
     -v <level>  debug verbosity level
     -h          help message

 [address] address of a Napster server in form aa.bb.cc.dd:port
           If not specified, will automatically choose the "best"
           server in the same way the Windows client does.
 <speed>   one of: 14K 28K 33K 56K 64K 128K CABLE DSL T1 T3
           Defaults to "unknown".
 <port>    If you provide -1 as the port (-p -1), then the client
           will choose an unused port at random.  The standard
           Napster port is 6699 (-p 6699), but you can choose any
           port you like or let the script do it for you.
USAGE
  getopts('rhl:u:d:m:p:v:',\%OPT) or die $USAGE;
  if ($OPT{h}) { print STDERR $USAGE; exit 0;}
}

use IO::File;
use MP3::Napster;
use Getopt::Std;

my $READLINE;
if (-t STDIN && !defined($ENV{EMACS})) {
  $READLINE = new Term::ReadLine $0
    if eval { require Term::ReadLine };
  $READLINE->ornaments(',,md,me');
}

use constant LINK_SPEED => LINK_UNKNOWN;
use constant DOWNLOAD_PATH => './songs';
use constant PORT => 6699;
use constant PLAYER => 'mpg123 -';

# note: test username/passwd = plugh1/xyzzy
# defaults:
$OPT{l} = LINK_SPEED unless defined $OPT{l};    # $OPT{l} is the link speed
$OPT{p} = PORT       unless defined $OPT{p};    # $OPT{p} is the port
$OPT{d} ||= DOWNLOAD_PATH;  # $OPT{d} is the download directory
$OPT{u} ||= $OPT{d};        # $OPT{u} is the upload directory
$OPT{m} ||= PLAYER;         # $OPT{m} is the player application

# process link speed a bit
unless ($OPT{l} =~ /^\d+$/ && $OPT{l} <= LINK_T3) {
  $OPT{l} = "LINK_$OPT{l}" unless $OPT{l} =~ /^LINK_/i;
  $OPT{l} = eval "\U$OPT{l}\E" || 0;
}

$| = 1;
$MP3::Napster::DEBUG_LEVEL = $OPT{v} if defined $OPT{v};

warn "[ connecting... ]\n";
my $addr = shift;

my $nap = MP3::Napster->new($addr) 
  || die "Couldn't connect: ",MP3::Napster->error,"\n";

END {
  if (defined $nap) {
    print "[ logging out, wait... ]\n";
    $nap->disconnect();
  }
}

# set up the download directory
mkdir $OPT{d},0777 or die "Couldn't make directory $OPT{d}: $!\n"
  unless -d $OPT{d};
$nap->download_dir($OPT{d});

setup_callbacks($nap);

login()    || die "Couldn't log in\n"   unless $OPT{r};
register() || die "Couldn't register\n" if $OPT{r};
print "\n";

# Update our link speed, if provided
$nap->change_registration(link => $OPT{l}) if $OPT{l};

# Share some files
my $shared_songs = 0;
opendir (S,$OPT{u}) || die "Couldn't open upload directory: $!";
while (my $song = readdir(S)) {
  next unless $song =~ /\.mp3$/;
  $nap->share("$OPT{u}/$song",1) && $shared_songs++;
}
closedir S;
my $port = $nap->listen($OPT{p}) if $OPT{p};
print "[ sharing $shared_songs songs ",$port?"on port $port":"(firewalled)"," ]\n";

print "\n";

while (defined($_ = getline())) {
  chomp;
  if (m!^/!) { # a command
    my ($command,$args) = m!^/(\w+)\s*(.*)!;
    $command = lc $command;
    $nap->channels,next         if $command eq 'channels';
    join_channel($args),next    if $command eq 'join';
    part_channel($args),next    if $command eq 'part';
    search($args),next          if $command eq 'search';
    msg($args),next             if $command eq 'msg';
    browse($args),next          if $command eq 'browse';
    download($args),next        if $command eq 'download' or $command eq 'g';
    status($args),next          if $command eq 'status';
    play($args),next            if $command eq 'play';
    users($args),next           if $command eq 'users';
    whois($args),next           if $command eq 'whois' or $command eq 'finger';
    ping($args),next            if $command eq 'ping';
    abort($args),next           if $command eq 'abort';
    boot($args),next            if $command eq 'boot';
    port($args),next            if $command eq 'port';
    password($args),next        if $command eq 'password';
    email($args),next           if $command eq 'email';
    exit(0),next                if $command eq 'quit';
    help(); next;
  }
  speak($_) if /\S/;
  help() unless /\S/;
}

sub getline {
  if ($READLINE) {
    my $l =  $READLINE->readline('');
    $READLINE->addhistory($l) if $l;
    return $l;
  }
  return scalar <>;
}

sub login {
  print "login: ";
  chomp (my $login = <>);
  print "password: ";
  system "stty -echo </dev/tty" unless $ENV{EMACS};
  chomp (my $pass = <>);
  system "stty echo </dev/tty" unless $ENV{EMACS};
  print "\n";
  warn "[ logging in... ]\n";
  if (my $email = $nap->login($login,$pass,$OPT{l},$OPT{p})) {
    print "[ Logged in with email $email ]\n";
    return 1;
  } else {
    print "[ Couldn't log in: ",$nap->error," ]\n";
    return undef;
  }
}

sub register {
  print "new nickname: ";
  chomp (my $login = <>);
  my $pass = get_password();
  print "link speed [14K 28K 33K 56K 64K 128K CABLE DSL T1 T3]: ";
  chomp (my $link_speed = <>);
  $link_speed = eval "\ULINK_$link_speed\E" || 0;

  warn "[ registering... ]\n";
  if (my $email = $nap->register($login,$pass,{link=>$link_speed,port=>$OPT{p}})) {
    print "[ Registered with email $email ]\n";
    return 1;
  } else {
    print "[ Couldn't register: ",$nap->error," ]\n";
    return undef;
  }
}

sub port {
  my $arg = shift;
  return unless $arg =~ /^\d+$/;
  print "* Changing port to $arg\n";
  $nap->process_message(SET_DATA_PORT,$arg);
}

sub password {
  return unless my $pass = get_password(1);
  print "* Changing password\n";
  $nap->change_registration(password => $pass);
}

sub email {
  return unless my $email = shift;
  print "* Changing email address\n";
  $nap->change_registration(email => $email);
}

sub get_password {
  my $new = $_[0] ? 'new ' : '';
  system "stty -echo </dev/tty" unless $ENV{EMACS};
  print "${new}password: ";
  chomp (my $pass1 = <>);
  print "\n";
  print "re-enter ${new}password: ";  
  chomp (my $pass2 = <>);
  print "\n";
  system "stty echo </dev/tty" unless $ENV{EMACS};
  unless ($pass1 eq $pass2) {
    print "they don't match\n";
    return;
  }
  return $pass1;
}

sub join_channel {
  my $chan = shift;
  foreach (split /\s+/,$chan) {
    print "[ Can't join $_ ",$nap->error," ]\n"
      unless $nap->join_channel($_);
      
  }
  my $channels = join(', ',$nap->enrolled_channels) || 'no channels';
  print "[ Enrolled in $channels ]\n";
}

sub part_channel {
  my $chan = shift;
  if ($nap->part_channel($chan)) {
    my $channels = join(', ',$nap->enrolled_channels) || 'no channels';
    print "[ Departing $chan, now a member of $channels ]\n";
  } else {
    print "[ Departure unsuccessful: ",$nap->error," ]\n";
  }
}

sub users {
  unless ($nap->channel) {
    print "[ no current channel ]\n";
    return;
  }
  foreach ($nap->users) {
    printf "\t[ %-20s sharing %4d files on a %-9s line ]\n",$_,$_->sharing,$_->link;
  }
}

sub speak {
  $nap->public_message(shift) || print "[ ERROR: no channel selected ]\n";
}

sub msg {
  my ($nick,$msg) = shift =~ /^(\S+)\s*(.*)/;
  $nap->private_message($nick,$msg);
  print "* you tell $nick: $msg\n";
}

sub print_search_results {
  my $counter=0;
  for my $song (@SEARCH) {
    (my $link = $song->link) =~ s/^LINK_//;
    printf "%3d. %-18s %-3dkbps %-3.1fM  %-8s %-50s\n",
       ++$counter,$song->owner,$song->bitrate,$song->size/1E6,$link,$song->name;
  }
}

sub search {
  my $args = shift;
  undef @SEARCH;
  $COUNTER = 0;
  print "[ searching... ]\n";
  @SEARCH = sort {
    $a->owner cmp $b->owner
      || $a cmp $b } $nap->search($args);
  print_search_results;
  print "[ search done. ",scalar @SEARCH," songs found ]\n";
}

sub browse {
  my $args = shift;
  undef @SEARCH;
  $COUNTER = 0;
  print "[ browsing... ]\n";
  @SEARCH = sort {$a cmp $b} $nap->browse($args);
  print_search_results();
  print "[ browse done. ",scalar @SEARCH," songs found ]\n";
}

sub download {
  my $args = shift;
  my $fh = shift;
  my (@num) = $args =~ /(\d+)/g;
  unless (@num) {
    print "[ usage: download <song_no> <song_no> <song_no>.... ]\n";
    return;
  }
  foreach (@num) {
    my $index = $_-1;
    my $song = $SEARCH[$index];
    unless ($song) {
      print "[ $_: No such song identified on last search ]\n";
      return;
    }
    if (my $d = $song->download($fh)) {
      $d->interval(200000);  # set reporting interval
      print "[ $song: starting download ]\n";
    } else {
      print "[ $song: ",$nap->error," ]\n";
    }
  }
}

sub play {
  my $args = shift;
  my $fh = IO::File->new('|' . PLAYER);
  print "[ Couldn't open player ".PLAYER.": $! ] \n" unless $fh;
  download($args,$fh);
}

# print download status
sub status {
  my $p;
  for my $t ($nap->transfers) {
    $p++;
    my $song = $t->song;
    my $status = $t->status;
    my $label = $t->direction eq 'upload' ? 'uploading to '.$t->nickname
                                          : 'downloading from '.$song->owner;
    print "[ ($label) $song: $status, ",$t->bytes,"/",$t->expected_size," bytes ]\n";
  }
  print "[ no uploads/downloads in progress ]\n" unless $p;
}

# abort
sub abort {
  my $args = shift;
  $args ||= '.';  # by default, abort 'em all
  for my $d ($nap->downloads) {
    my $song = $d->title;
    next unless $d =~ /$args/;
    print "[ $song: aborting ]\n";
    $d->done(1);
  }
}

# boot uploads
sub boot {
  my $args = shift;
  $args ||= '.';  # by default, abort 'em all
  for my $d ($nap->uploads) {
    my $song = $d->title;
    next unless $d =~ /$args/;
    print "[ $song: aborting ]\n";
    $d->done(1);
  }
}

sub whois {
  my $args = shift;
  foreach my $u (split /\s+/,$args) {
    $u = $SEARCH[$u-1]->owner 
      if $u =~ /^\d+/ && defined $SEARCH[$u-1];
    if (my $user = $nap->whois($u)) {
      my $profile = $user->profile;
      $profile =~ s/^/\t/gm;
      print $profile,"\n";
    } else {
      print "[ $u: ",$nap->error," ]\n";
    }
  }
}

sub ping {
  my $args = shift;
  return unless my @users = split /\s+/,$args;
  @users = map { lc(/^\d+$/ && defined $SEARCH[$_-1] ? $SEARCH[$_-1]->owner : $_)} @users;
  my $timing = $nap->ping(\@users,10);
  foreach (keys %$timing) {
    print " [ $_: $timing->{$_}s ]\n";
  }
  my %lc = map {lc($_)=>1} keys %$timing;
  print " [ $_: NOT pingable ]\n" foreach grep {!$lc{lc($_)}} @users;
}

sub help {
  print <<END;
  COMMANDS: 
       /channels                      list channels
       /join <chan1> <chan2>...       join channel(s)  
       /users                         list users in current channel
       /msg <nickname>                send private message to user
       /whois <nickname>              get info on user
       /finger <nickname>             same as /whois
       /browse <nickname>             browse user's shared songs
       /search <keywords>             search for a song
       /download <18> <20> <3>        download songs 18, 20 and 3
       /g <18> <20> <3>               same as /download
       /play <18> <20> <3>            play songs 18, 20 and 3 (requires mpg123 installed)
       /abort <regexp>                abort downloads matching regular expression (default all)
       /boot <regexp>                 abort uploads matching regular expression (default all)
       /status                        status of uploads/downloads
       /ping <nickname>               ping a user
       /quit                          outta here
END
;

}

############ callbacks #################
# callbacks
sub setup_callbacks {
  my $nap = shift;

  my $user_speaks = sub { 
    my ($nap,$message) = @_;
    my ($channel,$nickname,$mess) = $message =~/^(\S+) (\S+) (.*)/;
    print "[$channel] <$nickname> $mess\n";
  };

  my $private_msg = sub { 
    my ($nap,$message) = @_;
    my ($nickname,$mess) = $message =~/^(\S+) (.*)/;
    print "$nickname tells you: $mess\n";
  };

  my $user_joins = sub {
    my ($nap,$user) = @_;
    my $channel = $user->current_channel;
    my $sharing = $user->sharing;
    my $link    = $user->link;
    print "* $user joins $channel: sharing $sharing files on a $link line\n";
  };
  
  my $user_exits = sub {
    my ($nap,$user) = @_;
    my $channel = $user->current_channel;
    print "* $user has left $channel\n";
  };
  
  my $list_channel = sub {
    my ($nap,$channel) = @_;
    printf "[ %-15s %-40s %3d users ]\n",$channel,$channel->topic,$channel->user_count;
  };
  
  my $channel_topic = sub {
    my ($nap,$message) = @_;
    my ($channel,$banner) = $message =~ /^(\S+) (.*)/;
    print "[ \U$channel\E: $banner ]\n";
  };
  
  my $stats =  sub { 
    my ($users,$files,$gigs) = split /\s+/,$_[1];
    print "\t** SERVER STATS: $files files, $users users, ($gigs gigs) **\n";
  };

  my $transfer_started = sub { 
    my ($nap,$transfer) = @_;
    return unless $transfer->direction eq 'upload';
    my $song = $transfer->song;
    my $nick = $transfer->remote_user;
    print "\t[ $nick has begun to download $song ]\n";
  };
  
  my $transfer_progress = sub { 
    my ($nap,$transfer) = @_;
    my ($bytes,$expected) = ($transfer->bytes,$transfer->expected_size);
    print "\t[ $transfer: $bytes / $expected bytes ]\n";
  };
  
  my $transfer_done = sub { 
    my ($nap,$transfer) = @_;
    my $song = $transfer->song;
    print "\t[ $song done: ",$transfer->status," ]\n";
    if ($transfer->direction eq 'download' &&
	$transfer->status ne 'transfer complete' && 
	$transfer->local_path) {
      print "\t[ $song incomplete: unlinking file ]\n";
      unlink $transfer->local_path;
    }
  };

  my $error = sub {
    my ($nap,$msg) = @_;
    print "* error: $msg\n";
  };
  
  $nap->callback(PUBLIC_MESSAGE_RECVD,$user_speaks);
  $nap->callback(PRIVATE_MESSAGE,     $private_msg);
  $nap->callback(USER_JOINS,          $user_joins);
  $nap->callback(USER_DEPARTS,        $user_exits);
  $nap->callback(INVALID_ENTITY,      $error);
  $nap->callback(CHANNEL_ENTRY,       $list_channel);
  $nap->callback(CHANNEL_TOPIC,       $channel_topic);
  $nap->callback(SERVER_STATS,        $stats);
  $nap->callback(TRANSFER_STARTED,    $transfer_started);
  $nap->callback(TRANSFER_IN_PROGRESS,$transfer_progress);
  $nap->callback(TRANSFER_DONE,       $transfer_done);
  $nap->callback(MOTD,                sub { print defined $_[1] ? "* $_[1]\n" : "\n"; } );
  $nap->callback(PING,                sub { print "* $_[1] is pinging us\n"; } );
  $nap->callback(PONG,                sub { print "* Got a PONG from $_[1]\n"; } );
  $nap->callback(USER_OFFLINE,        sub { print "* $_[1] is offline\n"; } );
  $nap->callback(SET_DATA_PORT,       sub { print "* Changing data port to $_[1]\n"; } );
  $nap->callback(DATA_PORT_ERROR,     sub { print "* Server: data port is misconfigured\n"; } );
}
__END__
!NO!SUBS!
close OUT or die "Can't close $file: $!";
chmod 0755, $file or die "Can't reset permissions for $file: $!\n";
exec("$Config{'eunicefix'} $file") if $Config{'eunicefix'} ne ':';
chdir $origdir;
