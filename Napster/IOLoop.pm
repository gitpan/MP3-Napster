package MP3::Napster::IOLoop;

use strict;
use vars qw($VERSION);
use Carp 'croak';

use IO::Socket;
use MP3::Napster::MessageCodes 'TIMEOUT','DISCONNECTED';

use constant CLEANUP_INTERVAL => 60;
$VERSION = 1.00;
my $DEBUG_LEVEL = 0;

sub new {
  my $class  = shift;
  my $pollobject = shift;
  my $self = bless {
		callbacks   => {},
		events      => {},  # events to record
		halt_events => {},  # events to halt on
		pollobject  => $pollobject || new PollObject,
		ec          => undef,
		message     => undef,
		done        => 0,
	       },$class;

  $pollobject->periodic_event(CLEANUP_INTERVAL,
			      [$self => 'do_cleanup' ] ) if $pollobject;
  return $self;
}

sub event_code    { shift->{ec}             }
sub message       { shift->{message}        }
sub pollobject    {
  my $self = shift;
  my $d = $self->{pollobject};
  if (@_) {
    $self->{pollobject} = shift;
  }
  $d;
}

sub disconnect {
  my $self = shift;
  $self->process_event(DISCONNECTED);
  $self->{events} = {};
  $self->{callbacks} = {};
  $self->pollobject->periodic_event(0) if $self->pollobject;
  $self->pollobject(undef);
  $self->done(1);
}


sub debug {
  shift;
  $DEBUG_LEVEL = shift if @_;
  $DEBUG_LEVEL;
}

sub done {
  my $self = shift;
  my $d = $self->{done};
  $self->{done} = shift if @_;
  $d;
}

sub set_event {
  my $self = shift;
  $self->{ec}      = shift if @_ >= 1;
  $self->{message} = shift if @_ >= 1;
  return $self->{ec};
}

# pass through to pollobject
sub set_io_flags {
  shift->{pollobject}->set_io_flags(@_); 
}

sub add_event{
  my $self = shift;
  my ($event,$body) = @_;
  push @{$self->{events}{$event}},$body;
}

sub events {
  my $self = shift;
  my $event = shift;
  if (defined $event) {
    return unless $self->{events}{$event};
    return @{$self->{events}{$event}};
  }
  return keys %{$self->{events}};
}

sub run_until {
  my $self = shift;
  my ($events,$timeout) = @_;

  my $server = $self->server;

  # this will record events
  $self->{events}      = {};

  # this defines the events to halt on
  $self->{halt_events} = {map {$_=>undef} @$events};

  # run until an event occurs
  $self->run($timeout);

  # resume normal operations
  $self->{halt_events} = {};

  # find the event that occurred
  return if $self->events(TIMEOUT);
  foreach (@$events) {
    next unless my @msg = $self->events($_);
    return ($_,@msg);
  }
  return;    # shouldn't happen...
}

sub run {
  my $self    = shift;
  my $timeout = shift;

  # will do cleanup at timed intervals
  my $cleanup = $self->cleanup_interval;

  my $start        = time;
  my $timed_out    = 0;
  my $time_to_task = $cleanup;
  my $poll         = $self->pollobject;
  return unless $poll->can('poll');

  $self->{halt_events}{DISCONNECTED}++;

  while (!$self->done) {
    warn "\npolling...\n" if $self->debug > 2;

    # Did one of the expected events occur?
    last if grep { $self->{events}{$_} } keys %{$self->{halt_events}};

    # record the current time
    my $now = time;

    # Figure out how long to wait for.  
    # If a timeout is defined, then we wait that long or the cleanup interval.
    # Otherwise, we wait one cleanup interval.
    my $pause;
    if (defined $timeout) {
      my $remaining = $timeout - ($now - $start);
      $timeout++ and last if $remaining < 0;    # no time left, so forget it
      $pause = $remaining < $time_to_task ? $remaining : $time_to_task;
    } else {
      $pause = $time_to_task;
    }

    # Call select() now!!!!
    my ($readers,$writers) = $poll->poll($pause);

    # Is it time to run an intermittent task?
    $time_to_task -= (time-$now);
    # do intermittent task if time has expired
    if ($time_to_task <= 0) {
      $self->do_cleanup;
      $time_to_task = $cleanup;
    }

    # Did we time out?
    if (!defined $readers && defined $timeout) {
      $timed_out++;
      last;
    }

    # OK, we've passed all the tests.  Let's just handle I/O now.
    # input
    foreach (@$readers) {
      my $obj = MP3::Napster::IOEvent->lookup_fh($_) or next;
      $obj->in;
    }

    # output
    foreach (@$writers) {
      my $obj = MP3::Napster::IOEvent->lookup_fh($_) or next;
      $obj->out;
    }

  }

  # synthesize a synthetic event for timeouts
  $self->process_event(TIMEOUT,$timeout) if $timed_out;
}

# return the period for performing intermittent tasks
sub cleanup_interval {
  my $self = shift;
  return CLEANUP_INTERVAL;
}

sub do_cleanup {
  my $self = shift;
  # no intermittent events
}

# set a callback for an event
sub callback {
  my $self = shift;
  my ($event,$sub) = @_;
  unless (defined $sub) {
    return unless $self->{callbacks}{$event};
    return @{$self->{callbacks}{$event}};
  }
  die "usage: callback(EVENT,\$CODEREF)" unless ref $sub eq 'CODE';
  unshift @{$self->{callbacks}{$event}},$sub;
}

# clear a particular callback or all callbacks
sub delete_callback {
  my $self = shift;
  my $event = shift;
  defined $event or croak "usage: clear_callback(\$event [,\$coderef])";
  if (my $cb = shift) {
    my @cb = grep {$cb ne $_} @{$self->{callbacks}{$event}};
    $self->{callbacks}{$event} = \@cb;
  } else {
    delete $self->{callbacks}{$event};
  }
}

# process event processes an event and body,
# perform callback, and remember the last event
sub process_event {
  my $self = shift;
  my ($event,$body) = @_;

  warn "$event: $body\n" if $self->debug > 2;
  $self->modify_event(\$event,\$body);

  $self->set_event($event,$body);  # remember last event

  # add event to list if we know we're going to halt
  $self->add_event($event,$body) if %{$self->{halt_events}};

  # flag disconnect events
  $self->done(1) if $event == DISCONNECTED;

  for my $cb($self->callback($event)) {
    eval { $cb->($self,$event,$body) };
    warn $@ if $@;
  }
}

# this gives us a chance to modify the event before processing it
# default is no modification
sub modify_event {
  my $self = shift;
  my ($event,$body) = @_;  # we get references to event code and body
  return;                  # we do nothing by default
}

##########################################################################
#
# PollObject
#
# This is a little internal wrapper around IO::Select, which will make the
# API of IO::Select compatible with the API of PerlTK, GTK, etc
##########################################################################

package PollObject;

use strict;
use IO::Select;

sub new {
  my $class = shift;
  return bless {
		pollin           => IO::Select->new,
		pollout          => IO::Select->new,
		periodic_event   => [0,undef],
	       }
}

sub periodic_event {
  my $self = shift;
  my $d = $self->{periodic_event};
  if (@_) {
    $self->{periodic_event} = [@_];
  }
  @$d;
}

sub set_io_flags {
  my $self = shift;
  my ($fh,$operation,$flag) = @_;

  my $select = $operation eq 'read' ? $self->{pollin} : $self->{pollout};
  if ($flag) {
    $select->add($fh);
  } else {
    $select->remove($fh);
  }
}

sub poll {
  my $self    = shift;
  my $timeout = shift;
  IO::Select->select($self->{pollin},$self->{pollout},undef,$timeout);
}


1;


__END__
