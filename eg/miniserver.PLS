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
# teeny tiny napster server for use in regression tests

use strict;
require 5.6.0;
use IO::Select;
use IO::Socket;

use Errno 'EWOULDBLOCK';

my $PORT = shift || 9999;

use constant ERROR => 0;
use constant LOGIN => 2;
use constant LOGIN_ACK => 3;
use constant NEW_LOGIN  => 6;
use constant REGISTER  => 7;
use constant NICKNAME_OK => 8;
use constant ALREADY_REGISTERED => 9;
use constant BAD_NICKNAME => 10;
use constant PERMISSION_DENIED => 11;
use constant LOGIN_ERROR => 13;
use constant I_HAVE => 100;
use constant REMOVE => 102;
use constant SEARCH => 200;
use constant SEARCH_RESPONSE => 201;
use constant SEARCH_RESPONSE_END => 202;
use constant DOWNLOAD_REQ => 203;
use constant DOWNLOAD_ACK => 204;
use constant PRIVATE_MESSAGE      => 205;
use constant GET_ERROR    => 206;
use constant BROWSE_REQ => 211;
use constant BROWSE_RESPONSE => 212;
use constant BROWSE_RESPONSE_END => 213;
use constant UPLOADING          => 220;
use constant UPLOAD_COMPLETE    => 221;
use constant DOWNLOADING        => 218;
use constant DOWNLOAD_COMPLETE  => 219;
use constant JOIN_CHANNEL        => 400;
use constant PART_CHANNEL        => 401;
use constant SEND_PUBLIC_MESSAGE  => 402;
use constant PUBLIC_MESSAGE_RECVD => 403;
use constant JOIN_ACK            => 405;
use constant USER_JOINS          => 406;
use constant USER_DEPARTS        => 407;
use constant INVALID_ENTITY      => 404;
use constant CHANNEL_USER_ENTRY  => 408;
use constant CHANNEL_USER_END    => 409;
use constant CHANNEL_TOPIC       => 410;
use constant PASSIVE_DOWNLOAD_REQ => 500;
use constant UPLOAD_REQ => 501;
use constant PASSIVE_UPLOAD_REQ => 607;
use constant UPLOAD_ACK => 608;
use constant WHOIS_REQ  => 603;
use constant WHOIS_RESPONSE => 604;
use constant WHOWAS_RESPONSE=> 605;
use constant PASSIVE_UPLOAD_REQUEST => 607;
use constant LIST_CHANNELS => 617;
use constant CHANNEL_LIST_ENTRY => 618;
use constant USER_OFFLINE       => 620;
use constant MOTD               => 621;
use constant CHANGE_DATA_PORT   => 703;
use constant PING               => 751;
use constant PONG               => 752;
use constant LIST_CHANNELS2     => 827;
use constant LIST_USERS         => 830;
use constant USER_LIST_ENTRY    => 825;

sub dispatch($\$);

# this test server uses globals instead of objects.  oh well.
my (%REGISTRATION,%NICKNAMES,%SHARED,%USER_INDEX,%MD5_INDEX,%CHANNEL_USERS);

my %CHANNELS = (
		'Hiphop'      => 'The horny adolescents channel',
		'Alternative' => 'The horny adolescents-looking-for-cybersex channel',
		'Classical'   => 'The completely empty channel',
		'Lobby'       => 'The "what do the colored dots mean?" channel',
		);
my $MOTD = <<END;
Welcome to the teeny tiny napster server.
Anything goes here because nothing\'s happening!
END
;
my %STAT_CODES = (
		  UPLOADING()         => 1,
		  UPLOAD_COMPLETE()   => 1,
		  DOWNLOADING()       => 1,
		  DOWNLOAD_COMPLETE() => 1,
		  );
my (%IN,%OUT,%FH);  # buffers
# tie %IN,'Tie::RefHash';  # so we can use references as keys
# tie %OUT,'Tie::RefHash';

$SIG{INT} = sub { exit 1; };

$|=1;
my @args = (Listen => 20,
	    Proto => 'tcp',
	    Reuse => 1);
push(@args,LocalPort => $PORT) if $PORT > 0;
my $listen = IO::Socket::INET->new(@args) || die "Can't open listen socket: $!";
$listen->blocking(0);

print "miniserver process=$$ listening on port=",$listen->sockport,"\n";

my $in  = IO::Select->new($listen);
my $out = IO::Select->new;

my $t = 0;

while (1) {
  warn "polling...",$t++,"\n";
  my ($readers,$writers) = IO::Select->select($in,$out,undef);

  for my $r (@$readers) {

    if ($r eq $listen) {
      my $newsock = $r->accept or next;
      $newsock->blocking(0);
      new_connection($newsock);
      $in->add($newsock);
      next;
    } else {
      my $ok = 0;
      my $bytes = sysread($r,$IN{$r},2048,length $IN{$r});
      if ($bytes > 0) {
	$ok = dispatch($r,$IN{$r});
      } elsif (!defined($bytes) && $! == EWOULDBLOCK) {
	next;
      }
      unless ($ok) {
	warn $r->peerhost,": $!";
	$in->remove($r);
	clean_up($r);
      }
    }
  }

  for my $w (@$writers) {
    next unless $OUT{$w};
    local $SIG{PIPE} = 'IGNORE';
    my $bytes = syswrite($w,$OUT{$w});
    if ($bytes > 0) {
      substr($OUT{$w},0,$bytes) = '';
    } elsif (!$bytes) {
      next if !defined($bytes) && $! == EWOULDBLOCK;
    } else {
      # a pipe or some other type of error occurred
      warn $w->peerhost,": $!";
      $out->remove($w);
      clean_up($w);
    }
    $out->remove($w) unless length $OUT{$w};
    $in->add($w)     if length $OUT{$w} < 10_000;
  }

  # fix up the select objects
  foreach (keys %OUT) {
    $out->add($FH{$_})    if length $OUT{$_} > 0;
    $in->remove($FH{$_})  if length $OUT{$_} >= 10_000;
  }

}

sub new_connection {
  my $sock = shift;
  warn "accepted a new connection from ",$sock->peerhost;
  $IN{$sock} = '';
  $OUT{$sock} = '';
  $FH{$sock} = $sock;
}

sub dispatch ($\$) {
  my ($sock,$buffer) = @_;

  while (length $$buffer >= 4) { # message length
    my $body;
    my ($length,$event) = unpack("vv",$$buffer);
    if ($length > 0) { # try to get body
      last unless length $$buffer >= 4+$length;
      $body = substr($$buffer,4,$length);
    }
    substr($$buffer,0,4+$length) = '';
    return unless do_event($sock,$event,$body);
  }
  1;
}

sub do_event {
  my ($sock,$type,$data) = @_;
  warn "processing $type message from ",$sock->peerhost,"\n";

  return login($sock,$data)          if $type == LOGIN or $type == NEW_LOGIN;
  return register($sock,$data)       if $type == REGISTER;
  return whois($sock,$data)          if $type == WHOIS_REQ;
  return share_song($sock,$data)     if $type == I_HAVE;
  return unshare_song($sock,$data)   if $type == REMOVE;
  return browse($sock,$data)         if $type == BROWSE_REQ;
  return search($sock,$data)         if $type == SEARCH;

  # downloads where downloader will initiate request to uploader
  return download_req($sock,$data)   if $type == DOWNLOAD_REQ;
  return download_ack($sock,$data)   if $type == UPLOAD_ACK;
  return permission_denied($sock,$data)  if $type == PERMISSION_DENIED;

  # downloads where uploader will initiate request to download
  return passive_download_req($sock,$data)   if $type == PASSIVE_DOWNLOAD_REQ;

  # update upload/download stats
  return update_stats($sock,$type)    if $STAT_CODES{$type};

  return set_data_port($sock,$data)  if $type == CHANGE_DATA_PORT;
  return list_channels($sock,$data)  if $type == LIST_CHANNELS;
  return list_channels($sock,$data)  if $type == LIST_CHANNELS2;
  return join_channel($sock,$data)   if $type == JOIN_CHANNEL;
  return part_channel($sock,$data)   if $type == PART_CHANNEL;
  return list_users($sock,$data)     if $type == LIST_USERS;
  return send_public($sock,$data)    if $type == SEND_PUBLIC_MESSAGE;
  return send_private($sock,$data)    if $type == PRIVATE_MESSAGE;

  return ping_pong($sock,$type,$data)  if $type == PING or $type == PONG;

  warn "Can't handle message $type";
  return 1;
}

sub nickname {
  my $sock = shift;
  $NICKNAMES{fileno $sock} = shift if @_;
  return $NICKNAMES{fileno $sock};
}

sub registration {
  my $nickname = shift;
  $REGISTRATION{$nickname} = shift if @_;
  return $REGISTRATION{$nickname};
}

sub shared {
  my $nickname = shift;
  my $path = shift;
  $SHARED{$nickname,$path} = shift if @_;
  return $SHARED{$nickname,$path};
}

sub md5_index {
  my ($nickname,$path,$md5) = @_;
  $MD5_INDEX{$md5}{$nickname,$path}++;
}

sub user_index {
  my ($nickname,$path) = @_;
  $USER_INDEX{$nickname}{$path} = join $;,$nickname,$path;
}

sub register {
  my ($sock,$nick) = @_;
  if (registration($nick)) {
      msg($sock,ALREADY_REGISTERED);
  } elsif ($nick=~/\s/) {
      msg($sock,BAD_NICKNAME);
  } else {
      msg($sock,NICKNAME_OK);
  }
  1;
}

sub login {
  my ($sock,$data) = @_;
  my ($nickname,$password,$p,$version,$link_type,$email) = 
    $data =~ /^(\S+) (\S+) (\d+) "([^\"]+)" (\d+) ?(.*)$/;

  my ($port,$addr) = sockaddr_in(getpeername $sock);

  if (my $r = registration($nickname)) { # already registered ?
    if ($r->{port} != $port || $r->{addr} ne $addr) {
      msg($sock,
	  LOGIN_ERROR,
	  "you are already logged in from elsewhere; closing connection");
      return;  # undef kills connection
    }
  }

  warn "$nickname is logging in";
  nickname($sock,$nickname);  # register user

  registration($nickname,
	       { port      => $port,
		 addr      => unpack("V",$addr),
		 version   => $version,
		 link_type => $link_type,
		 port      => 0,
		 socket    => $sock,
		 time      => time(),
		 uploads   => 0,
		 downloads => 0,
		 channels  => {},
	       }
	      );
  $USER_INDEX{$nickname} = {};
  msg($sock,LOGIN_ACK,'anon@napster.com');

  # send the MOTD
  foreach (split "\n",$MOTD) {
    msg($sock,MOTD,$_);
  }

  1;
}

sub clean_up {
  my $sock = shift;
  warn $sock->peerhost,' is exiting';
  return unless my $nickname = nickname($sock);
  unshare_all($nickname);  # get rid of all shared songs
  part_all($sock,$nickname);     # part all channels
  delete $REGISTRATION{$nickname};
  delete $NICKNAMES{fileno $sock};
  delete $OUT{$sock};
  delete $IN{$sock};
  delete $FH{$sock}
}

sub msg {
  my $sock = shift;
  my ($msg,$data) = @_;
  warn "sending $msg\n";
  $data ||= '';
  my $length = length $data;
  my $message_data = pack("vva*",$length,$msg,$data);
  $OUT{$sock} .= $message_data;
  1;
}

sub set_data_port {
  my $sock = shift;
  my $port = shift;
  my $nick = nickname($sock) or return 1;

  $REGISTRATION{$nick}{port} = $port;
  warn "changed port for $nick to $port\n";
}

sub whois {
  my ($sock,$nickname) = @_;
  my $nick = nickname($sock);

  my $r = registration($nickname);
  return msg($sock,INVALID_ENTITY,$nickname) unless $r;

  my $login_time = time - $r->{time};
  my $shared     = scalar keys %{$USER_INDEX{$nickname}};
  my $channels   = join ' ',keys %{$r->{channels}};
  msg( $sock,
       WHOIS_RESPONSE,
       qq($nickname "User" $login_time "$channels" "Active" $shared $r->{downloads} $r->{uploads} $r->{link_type} "$r->{version}")
     );
}

sub list_channels {
  my ($sock,$data) = @_;
  warn "list channels request";
  for my $channel (sort keys %CHANNELS) {
    my $users = keys %{$CHANNEL_USERS{$channel}};
    msg ($sock,
	 CHANNEL_LIST_ENTRY,
	 "$channel $users $CHANNELS{$channel}"
	 );
  }
  msg( $sock,LIST_CHANNELS);
}

sub share_song {
  my ($sock,$data) = @_;
  return 1 unless my ($filename,$md5,$size,$bitrate,$freq,$time) =
    $data =~ /^"([^\"]+)" (\S+) (\d+) (\d+) (\d+) (\d+)$/;
  my $nickname = nickname($sock);
  shared($nickname,$filename,$data);    # add to shared list
  md5_index($nickname,$filename,$md5);  # add to index by md5
  user_index($nickname,$filename);      # add to index by user
  return 1;
}

sub unshare_song {
  my ($sock,$path) = @_;
  return 1 unless my $nickname = nickname($sock);

  return 1 unless my $shared = $USER_INDEX{$nickname}{$path};
  delete $USER_INDEX{$nickname}{$path};
  my $song_data = $SHARED{$nickname,$path};
  delete $SHARED{$nickname,$path};

  my ($md5) = $song_data =~ /^.+\" (\S+)/;
  delete $MD5_INDEX{$md5}{$nickname,$path};
  return 1;
}

sub unshare_all {
  my $nickname = shift;

  return unless $USER_INDEX{$nickname};

  foreach my $path (keys %{$USER_INDEX{$nickname}}) {
    my $song_data = $SHARED{$nickname,$path};
    my ($md5) = $song_data =~ /^.+\" (\S+)/;
    delete $MD5_INDEX{$md5}{$nickname,$path};
    delete $SHARED{$nickname,$path};
  }
  delete $USER_INDEX{$nickname};
}

sub browse {
  my ($sock,$nickname) = @_;

  return msg($sock,USER_OFFLINE,$nickname) unless registration($nickname);

  my @shared = values %{$USER_INDEX{$nickname}};
  for my $key (@shared) {
    next unless my $data = $SHARED{$key};
    msg($sock,BROWSE_RESPONSE,"$nickname $data");
  }
  msg($sock,BROWSE_RESPONSE_END);
}

sub search {
  my ($sock,$data) = @_;
  my ($pattern) = $data =~ /FILENAME CONTAINS "([^\"]+)"/;
  warn "searching for $pattern";

  # we just implement the keyword search
  foreach (keys %SHARED) {
    my ($nick,$path) = split $;;
    next unless $path =~ /\b$pattern\b/i;  # match on word boundaries
    # get user info
    next unless my $user = registration($nick);
    my ($ip,$link_type) = @{$user}{qw(addr link_type)};
    msg($sock,SEARCH_RESPONSE,"$SHARED{$_} $nick $ip $link_type");
  }
  msg($sock,SEARCH_RESPONSE_END);
}

sub ping_pong {
  my ($sock,$type,$user) = @_;
  my $nick = nickname($sock);

  my $d = $type == PING ? 'PING' : 'PONG';
  warn "$d: $nick => $user\n";

  # lookup user
  my $r = registration($user);
  return msg($sock,USER_OFFLINE,$user) unless $r;
  
  # get user's socket
  my $users_sock = $r->{socket};
  return msg($sock,USER_OFFLINE,$user) 
    unless $sock && $sock->connected;

  msg($users_sock,$type,$nick);
}

# This is confusing.  The download request
sub download_req {
  my ($sock,$data) = @_;
  my $nick = nickname($sock);
  warn "nickname = $nick\n";

  my ($user,$sharename) = $data =~ /^(\S+) "([^\"]+)"$/;

  my $r = registration($user);
  return msg($sock,USER_OFFLINE,qq($user "$sharename")) unless $r;

  return msg($sock,GET_ERROR,"$user is not sharing $sharename") 
    unless my $song_data = $SHARED{$user,$sharename};

  return msg($sock,USER_OFFLINE,$data) unless $r->{socket}->connected;

  # ask the lucky recipient for permission to do an upload
  msg($r->{socket},PASSIVE_UPLOAD_REQUEST,qq($nick "$sharename"));
}

# this comes back from remote client when it acknowledges a download request
# message contains requestor's name and the sharename
sub download_ack {
  my ($sock,$data) = @_;
  my $nick = nickname($sock);
  my ($user,$sharename) = $data =~ /^(\S+) "([^\"]+)"$/;

  my $u = registration($user);
  return msg($sock,USER_OFFLINE,$user) unless $u;

  my $r = registration($nick);

  return msg($sock,GET_ERROR,"you are not sharing $sharename") 
    unless my $song_data = $SHARED{$nick,$sharename};
  my ($md5) = $song_data =~ /^.+\" (\S+)/;

  # tell the downloader to go ahead
  msg($u->{socket},DOWNLOAD_ACK,qq($nick $r->{addr} $r->{port} "$sharename" $md5 $r->{link_type}));
}

sub permission_denied {
  my ($sock,$data) = @_;
  my $nick = nickname($sock);
  my ($user,$sharename) = $data =~ /^(\S+) "([^\"]+)"$/;
  my $r = registration($user) || return 1;
  msg($r->{socket},GET_ERROR,qq($nick "$sharename"));
}

sub passive_download_req {
  my ($sock,$data) = @_;
  my $nick = nickname($sock);  # who is making request
  my($user,$sharename) = $data =~ /^(\S+) "([^\"]+)"$/;

  # ignore this, if the guy isn't registered
  my $r = registration($nick) || return 1;
  
  my $u = registration($user);
  return msg($sock,USER_OFFLINE,$data) unless $u;

  return msg($sock,GET_ERROR,"$user is not sharing $sharename") 
    unless my $song_data = $SHARED{$user,$sharename};

  my ($md5) = $song_data =~ /^.+\" (\S+)/;
  
  # tell the uploader to make an outgoing connection
  msg($u->{socket},
      UPLOAD_REQ,
      qq($nick $r->{addr} $r->{port} "$sharename" $md5 $r->{link_type})
      );

}

sub update_stats {
  my ($sock,$type) = @_;
  my $nick = nickname($sock);
  return unless my $r = registration($nick);
  $r->{uploads}++   if $type == UPLOADING;
  $r->{uploads}--   if $type == UPLOAD_COMPLETE;
  $r->{downloads}++ if $type == DOWNLOADING;
  $r->{downloads}-- if $type == DOWNLOAD_COMPLETE;
  1;
}

sub join_channel {
  my ($sock,$channel) = @_;
  my $nick = nickname($sock)     || return 1;
  my $r    = registration($nick) || return 1;
  return msg($sock,INVALID_ENTITY,$channel) unless $CHANNELS{$channel};
  my $sharing     = keys %{$USER_INDEX{$nick}};
  $CHANNEL_USERS{$channel} ||= {};

  broadcast($channel,USER_JOINS,"$channel $nick $sharing $r->{link_type}");

  # add the user
  $CHANNEL_USERS{$channel}{$nick}++;
  $r->{channels}{$channel}++;

  # acknowledge the join
  msg($sock,JOIN_ACK,$channel);

  # get list of users
  my @users = keys %{$CHANNEL_USERS{$channel}};

  # send a series of user entries
  for my $user (@users) {
    next unless my $u = registration($user);
    my $s = keys %{$USER_INDEX{$user}};
    msg($sock,CHANNEL_USER_ENTRY,"$channel $user $s $u->{link_type}");
  }
  msg($sock,CHANNEL_USER_END);
  msg($sock,CHANNEL_TOPIC,"$channel $CHANNELS{$channel}");
}

sub part_channel {
  my ($sock,$channel) = @_;
  my $nickname = nickname($sock);
  return 1 unless my $r = registration($nickname);
  return 1 unless $r->{channels}{$channel};
  delete $r->{channels}{$channel};
  delete $CHANNEL_USERS{$channel}{$nickname};

  # acknowledge the part
  msg($sock,PART_CHANNEL,$channel);

  # broadcast
  my $sharing     = keys %{$USER_INDEX{$nickname}};
  broadcast($channel,USER_DEPARTS,"$channel $nickname $sharing $r->{link_type}");
  1;
}

sub part_all {
  my ($sock,$nickname) = @_;
  return unless my $r = registration($nickname);
  my @channels = keys %{$r->{channels}};
  foreach (@channels) {
    part_channel($sock,$_);
  }
  1;
}

sub list_users {
  my ($sock,$channel) = @_;
  return msg($sock,INVALID_ENTITY,$channel) unless $CHANNELS{$channel};
  my @users = keys %{$CHANNEL_USERS{$channel}};
  # send a series of user entries
  for my $user (@users) {
    next unless my $u = registration($user);
    my $s = keys %{$USER_INDEX{$user}};
    msg($sock,USER_LIST_ENTRY,"$channel $user $s $u->{link_type}");
  }
  msg($sock,LIST_USERS);
}

sub send_public {
  my ($sock,$data) = @_;
  my ($channel,$text) = $data =~ /^(\S+) (.*)/;
  my $nickname = nickname($sock);
  broadcast($channel,PUBLIC_MESSAGE_RECVD,"$channel $nickname $text");
}

sub send_private {
  my ($sock,$data) = @_;
  my ($user,$text) = $data =~ /^(\S+) (.*)/;
  my $nick = nickname($sock);
  my $u    = registration($user);
  return msg($sock,USER_OFFLINE,$user) unless $u && $u->{socket}->connected;
  msg($u->{socket},PRIVATE_MESSAGE,"$nick $text");
}

# broadcast a message to everyone subscribed to a channel
sub broadcast {
  my ($channel,$msg,$data) = @_;
  my @users = keys %{$CHANNEL_USERS{$channel}};
  foreach (@users) {
    next unless my $r = registration($_);
    next unless $r->{socket} && $r->{socket}->connected;
    # Don't let broadcasts block!
    $r->{socket}->blocking(0);
    msg($r->{socket},$msg,$data);
    $r->{socket}->blocking(1);
  }
  1;
}
__END__
!NO!SUBS!
close OUT or die "Can't close $file: $!";
chmod 0755, $file or die "Can't reset permissions for $file: $!\n";
exec("$Config{'eunicefix'} $file") if $Config{'eunicefix'} ne ':';
chdir $origdir;
