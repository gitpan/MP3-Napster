package MP3::TkNapster::Transfers;

use Tk;
use Tk::widgets qw/ROText LabFrame Adjuster/;
use MP3::Napster::TransferRequest;
use Carp 'croak';
use strict;

sub new {
  my $class = shift;
  my ($main,$nap) = @_;
  croak "usage: TkNapster::Transfer->new(\$scalarref)" unless ref $nap;
  my $self = bless {},$class;
  my $window = $self->init($main);
  @{$self}{qw(window nap transfers) } = ($window,$nap,{});
  $self;
}

sub nap         { ${shift->{nap}}  }
sub window      { shift->{window}  }
sub transfers_t { shift->{text}[0] }
sub local_t     { shift->{text}[1] }
sub show {
  my $w = shift->{window};
  $w->deiconify;
  $w->raise;
}

sub abort_all {
  my $self = shift;
  foreach (keys %{$self->{transfers}}) {
    $self->{transfers}{$_}->abort;
  }
  $self->transfers_t->delete('1.0','end');
}

sub add_download {
  my $self = shift;
  my $download = shift;
  my ($id,$status) = $self->status($download);
  $self->{transfers}{$id} = $download;
  my $text = $self->transfers_t;
  $self->{transfers}{$id} = $download;
  $text->insert('end',"$status\n",$id);
}

sub update_download {
  my $self = shift;
  my $download = shift;
  my ($id,$status) = $self->status($download);
  my $text = $self->transfers_t;
  my $index = $text->index("$id.first");
  my @tags = $text->tagNames($index);
  $text->delete("$id.first","$id.last");
  $text->insert($index,"$status\n",\@tags);
}

sub done_download {
  my $self = shift;
  my $download = shift;
  my ($id,$status) = $self->status($download);
  delete $self->{transfers}{$id};
  my $text = $self->transfers_t;
  $text->tagAdd('done',"$id.first","$id.last");
  $text->tagDelete($id);
}

sub delete_download {
  my $self = shift;
  my $download = shift;
  my ($id,$status) = $self->status($download);
  my $text = $self->transfers_t;
  $text->delete("$id.first","$id.last");
  delete $self->{transfers}{$id};
}

sub status {
  my $self = shift;
  my $transfer = shift;
  my $user   = $transfer->remote_user;
  my $title  = $transfer->song->title;
  my $status = $transfer->status;
  my $bytes  = $transfer->transferred;
  my $total  = $transfer->size;
  my $line   = join("\t",$user,$status,"$bytes/$total",$title);
  my $id     = overload::StrVal($transfer);
  return wantarray ? ($id,$line) : $line;
}

sub abort {
  my $self = shift;
  if (my $l = $self->{selected_objs}) {
    $_->abort foreach @$l;
  }
#  if (my $xy = $self->{selected_pos}) {
#    $self->transfers_t->delete("$xy linestart","$xy lineend + 1 char");
#  }
}

# create widgets and bindings for the song display page
sub init {
  my $self = shift;
  my $main = shift;
  my $tl   = $main->Toplevel(-title=>'Transfers',
			     -takefocus => 1);
  $tl->withdraw;
  $tl->packPropagate(0);

  # make menu
  my $menubar = $tl->Menu;
  $tl->configure(-menu=>$menubar);
  my $file_menu = $menubar->cascade(-label=>'File',
				    -tearoff=>0,
				    -underline=>0,
				   );
  $file_menu->command(-label=>'Add Files...');
  $file_menu->separator;
  $file_menu->command(-label=>'Close',
		      -command=>[$tl=>'withdraw']);

  my $transfer_popup = $main->Menu(-type=>'normal',-tearoff=>0);
  $transfer_popup->command(-label=>'abort',-command=>[ $self=>'abort'] );

  my $down = $tl->LabFrame(-label=>'Active Transfers',-labelside=>'top');
  my $a1 = $tl->Adjuster(-foreground=>'yellow');
  my $local = $tl->LabFrame(-label=>'Shared Files',-labelside=>'top');
  my $side = 'top';

  $_->Subwidget('label')->packConfigure(-anchor=>'w') foreach ($down,$local);

  $down->pack(-side=>$side,-fill=>'both',-expand=>1);
  $a1->packAfter($down,-side=>$side);
  $local->pack(-side=>$side,-fill=>'both',-expand=>1);

  my $f = $down->Frame->pack(-side=>'bottom');
  $f->Button(-text => 'Abort')->pack(-side=>'left',-expand=>1);
  $f->Button(-text => 'Abort All')->pack(-side=>'right',-expand=>1);

  foreach ($down,$local) {
    my $s = $_->Scrolled('ROText',
			 -background => 'black',
			 -foreground => 'yellow',
			 -highlightcolor=>'blue',
			 -scrollbars => 'soe',
			 -insertontime => 0,
			 -cursor     => 'hand2',
			 -wrap       => 'none',
			 -width      => 100,
			 -height     => $_ eq $down ? 10 : 20,
			)->pack(-fill=>'both',-expand=>1);
    $s->tagConfigure('done',-foreground=>'grey');
    $s->tagConfigure('selected',-background=>'blue');
    push(@{$self->{text}},$s);
  }
  $self->{text}[0]->bind('<1>',[\&do_menu,$self,$transfer_popup,Ev('X'),Ev('Y')]);
  $self->{text}[0]->bind('<3>',[\&do_menu,$self,$transfer_popup,Ev('X'),Ev('Y')]);

  $tl->protocol(WM_DELETE_WINDOW=>[$tl => 'withdraw']);
  $tl->packPropagate(1);
  $tl;
}

sub do_menu {
  my $t = shift;
  my $self = shift;
  my $menu = shift;
  my $xy = $Tk::event->xy;
  my @tags = $t->tagNames("$xy");
  return unless @tags;
  $self->{selected_objs} = [ grep {$_} map {$self->{transfers}{$_}} @tags ];
  $self->{selected_pos}  = $xy;
  $t->tagRemove('selected','1.0','end');
  $t->tagAdd('selected',"$xy linestart","$xy lineend");
  $menu->entryconfigure(0,-label => @{$self->{selected_objs}} ?	'abort':'clear');
  $menu->Post(@_);
}

1;
