package MP3::Napster;

use strict;
require 5.6.0;  # for IO::Socket fixes
use vars qw($VERSION %FIELDS %RDONLY $LAST_ERROR);
use base qw(MP3::Napster::IOLoop MP3::Napster::Base);
use Carp 'croak';

use MP3::Napster::MessageCodes;
use MP3::Napster::UserCommand;
use MP3::Napster::Server;
use MP3::Napster::User;
use MP3::Napster::Channel;
use MP3::Napster::Registry;
use MP3::Napster::Listener;
use MP3::Napster::PeerToPeer;
use MP3::Napster::TransferRequest;
use Exporter;

$VERSION = '2.01';

%FIELDS = map {$_=>undef} qw(nickname email server channel registry 
			     listener download_dir transfer_timeout attributes
			     allow_setport
			    );
%RDONLY = map {$_=>undef} qw(channel_hash);

use constant DEFAULT_TIMEOUT => 300;  # five minutes to timeout transfers

###############################
# codes to be considered errors
###############################
my %ERRORS = (
	      ERROR,               1,
	      LOGIN_ERROR,         1,
	      GET_ERROR,           1,
	      ALREADY_REGISTERED,  1,
	      INVALID_NICKNAME,    1,
	      INVALID_ENTITY,      1,
	      USER_OFFLINE,        1,
	     );

my %MESSAGE_CONSTRUCTOR = (
			   SEARCH_RESPONSE,      => 'MP3::Napster::Song->new_from_search',
			   BROWSE_RESPONSE,      => 'MP3::Napster::Song->new_from_browse',
			   CHANNEL_ENTRY,        => 'MP3::Napster::Channel->new_from_list',
			   CHANNEL_USER_ENTRY,   => 'MP3::Napster::User->new_from_user_entry',
			   USER_LIST_ENTRY,      => 'MP3::Napster::User->new_from_user_entry',
			   WHOIS_RESPONSE,       => 'MP3::Napster::User->new_from_whois',
			   WHOWAS_RESPONSE,      => 'MP3::Napster::User->new_from_whowas',
			   USER_JOINS,           => 'MP3::Napster::User->new_from_user_entry',
			   USER_DEPARTS,         => 'MP3::Napster::User->new_from_user_entry',
		  );

sub import {
  my $pkg = shift;
  my $callpkg = caller;
  Exporter::export 'MP3::Napster::MessageCodes', $callpkg, @_;
}

*send   = \&send_command;
*listen = \&port;

sub new {
  my $class       = shift;

  my ($server,$metaserver,$widget,$tk);
  if (@_ == 1) {
    $server = shift;   # caller can override automatic server detection
  } elsif (@_ >= 2) {
    my %opt = @_;
    $server     = $opt{'-server'}     || $opt{'server'};
    $widget     = $opt{'-tkmain'}     || $opt{'tkmain'};
    $metaserver = $opt{'-metaserver'} || $opt{'metaserver'};
  }
  if ($widget) {
    require MP3::Napster::TkPoll;
    $tk = MP3::Napster::TkPoll->new($widget);
  }

  my $self        = $class->SUPER::new($tk) or return;

  # create and store the server object
  if (my $servobj = MP3::Napster::Server->new($server,$self,$metaserver)) {
    $self->server($servobj);
  } else {
    $self->disconnect;
    return;
  }

  # create and store the file registry
  my $registry = MP3::Napster::Registry->new($self) or return;
  $self->registry($registry);

  $self->{channel_hash} = {};
  $self->download_dir('.'); # default download directory
  $self->transfer_timeout(DEFAULT_TIMEOUT); # default timeout for transfers
  $self->allow_setport(0);                  # don't allow setport responses
  $self->install_default_callbacks;
  $self;
}

# install STDIN command processor
sub command_processor {
  my $self = shift;
  my ($callback,$fh) = @_;
  ref($callback) or croak("Usage: \$napster-command_processor(\$coderef,\$filehandle)");
  $fh ||= \*STDIN;
  return MP3::Napster::UserCommand->new(in=>$fh,eventloop=>$self,callback=>$callback);
}

sub port {
  my $self = shift;
  my $listener = $self->listener;
  if (@_) {
    my $port = shift;
    $listener->close if $listener;
    $listener = MP3::Napster::Listener->new($self,$port)
      or return $self->error("can't create listener");
    $self->listener($listener);
    $self->send_command(CHANGE_DATA_PORT,$listener->port);
  }
  return $listener ? $listener->port : 0;
}

sub install_default_callbacks {
  my $self = shift;

  # successful login
  $self->callback(LOGIN_ACK, sub {
		    my $self  = shift;
		    my $email = shift;
		    $self->email($email);
		    $self->send_command(CHANGE_DATA_PORT,$self->port) if $self->port > 0;
		  });

  # successful registration
  $self->callback(REGISTRATION_ACK, sub {
		    my $self = shift;
		    my $att = $self->attributes or return;
		    my $password = $att->{password};
		    my $nickname = $self->nickname;
		    my $version = __PACKAGE__ . " v$VERSION";
		    my $message = qq($nickname $password $att->{port} "$version" $att->{link} $att->{email});
		    warn "first login for $nickname...\n" if $self->debug;
		    $self->send(NEW_LOGIN,$message);
		  });

  # channel enrollment
  $self->callback(JOIN_ACK,sub {
		    my $self = shift;
		    my ($code,$chan) = @_;
		    warn "JOIN_ACK: $chan\n" if $self->debug > 0;
		    $self->channel_hash->{"\u\L$chan"} = $chan;
		    $self->channel($chan);
		  });

  # set data port message (used by server when it can't get in)
  # NOTE: this might be a security hole -- needs some thought
  $self->callback(SET_DATA_PORT, sub { my $self = shift;
				       my ($code,$newport) = @_;
				       return unless $self->allow_setport;
				       return if $newport == $self->port;
				       warn "Set data port: $newport" if $self->debug;
				       $self->port($newport);
				     });

  # ping/pong
  $self->callback(PING,sub { 
		    my $self = shift;
		    my ($code,$data) = @_;
		    $self->send_command(PONG,$data) }
		 );

  # Handle upload requests when we are not firewalled and the remote
  # user will make an incoming connection to us.
  # We check our registry to see if the sharename is
  # recognized and send an ACK if so.  Otherwise, send a GET_ERROR
  $self->callback(PASSIVE_UPLOAD_REQUEST,
		  sub { my $self = shift;
			my ($code,$msg) = @_;
			my ($nick,$sharename) = $msg =~ /^(\S+) "([^\"]+)"/;
			return unless $nick;
			warn "processing passive upload request from $nick for $sharename\n" if $self->debug > 0;
			my $song = $self->registry->song($sharename);
			return $self->send_command(PERMISSION_DENIED,$msg) unless defined $song;
			if ($self->port > 0 
			    and (my $u = MP3::Napster::TransferRequest->new_upload($self,
										   MP3::Napster::User->new($self,$nick),
										   $song,
										   $song->path))) {
			  $u->status('queued');
			}
			$self->send_command(UPLOAD_ACK,$msg)
		      });

  # Handle upload requests when we are behind a firewall and are expected
  # to make an (active) outgoing connection to the peer.
  # We check our registry to see if the sharename is recognized
  # and initiate an outgoing connection if so.
  # Otherwise we send a PERMISSION_DENIED
  $self->callback(UPLOAD_REQUEST,
		  sub {
		    my $self = shift;
		    my ($code,$msg) = @_;
		    if (my ($nick,$ip,$port,$sharename,$md5,$speed) 
			= $msg =~ /^(\S+) (\d+) (\d+) "([^\"]+)" (\S+) (\d+)/) {
		      warn "processing active upload request from $nick for $sharename" if $self->debug > 0;
		      if (my $song = $self->registry->song($sharename)) {

			# turn the IP address into standard dotted quad notation
			my $addr =  join '.',unpack("C4",(pack "V",$ip));  
			my $upload = MP3::Napster::TransferRequest->new_upload($self,
									       MP3::Napster::User->new($self,$nick,$speed),
									       $song,
									       $song->path);
			$upload->peer("$addr:$port");
			MP3::Napster::PeerToPeer->new($upload,$self);
			warn "starting active transfer" if $self->debug > 0;
			return;
		      }
		    }
		    # if we don't share this file...
		    $self->send_command(PERMISSION_DENIED,$msg);
		  }
		 );

  # This is a type of delayed error that occurs when we've started
  # a download, but the remote user goes offline
  $self->callback(USER_OFFLINE,
		  sub { my $self = shift;
			my ($code,$msg) = @_;
			my ($nick,$sharename) = $msg =~ /^(\S+) "([^\"]+)"/;
			if (my $download = $self->downloads($nick,$sharename)) {
			  $download->status('user offline');
			  $download->abort;
			}
		      }
		 );
}

sub event  {
  my $ec = shift->{ec};
  $MESSAGES{$ec} || "UNKNOWN CODE $ec";
}

# get/set last error
sub error {
  my $self = shift;
  if (@_) {  # setting
    my $error = join '',@_;
    $error =~ s/\n$//;
    $error =~ s/ at.*line \d+\.//;
    warn "ERROR: $error\n" if $self->debug > 1;
    $LAST_ERROR    = $error;
    $self->{error} = $error if ref $self;
    return;  # deliberately return undef here
  }
  return ref($self) ? $self->{error} : $LAST_ERROR;
}

sub send_command {
  my $self = shift;
  $self->server->send_command(@_);
}

# get event as a number
sub event_code {
  return shift->ec;
}

# oldstyle API
sub wait_for {
  my $self = shift;
  my ($event,$timeout) = @_;
  return unless $self->pollobject->can('poll');
  my $events = ref($event) eq 'ARRAY' ? $event : [$event];
  my ($ec,@msg) = $self->run_until($events,$timeout) 
    or return $self->error("timeout while waiting for ",$MESSAGES{$events->[0]});
  return wantarray ? ($ec,@msg) : $ec;
}

sub send_and_wait {
  my $self = shift;
  my ($command,$message,$event,$timeout) = @_;
  $self->send_command($command,$message);
  $self->wait_for($event,$timeout);
}


sub modify_event {
  my $self = shift;
  my ($ec,$body) = @_;
  my $sub = $MESSAGE_CONSTRUCTOR{$$ec} or return;
  if (ref($sub) eq 'CODE') {  # oldstyle function call
    $$body = $sub->($self,$$body);
  } else {
    my ($class,$method) = split '->',$sub;
    $$body = $class->$method($self,$$body);
  }
}


###########################################################
##################### high level methods ###################
###########################################################

# login -- returns e-mail address of nickname if login is successful.
# otherwise stores error message in error(); possible error messages include
# "invalid nickname" and "login error"
sub login {
  my $self = shift;
  my ($nickname,$password,$link_type,$port) = @_;
  $link_type ||= LINK_UNKNOWN;
  $port   = 0 unless defined($port);
  # my $version = __PACKAGE__ . " v$VERSION";
  my $version = 'v2.0';
  my $message = qq($nickname $password 0 "$version" $link_type);
  $self->nickname($nickname);
  warn "trying to login...\n" if $self->debug > 0;

  return unless my ($ec,$msg) = $self->send_and_wait(LOGIN,
						     $message,
						     [LOGIN_ACK,INVALID_ENTITY,LOGIN_ERROR,ERROR],60);
  return $self->error($msg) unless $ec == LOGIN_ACK;
  $self->port($port) if $port;
  return $msg;
}

# immediate disconnect method
sub disconnect {
  my $self = shift;
  $self->registry(undef);
  if (my $s = $self->server) {
    $s->close;
    $self->server(undef);
  }
  $_->done(1) foreach $self->transfers;
  $self->SUPER::disconnect;
}

# called to register a new nickname
# accepts a block of attributes containing the following
# fields:
# { email     => 'your@email',
#   port      => preferred port for incoming requests
#   link      => a LINK_* constant
#   name      => your full name
#   address   => address fields
#   city      => city
#   state     => state
#   phone     => phone
#   age       => age
#   income    => your income?
#   education => your education?
# }
sub register {
  my $self = shift;
  my ($nickname,$password,$att) = @_;
  die "must provide nickname and password" unless $nickname && $password;
  $att ||= {};
  $att->{link}      ||= LINK_UNKNOWN;
  $att->{port}      ||= 0;
  $att->{email}     ||= 'anon@napster.com';
  $att->{password}    = $password;

  warn "requesting permission to register $nickname" if $self->debug;
  $self->attributes($att);
  $self->nickname($nickname);
  my ($ec,$msg) = $self->send_and_wait(REGISTRATION_REQUEST,$nickname,
				       [LOGIN_ACK,ALREADY_REGISTERED,INVALID_NICKNAME],20);
  return unless $ec == LOGIN_ACK;
  $self->port($att->{port}) if defined($att->{port});
  $self->new_info;
  $msg;
}

sub new_login {
  my $self = shift;
  my $att = $self->attributes;
  my $password = $att->{password};
  my $nickname = $self->nickname;

  my $version = __PACKAGE__ . " v$VERSION";
  my $message = qq($nickname $password 0 "$version" $att->{link} $att->{email});
  warn "logging in under $nickname...\n" if $self->debug;
  return unless my ($ec,$msg) = $self->send_and_wait(NEW_LOGIN,$message,LOGIN_ACK,20);
  return unless $ec == LOGIN_ACK;
}

sub new_info {
  my $self = shift;
  my $att = $self->attributes;
  warn "sending new user data\n" if $self->debug;
  $att->{$_} ||= '' foreach qw(name address city state phone age education);
  return unless $self->send(LOGIN_OPTIONS,
			    sprintf("NAME:%s ADDRESS:%s CITY:%s STATE:%s PHONE:%s AGE:%s INCOME:%s EDUCATION:%s",
				    @{$att}{qw(name address city state phone age education)}));
  1;
}

# change some registration information
# can provide:
#     link     => $new_link_speed,
#     password => $new_password;
#     email    => $new_email;
sub change_registration {
  my $self = shift;
  my %attributes = @_;
  $self->send_command(CHANGE_LINK_SPEED,$attributes{link})   if defined $attributes{link};
  $self->send_command(CHANGE_PASSWORD,$attributes{password}) if defined $attributes{password};
  $self->send_command(CHANGE_EMAIL,$attributes{email})       if defined $attributes{email};
  1;
}


##########################################################################
# Channel commands
##########################################################################

# return list of channels as an array
sub channels {
  my $self = shift;
  my $ec = $self->send_and_wait(LIST_CHANNELS,'',LIST_CHANNELS,20) || return;
  return $self->events(CHANNEL_ENTRY);
}

# join a channel
sub join_channel {
  my $self    = shift;
  my $channel = shift;
  $channel = ucfirst(lc $channel);
  if (my $c = $self->channel_hash->{$channel}) { # already belongs to this one
    $self->channel($c);  # make it primary
    return $c;
  }

  return unless my ($ec,$msg) = $self->send_and_wait(JOIN_CHANNEL,$channel,[INVALID_ENTITY,JOIN_ACK],10);
  return unless $ec == JOIN_ACK;
  return $self->channel;
}

# part a channel
sub part_channel {
  my $self    = shift;
  my $channel = shift;
  $channel = ucfirst(lc $channel);
  return $self->error("not a member of $channel")
    unless $self->channel_hash->{$channel};
  $self->send(PART_CHANNEL,$channel);
  delete $self->channel_hash->{$channel};
  if (my @channels = sort keys %{$self->channel_hash}) {
    $self->channel($self->{channel_hash}{$channels[0]});
  } else {
    $self->channel(undef);
  }
  1;
}

# list channels user is member of
sub enrolled_channels {
  my $self = shift;
  return keys %{$self->channel_hash};
}


##########################################################################
# User commands
##########################################################################

# return users in current channel
sub users {
  my $self = shift;
  my $channel = shift || $self->channel;
  return unless $channel;
  return unless $self->send_and_wait(LIST_USERS,$channel,LIST_USERS,10);
  return $self->events(USER_LIST_ENTRY);
}

# get whois information
sub whois {
  my $self = shift;
  my $nick = shift;
  return unless my ($ec,$message) = 
    $self->send_and_wait(WHOIS_REQ,$nick,
			 [WHOIS_RESPONSE,WHOWAS_RESPONSE,INVALID_ENTITY],10);
  return $message if $ec == WHOIS_RESPONSE or $ec == WHOWAS_RESPONSE;
  return;
}

# ping a user, return true if pingable
sub ping {
  my $self = shift;
  my ($user,$timeout) = @_;
  return $self->ping_multi($user,$timeout) if ref $user eq 'ARRAY';
  warn "ping(): waiting for a PONG from $user (timeout $timeout)\n" if $self->debug > 0;
  return unless my ($ec,@message) = 
    $self->send_and_wait(PING,$user,[PONG,INVALID_ENTITY,USER_OFFLINE],$timeout || 5);
  return unless $ec == PONG;
  return grep {lc($user) eq lc($_)} @message;
}

# ping multiple users, returning a hash of their response times
sub ping_multi {
  my $self = shift;
  my ($users,$timeout) = @_;
  die "usage ping_multi(\\\@users,\$timeout)" unless ref $users eq 'ARRAY';
  $timeout ||= 20;  # twenty second max wait

  # keep track of the pongs we receive
  my %pongs;
  my $pending = @$users;
  my @events = (PONG,INVALID_ENTITY,USER_OFFLINE);
  my $start = time;

  my $cb = sub {
    my $self = shift;
    my ($code,$msg) = @_;
    $pending--;
    $pongs{$msg}=time-$start if $code == PONG;
  };

  $self->callback($_,$cb)       foreach @events;
  $self->send_command(PING,$_)  foreach @$users;

  while ((my $remaining = $timeout - (time-$start)) > 0 and $pending > 0) {
    $self->wait_for(\@events,$remaining);
  }

  $self->delete_callback($_,$cb) foreach @events;
  return \%pongs;
}

##########################################################################
# Message Commands
##########################################################################

# send a public message
sub public_message {
  my $self = shift;
  my $mess = shift;
  my $channel = shift || $self->channel;
  return $self->error('no channel selected') unless $channel;
  $self->send_command(SEND_PUBLIC_MESSAGE,$channel." $mess");
  1;
}

# send a private message
sub private_message {
  my $self = shift;
  my ($nick,$mess) = @_;
  $self->send_command(PRIVATE_MESSAGE,"$nick $mess");
  1;
}

##########################################################################
# Song search commands
##########################################################################

# Initiate a search and return a list of MP3::Napster::Song objects
# arguments:
# artist => 'artist name'
# title  => 'song name'
# limit  => $maximum number of results to return (100)
# linespeed => "(at least|at best|equal to) $link_type" (codes)
# bitrate   => "(at least|at best|equal to) $bitrate" (in kbps)
# frequency => "(at least|at best|equal to) $freq" (in Hz)
sub search {
  my $self = shift;
  # if one argument, then treat it as the song
  my %attrs;
  if (@_ == 1) {
    $attrs{'title'} = shift;
  } else {
    %attrs = @_;
  }
  $attrs{limit} ||= 100;

  # fix parameters heuristically
  if ($attrs{linespeed}) {
    $attrs{linespeed} =~ s/(LINK_\w+)$/eval($1)/e;
    $attrs{linespeed} = uc $attrs{linespeed};
    $attrs{linespeed} = qq(AT LEAST $attrs{linespeed}) if $attrs{linespeed} =~ /^\d+$/;
  }
  if ($attrs{bitrate}) {
    $attrs{bitrate} =~ s/\s*(kbs|k)$//i;
    $attrs{bitrate} = uc $attrs{bitrate};
    $attrs{bitrate} = qq(AT LEAST $attrs{bitrate}) if $attrs{bitrate} =~ /^\d+$/;    
  }
  if ($attrs{frequency}) {
    $attrs{frequency} =~ s/(\d+)\s*khz$/1000*$1/ei;  # khz to hz
    $attrs{frequency} = uc $attrs{frequency};
    $attrs{frequency} = qq(AT LEAST $attrs{frequency}) if $attrs{frequency} =~ /^\d+$/;    
  }
  foreach (qw(linespeed bitrate frequency)) {
    next unless $attrs{$_};
    $attrs{$_} =~ s/(AT LEAST|AT BEST|EQUAL TO)/"$1"/g;
    $attrs{$_} =~ s/(\d+)/"$1"/g;
  }
  my $query;
  $query .= qq(FILENAME CONTAINS "$attrs{artist}" ) if $attrs{artist};
  $query .= qq(MAX_RESULTS $attrs{limit} );
  $query .= qq(FILENAME CONTAINS "$attrs{title}" ) if $attrs{title};
  $query .= qq(LINESPEED $attrs{linespeed} ) if $attrs{linespeed};
  $query .= qq(BITRATE $attrs{bitrate} ) if $attrs{bitrate};
  $query .= qq(FREQ $attrs{frequency} ) if $attrs{frequency};
#  $query .= qq(LOCAL_ONLY);
  warn "search query = $query" if $self->debug > 0;

  my $ec = $self->send_command(SEARCH,$query);
  my $timeout = $attrs{timeout} || 20;
  $self->wait_for(SEARCH_RESPONSE_END,$timeout); # allow $timeout seconds to get result

  # return the search results
  return $self->events(SEARCH_RESPONSE);
}

# browse a user's files
sub browse {
  my $self = shift;
  my $nick = shift;
  return
    unless my ($ec,$msg) = 
      $self->send_and_wait(BROWSE_REQUEST,$nick,
			   [BROWSE_RESPONSE_END,USER_OFFLINE,INVALID_ENTITY],30);
  return $self->error('user not online') unless $ec == BROWSE_RESPONSE_END;
  return $self->events(BROWSE_RESPONSE);
}

##########################################################################
# Registration of shared files
##########################################################################

# Mark a file as being available for sharing.
sub share {
  my $self = shift;
  my ($path,$cache) = @_;
  return $self->error('please log in') unless $self->nickname;
  return unless my $reg = $self->registry;
  $reg->share_file($path,$cache);
}

# mark an entire directory as being available for sharing
sub share_dir {
  my $self = shift;
  my ($dir,$cache) = @_;
  $cache = 1 unless defined $cache;
  opendir (S,$dir) or return $self->error("Couldn't open directory $dir: $!");
  my @share;
  while (my $song = readdir(S)) {
    next unless $song =~ /\.mp3$/;
    my $s = $self->share("$dir/$song",$cache);
    push @share,$s if $s;
  }
  @share;
}

##########################################################################
# Downloads/uploads
##########################################################################

# Request a download.  Provide an MP3::Napster::Song object, and a path or filehandle
# to save the data to.
sub download {
  my $self = shift;
  my ($song,$fh) = @_;
  my ($ec,$message);

  die "usage: download(\$song,\$file_or_filehandle)"
    unless ref $song and defined $fh;

  my ($nickname,$path) = ($song->owner,$song->path);
  return $self->error("can't download from yourself") if $self->nickname eq $nickname;

  $message = qq($nickname "$path");

  #timeout of 15 secs to get an ack
  return
    unless ($ec,$message) = $self->send_and_wait(DOWNLOAD_REQ,
						 $message,
						 [DOWNLOAD_ACK,GET_ERROR,
						  ERROR,USER_OFFLINE],15);
  return $self->error($self->event) unless $ec == DOWNLOAD_ACK;

  # The server claims that we can download now.  The message contains the
  # IP address and port to fetch the file from.
  my ($nick,$ip,$port,$filename,$md5,$linespeed) = 
    $message =~ /^(\S+) (\d+) (\d+) "([^\"]+)" (\S+) (\d+)/;

  warn "download message = $message\n" if $self->debug > 0;

  # turn nickname into an object
  $nick = MP3::Napster::User->new($self,$nick,$linespeed);

  # create request object
  my $request = MP3::Napster::TransferRequest->new_download($self,$nick,$song,$fh);

  if ($port == 0) { # they're behind a firewall!
    warn "initiating passive download\n" if $self->debug > 0;
    # we must have a listen thread going in this case
    return $self->error("can't download; both clients are behind firewalls")
	    unless $self->port > 0;
    my ($rc,$msg) = $self->send_command(PASSIVE_DOWNLOAD_REQ,qq($nick "$filename"));
    # the actual transfer will be initiated by the Listen object
    return $request;
  }

  # turn the IP address into standard dotted quad notation
  my $addr =  join '.',unpack("C4",(pack "V",$ip));
  $request->peer("$addr:$port");  # remember the peer in the request

  # create a new PeerToPeer object
  return unless MP3::Napster::PeerToPeer->new($request,$self);
  return $request;
}

# wait until all downloads are finished
sub wait_for_downloads {
  my $self = shift;
  $self->registry->unshare_all if $self->registry;
  $self->wait_for(TRANSFER_DONE) while $self->transfers;
}

# register/unregister a file transfer
sub register_transfer {
  my $self = shift;
  my ($type,$request,$register_flag) = @_;

  warn "register_transfer($type,$request,$register_flag)" if $self->debug > 0;
  my $path = $request->song;
  my ($title) = $path =~ m!([^/\\]+)$!;

  if ($register_flag) {
    $self->{$type}{lc $request->nickname,$title} = $request;
  } else {
    delete $self->{$type}{lc $request->nickname,$title};
  }
}

# return the download objects, 
# or a specific one, given the nickname and path of the remote song
sub downloads {
  my $self = shift;
  $self->_transfers('download',@_);
}

# list the uploads,
# or a specific one given the remote client nickname and song path
sub uploads {
  my $self = shift;
  $self->_transfers('upload',@_);
}

# transfers
sub transfers {
  my $self = shift;
  return ($self->uploads,$self->downloads);
}

# this is called intermittently to timeout idle connections
sub do_cleanup {
  my $self = shift;
  warn "do_cleanup()" if $self->debug;
  my @transfers = $self->transfers;
  for my $t (@transfers) {
    $t->abort if $t->idle >= $self->transfer_timeout;
    $t->abort if $t->aborted;
  }
}

# private subroutine called by downloads() and uploads()
sub _transfers {
  my $self = shift;
  my ($type,$nickname,$path) = @_;
  return unless $self->{$type};
  return values %{$self->{$type}} unless $nickname && $path;
  $nickname = lc $nickname;
  # protect against confused clients
  my ($title) = $path =~ m!([^/\\]+)$!;
  $self->{$type}{$nickname,$title};
}

sub DESTROY {
  my $self = shift;
  warn "$self->DESTROY" if $self->debug > 2;
}


1;

__END__

=head1 NAME

MP3::Napster - Perl interface to the Napster Server

=head1 SYNOPSIS

  use MP3::Napster;

  my $nap = MP3::Napster->new;

  # log in as "username" "password" using a T1 line
  $nap->login('username','password',LINK_T1) || die "Can't log in ",$nap->error;

  # listen for incoming transfer requests on port 6699
  $nap->port(6699) || die "can't listen: ",$nap->error;

  # set the download directory to "/tmp/songs"
  mkdir '/tmp/songs',0777;
  $nap->download_dir('/tmp/songs');

  # arrange for incomplete downloads to be unlinked
  $nap->callback(TRANSFER_DONE,
  	         sub { my ($nap,$code,$transf) = @_;
		       return unless $transf->direction eq 'download';
		       return if $transf->status eq 'transfer complete';
		       warn "INCOMPLETE: ",$transf->song," (UNLINKING)\n";
		       unlink $transf->local_path; 
		      } );

  # search for songs by the Beatles that are on a cable modem or better
  # and have a bitrate of at least 128 kbps
  my @songs = $nap->search(artist=>'beatles',linespeed=>LINK_CABLE,bitrate=>128);

  # initiate downloads on the first four songs
  my $count = 0;
  foreach my $s (@songs) {
    next if $seen_it{$s}++;
    next unless $s->owner->ping;
    next unless $s->download;  # try to initiate download
    print "Downloading $s, size = ",$s->size,"\n";
    last if ++$count >= 4;  # download no more than four
  }

  # disconnect after waiting for all pending transfers to finish
  $nap->wait_for_downloads;
  $nap->disconnect;

=head1 DESCRIPTION

MP3::Napster provides access to the Napster MP3 file search and
distribution protocol.  With it, you can connect to a Napster server,
exchange messages with users, search the database of MP3 sound files,
and either download selected MP3s to disk or pipe them to another
program, typically an MP3 player.

The module can be used to write Napster robots to search and download
files automatically, or as the basis of an interactive client.

=head1 THEORY OF OPERATION

The Napster protocol is asynchronous, meaning that it is
event-oriented.  After connecting to a Napster server, your program
will begin receiving a stream of events which you are free to act on
or ignore.  Examples of events include PUBLIC_MESSAGE, received
when another user sends a public message to a channel, and USER_JOINS,
sent when a user joins a channel.  You may install code subroutines
called "callbacks" in order to intercept and act on certain events.
Many events are also handled internally by the module.  It is also
possible to issue a command to the Napster server and then wait up to
a predetermined period of time for a particular event or set of events
to be returned.

If you wish to build an interactive Napster client on top of this
module, you will need to install a series of callbacks to handle each
of the events that you wish to catch.  Once the callbacks are
installed, you will call the run() method in order to run
MP3::Napster's event loop.  run() will not return until the connection
between client and server is finished.  To process line-oriented user
commands during this time, you can install a command-handling callback
using the command_processor() method.

MP3::Napster has a Tk mode, for writing applications on top of the
graphical PerlTk module.  In this mode, Tk takes over MP3::Napster's
internal event loop, processing I/O from the server and peers, and
invoking your callbacks when appropriate.

You don't need to worry about callbacks if you only intend to use the
module as a non-interactive robot.

Because of its asynchronous operation MP3::Napster makes heavy use of
nonblocking I/O and Perl's IO::Select class.  IO::Select is standard
in Perl versions 5.00503 and higher.  Other prerequisites are
Digest::MD5 and MP3::Info (both needed to handle MP3 uploads).

The Napster protocol has a peer-to-peer component.  During MP3 upload
and download operations between two users, one user's client will
initiate a connection to the other. In order for such a connection to
succeed, at least one of the clients must be listening for incoming
connections on a network port.  The MP3::Napster module can do this,
either by listening on a hard-coded port, or by selecting a free port
automatically. If you are behind a firewall and cannot make a port
available for incoming connections, MP3::Napster will be able to
exchange files with non-firewalled users, but not with those behind
firewalls.

For more information on the Napster protocol, see
opennap.sourceforge.net, or the file "napster.txt" which accompanies
this module.  This file contains a partial specification of the
Napster protocol, as reverse engineered by several Open Source
developers.

=head1 BASIC OPERATION

This section describes the basic operation of the module.

=head2 Connecting, Disconnecting, and Retrieving Errors

=over 4

=item B<$nap = MP3::Napster-E<gt>new([$address])>

=item B<$nap = MP3::Napster-E<gt>new(@options)>

The new() class method will attempt to establish a connection with a
Napster server.  If you wish to establish a connection with a
particular server, you may provide its address and port number in the
following format: aa.bb.cc.dd:PPPP, where PPPP is the port number.
You may use a hostnames rather than IP addresses if you prefer.

If you do not provide an address, MP3::Napster will choose the "best"
server by asking the "meta" Napster master server located at
server.napster.com:8875.  Note that there are several Napster servers,
and that a user logged into one server will not be visible to you if
you are logged into a different one.

If successful, new() return an MP3::Napster object.  Otherwise it will
return undef and leave an error message in $@ and in
MP3::Napster->error.

The module also provides a long form of the new() method which takes a
series of option/value pairs.  Options and their defaults are:

 Option    Description                   Default

 -server   Server in form addr:port      undef
 -meta     Metaserver in form addr:port  server.napster.com:8875
 -tkmain   TK main widget                undef

The B<-server> argument has the same meaning as in the single-argument
form of new().  B<-meta> allows you to specify an alternative address
for the Napster meta server.  B<-tkmain> provides a hook into the
Perl-Tk event handling, as described below under L<"Using MP3::Napster
with PerlTk">.  For example, to connect to the BitchX server and use
the Tk event handling system:

  use Tk;
  use MP3::Napster;
  $main = MainWindow->new;
  $nap  = MP3::Napster->new(-server => 'bitchx.dimension6.com:8888',
                            -tkmain => $main);

=item B<$nap-E<gt>disconnect([$wait])>

The disconnect() object method will sever its connection with the
Napster server and tidy up by cancelling any pending
upload or download operations.
 
By default, disconnect() will immediately abort all pending downloads
and uploads.  If you wish your script to wait until they are done,
call wait_for_downloads() first.

=item B<$nap-E<gt>wait_for_downloads>

This method will block until all pending uploads and downloads are
complete.  It first unshares all shared files, and refuses to service
new upload requests. 

In the case of a slow or hung peer, wait_for_downloads() will wait
until the transfer has timed out, ordinarily five minutes of complete
inactivity.  See L<"Waiting for Downloads"> for details on how to
alter this.

=item B<$nap-E<gt>run>

Run the event loop, receiving and responding to events.  This
operation will block until the connection is disconnected.
Ordinarily, you will disconnect the connection within a callback.

=item B<$nap-E<gt>error>

The error() method will return a human-readable string containing the
last error message to be emitted by the server or generated internally
by MP3::Napster.  You may clear the error message by setting it to an
empty string this way:

  $nap->error('');

If multiple errors occur in quick succession, error() will return only 
the most recent one.

=back

=head2 Login and Registration

After establishing a connection with a Napster server, you must either
login as an existing user, or register as a new one.  The methods in
this section provide access to the login facilities.

=over 4

=item B<$email = $nap-E<gt>login($nickname,$password [,LINK_SPEED] [,$port])>

The login() method will attempt to log you in as a registered user
under the indicated nickname and password.  You may optionally provide
a link speed and a value describing the port on which the client will
accept incoming connections.

The link speed should be selected from the following list of exported
constants:

  LINK_14K   LINK_64K    LINK_T1
  LINK_28K   LINK_128K   LINK_T3
  LINK_33K   LINK_CABLE  LINK_UNKNOWN 
  LINK_56K   LINK_DSL

The link speed will default to LINK_UNKNOWN if absent.  The indicated
speed will be displayed to other users when they browse your list of
shared files and user profile.

The port many be any valid internet port number, normally an integer
between 1024 and 65535.  The standard napster port is 6699, but you
are free to use any valid port. If a port of 0 is specified, the
module will identify your client to the server as being firewalled.
The module will still be able to perform file transfers by making
outgoing connections to other peers, but will not be able to exchange
files with other firewalled peers.  If a port of -1 is specified, the
module will pick an unused port automatically.  This is recommended
for multiuser systems.

If successful, login() will either return the email address you
provided at registration time or the anonymous email address
"anon@napster.com" if the account is not formally registered.
Otherwise an undefined value will be returned and the error message
left in $nap->error.  Typical errors include "no such user" and
"invalid password".

The nickname you logged in under is available as $nap->nickname.

=item B<$email = $nap-E<gt>register($nickname,$password,\%attributes)>

The register() method will attempt to register you as a new user under 
the indicated nickname and password.  You may optionally provide
register() with a hash reference containing one or more of the
following keys:

  key        description
  ---        -----------
  link       Link speed, selected from among the LINK_* constants
  port       Preferred port for incoming connections
  email      Your e-mail address
  name       Your full name
  address    Your street address
  city       Your city
  state      Your state (two-letter abbreviation)
  phone	     Your phone number
  age	     Your age
  income     Your income level
  education  Your educational level

Of these attributes only the link speed is relevant, since the others
can either be automatically determined by the module, or may be
considered intrusive by some people.  In addition, I have been unable
to confirm that the demographic attributes actually "take," since the
uploaded information is not made available to clients.

If successful, the registration email address will be returned.
Otherwise undef will be returned and $self->error will show the exact
error message.  Typical error messages are "user already registered"
and "invalid nickname."

=item B<$result = $nap-E<gt>change_registration(email=E<gt>$mail,password=E<gt>$pass,link=E<gt>$link)>

Change_registration() allows you to change some fields in your
registration record.  Pass it one or more of the keys "email",
"password" or "link" to change the indicated attribute.

There is no acknowledgement from the server, and therefore no positive
way to confirm that the changes occurred.  Indeed, there seem to be
synchronization problems among the Napster servers, so that a password 
change on one server may not take effect on others!  Therefore, use
this method with care.

=back

=head2 Sharing Files

Once you have logged in, you may begin sharing files with other users.
If you choose not to do this, you may still download files and
use other features of the Napster server.

=over 4

=item B<$share = $nap-E<gt>share('path/to/a/file.mp3' [,$cache])>

The share() method will mark an MP3 file as shared with the community.
The file may be specified using an absolute or relative path.
However, it must be a bona fide MP3 file.  MP3::Napster will use
MP3::Info to determine the file's bitrate, play length and other
information, and upload this information to the Napster server.

Rather than providing the Napster server with the file's full file
pathname, MP3::Napster constructs a "share name" based on the file's
IDv3 tag.  For example, the song "A Hard Day's Night" by the Beatles
will be shared under the name:

  [The Beatles] A Hard Day's Night.mp3

If the IDv3 tag is missing, the file is shared under its physical
filename after stripping off the path information.

If successful, the method returns an MP3::Napster::Song object, which
when used in a string context returns its share name (see
L<MP3::Napster::Song> for more details).  Otherwise the method
returns undef and leaves the error message in $self->error.

If you provide an optional $cache flag of true, then the IDv3 tag
information will be cached in a directory named ".mpeg-nap" parallel
to the downloaded file.  This avoids having to collect statistics on
the file every time you share it.  This is recommended if you
frequently share large numbers of files.  However, it requires that
the directory containing the indicated file be writable and
executable.

=item B<@shares = $nap-E<gt>share_dir('path/to/a/directory/' [,$cache])>

This is like share() but instead of sharing a single file it shares
the contents of a directory, and returns the list of
MP3::Napster::Song objects shared in this way.  Currently, the module
does not automatically monitor the directory and add to the list of
shares when it is updated.

=item B<$port = $nap-E<gt>port([$port])>

The port() method will set or change the port on which the client
listens for incoming connections.  This method is called internally by 
login() and register() immediately after the client successfully logs
into the server.  You may call the method at any time thereafter in
order to change the port, or to disable incoming connections.

You may hard-code a port to listen to and provide it as an argument to
listen().  If you provide a negative port number, port() will select
an unused high-numbered port and register it with the Napster server.
This is recommended if you are on a machine that is shared by multiple
users and there are no firewall issues that will limit the range of
open ports.  The standard port used by the PC clients is 6699.

Called with no arguments, this method returns the current port.

Note that it is possible for a Napster server to tell the module to
change its data port number.  Install a callback for the
CHANGE_DATA_PORT event if you want to be notified when this happens.
Set allow_setport() to a false value to prevent this from happening.

If you are behind a firewall and cannot accept incoming connections,
set the port to 0, or just accept the defaults.  This will inform the
Napster server that you are firewalled.  Although you will not be able
to exchange files with other firewalled users, you will be able to do
so with non-firewalled users.

If successful, port() returns the port that it is listening on.
Otherwise it returns undef and leaves the error message in
$nap->error.  Uploads requested by remote users will proceed
automatically without other intervention.  You can receive
notification of these uploads by installing callbacks for the
TRANSFER_STARTED, TRANSFER_IN_PROGRESS and TRANSFER_DONE events or by
interrogating the $nap->uploads() method (described below).

=item B<$flag = $nap-E<gt>allow_setport([$flag])>

The Napster protocol allows the server to send the client
SET_DATA_PORT commands, causing the module to change the port that it
is listening on.  This may be a security hole, because it allows
unscrupulous individuals to open arbitrary listening ports on your
machine, so by default, the module ignores such requests.  To turn
automatic handling of setport messages on, call allow_setport() with a 
true flag.

Without any arguments, the method returns the current state of the flag.

item B<$song-E<gt>unshare()>

Given a Song object returned from share() or share_file(), unshare()
will unregister the song, removing it from the search list at the
server and disallowing further downloads.

=back

=head2 Searching and Downloading Song Files

You may search the Napster sound file directory by keyword search, or
by browsing all the files shared by a named user.  The search
functions return a list of matching MP3::Napster::Song objects, each
of which contains such information about the song as its bitrate, its
length, and its sample frequency.  You can download a desired song
either by invoking its download() method directly (see
L<MP3::Napster::Song>) or by passing the song to the MPEG::Napster
object's download() method.  Also see L<MP3::Napster::User> for
information on how to determine whether the owner of a song is still
online and reachable.

=over 4

=item B<@songs = $nap-E<gt>browse($nickname)>

The browse() method returns a list of the song files shared by a user.
You may provide the user's nickname or a MP3::Napster::User object as
the argument.  The method will return a list of songs shared by the
user, or an empty list.  The empty list will be returned when the user
is online but sharing no files as well as in such exceptional
conditions as the user being offline or nonexistent.  You can
distinguish between the two cases by checking $nap->error.

=item B<@songs = $nap-E<gt>search('keywords')>

=item B<@songs = $nap-E<gt>search(%attributes)>

The first form of the search() method allows you to search for songs
by words located in the artist's name or the song title.  For example, 
this will search for Bob Dylan's I<Blowing in the Wind>:

 @songs = $nap->search('bob dylan blowing in the wind');

For unknown reasons, lowercase searches are more effective than
uppercase ones.  The result value is an array of matching songs, or an
empty list if none were found.

A more structured search can be made by providing search() with a hash 
of attribute/value pairs.  The available attributes are as follows:

  Attribute	   Value
  ---------	   -----
  artist	   The artist's name
  title		   The song title
  limit		   Limit the responses to the indicated number
  linespeed	   The link speed of the owner
  bitrate	   The bitrate of the song, in kbps
  frequency	   The sampling frequency of the song, in Hz

The linespeed, bitrate and frequency fields can be specified in any
of the following forms:

 Form                     Example
 ----                     -------
 1. a bare value          bitrate => 128
 2. "at least $value"     bitrate => 'at least 128'
 3. "at best $value"      bitrate => 'at best 64'
 4. "equal to $value"     frequency => 'equal to 44100'

Using a bare value is the same as specifying "at least".

In this example, we search for songs by Bob Dylan that have a bitrate
of at least 160 kbps and are sampled at exactly 44.1 kHz:

  @songs = $nap->search(artist => 'Bob Dylan',
                        title  => 'Blowing in the Wind,
			bitrate => 160,
			frequency => 'equal to 44100');

Due to server limitations, "artist" and "title" are interchangeable,
and "limit" doesn't seem to do anything.  Search results are limited
to 100 songs at the server's end of the connection.  No facility is
provided for searching on a song's size or play length.

=item B<$path = $nap-E<gt>download_dir( [$path] )>

The download_dir() gets or sets the path to the directory used for
automatic downloads.  If a song download is initiated without
providing an explicit path or filehandle, the song data will be
written into a file having the same name as the song located in the
directory indicated by download_dir().

Download_dir() starts out containing the empty string, which will
cause the song data to be written to the current working directory.
You may change the path by providing the method with an argument
containing a relative or absolute directory.  For example:

  $nap->download_dir('/tmp/songs');  # write data to this path

The download directory must already exist.  It will not be created for
you.

=item B<$download = $nap-E<gt>download($song [, $file | $fh ])>

Given an MP3::Napster::Song object returned from a previous search()
or browse(), the download() method will attempt to initiate a download
and perform the file transfer in the background.  If the download is
successfully initiated, an MP3::Napster::Transfer object will be
returned (see L<MP3::Napster::Transfer>).  You can use this object to
monitor the progress of the transfer.  If the download attempt was
unsuccessful, the method will return undef and leave an error message
in $nap->error.

You may also monitor the progress of the transfer by installing
callbacks for TRANSFER_STARTED, TRANSFER_IN_PROGRESS, and
TRANSFER_DONE, as described later.

The download() method takes an optional second argument that can be
either a file path or a filehandle.  In the case of a file path, the
file is opened for writing.  If the file already exists, it is opened
for appending and the download is coordinated in such a way that only
the portion of the local file that is missing is downloaded from the
peer.  This can be used to resume from previously cancelled download
attempts.

If you pass a filehandle to the download() method, the song data will
be written directly to the filehandle.  This will work for pipes and
other types of handles as well as with filehandles.  For example, you
can play a song directly off the net by opening up a pipe to your
favorite command-line MP3 decoder.

   open(PLAYER,"|mpg123 -");
   $nap->download($song,\*PLAYER);

You must pass filehandles as GLOB refs (\*FH), GLOBS (*FH) or as
IO::Handle objects.

If no path or filehandle is passed to download(), then the module will
write the song data into a file having same name as the song located
within the directory specified by the download_dir() method.

=item B<@downloads = $nap-E<gt>downloads>

=item B<@uploads   = $nap-E<gt>uploads>

=item B<@transfers = $nap-E<gt>transfers>

The downloads() method will return the list of active
MP3::Napster::Transfer objects being used for downloading.  If the
download has already completed, it will not be present on this list.

The uploads() method returns all pending uploads, and transfers()
returns the union of downloads() and uploads().

=back

See L<MP3::Napster::Transfer> for more information on managing
downloads, including how to abort them prematurely.

=head2 Chat Groups and Users

These methods provide access to Napster's chat groups, which are also
known as "channels".  To capture public and private messages, you must 
install callbacks for the relevant events.  See L<"Callbacks">.

=over 4

=item B<@channels = $nap-E<gt>channels>

The channels() method will return a list of available channels as an
array of MP3::Napster::Channel objects.  When used in a string
context, these objects interpolate as the name of the channel.  Object
methods provide access to the topic channel, the number of users on
the channel, and to the list of the users currently participating in
the channel.  The channel object also provides a join() method that
will allow you to join it and start receiving its events.

See L<MP3::Napster::Channel>.

=item B<$result = $nap-E<gt>join_channel($channel)>

The join_channel() method will join the indicated channel. You may
provide an MP3::Napster::Channel object from a previous channels()
call, or a plain string containing the name of the channel.

After joining a channel, the client will begin to send event messages
relevant to the channel, such as notifications of when users join or
leave the channel.  This method also sets the user's "current
channel", which is used as the default destination for the
public_message() method.

More than one channel can be joined simultaneously, up to a limit set
by the server.  If the channel is joined successfully, a true result
will be returned.  Otherwise undef will be returned and $nap->error
will contain the error message.  The list of channels currently joined
can be retrieved with the member_channels() method.  If you attempt to
join the same channel more than once, join_channel() will have the
effect of making the selected channel the current one.

=item B<$result = $nap-E<gt>part_channel($channel)>

The part_channel() method will disconnect you from the indicated
channel so that you no longer receive messages from the channel.  You
may pass the method an MP3::Napster::Channel object,or just a plain
string containing the channel name.  The method always returns a true
value, since the server provides no positive acknowledgement that the
channel was successfully departed.

=item B<$channel = $nap-E<gt>channel([$channel])>

The channel() method will return the current channel object, or undef
if no channel is current.  It can also be used to set the current
channel to the one indicated by the argument.  However it is better to
use join_channel() for this purpose.

=item B<@channels = $nap-E<gt>enrolled_channels>

This method returns the list of channels in which the user is
currently enrolled, or an empty list if the user is not enrolled in
any.

=item B<@users = $nap-E<gt>users([$channel])>

The users() method returns the list of users currently attached to the
channel as an array of MP3::Napster::User objects.  User object
methods allow you to ping the indicated user, discover a limited
amount of information about him or her, and list his or her files.

If you provide a channel name or object, the user list will be
retrieved from that channel.  Otherwise the method returns the list of
users enrolled in the current channel.

In case of error, the methods returns an empty list and stashes the
error message in $nap->error.

=item B<$result = $nap-E<gt>public_message($message [,$channel])>

This method sends a public message to the indicated channel, or the
current channel if one is not designated.  On success, the method
returns a true result.  On failure, it returns undef and sets
$nap->error to a pithy error message.

I do not know whether there is a limit on the size or content of
public messages.  Most messages posted to the Napster service are
short single lines containing cryptic abbreviations and
poorly-disguised obscenities.

=item B<$result = $nap-E<gt>private_message($nickname,$message)>

Private_message() sends a private message to the indicated user.  You
may provide an MP3::Napster::User object, or just the user's nickname
as a string.  On success, the method returns a true result.  On
failure, it returns undef and sets $nap->error to an error message.

I do not know whether there is a limit on the size or content of
private messages.  Most messages posted to the Napster service are
short single lines.

=item B<$user = $nap-E<gt>whois($nickname)>

Given a string containing the nickname of a user, whois() returns an
MP3::Napster::User object which you can query for further information
on the user.  On an error, this method returns undef and sets
$nap->error.  The most typical error is "no such user".  If the user
is offline, you will receive an object whose fields are mostly
blank. See L<MP3::Napster::User>.

=item B<$result = $nap-E<gt>ping($nickname [,$timeout])>

Given a string containing the nickname of a user or a
MP3::Napster::User object and an optional timeout value in seconds,
ping() sends a ping message to the user's client to determine if he or
she is online.  If the user's client responds within the indicated
period of time, then the method returns true.

This method is also accessible directly from the MP3::Napster::User
object.

If timeout is explicitly set to zero, then the routine will return
immediately without waiting for the reply.  You may intercept the PONG
event with a callback in order to calculate the round-trip time to the
remote user.

=item B<($users,$files,$gigabytes) = $nap-E<gt>stats>

The stats() method returns a three element list containing server
statistics.  The elements of the list are the number of users
currently logged in, the number of song files being shared, and the
total number of gigabytes of the shared files.

Statistics messages (event SERVER_STATS) are issued by the Napster
server at more-or-less random intervals. If no statistics event has
arrived, this method will block until one does.  This is not usually a
problem as the first statistics event arrives soon after login.

=back

=head2 Low-Level Functions

Some low-level functions are documented.  Others are for internal use
and shouldn't be relied upon.  Caveat emptor!

=over 4

=item B<$result = $nap-E<gt>send($event_code,$message)>

This method will send the indicated event code and message to the
server, and will return a result code indicating whether the message
was sent successfully (but not whether it was in the correct format or
correctly processed!)

For a list of event codes, see L<"Outgoing Events"> below.  For the
exact format of the message to send, see the napster.txt document that
accompanies the MP3::Napster distribution.

Example:

  $nap->send(PING,"Poppa_Bear");

=item B<($event,$message) = $nap-E<gt>wait_for(\@event_codes [,$timeout])>

The wait_for() method will block until one of the indicated events
occurs or the call times out, using the optional $timeout argument
(expressed in seconds).  If one of the events occurs, wait_for() will
return a two-element list containing the event code and the message.
If the call times out, the method will return an empty list.

wait_for() provides a number of shortcut variants.  To wait for just
one event, you can pass the event code as a scalar rather than an
array reference.  If you call the method in a scalar context, it will
return just the event code, discarding the message, or undef in the
case of a timeout.

Example 1:

  $nap->send(PING,"Poppa_Bear");
  if ( ($ec,$msg) = $nap->wait_for(PONG,20) ) { # wait 20 seconds
     print "Got a PONG from $msg\n";
  } else {
     print "PING timed out\n";
  }

Example 2:

  $nap->send(PING,"Poppa_Bear");
  $ec = $nap->wait_for([PONG,NO_SUCH_USER],20);
  if ($ec == PONG) {
     print "Got a PONG\n";
  } elsif ($ec == NO_SUCH_USER) {
     print "No such user!\n";
  } else {
     print "Timed out\n";
  }


=item B<($event,$message) = $nap-E<gt>send_and_wait($event_code,$message,\@event_codes [,$timeout])>

This method combines send() with wait_for() in one operation.

Example:

  ($ec,$msg) = $nap->send_and_wait(PING,"Poppa_Bear",[PONG,NO_SUCH_USER],20);
  if ($ec == PONG) {
     print "Got a PONG from $msg\n";
  } elsif ($ec == NO_SUCH_USER) {
     print "Invalid user: $msg\n";
  } else {
     print "Timed out\n";
  }

If timeout is explicitly set to zero, then no wait will be performed
and this call will be equivalent to send().

=item B<$result = $nap-E<gt>process_message($event_code,$message)>

If you wish to insert an event of your own making into the event
queue, process_message() allows you to do so.  This will block until
all callbacks for the event have finished execution.

=back

=head2 Waiting for Downloads

Because file transfers occur in the background, you have to be careful
that your script does not quit while they are still in progress.  The
easiest way to do this is to call wait_for_downloads().  This will
unshare all shared songs to prevent further transfers from being
initiated and then block until the last transfer is finished.  During
this time, the callbacks installed for TRANSFER_IN_PROGRESS and
TRANSFER_DONE will be executed as usual.

If you prefer, you can manually check and wait on pending
transfers. You might want to do this, for instance, if you want to
wait for downloads, but don't care about interrupting pending uploads.
This code fragment illustrates the idiom:

  # wait for the downloads to complete
  while (@d = $nap->downloads) {
    warn "waiting for ",scalar(@d)," downloads to finish...\n";
    my ($event,$download) = $nap->wait_for(TRANSFER_DONE);   
    warn "$download is done...\n";
  }

This is a loop that fetches the list of downloads currently in
progress by calling the downloads() method.  If it is non-empty, then
there are still downloads in progress.  The code prints out a warning
message, and then performs a wait_for() for a TRANSFER_DONE event.
When wait_for() returns, the second item in the result list is the
affected MP3::Napster::Transfer object. The code prints out the
Transfer object (which interpolates the song name as a string), and
goes back to looping.  When all the downloads are done, downloads()
will return an empty list and the loop will finish.

You might want to modify this code to print out the status of finished
downloads and to unlink incomplete song files.  It is also possible to
abort a pending download by calling its abort() method (see
L<MP3::Napster::Transfer>).  See the napster.pl and
eg/simple_download.pl scripts for some ideas on doing this.

Similar code will also work for pending uploads.

To time out the process of waiting for transfers to complete, you can
use a standard eval{} block:

  eval {
     alarm(300);  # allow five minutes for completion
     local $SIG{ALARM} = sub { die "timeout" };
     $nap->wait_for_downloads();
  }
  alarm(0);

You may also adjust an internal timeout used for idle transfers:

=over 4

=item B<$timeout = $nap-E<gt>transfer_timeout([$timeout])>

Internally the module checks transfers at regular intervals and
cancels any that have been inactive for a period of time.  Inactivity
means that no data has been transmitted in either direction.

The default timeout is 300 seconds (five minutes).  You may examine
and change this value with the transfer_timeout() method.

=back

=head1 CALLBACKS

If you wish to write an interactive Napster client based on this
module, you will need to intercept and act on at least some of the
server events that are issued asynchronously after you login. You do
this by installing callbacks, which are simply Perl code references
associated with certain event codes. Once a callback is installed, the
subroutine is invoked whenever the corresponding event occurs.  An
event can have multiple callbacks installed, or no callbacks at all.

=head2 Callback Methods

The callback() and replace_callback() methods allow you to attach and
remove callbacks from events.

=over 4

=item B<$coderef = $nap-E<gt>callback(EVENT_CODE [,$coderef])>

The callback() method assigns a callback subroutine to an event.  The
event code is a small integer constant that is imported by default
when you load MP3::Napster.  See L<"Incoming Events"> for the listing
of event codes.  It is possible to have several callbacks assigned to
a single event.  The subroutines will be called in the reverse order
of which they were assigned.

The two-argument form appends a callback to the event. With a single
argument, callback() returns the list of callbacks currently assigned
to the event.

=item B<$nap-E<gt>replace_callback(EVENT_CODE [,$coderef])>

The replace_callback() method assigns a callback to the indicated
event code, replacing whatever was there before.  When called with a
single event code argument, any callbacks assigned to the event code
are deleted.

=item B<$nap-E<gt>delete_callback(EVENT_CODE [,$coderef])>

The delete_callback() method deletes a callback from the indicated
event code.  If called without a code reference, all callbacks
assigned to the event are cleared.  Use this with caution, as some
callbacks are used internally to handle transfer requests.

=item B<$event_code = $nap-E<gt>event_code>

The event_code() method returns the current event code.  It is most
useful when called from within a callback subroutine to determine what
event triggered the callback.

=item B<$event_code = $nap-E<gt>event_code>

The event_code() method returns the current event code.  It is most
useful when called from within a callback subroutine to determine what
event triggered the callback.

=item B<$event = $nap-E<gt>event>

The event() method returns the current event as the string
corresponding to the event code constant.  For example, the USER_JOINS
code, numeric 406, will be returned by $nap->event_code as numeric
406, and as "USER_JOINS" by $nap->event.

=item B<$message = $nap-E<gt>message($code [,$msg])>

The message() method returns the message associated with the specified
event code.  It can also be used to change the message.  This method
is most useful when used from within a callback.

=back

When a callback is invoked, it is passed three arguments consisting of
the MP3::Napster object, the event code, and a callback-specific
message.  Usually the message is a string, but for some callbacks it
is a more specialized object, such as an MP3::Napster::Song.  Some
events have no message, in which case $msg will be undefined.

Callbacks should have the following form:

 sub callback {
    my ($nap,$code,$msg) = @_;
    # do something
 }

Here's an example of installing a callback for the USER_JOINS event,
in which the message is an MP3::Napster::User object corresponding to
the user who joined the channel:

 sub report_join {
   my ($nap,$code,$user) = @_;
   my $channel = $user->current_channel;
   print "* $user has entered $channel *\n";
 }

 $nap->callback(USER_JOINS,\&report_join);

The same thing can also be accomplished more succinctly using
anonymous coderefs:

 $nap->callback(USER_JOINS,
                sub {
                    my ($nap,$code,$user) = @_;
                    my $channel = $user->current_channel;
                    print "* $user has entered $channel *\n";
                });

Callbacks are invoked in an eval() context, which means that they
can't crash the system (hopefully).  Any error messages generated by
die() or compile-time errors in callbacks are printed to standard
error.

=head2 Handling User Input

If you wish to write an interactive application that takes user input
and passes it on to the Napster server, MP3::Napster provides a way to
monitor a filehandle for available data and invoke a callback whenever
there is a complete line to read.

=over 4

=item B<$nap->command_processor($coderef [,$filehandle])>

The command_processor will install the code reference $coderef to be
called whenever $filehandle has a complete line of data to be read.
If no filehandle is provided, then STDIN is assumed.

=back

Here is an example of using this facility:

 $nap->command_processor(\&do_command,\*STDIN);
 $nap->run;

 sub do_command {
   my $nap  = shift;
   my $line = shift;
   if ($line =~ /^login/) {
      do_login($line);
   } elsif ($line =~ /^whisper/) {
      do_whisper($line);
   }
 }

This example first installs do_command() as the handler for data
coming in on STDIN, and then calls $nap->run, starting the event loop.
Whenever there is a complete line to read the callback will be called
with two arguments consisting a reference to the MP3::Napster object,
and the input line.  The line may end with a terminating newline.  On
end of file, the callback will be called a final time with undef as
the second argument.

The more traditional way of doing this will not necessarily work
satisfactorily:

  while (my $line = <>) {
   if ($line =~ /^login/) {
      do_login($line);
   } elsif ($line =~ /^whisper/) {
      do_whisper($line);
   }
  }

The problem is that the program spends most of its time waiting on
STDIN.  During this time, background processing of file transfers and
other events will not be executed.

=head2 Using MP3::Napster with PerlTk

If you wish to use MP3::Napster with PerlTk, call MP3::Napster->new()
with a B<-tkmain> argument, providing it with the reference to the
main window returned by the Tk::MainWindow() function.  This will
change MP3::Napster's event processing in the following fundamental
ways:

=over 4

=item 1. Outgoing message methods will return immediately.

login(), register(), search() and all the other methods that send
messages to the server will no longer wait for a result, but will
return immediately.  The return value will indicate only whether the
message was successfully queued for transmission.  You must detect the
result of the command by intercepting and handling events returned by
the server.

=item 2. The run(), wait_for(), and send_and_wait() methods return immediately

Similarly, these methods no longer block until an event has occurred
but return immediately.

=item 3. Tk's MainLoop handles I/O

All I/O is handled through Tk's internal event handling, by using
Tk::fileevent() to install a set of filehandles to be monitored for
I/O.  You must call MainLoop() in order for anything to happen.

=back

A very very primitive PerlTk interface to MP3::Napster can be found in
the top level of the MP3::Napster directory in tknapster.pl.  It is
installed automatically in /usr/local/bin during "make install".

=head2 Incoming Events

This is a list of the events that can be intercepted and handled by
callbacks.  Those that are marked as "used internally" may already
have default callbacks installed, but you are free to add your own
using callback().  However be careful before using replace_callback()
or delete_callback() to remove the default handler, and be sure you
know what you're doing!

Not all of the known events are documented here (but will be in later
versions).  In addition, there are a number of events whose
significance is not yet understood by those reverse engineering the
Napster protocol.

=over 4

=item ERROR (code 0)

  Message: <error string>

This is an error message from the server, ordinarily handled
internally by remembering the error text for retrieval by the error()
method.

=item LOGIN_ACK (code 3)

  Message: <email address>

Acknowledgement of a successful login attempt.  Usually handled
internally by the login() and register() methods.

=item REGISTRATION_ACK (code 8)

  Message: none

Server acknowledges a successful registration attempt.  Ordinarily
handled internally by register().

=item ALREADY_REGISTERED (code 9)

 Message: none

Registration has failed because the nickname is taken.  Ordinarily
handled internally by register().

=item INVALID_NICKNAME (code 10)

  Message: none

Registration has failed because the nickname is invalid.  Ordinarily
handled internally by register().

=item LOGIN_ERROR (code 13)

   Message: <error string>

Some error occurred during login (such as invalid password).
Ordinarily handled internally by login().

=item SEARCH_RESPONSE (code 201)

  Message: MP3::Napster::Song

This event is returned in the course of a search to indicate a
matching song.  The event is the MP3::Napster::Song corresponding to
the search result.  There will be one such events for each song that
is matched.  You might want to stuff the result into a global array in
order to build up a list of such responses.  This is ordinarily
handled internally by the search() method.

=item SEARCH_RESPONSE_END (code 202)

  Message: none

This event is returned at the end of a search to indicate that it is
done.  This is ordinarily handled internally by the search() method.

=item DOWNLOAD_ACK (code 204)

  Message: <nick> <ip> <port> "<filename>" <md5> <linespeed>

This event is sent by the server to acknowledge your request for a
download (event DOWNLOAD_REQ).  The message is a string containing
multiple fields.  See napster.txt in the MP3::Napster distribution
for details.  This event is ordinarily handled internally by the
download() method.

=item PRIVATE_MESSAGE (code 205)

  Message: <nick> <msg>

User has sent you a private message.  The message is a string
containing the fields <nick> and <msg> separated by a single space.
You can parse it out with the regular expression /^(\S+) (.*)/

This event is ordinarily ignored.

=item GET_ERROR (code 206)

  Message: <nick> "<filename>"

The file requested for download from user <nick> is unavailable.  The
message is a string containing the user's nickname and the requested
file path, enclosed in quotes.  For example:

	lefty "C:\stuff\mp3\John Phillips Sousa - Oh Canada!"

This condition is usually handled internally by the download() method.

=item USER_SIGNON (code 209)

  Message: <nick> <link>

A user on your hotlist has logged on to the server.  The message
consists of the user's nickname and a small integer indicating the
user's link speed, separated by a space.

Hotlists are not currently implemented in the MP3::Napster API.  This 
message will probably be converted into an MP3::Napster::User object
in the final version.

=item USER_SIGNOFF (code 210)

  Message: <nick>

A user on your hotlist has logged off.

=item BROWSE_RESPONSE (code 212)

  Message: MP3::Napster::Song

During a browse() of another user's shared files, a series of
BROWSE_RESPONSE events will be returned, one for each song on the
user's share list.  The message is converted internally into an
MP3::Napster::Song object.  This is ordinarily handled internally by
the browse() method, but an additional callback can be installed
without interference.

=item BROWSE_RESPONSE_END (code 213)

  Message: none

This event is sent to indicate that list of shared files returned in
response to a browse request is done.  This is ordinarily handled
internally by the browse() method, but an additional callback can be
installed without interference.

=item SERVER_STATS (code 214)

  Message: <users> <files> <gigs>

This event is sent intermittently by the server to give summary
statistics.  The message consists of the number of users, number of
shared files, and total size of shared data in gigabytes, separated by
whitespace. For example:

  1021 8772 932

This event is ordinarily ignored.

=item RESUME_RESPONSE (code 216)

  Message: MP3::Napster::Song

The resume mechanism allows you to complete an interrupted download by 
searching for users who have songs that match the MD5 sum of the first 
300K of the interrupted transfer.

After a RESUME_REQUEST, the server will return a list of all users who
have a song that exactly matches the specified MD5 hash fingerprint.
Each matching song generates a RESUME_RESPONSE event, similar to a
SEARCH_RESPONSE event.  The message contains the matching song.

The resume mechanism is not fully implemented in this version of
MP3::Napster.

=item RESUME_RESPONSE_END (code 217)

  Message: none

This event is sent at the end of a series of resume responses.

=item PUBLIC_MESSAGE (code 403)

  Message: <chan> <nick> <msg>

This event is received when a user sends a public message to one of
the channels in which you are enrolled.  The message consists of the
channel, the user's nickname, and the message, separated by spaces:

    Alternative rastaman What do the colored dots mean?

The fields can be parsed out with this regular expression:

  my ($chan,$nick,$msg) = $message =~ /^(\S+) (\S+) (.*)/;

This event is ignored by default.

=item INVALID_ENTITY (code 404)

  Message: <error string>

This error message is returned when the client has requested an
operation on an invalid user or a channel.  This can be used to
indicate that the user has gone offline, that the user doesn't exist,
or that the channel doesn't exist.  Ordinarily this is handled by
saving the message and making it available in $nap->error.

=item JOIN_ACK (code 405)

  Message: <channel>

This event is sent when you have successfully joined a channel.  It is 
ordinarily handled internally by the join_channel() method.

=item USER_JOINS (code 406)

  Message: MP3::Napster::User

This event is sent when a user joins a channel that you are registered
for.  The message is an MP3::Napster::User object.  To determine
which channel generated the event, interrogate the user object's
current_channel() method.

=item USER_DEPARTS (code 407)

  Message:  MP3::Napster::User

The user has departed one of the channels in which you are enrolled.
To determine which channel generated the event, interrogate the
object's current_channel() method.

=item CHANNEL_USER_ENTRY (code 408)

  Message: MP3::Napster::User

Soon after joining a channel using join(), the server will return a
list of users enrolled in the channel by sending a series of
CHANNEL_USER_ENTRY events.  The message for each event contains a
single MP3::Napster::User object.

This event is ordinarily ignored.

=item CHANNEL_USER_END (code 409)

  Message: none

This event is sent to indicate the end of a series of
CHANNEL_USER_ENTRY events.

=item CHANNEL_TOPIC (code 410)

  Message: <topic>

This event is sent soon after joining a channel and contains the
welcome banner for the channel.  Usually ignored.

=item UPLOAD_REQUEST (code 501)

  Message: <nick> <ip> <port> "<sharename>" <md5> <link>

User <nick> is requesting that you upload to his or her client the
shared file named "sharename", using the indicated IP address and port
to establish an outgoing connection to the remote user's machine.
This event is issued when your client is behind a firewall and cannot
accept incoming connections.  Ordinarily this event is handled
internally and you will not want to replace it.  For details on the
format of the message, see the napster.txt document.

Unlike PASSIVE_UPLOAD_REQUEST, this event requires your client to make
an outgoing connection with the indicated client.

Also see PASSIVE_UPLOAD_REQUEST, TRANSFER_STARTED, TRANSFER_IN_PROCESS
and TRANSFER_DONE.

=item LINK_SPEED_RESPONSE (601)

  Message: <nick> <link>

This event is sent in response to a LINK_SPEED_REQUEST message and
contains the indicated user's link speed as a small integer.
Currently this event is neither triggered by MP3::Napster or handled.

=item WHOIS_RESPONSE (code 604)

  Message: MP3::Napster::User

This event is returned in response to a whois() method, and contains
information about the requested user.  Ordinarily it is handled
internally by whois().

=item WHOWAS_RESPONSE (code 605)

  Message: MP3::Napster::User

This event is returned in response to a whois() method when the user
is currently offline.  It is ordinarily handled internally by whois().

=item PASSIVE_UPLOAD_REQUEST (code 607)

  Message: <nick> "<sharename>"

User <nick> is notifying your client that it will soon establish an
incoming connection to your machine in order to download the shared
file named "filename".  The quotes are part of the message, as in:

  jenz22 "[Antonio Vivaldi] La Notte G minor.mp3"

The "passive" part means that your client does not need to establish
the connection.  It just waits for the remote client's incoming connect.

Ordinarily this event is handled internally.  You definitely do not
want to replace it.

Also see UPLOAD_REQUEST, TRANSFER_STARTED, TRANSFER_IN_PROCESS and
TRANSFER_DONE.

=item SET_DATA_PORT (code 613)

  Message: <port>

The server sends this event when requesting that the client change its
port for incoming connections. The default behavior is to change the
port the client is listening on.  This may not be what you want if
there is a firewall in the way.

=item CHANNEL_ENTRY (code 618)

  Message: MP3::Napster::Channel

After requesting the channel list using channels() the server will
return a series of CHANNEL_ENTRY events, each containing an
MP3::Napster::Channel object.  You may interrogate the object to get
more information about the channel, its users, and topic.

=item LIST_CHANNELS (code 617)

  Message: none

This indicates that the CHANNEL_ENTRY list is finished.

=item USER_OFFLINE (code 620)

  Message: <nick>

The user has gone offline.  This is returned as an error condition for
a variety of user inquiries.  

This description may be mistaken, as newer versions of napster.txt
describe this as an unknown event code.

=item MOTD (code 621)

  Message: <line of text>

A series of message-of-the-day messages are returned soon after
logging into the system.  Each message contains a line of text for
display by the client.  This event is ordinarily ignored.

=item PING (code 751)

  Message: <nick>

This event occurs when another user is attempting to ascertain if your
client is still alive and connected to the network.  The message
contains your nickname.  The client should respond to the PING event
with a PONG message, and in fact the default callback for PING looks
like this:

  $self->callback(PING,sub { my $self = shift;
			     $self->send(PONG,$self->nickname) });


=item USER_LIST_ENTRY (code 825)

  Message: MP3::Napster::User

A series of these events are sent in response to a users() request,
each containing an MP3::Napster::User object corresponding to one of
the users enrolled in the current channel.  This event is ordinarily
handled internally by users().

=item LIST_USERS (code 830)

  Message: none

This is sent at the end of a series of USER_LIST_ENTRY messages to
indicate that the list is finished.

=item TRANSFER_STARTED (code 1024)

  Message: MP3::Napster::Transfer

This event is sent when a download or upload begins.  You may examine
the MP3::Napster::Transfer object to determine the direction of the
transfer and the name of the remote user.

This is actually a pseudo-event generated internally by MP3::Napster,
and not part of the Napster protocol itself.

=item TRANSFER_IN_PROGRESS (code 1025)

  Message: MP3::Napster::Transfer

This event is sent periodically during the course of a download or
upload.  The precise interval can be adjusted with calls to the
Transfer object's interval() method.  You may examine the object to
determine the status of the transfer, and how many bytes have been
transferred.

This is actually a pseudo-event generated internally by MP3::Napster,
and not part of the Napster protocol itself.

=item TRANSFER_DONE (code 1026)

 Message: MP3::Napster::Transfer

This message is sent when a transfer is done.  Examine the object to
determine whether the transfer was completed normally.

This is actually a pseudo-event generated internally by MP3::Napster,
and not part of the Napster protocol itself.

=back

=head2 Outgoing Events

This section is a brief summary of the outgoing commands that you can
send to the Napster server via the send() method.  Most of these
commands are easier to issue through API calls, such as
$nap->search().  You may need to use these outgoing commands to
implement certain features that are not yet part of the API, such as
the various Napster administrative functions.

See the napster.txt document for a fuller description of these
commands.  As with the incoming events, not all of the known commands
are documented here, and there are commands issued by the PC client
whose significance is not yet understood.

=over 4

=item LOGIN (code 2)

  Message: <nick> <password> <port> "<client-version>" <linkspeed>

This requests a login for username <nick> with the specified password,
port, client name and version and link type.  This message is issued
automatically by login().

=item NEW_LOGIN (code 6)

  Message: <nick> <pass> <port> "<client-version>" <linkspeed> <email-address>

This is an alternative login format that is used immediately after a
successful registration request (see below).

=item REGISTRATION_REQUEST (code 7)

  Message: <nick>

This message requests the registration of a new nickname.  It is
issued automatically by the register() method.

=item LOGIN_OPTIONS (code 14)

  Message: NAME:%s ADDRESS:%s CITY:%s STATE:%s PHONE:%s AGE:%s INCOME:%s EDUCATION:%s

This is sent at some point after a successful login or registration in
order to upload the indicated information to the Napster server.  The
description of the message in napster.txt is unclear on when and how
the message should be used.  It is likely that the current module does
not implement it correctly.

=item I_HAVE (code 100)

  Message: "<sharename>" <md5> <size> <bitrate> <frequency> <time>

This message is sent to register a shared song file with the Napster
server.  It is normally handled for you by the share() method.  See
napster.txt for a fuller description.

=item REMOVE_FILE (code 102)

  Message: "<sharename>"

This message removes the indicated shared song from the list
maintained by the server.  It is not currently available in the
MP3::Napster API.

=item SEARCH (code 200)

  Message: (see napster.txt)

This message initiates a search for a shared song.  The message format
is complex, but explained well in napster.txt.

=item DOWNLOAD_REQ (code 203)

  Message: <nick> "<sharename>"

This message notifies the server of the client's intention to download 
file "sharename" from the indicated user.  The server will reply with
a DOWNLOAD_ACK.  This is normally handled for you by the download() method.

=item PRIVATE_MESSAGE (code 205)

  Message: <nick> <message>

This message code sends a private message to the indicated user. It is 
normally handled for you by the private_message()  method.

=item BROWSE_REQUEST (code 211)

  Message: <nick>

This sends a request to the server to browse all the files shared by
the indicated user.  This is ordinarily issued by the browse()
method.  The response is returned as a series of BROWSE_RESPOND events.

=item RESUME_REQUEST (code 215)

  Message: <md5> <size>

This issues a request to search for all songs that match the indicated 
MD5 hash and file size.  This is used to resume previously interrupted 
transfers.  The server replies with a series of RESUME_RESPONSE
events.

The resume facility is not yet implemented in MP3::Napster.

=item DOWNLOADING (code 218)

 Message: none

The client sends this message to the server to indicate that it has
begun downloading a song.  It does nothing except to bump up the
"download" count in the user's profile, and is ordinarily handled
automatically in the download() method.

=item DOWNLOAD_COMPLETE (code 219)

  Message: none

This indicates that the client has completed a download, and reduces
the download count by one.

=item UPLOADING (code 220)

  Message: none

This indicates that the client has begun an upload, and is ordinarily
issued automatically by the module when it has shared files.

=item UPLOAD_COMPLETE (code 221)

  Message: none

This message indicates that the client has finished an upload.

=item JOIN_CHANNEL (code 400)

  Message: <channel>

This is the message that is issued by join() to enroll in a channel.
If succesful, the server will return with a JOIN_ACK.

=item PART_CHANNEL (code 401)

  Message: <channel>

This message is sent when departing a channel, ordinarily issued by
the part_channel() method.  Oddly, the server doesn't acknowledge this 
one.

=item SEND_PUBLIC_MESSAGE (code 402)

  Message: <channel> <message>

This message sends a public message to the indicated channel.  It is
issued by the public_message() method.

=item CHANNEL_TOPIC (code 410)

  Message: <channel> <topic>

This message can be sent in order to change the topic assigned to a
channel.  You probably need special privileges to do this.

=item PASSIVE_DOWNLOAD_REQ (code 500)

  Message: <nick> "<sharename>"

This message requests that the user <nick> make an outgoing connection
to the client's machine and send <sharename>.  It's used in the case
that the owner of the file is behind a firewall and cannot accept
incoming connections.  This message is ordinarily issued for you by
the download() method.

=item LINK_SPEED_REQUEST (code 600)

  Message: <nick>

This message requests a user's link speed.  The result will be a
LINK_SPEED_RESPONSE event.

=item WHOIS_REQ (code 603)

  Message: <nick>

This requests information about the specified user, ordinarily issued
by the whois() method.

=item LIST_CHANNELS (code 617)

  Message: none

This message is sent to get a list of channels and their topics from
the server.  The response is a set of CHANNEL_ENTRY events, followed
by a LIST_CHANNELS event to end the list (yes, the same event code is
used for request and response).  This is ordinarily handled for you by 
the channels() method.

=item DATA_PORT_ERROR (code 626)

  Message: <nick>

The client sends this message to the server when it has attempted and
failed to make an outgoing connection to the indicated user.  This is
issued when appropriate by MP3::Napster's file transfer routines.

=item CHANGE_LINK_SPEED (code 700)

  Message: <link>

This message can be issued after login to change the listed link speed 
for the user.  It is sent (perhaps incorrectly?) by the
change_registration() method.

=item CHANGE_PASSWORD (code 701)

   Message: <password>

This message can be issued after login to change the user's
password.  It is issed by the change_registration() method.  Note that
napster.txt does not document this code; I found it by accident when
trying to change the e-mail address (see below).

=item CHANGE_EMAIL (code 702)

  Message: <email address>

This message can be issued after login to change the user's e-mail
address, or at least so it's documented.  In practice, I get a cryptic
error message from the server

=item CHANGE_DATA_PORT  (code 703)

  Message: <port>

This message is used to inform the server that the client is now
listening on a different port for incoming connections. This message
is issued automatically when processing the SET_DATA_PORT event.
Ordinarily you will not want to manipulate it directly.

=item PING (code 751)

  Message: <nick>

This message sends a PING event to the indicated user, ordinarily
issued by the ping() method.  If the user's client is still online, it
will respond with a PONG message.

=item PONG (code 752)

  Message: <nick>

A client should respond to a PING event with a PONG message.  In fact,
the default callback for the PING event does exactly that.


=item LIST_USERS (code 830)

  Message: <channel>

This message requests a list of all the users in the indicated
channel.  The server replies with a series of USER_LIST_ENTRY events.
followed by a final LIST_USERS event (the same code is used both to
initiate and terminate a user list).  This is ordinarily issued by the
users() method.

=back

=head1 MORE INFORMATION ON THE NAPSTER PROTOCOL

More information on the Napster protocol can be found in the document
"napster.txt" that accompanies this module.  Other information can be
found in the documents and discussion groups available through
opennap.sourceforge.net.

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Napster::User>, L<MP3::Napster::Song>,
L<MP3::Napster::Channel>, and L<MPEG::Napster::Transfer>

=cut

