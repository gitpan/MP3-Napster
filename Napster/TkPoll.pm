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
	       }
}

sub set_io_flags {
  my $self = shift;
  my ($fh,$operation,$flag) = @_;

  my ($op,$sub)  = $operation eq 'read' ? ('readable',\&doin)
                                        : ('writable',\&doout);

  unless ($flag) {
    $self->{fileno($fh).$op} && $self->{widget}->fileevent($fh,$op => '');
    undef $self->{$fh,$op};
  } else {
    $self->{widget}->fileevent($fh,$op => [$sub,$fh]);
    $self->{fileno($fh).$op}++;
  }
}

sub doin {
  my $obj = MP3::Napster::IOEvent->lookup_fh(shift) or return;
  $obj->in;
}

sub doout {
  my $obj = MP3::Napster::IOEvent->lookup_fh(shift) or return;
  $obj->out;
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

sub DESTROY {
  my $self = shift;
}

1;


__END__
