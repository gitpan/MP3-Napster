#!/usr/bin/perl

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
use lib './blib/lib','../blib/lib';
use IO::Handle;
use FindBin qw($Bin);

######################### We start with some black magic to print on failure.
BEGIN { $| = 1; print "1..47\n"; }
END {print "not ok 1\n" unless $loaded;}
use MP3::Napster;
$loaded = 1;
print "ok 1\n";
######################### End of black magic.

my $test_num = 2;
sub test ($;$) {
    local($^W) = 0;
    my($true,$msg) = @_;
    print($true ? "ok $test_num\n" : "not ok $test_num $msg\n");
    $test_num++;
}

$| = 1;

my $SONG1 = 'meow.mp3';
my $SONG2 = 'bark.mp3';
my %SHARENAMES;

# Advanced tests of functionality.  Requires the miniserver.pl script to be running.
my $miniserver = "$Bin/../eg/miniserver.pl";
open(SERVER,"$miniserver -1 2>./miniserver.log |") || die "Can't start miniserver for testing";

my $line = <SERVER>;
my ($server_pid,$socket) = $line =~ /process=(\d+).+port=(\d+)/
  or die "couldn't get port and pid number for miniserver";

my $nap1 = MP3::Napster->new("127.0.0.1:$socket");

#2
test($nap1,"Can't connect");

#3
test($nap1->login('lstein','phonypassword',LINK_DSL),"Can't login");

#4
test($nap1->listen(-1),"Can't listen");

#5
test(scalar($nap1->channels),"Can't list channels");

my $user = $nap1->whois('lstein');

#6
test($user eq 'lstein',"whois failed");

#7
test($user && $user->link eq 'DSL',"whois failed");

#8
test($user->downloads==0,"download count incorrect");

#9
test($nap1->join_channel('Alternative'),"Can't join");

#10
my @users = $nap1->users;
test(@users==1,"wrong user count");

#11
my @songs = $nap1->browse('lstein');
test(@songs==0,"found some songs on browse, but shouldn't");

#12
@songs = $nap1->search('Le Chat');
test(@songs==0,"found some songs on search, but shouldn't");

# create a new client
#13
my $nap2 = MP3::Napster->new("127.0.0.1:$socket");
test($nap2,"Can't connect");

#14
test($nap2->login('plugh','xyzzy',LINK_T3),"Can't login");

#15
test($nap2->listen(-1),"Can't listen");

# share a couple of songs
#16
test($SHARENAMES{$SONG1} = $nap2->share("$Bin/../mp3s/$SONG1"));

#17
test($SHARENAMES{$SONG2} = $nap2->share("$Bin/../mp3s/$SONG2"));

# give server a chance to register new uploads...
sleep 1;

# can first user see second user's songs?
#18
@songs = $nap1->browse('plugh');
test(@songs==2,"first user can't see second user's songs");

#19
test(@songs && $songs[0]->owner eq 'plugh',"error getting song info");

#20
test(@songs && $songs[0]->bitrate == 128,"error getting song bitrate");

#21
@songs = $nap1->search('Chat');
test(@songs==1,"song search error");

# Log in a third user.  This one will be firewalled (no listening port)
#22
my $nap3 = MP3::Napster->new("127.0.0.1:$socket");
test($nap3,"Can't connect");

#23
test($nap3->login('firewall','xyzzy',LINK_T3),"Can't login");

# everyone joins the alternative channel
#24
test($nap1->join_channel('Alternative'),"Can't join channel 1");

#25
test($nap2->join_channel('Alternative'),"Can't join channel 2");

#26
test($nap3->join_channel('Alternative'),"Can't join channel 3");

#27
test((@users=$nap1->users()) == 3,"wrong user count");
my ($self) = grep { $nap1->nickname eq $_ } @users;

#28
test($self->ping,"can't ping");

#29
# firewalled user now shares the doggy file
test($SHARENAMES{$SONG2} = $nap3->share("$Bin/../mp3s/$SONG2","nap3 can't share song"));


# test callbacks
# this is awkward -- need to create a pipe for IPC and run nap2 and nap3
# as separate processes
pipe(READER,WRITER) or die "pipe failed, test aborted: $!";
WRITER->autoflush(1);
$nap2->callback(PUBLIC_MESSAGE,
		sub {my($nap,$code,$message)=@_;
		     print WRITER "nap2: $message\n"});

$nap3->callback(PUBLIC_MESSAGE,
		sub {my($nap,$code,$message)=@_;
		     print WRITER "nap3: $message\n"});

my($child2,$child3);
defined($child2 = fork()) or die "fork1 failed, test aborted: $!";
if ($child2 == 0) {
  close READER;
  $nap2->run;
  exit 0;
}

defined($child3 = fork()) or die "fork2 failed, test aborted: $!";
if ($child3 == 0) {
  close READER;
  $nap3->run;
  exit 0;
}

close WRITER;

#30
test($nap1->public_message("Hey there, how are you!"),"can't send public message");
my ($lines);
eval {
  local $SIG{ALRM} = sub { die 'timeout' };
  alarm(5);
  $lines .= <READER>;
  $lines .= <READER>;
};
alarm(0);

#31
test($lines =~ /nap2: Alternative lstein Hey there/,"nap2 didn't get public message");

#32
test($lines =~ /nap3: Alternative lstein Hey there/,"nap3 didn't get public message");

# test file transfer from non-firewall to non-firewall
mkdir './tmp',0777;

#33
test($nap1->download_dir('./tmp'),"couldn't set download directory");

#34
@songs = $nap1->search('Le Chat');
test(@songs==1,"search failed");

#35
test(my $d = $songs[0]->download,"active download failed");

#36
test($nap1->downloads == 1,"download list failed");

#37
$nap1->wait_for(TRANSFER_DONE,15);
test(defined $d && $d->done,"file transfer not done, but should be");

#38
test(defined $d && $d->status eq 'transfer complete',"file transfer incomplete, but should be");

#39
test(-e "./tmp/$SHARENAMES{$SONG1}","file wasn't created properly");

#40
test(-s "./tmp/$SHARENAMES{$SONG1}" == -s "$Bin/../mp3s/$SONG1","file corrupted or truncated in transit");

#41
@songs = $nap1->browse('firewall');
test(@songs==1,"nap1 can't browse nap3's files");

#42
test($d = $songs[0]->download,"passive (firewalled) download failed");

#43
test($nap1->downloads == 1,"download list failed");

#44
$nap1->wait_for(TRANSFER_DONE,15);
test($d->done,"file transfer not done, but should be");

#45
test($d->status eq 'transfer complete',"file transfer incomplete, but should be");

#46
test(-e "./tmp/$SHARENAMES{$SONG2}","file wasn't created properly");

#47
test(-s "./tmp/$SHARENAMES{$SONG2}" == -s "$Bin/../mp3s/$SONG2","file corrupted or truncated in transit");

END { 
  kill 'TERM' => $server_pid if defined $server_pid;
  foreach ($SONG1,$SONG2) {
    unlink "./tmp/$SHARENAMES{$_}" if -e "./tmp/$SHARENAMES{$_}";
  }
  rmdir "./tmp" if -d "./tmp";
}



