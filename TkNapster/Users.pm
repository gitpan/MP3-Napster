package MP3::TkNapster::Users;

use strict;
use MP3::Napster;
use MP3::TkNapster::Globals;

sub new {
  my $class = shift;
  my $nap   = shift;
  bless { nap          => $nap,
	  current_user => undef,
	  users        => {},
	},$class;
}

sub current {
  my $self = shift;
  my $d = $self->{current_user};
  $self->{current_user} = shift if @_;
  $d;
}

sub add {
  my $self = shift;
  $self->{users}{$_} = $_ foreach @_;
}

sub delete {
  my $self = shift;
  CORE::delete @{$self->{users}}{@_};
}

sub users {
  my $self = shift;
  values %{$self->{users}};
}

sub object {
  my $self = shift;
  my $user = shift;
  $self->{users}{$user};
}

sub browse_user {
  my $self = shift;
  my $user = $self->current or return;
  $status = "browsing $user...";
  $songwindow->clear_songs() if defined $songwindow;
  $nap->browse($user);
}

sub ping_user {
  my $self = shift;
  my $user = $self->current or return;
  $status = "pinging $user...";
  $nap->ping($user);
}

sub info_user {
  my $self = shift;
  my $user = $self->current or return;
  $status = "fingering $user...";
  $nap->whois($user);
}

sub whisper_user {
  my $self = shift;
  my $user = $self->current or return;
  my $d = $main->DialogBox(-title=>'Whisper',
			   -buttons=>['OK','Cancel'],
			   -default_button => '');
  $d->add('Label',
	  -text=>"Message to $user")->pack(-side=>'left');
  my $e = $d->add('Entry',
		  -width          => 80,
		 )->pack(-side=>'left');
  $e->bind('<KeyPress-Return>',sub { $d->Subwidget('B_OK')->invoke });
  $e->focus;
  my $button = $d->Show;
  return unless $button eq 'OK';
  $status = "Sending message to $user...";
  $nap->private_message($user,$e->get);
}

1;
