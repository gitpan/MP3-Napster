package MP3::Napster::Transfer;
# upload/download support

use strict;
use Thread qw(cond_wait cond_signal);
use IO::Select;
use IO::Socket;
use IO::File;
use Errno qw(EWOULDBLOCK EINPROGRESS);
use MP3::Napster();
use MP3::Napster::Base;

use vars qw($VERSION @ISA %FIELDS %RDONLY);
$VERSION = '0.03';

@ISA = 'MP3::Napster::Base';
%FIELDS  = map {$_=>undef} qw(position bytes expected_size interval connection);
%RDONLY =  map {$_=>undef} qw(server nickname song direction);


use constant ABORT_CHECK => 1;
use constant TIMEOUT => 10;
use constant INTERVAL => 100_000;

use overload '""'  => 'asString',
             'cmp' => 'cmp';

sub new : locked {
  my $pack = shift;

  # $file is local filehandle or filename
  # $socket is connected socket or "addr:port"
  # the nickname is the ID of the user who will be *receiving* the file
  # direction is 'upload' or 'download'

  my ($server,$nickname,$song,$file,$socket,$direction) = @_;  
  die "MP3::Napster::Transfer->new() must provide following parameters: \$server,\$song,\$local_fh,\$socket,\$direction" 
    unless $server and $song and $direction=~/^(upload|download)$/;

  my $self = bless {
		    server          => $server,
		    nickname        => $nickname,
		    song            => $song,
		    file            => $file,
		    fh              => undef,
		    peer            => $socket,
		    position        => 0,
		    bytes           => 0,
		    direction       => $direction,
		    expected_size   => '??',
		    interval        => INTERVAL,
		    status          => 'waiting for transfer',
		   },$pack;
  $self->server->register_transfer($direction,$self=>1);
  return $self;
}

# (server, song, file, socket)
sub new_upload {
  my $pack = shift;
  my ($server,$nickname,$song,$file,$socket) = @_;  
  return $pack->new($server,$nickname,$song,$file,$socket,'upload');
}

sub new_download {
  my $pack = shift;
  my ($server,$nickname,$song,$file,$socket) = @_;  
  return $pack->new($server,$nickname,$song,$file,$socket,'download');
}

sub title : locked method { 
  shift->song->name  
}
sub remote_path : locked method { 
  shift->song->path  
}
sub local_path : locked method { 
  return unless $_[0]->{file} and !ref($_[0]->{file});
  return $_[0]->{file};
}
sub sender : locked method { 
  shift->song->owner 
}
sub recipient  : locked method  { 
  shift->nickname  
}
sub remote_user  : locked method { 
  my $s = shift;
  return $s->direction eq 'download' ? $s->song->owner
                                     : $s->nickname;
}
sub local_user  : locked method { 
  my $s = shift;
  return $s->direction eq 'download' ? $s->nickname
                                     : $s->song->owner;
}
sub asString  : locked method { 
  my $s = shift; 
  my $user  = $s->remote_user;
  my $dir   = $s->direction eq 'download' ? 'downloading from' : 'uploading to';
  my $title = $s->title;
  return "($dir $user) $title"; }

sub socket : locked method {
  my $self = shift;
  $self->{peer} = $_[0]  if defined $_[0];                     # set the socket
  return $self->{peer}   if ref $self->{peer} and $self->{peer}->isa('IO::Socket');  # return socket if connected

  # otherwise try to establish connection
  my $peer = $self->{peer};
  $self->status("connecting to $self->{peer}");

  # timeout not working
#  my $sock = IO::Socket::INET->new(PeerAddr => $peer,
#				   Proto    => 'tcp',
#				   Type     => SOCK_STREAM,
#				   Timeout  => TIMEOUT);

  # and IO::Socket on 5.00503 doesn't work either!
#   my $sock = IO::Socket::INET->new(Proto    => 'tcp',
# 				   Type     => SOCK_STREAM);

  # so do it manually (sigh)
  my $sock = Symbol::gensym() || die "Can't generate symbol for socket";
  socket($sock,AF_INET,SOCK_STREAM,scalar getprotobyname('tcp')) || die "Can't make socket";
  bless $sock,'IO::Socket::INET';

  my ($addr,$port) = split /:/,$peer;
  $sock->blocking(0);
  unless (connect($sock,pack_sockaddr_in($port,inet_aton($addr)))) {
    if ($! == EINPROGRESS) {
      warn "selecting on non-blocking connect" if $MP3::Napster::DEBUG_LEVEL > 2;
      my $r = IO::Select->new($sock);
      undef $sock unless $r->can_write(TIMEOUT) && $sock->connected;
      warn "finished selecting ($!): ",$sock ? 'got it':'failed' 
	if $MP3::Napster::DEBUG_LEVEL > 2;
    } else {
      undef $sock;
    }
  }

  unless ($self->{peer} = $sock) {
    warn "sending data port error" if $MP3::Napster::DEBUG_LEVEL > 2;
    $self->server->send(MP3::Napster->DATA_PORT_ERROR,
			$self->direction eq 'download' ? $self->song->owner
                                                       : $self->nickname);
    return $self->server->error($self->status("ERROR: couldn't connect to $peer"));
  }

  # put the socket back in ordinary blocking mode
  $sock->blocking(1);

  # read the garbage byte sent by client on incoming connection
  $self->status('reading welcome byte');
  my $data;
  unless ($sock->sysread($data,1)) {
    $self->status("ERROR: couldn't read garbage byte");
    $sock->close;
    $self->{peer} = undef;
    return;
  }

  # if we got here, all is ok
  return $sock;
}

sub fh : locked method { 
  my $self = shift;
  $self->{fh} = $_[0] if defined $_[0];
  return $self->{fh} if $self->{fh};

  return unless my $file = $self->{file};
  { 
    no strict 'refs';
    return $self->{fh} = $file if defined(fileno $file);
  }

  # for uploads, we open handle for reading
  # otherwise we open it for appending (to recover partial downloads)
  my $fh;
  if ($self->direction eq 'upload') { # uploading a file
    $fh = IO::File->new("$file");
  } else {
    $fh = IO::File->new(">>$file");      # downloading, try to append
    $self->position(tell $fh) if $fh;    # position at which we should start downloading
  }

  unless ($self->{fh} = $fh) {
    $self->status("ERROR: Couldn't open $file: $!");
    $self->server->error("Couldn't open $file: $!");
  }
  return $self->{fh};
}

sub cmp {
  my ($a,$b,$reversed) = @_;
  return $reversed ? $a->asString cmp $b
                   : $b cmp $a->asString;
}
# add number of bytes
sub _increment : locked method {
  shift->{bytes} += shift;
}
sub done : locked method {
  my $self = shift;
  $self->{done} = $_[0] if defined $_[0];
  if ($self->status =~ /waiting for transfer|queued|cancelled|connecting/) {  
    $self->server->register_transfer($self->direction,$self=>0);
    $self->server->process_message( MP3::Napster->TRANSFER_DONE,$self );
  }
  # otherwise we just allow the transfer thread to take care of it
  return $self->{done};
}
sub status : locked method { 
  my $self = shift;
  if (defined $_[0]) {
    warn "$self: $_[0]\n" if $MP3::Napster::DEBUG_LEVEL > 1;
    $self->{status} = $_[0];
  }
  $self->{status};
}

# human-readable status string
sub statusString {
  my $self = shift;
  return join ' ',$self->nickname,$self->song,$self->status,$self->bytes.'/'.$self->expected_size;
}


######################################################################
# real work starts here
######################################################################

# connect to remote host and send header
sub active_transfer {
  my $self = shift;
  my $tid = Thread->new(\&_active_transfer,$self);
  unless ($tid) {
    $self->status("ERROR: couldn't spawn new thread");
    $self->server->error("Transfer->active_transfer(): couldn't spawn new thread");
    $self->_finish;
    return;
  }
  if ($MP3::Napster::DEBUG_LEVEL > 2) {
    $self->server->add_thread($tid);
  } else {
    $tid->detach;
  }
  return $tid;
}

# already connected, just start transferring
sub passive_transfer {
  my $self = shift;
  $self->connection('passive');

  # tell the user we have started the transfer
  $self->server->process_message( MP3::Napster->TRANSFER_STARTED,$self );

  # and let the server know too
  $self->server->send($self->direction eq 'download' ? MP3::Napster->DOWNLOADING
		                                     : MP3::Napster->UPLOADING);

  warn "passive_transfer(): checking socket and fh" if $MP3::Napster::DEBUG_LEVEL > 1;
  my $sock = $self->socket;
  my $fh   = $self->fh;

  unless ($sock && $fh) {
    $self->_finish;
    return;
  }

  if ($self->direction eq 'upload') { # passive upload
    warn "passive_transfer(): processing upload request" if $MP3::Napster::DEBUG_LEVEL > 1;
    my $position = $self->position;  # already set for us
    $self->expected_size($self->song->size);
    seek($fh,$position,0);
    $self->bytes($position);
    # send the size of the song
    $sock->send($self->song->size,0);  # send size
    $self->_transfer($fh,$sock);
  } 

  else {  # passive download
    warn "passive_transfer(): processing download request" if $MP3::Napster::DEBUG_LEVEL > 1;
    warn "passive_transfer(): expected size = ",$self->expected_size,' position = ',$self->position if $MP3::Napster::DEBUG_LEVEL > 1;
    $self->status('setting position');
    unless ($sock->send($self->position,0) > 0) {
      $self->status("ERROR: couldn't set position");
      $self->_finish
    } else {
      seek($fh,$self->position,0);
      $self->bytes($self->position);
      $self->_transfer($sock,$fh);
    }
  }
  $self->_finish;
}

# this runs in a separate thread
sub _active_transfer {
  my $self = shift;
  $self->server->process_message( MP3::Napster->TRANSFER_STARTED,$self );
  $self->connection('active');

  my $direction = $self->direction;
  my $data;

  $self->status('initiating active connect');

  # this will initiate the connection if need be
  my $sock = $self->socket;

  # this will open the file if need be
  my $fh   = $self->fh;

  unless ($sock && $fh) {
    $self->_finish;
    return;
  }

  # this is the request and the message that will be sent to the remote client
  my ($req,$title,$message);
  if ($direction eq 'download') {
    $req   = 'GET';
    $title = $self->remote_path;
    $message = join (' ',$self->nickname,qq("$title"),$self->position);
  } else {  # upload
    $req = 'SEND';
    $title = $self->title;
    $message = join (' ',$self->server->nickname,qq("$title"),$self->song->size);
  }

  # tell the server that we have begun up/downloading file
  $self->server->send($direction eq 'download' ? MP3::Napster->DOWNLOADING
		                               : MP3::Napster->UPLOADING);

 TRY: {

    # write out the request
    warn "$self: $req\n" if $MP3::Napster::DEBUG_LEVEL > 1;

    unless ($sock->send($req,0) > 0) {
      $self->status("ERROR: couldn't send $req: $!");
      last TRY;
    }

    warn "$self: $message\n" if $MP3::Napster::DEBUG_LEVEL > 1;
    unless ($sock->send($message,0) > 0) {
      $self->status("ERROR: couldn't send request: $!");
      last TRY;
    }
    # Sent header correctly.  Now try to read result
    $self->status('request sent');

    # The client may send us an error message.
    # Otherwise on downloads it will send us the size of the file.
    # On uploads it will send us the desired starting position
    warn "$self: trying to read header\n" if $MP3::Napster::DEBUG_LEVEL > 1;

   unless ($sock->sysread($data,10) && length $data) {
      $self->status("ERROR: couldn't get data start");
      last TRY;
    } elsif ($data =~ /^(INVALID|FILE NOT FOUND)/) {
      $self->status("ERROR: $data");
      last TRY;
    }

    # start our byte counter off with current position
    # of file
    $self->bytes($self->position);

    # data contains the total size or position to come.  
    # Unfortunately we sometimes get some sound data as well.
    # We detect this by searching for chr(255) -- MP3 data starting
    # or, failing that, "I" (ID3 data starting)
    warn "header = $data\n" if $MP3::Napster::DEBUG_LEVEL > 1;
    if ($data =~ /^(\d+)(\D.*)/) { # music info after the end of the size
      my $music = $2;
      $data = $1;
      warn "$self: writing ",length $music," bytes of music data\n" if $MP3::Napster::DEBUG_LEVEL > 1;  
      syswrite $fh,$music;
      $self->_increment(length $music);
    }

    # If we're doing a download, then the received data is the size.
    if ($direction eq 'download') { # downloading from remote client
      warn "$self: data size = $data\n" if $MP3::Napster::DEBUG_LEVEL > 1;  
      $self->expected_size($data);
      $self->_transfer($sock,$fh);
    } 

    # otherwise the received data is the offset
    else {  # uploading to remote client
      warn "$self: data position = $data\n" if $MP3::Napster::DEBUG_LEVEL > 1;  
      $self->position($data);
      seek $fh,$self->position,0;  # seek to indicated position
      $self->bytes($self->position);
      $self->expected_size($self->song->size);
      $self->_transfer($fh,$sock); # do the transfer
    }
  }

  $self->_finish;
}

# 
# transfer from point a to point b in nonblocking fashion
# with checking for abort
sub _transfer {
  my $self = shift;
  my ($from,$to) = @_;
  my $byte_counter = 0;

  $self->status('transferring');
  my $readers = IO::Select->new($from) || die "Couldn't create reader IO::Select";
  my $writers = IO::Select->new($to)   || die "Couldn't create writer IO::Select";

  $to->blocking(0);    # so that we never block on writes
 TRANSFER:
  while (1) {
    my $data;
    if ($self->done) {
      $self->status($self->direction." interrupted");
      last TRANSFER;
    }

    # wait until $from becomes ready to read
    next TRANSFER unless my ($r) = $readers->can_read(ABORT_CHECK);  

    # try to read some data
    unless ($r->sysread($data,2048)) {  # zero bytes, eof or error
      warn "_transfer(): sysread() returned 0: $!\n" if $MP3::Napster::DEBUG_LEVEL > 2;  
      $self->status('transfer '.($self->bytes >= $self->expected_size ? 'complete' : 'incomplete'));
      $self->done(1);
      last TRANSFER;
    }

    # try to write the data in a nonblocking fashion (this is only relevant when
    # the destination is a socket or pipe)
    my $bytes_written = 0;
    while (length $data) {
      if (my ($s) = $writers->can_write(ABORT_CHECK)) {
	my $bytes = syswrite $s,$data;
	if (!$bytes) {
	  warn "_transfer(): syswrite() failed: $!\n" if $MP3::Napster::DEBUG_LEVEL > 2;  
	  next if $! == EWOULDBLOCK;
	  $self->status("ERROR: ".$self->direction." terminated prematurely: $!");
	  last TRANSFER;
	}
	substr($data,0,$bytes) = '';
	$bytes_written += $bytes;
      } else {
	next TRANSFER if $self->done;
      }
    }
    $self->_increment($bytes_written);
    if ( $self->interval &&  ($byte_counter += $bytes_written) > $self->interval) {  # generate a callback every 10K bytes
      $self->server->process_message ( MP3::Napster->TRANSFER_IN_PROGRESS,$self );
      $byte_counter = 0;
    }
  }
}

sub _finish {
  my $self = shift;
  warn $self->direction," finished, status = ",$self->status,"\n" if $MP3::Napster::DEBUG_LEVEL > 2;  
  $self->done(1);
  $self->fh->close     if ref $self->{fh};
  $self->socket->close if ref $self->{peer};
  warn "calling register_transfer\n" if $MP3::Napster::DEBUG_LEVEL > 2;  
  $self->server->register_transfer($self->direction,$self=>0);
  warn "calling process_message() x 2\n" if $MP3::Napster::DEBUG_LEVEL > 2;  
  $self->server->process_message( MP3::Napster->TRANSFER_IN_PROGRESS,$self );
  $self->server->process_message( MP3::Napster->TRANSFER_DONE,$self );
  # tell the server that we have finished up/downloading file
  $self->server->send($self->direction eq 'download' ? MP3::Napster->DOWNLOAD_COMPLETE
		                                     : MP3::Napster->UPLOAD_COMPLETE);
}

1;

__END__

=head1 NAME

MP3::Napster::Transfer - Manage Napster file transfer sessions

=head1 SYNOPSIS

  $transfer = $nap->download($song);
  print $transfer->asString,"\n";

  print $transfer->title,"\n";
  print $transfer->song,"\n";
  print $transfer->remote_path,"\n";
  print $transfer->local_path,"\n";
  $fh = $transfer->fh;

  print $transfer->sender,"\n";
  print $transfer->recipient,"\n";
  print $transfer->remote_user,"\n";
  print $transfer->local_user,"\n";

  print $transfer->direction,"\n";
  print $transfer->status,"\n";
  print $transfer->bytes,"\n";
  print $transfer->expected_size,"\n";

  print $transfer->done;

  $transfer->interval(100_000);  # set reporting interval to 100K
  $transfer->done(1);            # abort transfer

=head1 DESCRIPTION

MP3::Napster::Transfer allows you to monitor and control upload and
download sessions initiated by the MP3::Napster module.

=head2 OBJECT CONSTRUCTION

Transfer objects are not constructed from scratch, but are created
during the operation of MP3::Napster clients.  Transfers from remote
clients to the local machine are created by the download() method.
Uploads to remote clients are created in response to requests by the
Napster server.

=head2 OBJECT METHODS

Object methods provide access to transfer status information and allow
you terminate the transfer prematurely.

=over 4

=item B<Accessors>

The accessors provide read-only access to the following attributes:

 Accessor                   Description
 --------                   -----------
 $transfer->title           Title of the transfer, currently derived from the song name
 $transfer->direction       Direction of the transfer, either "upload" or "download"
 $transfer->asString        String of form "(downloading from foo) ChaChaCha.mp3"
 $transfer->remote_path     Path to the song on the remote host
 $transfer->local_path      Path to the song on the local host
 $transfer->fh              Filehandle connected to the local song file
 $transfer->socket          Socket connected to the remote host

NOTES: In the case of a song that is being downloaded to a file, local_path()
will return the path on the local machine.  In the case of a download
that is being piped to a program, local_path() will return undef.  In
either case, fh() will return the local filehandle and socket() will
return the handle connected to the remote host.

 $transfer->sender          Nickname of sender
 $transfer->recipient       Nickname of recipient
 $transfer->remote_user     Nickname of remote user
 $transfer->local_user      Nickname of local user

NOTES: These four methods return MP3::Napster::User objects
corresponding to the two users involved in the transfer.  Local_user()
will always return the MP3::Napster::User that you are logged in as
and remote_user() will always return the nickname of the peer, but
send() and receipient() will vary depending on the direction of the
transfer.

 $transfer->status          Status of the transfer (see NOTES)
 $transfer->statusString    Status plus transfer progress
 $transfer->bytes           Number of bytes transferred
 $transfer->expected_size   Expected size of the transfer
 $transfer->connection      Connection type: "active" or "passive"

NOTES: The expected_size() method returns the total size of the song,
in bytes, even when resuming from an interrupted transfer.  However,
in the latter case, bytes() will be set to the size previously
transferred.

A transfer can either be initiated by the local host, in which case an
outgoing connection is made to the peer, or it can be initiated by the
peer, in which case the peer makes an incoming connection to the local
host.  The connection() method returns "active" in the former case,
and "passive" in the latter.  In the case of two non-firewalled peers,
downloads are active and uploads are passive.  If one of the peers is
behind a firewall, then the firewalled peer makes active connections
exclusively.

The status() method returns a human readable string indicating the
current status of the transfer.  The status states vary depending on
whether the transfer is active or passive.  The following status
strings are possible in either case:

 "waiting for transfer"           Object created, waiting for something to happen
 "transferring"                   Data transfer is in progress
 "transfer complete"              Transfer done, file transferred completely
 "transfer incomplete"            Transfer done, file transferred incompletely
 "ERROR: <error message>"         An error of some sort

The difference between "transfer incomplete" and "ERROR" is that in
the former situation the transfer was cancelled prematurely by the
local host or the peer, while in the latter the transfer was
terminated by a software error of some sort.

These additional status strings are possible for active connections:

 "initiating active connect"      Beginning an outgoing connection
 "connecting to aa.bb.cc.dd:port" Trying to connect to remote peer
 "reading welcome byte"           Reading a 1 byte acknowledgement from peer 
 "request sent"                   Sent request and waiting for transfer

This additional status string is possible for passive connections:

 "setting position"               Setting file position for interrupted transfers

The "transferring", "transfer complete", "transfer incomplete", and
"ERROR" status messages are guaranteed never to change.  The other
status strings may be modified in later versions of this module.

=item B<$done = $transfer-E<gt>done( [$flag] )>

The done() method will return a true value if the transfer is
finished.  You may check its status() method to determine whether the
transfer finished normally or abnormally.

To prematurely abort a file transfer, you may pass a true value to
done():

 $transfer->done(1);  # abort!

=item B<$interval= $transfer-E<gt>interval( [$interval] )>

The MP3::Napster::Transfer object issues up to three Napster events
during its lifetime, any one of which can be intercepted by callbacks:

 TRANSFER_STARTED      When the transfer is first initiated
 TRANSFER_DONE	       When the transfer is finished
 TRANSFER_IN_PROGRESS  At periodic intervals during the transfer

The interval() method allows you to get or set the interval at which
TRANSFER_IN_PROGRESS messages are issued.  The interval is measured
bytes, so you can set interval() to 100,000 in order to be notified
each time approximately 100K of data is transferred (the exact number
varies by up to 1K depending on how much is sent in any given read()
or write() call).  If you do not wish to receive such messages, set
interval() to 0.

Example:

  $transfer->interval(250_000);  # notify every 250K

As explained in L<MP3::Napster>, the callback for these events will
receive two arguments consisting of the MP3::Napster object and the
MP3::Napster::Transfer object.  Here are practical examples of
intercepting and using the three events to produce informational
messages:

  $nap->callback(TRANSFER_STARTED,
             sub { 
	        my ($nap,$transfer) = @_;
                return unless $transfer->direction eq 'upload';
                my $song = $transfer->song;
                my $nick = $transfer->remote_user;
                print "\t[ $nick has begun to download $song ]\n";
              });

  $nap->callback(TRANSFER_IN_PROGRESS,
             sub { 
                my ($nap,$transfer) = @_;
                my ($bytes,$expected) = ($transfer->bytes,$transfer->expected_size);
                print "\t[ $transfer: $bytes / $expected bytes ]\n";
             });

  $nap->callback(TRANSFER_DONE,
             sub { 
                my ($nap,$transfer) = @_;
                my $song = $transfer->song;
                print "\t[ $song done: ",$transfer->status," ]\n";

                if ($transfer->direction eq 'download' &&
	               $transfer->status ne 'transfer complete' && 
	                   $transfer->local_path) {
                    print "\t[ $song incomplete: unlinking file ]\n";
                    unlink $transfer->local_path;
                }
             });

=item B<String Overloading>

If used in a string context, MPEG::Napster::Transfer objects will
invoke the asString() method.  This allows the objects to be directly
interpolated into strings, printed, and pattern matched.

=back

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Napster>, L<MP3::Napster::User>, L<MP3::Napster::Channel>, and
L<MPEG::Napster::Song>

=cut

