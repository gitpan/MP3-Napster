package MP3::Napster::TransferRequest;
# registers a request to transfer (upload or download)

use strict;
use MP3::Napster;
use MP3::Napster::MessageCodes qw(TRANSFER_IN_PROGRESS TRANSFER_DONE TRANSFER_ABORTED TRANSFER_STARTED TRANSFER_STATUS
				 DOWNLOADING UPLOADING DOWNLOAD_COMPLETE UPLOAD_COMPLETE);
use IO::File;
use Carp 'croak';
use vars '$VERSION';
$VERSION = 1.00;

use overload '""'  => 'asString',
             fallback => 1;


use constant INTERVAL => 100_000;

# compatibility aliases
*bytes         = \&transferred;
*expected_size = \&size;

sub new_upload {
  my $class = shift;
  $class->new(@_,'upload');
}

sub new_download {
  my $class = shift;
  $class->new(@_,'download');
}

sub new {
  my $pack = shift;

  # $file is local filehandle or filename
  # $socket is connected socket or "addr:port"
  # the nickname is the ID of the peer
  # direction is 'upload' or 'download'
  my ($server,$nickname,$song,$file,$direction) = @_;

  no strict 'refs';
  my $fh;
  if (defined(fileno($file))) {
    $fh = $file;
    undef $file;
  }
  my $self = bless {
		    server          => $server,
		    nickname        => $nickname,
		    song            => $song,
		    file            => $file,
		    fh              => $fh,
		    direction       => $direction,
		    offset          => 0,
		    transferred     => 0,
		    size            => 0,
		    last_accessed   => time,
		    interval        => INTERVAL,
		    peer            => undef,
		    status          => 'queued',
		    io_object       => undef,
		   },$pack;

  $self->set_offset($file) if $file;
  $self->server->register_transfer($direction,$self=>1);
  $self->server->process_event(TRANSFER_STARTED,$self);
  return $self;
}

sub done {
  my $self = shift;
  return if $self->aborted;
  if (my $done = shift) {
    $self->_done('transfer complete');
  }
  $self->status eq 'transfer complete';
}

sub abort {
  my $self = shift;
  return if $self->aborted;
  $self->aborted(1);
  $self->_done('transfer aborted');
}

sub _done {
  my $self = shift;
  my $status = shift;
  $self->status($status);
  $self->server->register_transfer($self->direction,$self => 0);
  $self->server->process_event(TRANSFER_DONE,$self);  # send the other one too/ backward compatbility
  $self->server->send_command($self->direction eq 'download' ? DOWNLOAD_COMPLETE : UPLOAD_COMPLETE);
  $self->io_object->close('now') if $self->io_object;
  $self->io_object(undef);
}

sub title {
  my $song = shift->song;
  return $song->name if $song;
}
sub local_path {shift->{file}}

# return the amount of time this object has been idle
sub idle {
  my $self = shift;
  return time - $self->last_accessed;
}

sub status {
  my $self = shift;
  my $d = $self->{status};
  if (@_) {
    $self->{status} = shift;
    $self->server->process_event(TRANSFER_STATUS,$self)
      if $self->server and $self->{status} ne $d;
  }
  $d;
}

sub io_object {
  my $self = shift;
  my $d = $self->{io_object};
  $self->{io_object} = shift if @_;
  $d;
}

sub server    {
  my $self = shift;
  my $d = $self->{server};
  $self->{server} = shift if @_;
  $d;
}


sub aborted {
  my $self = shift;
  my $d = $self->{aborted};
  $self->{aborted} = shift if @_;
  $d;
}

sub interval {
  my $self = shift;
  my $d = $self->{interval};
  $self->{interval} = shift if @_;
  $d;
}

sub last_accessed {
  my $self = shift;
  my $d = $self->{last_accessed};
  $self->{last_accessed} = shift if @_;
  $d;
}

sub size {
  my $self = shift;
  my $d = $self->{size};
  $self->{size} = shift if @_;
  $d;
}

sub offset {
  my $self = shift;
  my $d = $self->{offset};
  $self->{offset} = shift if @_;
  $d;
}

sub set_size_or_offset {
  my $self = shift;
  my $size_or_offset = shift;
  if ($self->direction eq 'download') {
    $self->size($size_or_offset);
  } else {
    $self->offset($size_or_offset);
  }
}

sub peer {
  my $self = shift;
  my $d = $self->{peer};
  $self->{peer} = shift if @_;
  $d;
}

sub direction { shift->{direction} }
sub nickname  { shift->{nickname}  }
sub song      { shift->{song}      }

sub localfh {
  my $self = shift;
  unless ($self->{fh}) {
    my $file = $self->{file};
    my $mode = $self->direction eq 'upload' ? O_RDONLY
                                            : O_WRONLY|O_CREAT|O_APPEND;
    $self->{fh} = IO::File->new($file,$mode);
    croak "Can't open file $self->{file}: $!" unless $self->{fh};
    if ($self->offset) {
      sysseek($self->{fh},$self->offset,0) or die "sysseek(): $!";
      $self->{transferred} = $self->offset;
    }
  }
  $self->{fh};
}

sub increment {
  my $self = shift;
  my $bytes = shift;
  $self->{transferred}  += $bytes;
  if ($self->interval &&
      ($self->{byte_counter} += $bytes) > $self->interval) {
    $self->status('transfer in progress');
    $self->server->process_event(TRANSFER_IN_PROGRESS,$self);
    $self->{byte_counter} = 0;
  }
  $self->last_accessed(time);
}


sub start {
  my $self = shift;
  # tell the server that we have begun up/downloading file
  $self->server->send_command($self->direction eq 'download' ? DOWNLOADING : UPLOADING);
  $self->status('transfer in progress');
}

# keep track of how many bytes are transferred
sub transferred   { shift->{transferred} }

sub set_offset {
  my $self = shift;
  my $file = shift;
  my $size = (stat($file))[7];
  $size = 0 unless defined $size;
  $self->offset($size);
  $self->size($size);
}

# GET or SEND
sub request_method {
  my $self = shift;
  return $self->direction eq 'download' ? 'GET' : 'SEND';
}

# produce the request string that we use for active connections
sub request_string {
  my $self = shift;
  my ($nickname,$title,$size);

  if ($self->direction eq 'download') {
    $title    = $self->song->path;
    $nickname = $self->server->nickname;
    $size     = $self->offset;
  } else {
    $title    = $self->song;
    $nickname = $self->server->nickname;
    $size     = $self->song->size;
  }

  return join (' ',$nickname,qq("$title"),$size);
}

sub remote_user {
  my $s = shift;
  return $s->direction eq 'download' ? $s->song->owner
                                     : $s->nickname;
}
sub local_user {
  my $s = shift;
  return $s->direction eq 'download' ? $s->nickname
                                     : $s->song->owner;
}

sub asString {
  my $s = shift; 
  my $user  = $s->nickname || '';
  my $dir   = $s->direction eq 'download' ? 'from' : 'to';
  my $title = $s->title || '';
  return "($dir $user) $title";
}

sub DESTROY {
   my $self = shift;
   warn "DESTROY $self" if $self->server && $self->server->debug;
}

1;

__END__
