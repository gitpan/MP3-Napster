#!/usr/bin/perl

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
use lib './blib/lib','../blib/lib';
use FindBin qw($Bin);

######################### We start with some black magic to print on failure.
BEGIN { $| = 1; print "1..50\n"; }
END {print "not ok 1\n" unless $loaded;}
use MP3::Napster;
$loaded = 1;
print "ok 1\n";
######################### End of black magic.

my $test_num = 2;
sub test {
    local($^W) = 0;
    my($true,$msg) = @_;
    print($true ? "ok $test_num\n" : "not ok $test_num $msg\n");
    $test_num++;
}

$| = 1;

my $SONG1 = 'meow.mp3';
my $SONG2 = 'bark.mp3';
my %SHARENAMES;
$MP3::Napster::DEBUG_LEVEL = 0;

# Advanced tests of functionality.  Requires the miniserver.pl script to be running.
my $miniserver = "$Bin/../eg/miniserver.pl";
open(SERVER,"$miniserver -1 2>./miniserver.log |") || die "Can't start miniserver for testing";

my $line = <SERVER>;
my ($server_pid,$socket) = $line =~ /process=(\d+).+port=(\d+)/
  or die "couldn't get port and pid number for miniserver";

my $nap1 = MP3::Napster->new("127.0.0.1:$socket");
test($nap1,"Can't connect");
test($nap1->login('lstein','phonypassword',LINK_DSL),"Can't login");
test($nap1->listen(-1),"Can't listen");
test(scalar($nap1->channels),"Can't list channels");

my $user = $nap1->whois('lstein');
test($user eq 'lstein',"whois failed");
test($user && $user->link eq 'DSL',"whois failed");
test($user->downloads==0,"download count incorrect");

test($nap1->join_channel('Alternative'),"Can't join");
my @users = $nap1->users;
test(@users==1,"wrong user count");

my @songs = $nap1->browse('lstein');
test(@songs==0,"found some songs on browse, but shouldn't");

@songs = $nap1->search('Le Chat');
test(@songs==0,"found some songs on search, but shouldn't");

# create a new client
my $nap2 = MP3::Napster->new("127.0.0.1:$socket");
test($nap2,"Can't connect");
test($nap2->login('plugh','xyzzy',LINK_T3),"Can't login");
test($nap2->listen(-1),"Can't listen");

# share a couple of songs
test($SHARENAMES{$SONG1} = $nap2->share("$Bin/../songs/$SONG1"));
test($SHARENAMES{$SONG2} = $nap2->share("$Bin/../songs/$SONG2"));

# give server a chance to register new uploads...
sleep 1;

# can first user see second user's songs?
@songs = $nap1->browse('plugh');
test(@songs==2,"first user can't see second user's songs");
test(@songs && $songs[0]->owner eq 'plugh',"error getting song info");
test(@songs && $songs[0]->bitrate == 128,"error getting song bitrate");

@songs = $nap1->search('Chat');
test(@songs==1,"song search error");

# can first user ping second user?
test($nap1->ping('plugh'),"first user can't ping second user");

# Log in a third user.  This one will be firewalled (no listening port)
my $nap3 = MP3::Napster->new("127.0.0.1:$socket");
test($nap3,"Can't connect");
test($nap3->login('firewall','xyzzy',LINK_T3),"Can't login");

# everyone joins the alternative channel
test($nap1->join_channel('Alternative'),"Can't join channel 1");
test($nap2->join_channel('Alternative'),"Can't join channel 2");
test($nap3->join_channel('Alternative'),"Can't join channel 3");
test((@users=$nap1->users()) == 3,"wrong user count");
test(@users && $users[0]->ping,"can't ping");

# test callbacks
my ($msg1,$msg2);
$nap2->callback(PUBLIC_MESSAGE_RECVD,
		sub {my($nap,$message)=@_;
		     $msg1 = $message});
$nap3->callback(PUBLIC_MESSAGE_RECVD,
		sub {my($nap,$message)=@_;
		     $msg2 = $message});
test($nap1->public_message("Hey there, how are you!"),"can't send public message");
sleep 1;

test($msg1,"nap2 didn't get public message");
test($msg2,"nap3 didn't get public message");
test($msg1 eq $msg2,"public messages don't match");
test($msg1 =~ /^lstein Alternative Hey there/,"public message corrupted");

# test file transfer from non-firewall to non-firewall
mkdir './tmp',0777;
test($nap1->download_dir('./tmp'),"couldn't set download directory");
@songs = $nap1->search('Le Chat');
test(@songs==1,"search failed");

test(my $d = $songs[0]->download,"active download failed");
test($nap1->downloads == 1,"download list failed");
$nap1->wait_for(TRANSFER_DONE,15);
test($d->done,"file transfer not done, but should be");
test($d->status eq 'transfer complete',"file transfer incomplete, but should be");
test(-e "./tmp/$SHARENAMES{$SONG1}","file wasn't created properly");
test(-s "./tmp/$SHARENAMES{$SONG1}" == -s "$Bin/../songs/$SONG1","file corrupted or truncated in transit");

# firewalled user now shares the doggy file
test($SHARENAMES{$SONG2} = $nap3->share("$Bin/../songs/$SONG2","nap3 can't share song"));

# wait for it to take effect
sleep 1;

@songs = $nap1->browse('firewall');
test(@songs==1,"nap1 can't browse nap3's files");
test($d = $songs[0]->download,"passive (firewalled) download failed");
test($nap1->downloads == 1,"download list failed");
$nap1->wait_for(TRANSFER_DONE,15);
test($d->done,"file transfer not done, but should be");
test($d->status eq 'transfer complete',"file transfer incomplete, but should be");
test(-e "./tmp/$SHARENAMES{$SONG2}","file wasn't created properly");
test(-s "./tmp/$SHARENAMES{$SONG2}" == -s "$Bin/../songs/$SONG2","file corrupted or truncated in transit");

END { 
  $nap1->disconnect(5) if defined $nap1;
  $nap2->disconnect(5) if defined $nap2;
  $nap3->disconnect(5) if defined $nap3;
  kill 'TERM' => $server_pid if defined $server_pid;
  foreach ($SONG1,$SONG2) {
    unlink "./tmp/$SHARENAMES{$_}" if -e "./tmp/$SHARENAMES{$_}";
  }
  rmdir "./tmp" if -d "./tmp";
}



