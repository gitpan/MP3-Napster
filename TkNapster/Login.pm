package MP3::TkNapster::Login;

use strict;

use Tk;
use Tk::widgets qw/DialogBox/;
use MP3::Napster::MessageCodes;
use Carp 'croak';
use constant DEFAULT_SPEED => LINK_56K;

sub new {
  my $class = shift;
  my $main = shift;
  my $self = bless {
		    servers   => {},
		    server    => '',
		    nickname  => '',
		    password  => '',
		    link      => 0,
		    linklabel => '',
		    userport  => 6699,
		    newuser   => '',
		   },$class;
  $self->{window} = $self->make_window($main);
  $self;
}

sub nickname  { shift->{nickname} }
sub password  { shift->{password} }
sub port      { shift->{userport} }
sub newuser   { shift->{newuser}  }
sub link      { shift->{link}  }
sub show      { shift->{window}->Show }
sub server   {
  my $self = shift;
  my $server = $self->{server} or return;
  my ($addr,$meta) = @{$self->{servers}{$server}};
  return wantarray ? ($addr,$meta) : $addr;
}

sub make_window {
  my $self = shift;
  my $main = shift;
  my $bold   = $main->fontCreate(-family=>'Helvetica',-weight=>'bold');
  my $ld = $main->DialogBox(-title   => 'Login',
			    -buttons => ['Connect','Cancel'],
			    -default_button => 'Connect');
  $ld->add('Label',-text=>'Log In',-font=>$bold)->pack(-fill=>'x');
  my $f  = $ld->add('Frame')->pack(-side=>'top',-fill=>'both',-expand=>1);
  my $f1 = $f->Frame->pack(-side=>'left',-fill=>'both',-expand=>1);
  my $f2 = $f->Frame->pack(-side=>'left',-fill=>'both',-expand=>1);
  my $f3 = $f->Frame->pack(-side=>'right',-fill=>'x',-expand=>1);

  $f1->Label(-text=>'Server:',-relief=>'groove')->pack(-side=>'top',-fill=>'x',-expand=>1);
  $f1->Label(-text=>'Nickname:',-relief=>'groove')->pack(-side=>'top',-fill=>'x',-expand=>1);
  $f1->Label(-text=>'Password:',-relief=>'groove')->pack(-side=>'top',-fill=>'x',-expand=>1);
  # this is optional, don't pack it
  my $confirm_l = $f1->Label(-text=>'Confirm:',-relief=>'groove');

  my @servers;
  while (<main::DATA>) {
    next if /^\#/;
    chomp;
    my ($label,$addr,$meta) = /^(\w+)\s+([\w.]+:\d+)\s+(\d+)$/ or next;
    $self->{server} ||= $label;
    push @servers,$label;
    $self->{servers}{$label} = [$addr,$meta];
  }
  $f2->Optionmenu(-variable  => \$self->{server},
		  -options   => \@servers,
		  -width     => 15)->pack(-side=>'top',-fill=>'x',-expand=>1);

  my $n = $f2->Entry(-textvariable=>\$self->{nickname},
		     -width=>20)->pack(-side=>'top',-fill=>'x',-expand=>1);
  my $p = $f2->Entry(-textvariable=>\$self->{password},
		     -width=>20,
		     -show=>'*')->pack(-side=>'top',-fill=>'x',-expand=>1);

  # don't pack this
  my $confirm_e = $f2->Entry(-width=>20,-show=>'*');

  my $do_check = sub {
    my $button = $ld->Subwidget('B_Connect');
    if ($self->{newuser}) {
      $button->configure(-state => $n->get()
			 && $p->get() ne ''
			 && $p->get() eq $confirm_e->get() 
			 ? 'normal' : 'disabled');
    } else {
      $button->configure(-state => $n->get() && $p->get() ? 'normal' : 'disabled');
    }
  };

  $_->bind('<KeyPress>',$do_check) foreach ($n,$p,$confirm_e);
  $_->bind('<Return>','focusNext') foreach ($n,$p,$confirm_e);
  $n->focus;

  # link speed option menu
  ($self->{linklabel} = $LINK{$self->{link} = DEFAULT_SPEED}) =~ s/^LINK_//;
  my @link_speed;
  for (sort {$a<=>$b} keys %LINK) {
    (my $label = $LINK{$_}) =~ s/^LINK_//;
    push @link_speed,[$label=>$_];
  }

  my $linkspeed = $f3->Frame->pack(-side=>'top',-fill=>'both',-expand=>1);
  $linkspeed->Optionmenu(-variable     => \$self->{linklabel},
			 -options      => \@link_speed,
			 -width        => 8,
			 -command      => sub {
			   $self->{link}      = $self->{linklabel};
			   $self->{linklabel} = $LINK{$self->{linklabel}};
			   $self->{linklabel} =~ s/^LINK_//;
			 },
			)->pack(-side=>'right');
  $linkspeed->Label(-text=>"Link Speed: ",-relief=>'groove')->pack(-side=>'right');

  my $port = $f3->Frame->pack(-side=>'top',-fill=>'x',-expand=>1);
  $port->Entry(-textvariable=>\$self->{userport},
	       -width=>6)->pack(-side=>'right');
  $port->Label(-text=>'Port: ',-relief=>'groove')->pack(-side=>'right');

  my $d = $ld->add('Checkbutton',
		   -text         => 'Register as new user',
		   -variable     => \$self->{newuser},
		   -command      => sub {
		     if ($self->{newuser}) {
		       $confirm_l->pack;
		       $confirm_e->pack;
		     } else {
		       $confirm_l->packForget;
		       $confirm_e->packForget;
		     }
		   }
		  )->pack(-side=>'top',-expand=>'x');
  $ld->Subwidget('B_Connect')->configure(-state=>'disabled');
  $ld;
}

1;
