package MP3::Napster;

use strict;
use IO::Socket;
use IO::Select;
use Thread qw(cond_wait cond_signal cond_broadcast async yield);
use Thread::Queue;
# use Thread::Signal;
use MP3::Napster::Registry;
use MP3::Napster::Listener;
use MP3::Napster::Channel;
use MP3::Napster::Transfer;
use MP3::Napster::Song;
use MP3::Napster::User;
use Errno 'EWOULDBLOCK';
require Exporter;
use vars qw($VERSION @ISA @EXPORT @EXPORT_OK $DEBUG_LEVEL %FIELDS %RDONLY);

$SIG{PIPE} = 'IGNORE';

$VERSION = '0.95';
$DEBUG_LEVEL = 0;

@ISA = qw(Exporter MP3::Napster::Base);

@EXPORT = qw(LINK_UNKNOWN LINK_14K LINK_28K LINK_33K LINK_56K LINK_64K
	     LINK_128K LINK_CABLE LINK_DSL LINK_T1 LINK_T3 %LINK 
	     ERROR LOGIN LOGIN_ACK NEW_LOGIN REGISTRATION_REQUEST
	     REGISTRATION_ACK ALREADY_REGISTERED INVALID_NICKNAME
	     LOGIN_ERROR LOGIN_OPTIONS I_HAVE REMOVE_FILE SEARCH
	     SEARCH_RESPONSE SEARCH_RESPONSE_END DOWNLOAD_REQ
	     DOWNLOAD_ACK BROWSE_REQUEST BROWSE_RESPONSE
	     BROWSE_RESPONSE_END SERVER_STATS RESUME_REQUEST
	     RESUME_RESPONSE RESUME_RESPONSE_END 
	     WHOIS_RESPONSE WHOWAS_RESPONSE
	     PART_CHANNEL JOIN_CHANNEL
	     SEND_PUBLIC_MESSAGE PUBLIC_MESSAGE_RECVD PRIVATE_MESSAGE 
	     JOIN_ACK USER_JOINS USER_DEPARTS CHANNEL_USER_ENTRY
	     CHANNEL_USER_END CHANNEL_TOPIC LIST_CHANNELS
	     CHANNEL_ENTRY MOTD 
	     LINK_SPEED_REQUEST LINK_SPEED_RESPONSE
	     PASSIVE_DOWNLOAD_REQ PASSIVE_UPLOAD_REQ
	     CHANGE_LINK_SPEED CHANGE_EMAIL CHANGE_DATA_PORT
	     PING PONG  SET_DATA_PORT
	     UPLOADING UPLOAD_COMPLETE 
	     DOWNLOADING DOWNLOAD_COMPLETE
	     TRANSFER_STARTED TRANSFER_DONE TRANSFER_IN_PROGRESS
	     GET_ERROR DATA_PORT_ERROR
	     USER_OFFLINE USER_SIGNON USER_SIGNOFF INVALID_ENTITY
	    );

%FIELDS = map {$_=>undef} qw(ec registry abort server channel socket 
			     nickname listener download_dir
			     tagged_events disconnecting);
%RDONLY = map {$_=>undef} qw(channel_hash main_thread event_thread listen_thread);

# default server for best host
use constant SERVER_ADDR => "208.184.216.223:8875";

use MP3::Napster::Base ('LINK' => {
				    LINK_UNKNOWN => 0,
				    LINK_14K     => 1,
				    LINK_28K     => 2,
				    LINK_33K     => 3,
				    LINK_56K     => 4,
				    LINK_64K     => 5,
				    LINK_128K    => 6,
				    LINK_CABLE   => 7,
				    LINK_DSL     => 8,
				    LINK_T1      => 9,
				    LINK_T3      => 10},
			 'MESSAGES' => {
					ERROR                => 0,
					LOGIN                => 2,
					LOGIN_ACK            => 3,
					NEW_LOGIN            => 6,
					REGISTRATION_REQUEST => 7,
					REGISTRATION_ACK     => 8,
					ALREADY_REGISTERED   => 9,
					INVALID_NICKNAME     => 10,
					PERMISSION_DENIED    => 11,
					LOGIN_ERROR          => 13,
					LOGIN_OPTIONS        => 14,
					I_HAVE               => 100,
					REMOVE_FILE          => 102,
					SEARCH               => 200,
					SEARCH_RESPONSE      => 201,
					SEARCH_RESPONSE_END  => 202,
					DOWNLOAD_REQ         => 203,
					DOWNLOAD_ACK         => 204,
					PRIVATE_MESSAGE      => 205,
					GET_ERROR            => 206,
					USER_SIGNON          => 209,
					USER_SIGNOFF         => 210,
					BROWSE_REQUEST       => 211,
					BROWSE_RESPONSE      => 212,
					BROWSE_RESPONSE_END  => 213,
					SERVER_STATS         => 214,
					RESUME_REQUEST       => 215,
					RESUME_RESPONSE      => 216,
					RESUME_RESPONSE_END  => 217,
					DOWNLOADING          => 218,
					DOWNLOAD_COMPLETE    => 219,
					UPLOADING            => 220,
					UPLOAD_COMPLETE      => 221,
					JOIN_CHANNEL         => 400,
					PART_CHANNEL         => 401,
					SEND_PUBLIC_MESSAGE  => 402,
					PUBLIC_MESSAGE_RECVD => 403,
					INVALID_ENTITY       => 404,
					JOIN_ACK             => 405,
					USER_JOINS           => 406,
					USER_DEPARTS         => 407,
					CHANNEL_USER_ENTRY   => 408,
					CHANNEL_USER_END     => 409,
					CHANNEL_TOPIC        => 410,
					PASSIVE_DOWNLOAD_REQ => 500,
					UPLOAD_REQ           => 501,
					LINK_SPEED_REQUEST   => 600,
					LINK_SPEED_RESPONSE  => 601,
					WHOIS_REQ            => 603,
					WHOIS_RESPONSE       => 604,
					WHOWAS_RESPONSE      => 605,
					PASSIVE_UPLOAD_REQUEST => 607,
					UPLOAD_ACK           => 608,
					SET_DATA_PORT        => 613,
					LIST_CHANNELS        => 617, # used both to start and end channel list
					CHANNEL_ENTRY        => 618,
					USER_OFFLINE         => 620,
					MOTD                 => 621,
					DATA_PORT_ERROR      => 626,
					CHANGE_LINK_SPEED    => 700,
					CHANGE_PASSWORD      => 701,
					CHANGE_EMAIL         => 702,
					CHANGE_DATA_PORT     => 703,
					PING                 => 751,
					PONG                 => 752,
					USER_LIST_ENTRY      => 825,
					LIST_USERS           => 830, # used both to start and end user list
					# pseudo events
					TRANSFER_STARTED     => 1024,
					TRANSFER_DONE        => 1025,
					TRANSFER_IN_PROGRESS => 1026,
					# timeouts
					TIMEOUT              => 2000,
					DISCONNECTING        => 2001,
				       }
			);

my %MULTILINE_CODE = (MOTD()               => 1,
		      CHANNEL_USER_ENTRY() => 1,
		      CHANNEL_ENTRY()      => 1,
		      USER_LIST_ENTRY()    => 1,
		      SEARCH_RESPONSE()    => 1,
		      RESUME_RESPONSE()    => 1,
		      BROWSE_RESPONSE()    => 1,
		      PONG()               => 1,
		     );
my %ERRORS = (
	      ERROR()              => 1,
	      LOGIN_ERROR()        => 1,
	      GET_ERROR()          => 1,
	      ALREADY_REGISTERED() => 1,
	      INVALID_NICKNAME()   => 1,
	      INVALID_ENTITY()     => 1,
	      USER_OFFLINE()       => 1,
	     );

my %MESSAGE_CONSTRUCTOR = (
		   SEARCH_RESPONSE()      => sub  {MP3::Napster::Song->new_from_search(@_) },
		   BROWSE_RESPONSE()      => sub  {MP3::Napster::Song->new_from_browse(@_) },
		   CHANNEL_ENTRY()        => sub  {MP3::Napster::Channel->new_from_list(@_) },
		   CHANNEL_USER_ENTRY()   => sub  {MP3::Napster::User->new_from_user_entry(@_) },
                   USER_LIST_ENTRY()      => sub  {MP3::Napster::User->new_from_user_entry(@_) },
                   WHOIS_RESPONSE()       => sub  {MP3::Napster::User->new_from_whois(@_)},
                   WHOWAS_RESPONSE()      => sub  {MP3::Napster::User->new_from_whowas(@_)},
                   USER_JOINS()           => sub   {MP3::Napster::User->new_from_user_entry(@_)},
                   USER_DEPARTS()         => sub  {MP3::Napster::User->new_from_user_entry(@_)},
		  );

my $LAST_ERROR = '';

# create a new MP3::Napster object, resolving the "best" server
# address using the server server
sub new {
  my $pack = shift;
  my $server = shift;  # caller can override automatic server detection
  my $self = bless { error        => undef,
		     server       => undef,
		     socket       => undef,
		     download_dir => '.',    # download directory
		     download     => {},     # list of downloads
		     upload       => {},     # list of uploads
		     listener     => undef,  # incoming connections
		     channel      => undef,  # current channel
		     messages     => {},     # incoming data, sorted by result code
		     ec           => '',     # last received result code
		     callbacks    => {},     # user callback subroutines
		     tagged_events=> {},     # events that will cause a cond_signal
		     channel_hash => {},     # keep track of channels user is registered for
		     send_queue      => Thread::Queue->new(),  # send queue (outgoing)
		     event_queue     => Thread::Queue->new(),  # event queue (incoming)
		     main_thread     => Thread->self,
		     send_thread     => undef,
		     receive_thread  => undef,
		     event_thread    => undef,
		     listen_thread   => undef,
		     other_threads   => [],
		     registry        => undef,  # registry of local songs
		   },$pack;
  if ($server) {
    $self->server($server);
  } else {
    return unless $self->fetch_server;
  }
  return unless $self->connect();
  $self->registry(MP3::Napster::Registry->new($self));
  return $self;
}

# get/set last error
sub error {
  my $self = shift;
  lock $self if ref $self;
  lock $LAST_ERROR;
  if (@_) {  # setting
    my $error = shift;
    warn "ERROR: $error\n" if $DEBUG_LEVEL > 1;
    $LAST_ERROR    = $error;
    $self->{error} = $error if ref $self;
    return;  # deliberately return undef here
  }
  return ref($self) ? $self->{error} : $LAST_ERROR;
}

# set a timer
sub timer : locked method {
  my $self = shift;
  my $timeout  = shift;
  my $start = time;

  if ($timeout > 0) {
    my $timer_thread = async {
      Thread->self->detach;   # no need to join
      while ($timeout > (time - $start)) {
	select(undef,undef,undef,1);                        # go to sleep for 1 second
	{
	  lock $self;
	  return unless $self->{timeout}{Thread->self->tid};  # while we were sleeping, our timer was removed
	}
      }
      # we've timed out
      warn "timeout!" if $DEBUG_LEVEL > 0;
      my $tid = Thread->self->tid;
      lock $self->{ec};
      $self->ec(TIMEOUT);
      $self->message(TIMEOUT,$tid);
      cond_signal $self->{ec};
    };
    $self->{timeout}{$timer_thread->tid} = 1;
    return $timer_thread->tid;  # return the timer number
  }
}

# clear a timer
sub clear_timer : locked method {
  my $self = shift;
  my $timer = shift;
  return delete $self->{timeout}{$timer} if defined($timer);
  delete $self->{timeout};
}

# get/set the last result for a particular result code
sub message : locked method {
  my $self = shift;
  my $ec = shift;
  return @_ ? $self->{messages}{$ec} = shift
            : $self->{messages}{$ec};
}

# get event as a number
sub event_code {
  return shift->ec;
}

# get event as a string
sub event : locked method {
  return $MESSAGES{shift->ec};
}

# return the listening port
sub port : locked method {
  return 0 unless my $l = $_[0]->listener;
  return $l->port+0;
}

# connect to the server
sub connect : locked method {
  my $self = shift;
  my $server = $self->server;
  return $self->error('no server address defined') unless $server;

  warn "Trying to connect to $server...\n" if $DEBUG_LEVEL > 0;
  my $sock = IO::Socket::INET->new($server);
  return $self->error("connection refused") unless $sock;
  $self->socket($sock);

  warn "Connected: starting event thread...\n" if $DEBUG_LEVEL > 0;
  return unless $self->{event_thread} = Thread->new(\&process_event,$self);

  warn "Starting send thread...\n" if $DEBUG_LEVEL > 0;
  return unless $self->{send_thread} = Thread->new(\&send_loop,$self);

  # install the default callbacks
  $self->install_default_callbacks;

  warn "Starting receive thread..." if $DEBUG_LEVEL > 0;
  return unless $self->{receive_thread} = Thread->new(\&receive_loop,$self);

  return $self->socket;
}

# Mark a file as being available for sharing.
sub share {
  my $self = shift;
  my ($path,$cache) = @_;
  return $self->error('please log in') unless $self->nickname;
  return unless my $reg = $self->registry;
  $reg->share_file($path,$cache);
}

# Start the listening (upload and passive transfer) thread going
sub listen : locked method {
  my $self = shift;
  my $port = shift;
  return $self->error("can't create listener")
    unless $self->listener(MP3::Napster::Listener->new($self));
  if (my $t = $self->listener->start($port)) {
    $self->{listen_thread} = $t;
    $self->send(CHANGE_DATA_PORT,$self->port);
    return $self->port;
  } else {
    $self->listener(undef);
    return;
  }
}

# disconnect
sub disconnect {
  my $self = shift;
  my $wait = shift;
  
  return if $self->disconnecting;
  return unless my $sock = $self->socket;
  $self->disconnecting(1);

  warn "disconnect(): waiting on pending transfers\n" if $DEBUG_LEVEL > 0;
  $self->wait_for_file_transfers($wait||0);

  warn "disconnect(): warning threads that we're done\n" if $DEBUG_LEVEL > 0;
  $self->abort(1);

  warn "disconnect(): warning listener that we're done\n"  if $DEBUG_LEVEL > 0;
  $self->listener->done(1) if $self->listener;

  warn "disconnect(): shutting down send thread\n" if $DEBUG_LEVEL > 0;
  $self->{send_queue}->enqueue(undef);

  for my $t ( @{$self}{qw(send_thread receive_thread event_thread listen_thread)},
	      @{$self->{other_threads}} ) {
    next if !defined($t) || $t->equal(Thread->self);
    $t->eval;
    warn $@ if $@;
    undef $self->{$t};
  }

  $self->socket(undef);
  warn "socket closed" if $DEBUG_LEVEL > 0;
}

sub connected : locked method {
  return unless my $sock = $_[0]->socket;
  return $sock->connected;
}

sub add_thread : locked method {
  my $self = shift;
  return unless my $t = shift;
  push(@{$self->{other_threads}},$t);
}

# wait and clean up file transfers
sub wait_for_file_transfers {
  my $self = shift;
  my $wait = shift;
  my $time = time;

  my %old_status = map {$_ => $_->statusString} $self->transfers;

  while ( (my @t = $self->transfers) and 
	  (my $left = $wait-(time-$time)) > 0 ) {

    warn "waiting for ",scalar(@t)," transfers to finish, time left = $left...\n" if $DEBUG_LEVEL > 0;
    $self->wait_for( TRANSFER_DONE,$left < 30 ? $left : 30 );

    # check whether the status has changed
    # kill any whose status has not changed in 1 minute's time
    foreach ($self->transfers) {
      if ($_->statusString eq $old_status{$_}) {
	warn "$_: status hasn't changed, so killing it\n" if $DEBUG_LEVEL > 0;
	$_->done(1);
	delete $old_status{$_};
	next;
      }
      $old_status{$_} = $_->statusString;
    }

  }
  # out of time
  if (my @t = $self->transfers) {
    warn "times up! killing ",scalar(@t)," old file transfers\n" if $DEBUG_LEVEL > 0;
    for my $t (@t) { 
      $t->done(1);
      $self->wait_for(TRANSFER_DONE,5);  # give it 5 seconds
    }
  }

}

# reconnect
sub reconnect {
  my $self = shift;
  $self->disconnect && $self->connect;
}

# send a public message
sub public_message {
  my $self = shift;
  my $mess = shift;
  my $channel = shift || $self->channel;
  return $self->error('no channel selected') unless $channel;
  $self->send(SEND_PUBLIC_MESSAGE,$channel." $mess");
  1;
}

# send a private message
sub private_message {
  my $self = shift;
  my ($nick,$mess) = @_;
  $self->send(PRIVATE_MESSAGE,"$nick $mess");
  1;
}

# login -- returns e-mail address of nickname if login is successful.
# otherwise stores error message in error(); possible error messages include
# "invalid nickname" and "login error"
sub login {
  my $self = shift;
  my ($nickname,$password,$link_type,$port) = @_;
  $link_type ||= LINK_UNKNOWN;
  $port   = 0 unless defined($port) and $port > 0 and $port < 65534;
  my $version = __PACKAGE__ . " v$VERSION";
  my $message = qq($nickname $password $port "$version" $link_type);
  warn "trying to login...\n" if $DEBUG_LEVEL > 0;

  lock $self->{ec};
  return $self->error('timeout waiting for login')
    unless my ($ec,$msg) = $self->send_and_wait(LOGIN,$message,[LOGIN_ACK,INVALID_ENTITY,LOGIN_ERROR,ERROR],60);
  return unless $ec == LOGIN_ACK;
  $self->nickname($nickname);
  return $self->message(LOGIN_ACK);
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

  warn "requesting permission to register $nickname" if $DEBUG_LEVEL > 0;
  my ($ec,$msg) = $self->send_and_wait(REGISTRATION_REQUEST,$nickname,
				       [REGISTRATION_ACK,ALREADY_REGISTERED,INVALID_NICKNAME],20);
  return unless $ec == REGISTRATION_ACK;

  my $version = __PACKAGE__ . " v$VERSION";
  my $message = qq($nickname $password $att->{port} "$version" $att->{link} $att->{email});
  warn "logging in under $nickname...\n" if $DEBUG_LEVEL > 0;
  return unless  ($ec,$msg) = $self->send_and_wait(NEW_LOGIN,$message,LOGIN_ACK,20);
  return unless $ec == LOGIN_ACK;

  $self->nickname($nickname);
  warn "sending new user data\n" if $DEBUG_LEVEL > 0;
  $att->{$_} ||= '' foreach qw(name address city state phone age education);
  return unless $self->send(LOGIN_OPTIONS,
			    sprintf("NAME:%s ADDRESS:%s CITY:%s STATE:%s PHONE:%s AGE:%s INCOME:%s EDUCATION:%s",
				    @{$att}{qw(name address city state phone age education)}));
  return $msg;
}

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
  warn "search query = $query" if $DEBUG_LEVEL > 0;
  
  # clear the state variable for the search response and trigger a new search
  lock $self->{ec};
  $self->error('');
  $self->message(SEARCH_RESPONSE,[]);
  my $ec = $self->send(SEARCH,$query);
  return unless $self->wait_for(SEARCH_RESPONSE_END,60); # allow 60 seconds to get result
  # return the search results
  return @{$self->message(SEARCH_RESPONSE)};
}

# browse a user's files
sub browse {
  my $self = shift;
  my $nick = shift;
  $self->error('');
  # clear the state variable for the search response and trigger a new search
  lock $self->{ec};
  $self->message(BROWSE_RESPONSE,[]);
  return $self->error('timeout waiting for browse response')
    unless my ($ec,$msg) = $self->send_and_wait(BROWSE_REQUEST,$nick,[BROWSE_RESPONSE_END,USER_OFFLINE,INVALID_ENTITY],30);
  return $self->error('user not online') unless $ec == BROWSE_RESPONSE_END;
  return @{$self->message(BROWSE_RESPONSE)};
}

# get whois information
sub whois {
  my $self = shift;
  my $nick = shift;
  return unless my ($ec,$message) = $self->send_and_wait(WHOIS_REQ,$nick,
							 [WHOIS_RESPONSE,WHOWAS_RESPONSE,INVALID_ENTITY],10);
  return $message if $ec == WHOIS_RESPONSE or $ec == WHOWAS_RESPONSE;
  return;
}

# return server stats as a three-element list
sub stats {
  my $self = shift;
  $self->wait_for(SERVER_STATS) unless defined $self->message(SERVER_STATS);
  return split /\s+/,$self->message(SERVER_STATS);
}

# return list of channels as an array
sub channels {
  my $self = shift;
  lock $self->{ec};
  $self->message(CHANNEL_ENTRY,[]);
  my $ec = $self->send_and_wait(LIST_CHANNELS,'',LIST_CHANNELS,20);
  return @{$self->message(CHANNEL_ENTRY)};
}

# join a channel
sub join_channel {
  my $self    = shift;
  my $channel = shift;
  $channel = ucfirst(lc $channel);
  if ($self->channel_hash->{$channel}) { # already belongs to this one
    $self->channel($channel);  # make it primary
    return $self->channel_hash->{$channel};
  }

  $self->message(CHANNEL_USER_ENTRY,[]); # clear the channel user entry
  return $self->error('timeout') 
    unless my ($ec,$msg) = $self->send_and_wait(JOIN_CHANNEL,$channel,[INVALID_ENTITY,JOIN_ACK],10);
  return unless $ec == JOIN_ACK;
  return $self->channel($channel);
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
  my @channels = sort keys %{$self->channel_hash};
  $self->channel($channels[0]);
  1;
}

# list channels user is member of
sub enrolled_channels : locked method {
  my $self = shift;
  return keys %{$self->channel_hash};
}

# return users in current channel
sub users {
  my $self = shift;
  my $channel = shift || $self->channel;
  return unless $channel;
  lock $self->{ec};
  $self->message(USER_LIST_ENTRY,[]);
  return unless $self->send_and_wait(LIST_USERS,$channel,LIST_USERS,10);
  return @{$self->message(USER_LIST_ENTRY)};
}

# ping a user, return true if pingable
sub ping {
  my $self = shift;
  my ($user,$timeout) = @_;
  return $self->ping_multi($user,$timeout) if ref $user;
  warn "ping(): waiting for a PONG from $user (timeout $timeout)\n" if $DEBUG_LEVEL > 0;
  return unless my ($ec,$message) = $self->send_and_wait(PING,$user,[PONG,INVALID_ENTITY,USER_OFFLINE],$timeout || 5);
  return unless $ec == PONG;
  return grep {lc($user) eq lc($_)} @$message;
}

# ping multiple users, returning their response time within a threshold
sub ping_multi {
  my $self = shift;
  my ($users,$timeout) = @_;
  die "usage ping_multi(\\\@users,\$timeout)" unless ref $users eq 'ARRAY';
  $timeout ||= 5;  # five second wait max
  my $time = time;

  lock $self->{ec};
  $self->message(PONG,[]);  # clear list

  my $pongs = {};
  my $pending = { map {lc $_=>1} @$users };
  my @events = (PONG,INVALID_ENTITY,USER_OFFLINE);

  my $callback = sub {
    my ($nap,$msg) = @_;
    my $ec = $nap->ec;
    my $user = $msg;
    $user = $1 if $ec == INVALID_ENTITY && $msg =~ /ping failed, (\S+) is not online/;
    delete $pending->{lc $user};
    return unless $nap->ec == PONG;
    $pongs->{$user} = time-$time;
  };
  $self->callback($_,$callback) foreach @events;

  # set the timer
  my $timer = $self->timer($timeout);

  # send out the pings
  $self->send(PING,$_) foreach @$users;

  # intercept timeouts and PONGs
  $self->tagged_events( {TIMEOUT()=>1,map {$_=>1} @events} );

  while ( 1 ) {
    cond_wait $self->{ec};
    last if $self->message(TIMEOUT) && $self->message(TIMEOUT) == $timer;
    last unless %$pending;
  }

  $self->clear_timer;
  $self->tagged_events({});

  $self->delete_callback($_,$callback) foreach @events;  # get rid of the callback

  return $pongs;
}

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
  lock $self->{ec};

  #timeout of 15 secs to get an ack
  return $self->error('timeout waiting for download ack') 
    unless ($ec,$message) = $self->send_and_wait(DOWNLOAD_REQ,
						 $message,
						 [DOWNLOAD_ACK,GET_ERROR,
						  ERROR,USER_OFFLINE],15);
  return unless $ec == DOWNLOAD_ACK;
  
  # The server claims that we can download now.  The message contains the
  # IP address and port to fetch the file from.
  my ($nick,$ip,$port,$filename,$md5,$linespeed) = 
    $message =~ /^(\S+) (\d+) (\d+) "([^\"]+)" (\S+) (\d+)/;

  warn "download message = $message\n" if $DEBUG_LEVEL > 0;
  
  # turn nickname into an object
  $nick = MP3::Napster::User->new($self,$nick,$linespeed);

  if ($port == 0) { # oops, they're behind a firewall!
    return $self->error("can't download; both clients are behind firewalls") 
	    unless $self->port > 0;
    return unless my $download = MP3::Napster::Transfer->new_download($self,
								       $nick,
								       $song,
								       $fh,
								       undef);
    my ($rc,$msg) = $self->send(PASSIVE_DOWNLOAD_REQ,qq($nick "$filename"));
    # the listen thread will wait for the remote client to contact us, then initiate
    # the actual transfer.
    return $download;
  }
  
  # turn the IP address into standard dotted quad notation
  my $addr =  join '.',unpack("C4",(pack "V",$ip));  

  # create a new download object
  return unless my $download = MP3::Napster::Transfer->new_download($self,
								     $self->nickname,
								     $song,
								     $fh,
								     "$addr:$port");

  $download->active_transfer;  # this starts a separate thread
  return $download;
}

# change some registration information
# can provide:
#     link     => $new_link_speed,
#     password => $new_password;
#     email    => $new_email;
sub change_registration {
  my $self = shift;
  my %attributes = @_;
  $self->send(CHANGE_LINK_SPEED,$attributes{link})   if defined $attributes{link};
  $self->send(CHANGE_PASSWORD,$attributes{password}) if defined $attributes{password};
  $self->send(CHANGE_EMAIL,$attributes{email})       if defined $attributes{email};
  1;
}

# register/unregster a file transfer
sub register_transfer : locked method{
  my $self = shift;
  my ($type,$object,$register_flag) = @_;

  warn "register_transfer($type,$object,$register_flag)" if $DEBUG_LEVEL > 1;
  my $title = $object->title;

  if ($register_flag) {
    $self->{$type}{lc $object->nickname,$title} = $object;
  } else {
    delete $self->{$type}{lc $object->nickname,$title};
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

sub transfers {
  my $self = shift;
  return ($self->uploads,$self->downloads);
}

# private subroutine called by downloads() and uploads()
sub _transfers : locked method {
  my $self = shift;
  my ($type,$nickname,$path) = @_;
  return values %{$self->{$type}} unless $nickname && $path;
  # protect against confused clients
  my ($title) = $path =~ m!([^/\\]+)$!;
  $nickname = lc $nickname;
  $self->{$type}{$nickname,$title};
}


# register a callback on an event
sub callback : locked method {
  my $self = shift;
  my ($event,$sub) = @_;
  unless (defined $sub) {
    return unless $self->{callbacks}{$event};
    return @{$self->{callbacks}{$event}};
  }
  die "usage: callback(EVENT,\$CODEREF)" unless ref $sub eq 'CODE';
  unshift @{$self->{callbacks}{$event}},$sub;
}

# replace or delete all callbacks 
sub replace_callback : locked method {
  my $self = shift;
  my ($event,$sub) = @_;
  delete $self->{callbacks}{$event} unless $sub;
  $self->{callbacks}{$event} = [$sub] if $sub;
}

# delete a particular callback by address
sub delete_callback : locked method {
  my $self = shift;
  my ($event,$sub) = @_;
  return unless my $carray = $self->{callbacks}{$event};
  $self->{callbacks}{$event} = [ grep { $sub != $_ } @$carray ];
}

# Discover which server is the "best" one for us to contact.
sub fetch_server {
  my $self = shift;
  my $error;
  if (my $socket = IO::Socket::INET->new(SERVER_ADDR)) {
    my $data;
    # fetch all the data available, usually a dozen bytes or so
    if (sysread($socket,$data,1024)) { 
      my ($s) = $data =~ /^(\S+)/;
      return $self->error('server overloaded') if $s =~ /^127\.0\.0\.1:/;
      $self->server($s);
      return 1;
    }
    $error = 'no data returned from napster server';
  } else {
    $error = "connection refused";
  }
  $self->error($error) if $error;
  return;
}

sub send {
  my $self = shift;
  my ($code,$data) = @_;
  $data = '' unless defined $data;
  $self->{send_queue}->enqueue([$code,$data]);
  1;
}

# Send a napster message and wait for a response.
# The message body can be found in the result.
sub send_loop {
  my $self = shift;
  my $queue = $self->{send_queue};
  my $sock  = $self->socket;
  while ( defined (my $msg = $queue->dequeue) ) {
    my ($code,$data) = @$msg;
    warn "sending ",$MESSAGES{$code}||$code," $data\n" if $DEBUG_LEVEL > 1;
    return $self->error('Not connected') unless my $sock = $self->socket();
    {
      lock $sock;
      my $message = pack ("vv",length $data,$code);
      syswrite($sock,$message) or die "Can't syswrite() message code: $!";
      next unless $data;
      syswrite($sock,$data)    or die "Can't syswrite() message data: $!";
    }
  }
  lock $sock;
  warn "done with send_loop(): shutting down socket\n" if $DEBUG_LEVEL > 0;
  $sock->shutdown(1);
}

# Receive a napster message.  This will return a two-element list
# consisting of the message type and the contents of the message.
sub recv {
  my $self = shift;
  return $self->error('Not connected') unless my $sock = $self->socket;

  # read a 4-byte message from the input stream
  warn "recv(): reading message\n" if $DEBUG_LEVEL > 2;
  my $data;
  my $bytes = sysread($sock,$data,4);
  $bytes += 0;
  warn "recv(): got $bytes bytes\n" if $DEBUG_LEVEL > 2;
  warn "recv(): end of file\n"  if !$bytes and $DEBUG_LEVEL > 2;
  return unless $bytes;

  # unpack it into length and type
  my ($length,$type) = unpack("vv",$data);
  return $self->error("Invalid return code: $type") 
    unless $type >= 0 and $type <= 2000;  # allowable range for message

  # read the rest of the data
  if (( my $bytes = $length) > 0) {
    $data = '';
    while ($bytes > 0) {
      return unless my $got = sysread($sock,$data,$bytes,length $data);
      $bytes -= $got;
    }
    return ($type,$data);
  }
  return $type;
}

# send a message and wait for list of result codes
sub send_and_wait {
  my $self = shift;
  my ($outgoing_code,$message,$incoming_code,$timeout) = @_;
  lock $self->{ec};
  return unless $self->send($outgoing_code,$message);
  return $self->wait_for($incoming_code,$timeout)
    unless defined $timeout && $timeout ==0;
}

# Wait for a particular result code or a list of result codes.
# Return the rc and the message body.
sub wait_for {
  my $self = shift;
  my ($ec,$timeout) = @_;
  return unless defined $ec;

  # lock so that we don't miss any events
  lock $self->{ec};
  my %ok = (ref $ec eq 'ARRAY') ? map {$_=>1} @$ec : ($ec=>1);
  warn "waiting for ",join(' ',map {$MESSAGES{$_}||$_} keys %ok)," (timeout = $timeout)\n" if $DEBUG_LEVEL > 1;

  $self->ec('');
  $ok{TIMEOUT()}++ if $timeout;
  foreach (keys %ok) {
    $self->message($_,undef);
  }
  $self->tagged_events(\%ok);

  undef $ec;
  my $msg;

  # keep track of the time
  my $timer = $self->timer($timeout) if $timeout;
  
  cond_wait $self->{ec};
  # see which one of our event codes arrived
  foreach (sort { $a <=> $b} keys %ok) {
    if (defined ($msg = $self->message($_))) { $ec = $_; last }
  }
  warn "wait_for(): got ",$MESSAGES{$ec} || $ec || 'nothing'," $msg\n" if $DEBUG_LEVEL > 1;

  # clear the timeout
  $self->clear_timer($timer) if $timeout;
  # and the list of tagged events
  $self->tagged_events({});  
  return if $ec == TIMEOUT && $msg == $timer;
  return wantarray ? ($ec,$msg) : $ec;
}

# Sort messages from the server into the appropriate slot.
# If multiple messages are present, then 
sub process_message {
  my $self = shift;
  my ($ec,$message) = @_;
  $self->{event_queue}->enqueue([$ec,$message]);
}

sub process_event {
  my $self = shift;
  my $queue = $self->{event_queue};
  warn "process_event(): starting\n" if $DEBUG_LEVEL > 0;
  while (defined (my $msg = $queue->dequeue)) {
    print STDERR "process_event(): locking {ec}..."  if $DEBUG_LEVEL > 2;
    # wait until someone has unlocked {ec}
    lock $self->{ec};
    warn "got it\n"  if $DEBUG_LEVEL > 2;

    my ($ec,$message) = @$msg;
    warn $MESSAGES{$ec} || $ec,defined $message ? ": $message\n" : "\n"  if $DEBUG_LEVEL > 1;

    $self->ec($ec);
    $self->error($message ? "$MESSAGES{$ec}: $message" : $MESSAGES{$ec}) if $ERRORS{$ec};

    # transform some messages
    $message = $MESSAGE_CONSTRUCTOR{$ec}->($self,$message) if $MESSAGE_CONSTRUCTOR{$ec};

    if ($MULTILINE_CODE{$ec}) {
      lock $self;
      push (@{$self->{messages}{$ec}},$message);
    } else {
      $self->message($ec,$message||'');
    }

    $self->invoke_callback($ec,$message);

    # signal threads waiting on any rc
    cond_signal $self->{ec} if $self->tagged_events()->{$ec} || $ec == DISCONNECTING;
  }
  warn "process_event(): done\n" if $DEBUG_LEVEL > 0;
}

# default callbacks
sub install_default_callbacks {
  my $self = shift;


  # ping/pong callback
  $self->callback(PING,sub { my $self = shift;
			     my $data = shift;
			     $self->send(PONG,$data) });

  # channel enrollment
  $self->callback(JOIN_ACK,sub { my $self = shift;
				 my $chan = shift;
				 warn "JOIN_ACK: $chan\n" if $DEBUG_LEVEL > 0;
				 $self->channel_hash->{"\u\L$chan"}++ });
  
  # set data port message (used by server when it can't get in)
  $self->callback(SET_DATA_PORT, sub { my $self = shift;
				       my $newport = shift;
				       return if $newport == $self->port;
				       warn "Set data port: $newport" if $DEBUG_LEVEL > 0;
				       if ($self->port) {
					 lock $self->listener->{done};
					 $self->listener->done(1);
					 cond_wait $self->listener->{done};
				       } else {
					 $self->listener(MP3::Napster::Listener->new($self)) 
					   unless $self->listener;
				       }
				       $self->listener->start($newport);
				       $self->send(CHANGE_DATA_PORT,$self->port);
				     });

  # Handle upload requests when we are not firewalled and the remote
  # user will make an incoming connection to us.
  # We check our registry to see if the sharename is
  # recognized and send an ACK if so.  Otherwise, send a GET_ERROR
  $self->callback(PASSIVE_UPLOAD_REQUEST,
		  sub { my $self = shift;
			my $msg = shift;
			if (!$self->disconnecting
			    and
			    my ($nick,$sharename) = $msg =~ /^(\S+) "([^\"]+)"/) {
			  warn "processing upload request from $nick for $sharename\n" if $DEBUG_LEVEL > 1;
			  my $song = $self->registry->song($sharename);
			  if ($song && 
			      (my $u = MP3::Napster::Transfer->new_upload($self,
									  MP3::Napster::User->new($self,$nick),
									  $song,$song->path))) {
			    $u->status('queued');
			    $self->send(UPLOAD_ACK,$msg);
			    return;
			  }
			}
			$self->send(PERMISSION_DENIED,$msg);
		      });

  # Handle upload requests when we are behind a firewall and are expected
  # to make an (active) outgoing connection to the peer.
  # We check our registry to see if the sharename is recognized
  # and initiate an outgoing connection if so.
  # Otherwise we send a PERMISSION_DENIED
  $self->callback(UPLOAD_REQ,
		  sub {
		    my $self = shift;
		    my $msg = shift;
		    if (!$self->disconnecting
			and
			my ($nick,$ip,$port,$sharename,$md5,$speed) 
			= $msg =~ /^(\S+) (\d+) (\d+) "([^\"]+)" (\S+) (\d+)/) {
		      warn "processing passive upload request from $nick for $sharename" if $DEBUG_LEVEL > 1;
		      if (my $song = $self->registry->song($sharename)) {

			# turn the IP address into standard dotted quad notation
			my $addr =  join '.',unpack("C4",(pack "V",$ip));  
			my $upload = MP3::Napster::Transfer->new_upload($self,
									MP3::Napster::User->new($self,$nick,$speed),
									$song,
									$song->path,
									"$addr:$port");

			# start upload in new thread
			warn "starting active transfer" if $DEBUG_LEVEL > 1;
			$upload->active_transfer;
			return;
		      }
		    }
		    # if we don't share this file...
		    $self->send(PERMISSION_DENIED,$msg);
		  }
		 );

  # handle delayed user offline message, which may be sent for requested downloads
  # eg USER_OFFLINE: Bendewd "D:\Program Files\Napster\Music\12-31-99d1t02-Blue Indian.mp3" 3528852 3
  $self->callback(USER_OFFLINE,
		  sub {
		    my $self = shift;
		    my $msg = shift;
		    return unless my ($user,$path) = $msg =~ /^(\S+) "([^\"]+)"/;
		    foreach ($self->transfers) {
		      if (lc($_->remote_user) eq lc($user)
			  and 
			  lc($_->remote_path) eq lc($path)) {
			warn "$user offline, ",$_->direction," of ",$_->title," cancelled\n" if $DEBUG_LEVEL > 0;
			$_->status("transfer cancelled ($user offline)"); 
			$_->done(1);
		      }
		    }
		  }
		  );
  
}

# invoke each callback in turn
sub invoke_callback {
  my $self = shift;
  my ($event,$message) = @_;
  return unless my @callbacks = $self->callback($event);
  foreach (@callbacks) {
    eval { $_->($self,$message) };  # protect against bad callbacks
    warn $@ if $@;
  }
}

# Start the receive loop as a thread
sub receive_loop {
  my $self = shift;
  warn "starting receive_loop()\n" if $DEBUG_LEVEL > 0;
  while (my($ec,$message) = $self->recv) {
    $self->process_message($ec,$message);
  }
  warn "done with receive_loop(): queing DISCONNECTING\n" if $DEBUG_LEVEL > 0;
  $self->process_message( DISCONNECTING,$self );

  warn "receive_loop(): queueing undef\n" if $DEBUG_LEVEL > 0;
  $self->{event_queue}->enqueue(undef);

  $self->disconnect unless $self->disconnecting;
}

sub DESTROY : locked method{
  shift->disconnect;
}

1;
__END__

=head1 NAME

MP3::Napster - Perl extension for the Napster Server

=head1 SYNOPSIS

  use MP3::Napster;

  my $nap = MP3::Napster->new;

  # log in as "username" "password" using a T1 line
  $nap->login('username','password',LINK_T1) || die "Can't log in ",$nap->error;

  # listen for incoming transfer requests on port 6699
  $nap->listen(6699) || die "can't listen: ",$nap->error;

  # set the download directory to "/tmp/songs"
  mkdir '/tmp/songs',0777;
  $nap->download_dir('/tmp/songs');

  # arrange for incomplete downloads to be unlinked
  $nap->callback(TRANSFER_DONE,
  	         sub { my ($nap,$transf) = @_;
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

  # disconnect after waiting for all pending transfers to finish (10 min max)
  END { $nap->disconnect(600) if $nap }

=head1 DESCRIPTION

MP3::Napster provides access to the Napster MP3 file search and
distribution protocol.  With it, you can connect to a Napster server,
exchange messages with users, search the database of MP3 sound files,
and either download selected MP3s to disk or pipe them to another
program, typically an MP3 player.

=head1 THEORY OF OPERATION

The Napster protocol is asynchronous, meaning that it is
event-oriented.  After connecting to a Napster server, your program
will begin receiving a stream of events which you are free to act on
or ignore.  Examples of events include PUBLIC_MESSAGE_RECVD, received
when another user sends a public message to a channel, and USER_JOINS,
sent when a user joins a channel.  You may install code subroutines
called "callbacks" in order to intercept and act on certain events.
Many events are also handled internally by the module.  It is also
possible to issue a command to the Napster server and then wait up to
a predetermined period of time for a particular event or set of events
to be returned.

Because of its asynchronous operation MP3::Napster makes heavy use of
Perl's Thread class.  You must have a version of Perl built with the
USE_THREADS compile-time option.  At build and install time,
MP3::Napster will check this for you and refuse to continue unless
your version of Perl is threaded.  Other prerequisites are Digest::MD5
and MP3::Info (both needed to handle MP3 uploads).

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

The new() class method will attempt to establish a connection with a
Napster server.  If you wish to establish a connection with a
particular server, you may provide its address and port number in the
following format: aa.bb.cc.dd:PPPP, where PPPP is the port number.
You may use a hostnames rather than IP addresses if you prefer.

If you do not provide an address, MP3::Napster will choose the "best"
server by asking the Napster master server located at
208.184.216.223:8875.  Note that there are several Napster servers,
and that a user logged into one server will not be visible to you if
you are logged into a different one.

If successful, new() return an MP3::Napster object.  Otherwise it will
return undef and leave an error message in $@ and in
MP3::Napster->error.

=item B<$nap-E<gt>disconnect([$wait])>

The disconnect() object method will sever its connection with the
Napster server and tidy up by cancelling any pending upload or
download operations.  If you do not call disconnect(), then your
program will hang until the server decides to manually disconnect you,
which may not be for some time.  The best way to ensure that
disconnect() is always called before your program exits is to put the
method in an END {} block:

  END { $nap->disconnect if defined $nap }

By default, disconnect() will immediately abort all pending downloads
and uploads.  If you wish your script to pause until they are done,
pass disconnect() an argument indicating the number of seconds you are
willing to wait for file transfers to complete.  Disconnect() will
pause until all file transfers are done, or until it times out.
During this period of time, MP3::Napster will not accept new upload
requests.

For other techniques for waiting on file transfers, see the section
L<"Waiting for Downloads Efficiently">.

=item B<$nap-E<gt>reconnect>

This method performs a disconnect() and then a connect(), attempting
to reestablish a connection with the server.

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

=item B<$email = $nap-E<gt>login($nickname,$password [,LINK_SPEED])>

The login() method will attempt to log you in as a registered user
under the indicated nickname and password.  You may optionally provide
a link speed selected from the following list of exported constants:

  LINK_14K   LINK_64K    LINK_T1
  LINK_28K   LINK_128K   LINK_T3
  LINK_33K   LINK_CABLE  LINK_UNKNOWN 
  LINK_56K   LINK_DSL

The link speed will default to LINK_UNKNOWN if absent.  The indicated
speed will be displayed to other users when they browse your list of
shared files and user profile.

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
Otherwise undef will be returned and $self->error will return the
exact error message.  Typical error messages are "user already
registered" and "invalid nickname."

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

=item B<$sharename = $nap-E<gt>share('path/to/a/file.mp3' [,$cache])>

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

=item B<$port = $nap-E<gt>listen([$port])>

The listen() method will launch a thread that listens and services
incoming connections from other clients.  It is used for uploads and
downloads when communicating with clients that are behind firewalls;
you will want to call this even if you are not sharing any files.

You may hard-code a port to listen to and provide it as an argument to
listen().  If you provide a negative port number, or no port number at
all, listen() will select an unused high-numbered port and register it
with the Napster server.  This is recommended if you are on a machine
that is shared by multiple users and there are no firewall issues that
will limit the range of open ports.  The standard port used by the PC
clients is 6699.  

Note that it is possible for the Napster server to tell the module to
change its data port number, and this may happen at any time.  Install
a callback for the CHANGE_DATA_PORT event if you want to be notified
when this happens.

If you are behind a firewall and cannot accept incoming connections,
do not call this method at all as it will incorrectly inform the
Napster server that you can accept incoming connections.  When running
behind a firewall, you will be unable to exchange files with other
firewalled users.  However, you will still be able to upload and
download files from those users who are not firewalled.

If successful, listen() returns the port that it is listening on.
Otherwise it returns undef and leaves the error message in
$nap->error.  Uploads requested by remote users will proceed
automatically without other intervention.  You can receive
notification of these uploads by installing callbacks for the
TRANSFER_STARTED, TRANSFER_IN_PROGRESS and TRANSFER_DONE events or by
interrogating the $nap->uploads() method (described below).

=item

TODO: Provide an API for listing and deleting shared songs.

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
and perform the file transfer in a background thread.  If the download
is successfully initiated, an MP3::Napster::Transfer object will be
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

The wait_for() method will cause the current thread of execution to
sleep until one of the indicated events occurs or the call times out,
using the optional $timeout argument (expressed in seconds).  If one
of the events occurs, wait_for() will return a two-element list
containing the event code and the message.  If the call times out, the
method will return an empty list.

Wait_for() provides a number of shortcut variants.  To wait for just
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

This method combines send() with wait_for() in one operation, and is
actually more reliable than using the two separately.  This is because
send_and_wait() locks the current event queue so that no threads can
update it until after the message is sent and wait_for() has been
called.  Otherwise there is a risk of the desired event occurring
before you have a chance to wait for it.

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
queue, process_message() allows you to do so.  Any threads waiting on
the event will be alerted, and all installed callbacks for the event
will be invoked.

=back

=head2 Waiting for Downloads Efficiently

Because file transfers occur in their own thread, you have to be
careful that your script does not quit while they are still in
progress.  The easiest way to do this is to call disconnect() with a
positive argument indicating the number of seconds you are willing to
wait for pending file transfers to complete.  During this time,
callbacks installed for TRANSFER_IN_PROGRESS and TRANSFER_DONE will be
executed as usual.

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

When a callback is invoked, it is passed two arguments consisting of
the MP3::Napster object and a callback-specific message.  Usually the
message is a string, but for some callbacks it is a more specialized
object, such as an MP3::Napster::Song.  Some events have no message,
in which case $msg will be undefined.

Callbacks should have the following form:

 sub callback {
    my ($nap,$msg) = @_;
    # do something
 }

Here's an example of installing a callback for the USER_JOINS event,
in which the message is an MP3::Napster::User object corresponding to
the user who joined the channel:

 sub report_join {
   my ($nap,$user) = @_;
   my $channel = $user->current_channel;
   print "* $user has entered $channel *\n";
 }

 $nap->callback(USER_JOINS,\&report_join);

The same thing can also be accomplished more succinctly using
anonymous coderefs:

 $nap->callback(USER_JOINS,
                sub {
                    my ($nap,$user) = @_;
                    my $channel = $user->current_channel;
                    print "* $user has entered $channel *\n";
                });

Callbacks are invoked in an eval() context, which means that they
can't crash the system (hopefully).  Any error messages generated by
die() or compile-time errors in callbacks are printed to standard
error.

=head2 Incoming Events

This is a list of the events that can be intercepted and handled by
callbacks.  Those that are marked as "used internally" may already
have default callbacks installed, but you are free to add your own
using callback().  However be careful before using replace_callback()
to remove the default handler, and be sure you know what you're doing!

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

=item PUBLIC_MESSAGE_RECVD (code 403)

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

