package MP3::Napster::TkPoll;

use strict;
use Carp 'croak';
use Tk;

sub new {
  my $class  = shift;
  my $widget = shift;
  return bless {
		widget          => $widget,
		periodic_event  => 0,
		handles         => {},
	       }
}

sub set_io_flags {
  my $self = shift;
  my ($fh,$operation,$flag) = @_;

  my $op = $operation eq 'read' ? 'readable' : 'writable';
  my $cb;
  if ($flag) {
    my $obj = MP3::Napster::IOEvent->lookup_fh($fh);
    $cb = $operation eq 'read' ? [$obj=>'in'] : [ $obj=>'out' ];
    $self->{handles}{fileno($fh)} = $fh;
  } else {
    $cb = '';
    delete $self->{handles}{fileno($fh)};
  }

  if (my $obj = tied *$fh) {
    my $imode = Tk::Event::IO::imode($op);
    $obj->handler($imode,$cb);
  } else {
    $self->{widget}->fileevent($fh,$op=>$cb);
  }

}

sub handles {
  return values %{shift->{handles}};
}

sub periodic_event {
  my $self = shift;
  my $id = $self->{periodic_event};
  if (@_ == 2) {
    my($seconds,$callback) = @_;
    my $id = $self->{widget}->repeat($seconds*1000,$callback);
    $self->{periodic_event} = $id;
  } elsif (@_ == 1 && $_[0] == 0) {
    $self->{widget}->afterCancel($id);
  }
  $id;
}

# these two subroutines are provided for API compatibility, but not
# actually used, since Tk handles callbacks itself
sub doin {
  my $obj = MP3::Napster::IOEvent->lookup_fh(shift) or return;
  $obj->in;
}

sub doout {
  my $obj = MP3::Napster::IOEvent->lookup_fh(shift) or return;
  $obj->out;
}

sub DESTROY {
  my $self = shift;
}

package Tk::Event::IO;

no warnings 'redefine';

sub BINMODE {
  my $obj = $_[0];
  binmode($obj->handle);
}

sub WRITE {
 my $obj = $_[0];
 return syswrite($obj->handle,$_[1],$_[2]);
}

sub READ
{
 my $obj = $_[0];
 my $h = $obj->handle;
 return sysread($h,$_[1],$_[2],defined $_[3] ? $_[3] : 0);
}

1;

__END__
