package MP3::TkNapster::Songlist;

use Tk;
use Tk::widgets qw/ROText LabFrame Adjuster/;
use IO::File;
use Carp 'croak';
use MP3::TkNapster::Globals;
use strict;

use constant FIND_ICON     => '/usr/X11R6/include/X11/pixmaps/app_find.xpm';
use constant C_BITMAP => <<'END';
#define cancel_width 8
#define cancel_height 8
static char cancel_bits[] = {
  0x81, 0x42, 0x24, 0x18, 0x18, 0x24, 0x42, 0x81, };
END
;
use constant MAXLEN => 40;  # maximum length of song title

sub new {
  my $class = shift;
  my ($main,$nap) = @_;
  croak "usage: TkNapster::Songlist->new(\$scalarref)" unless ref $nap;
  my $self = bless {},$class;
  my $window = $self->init($main);
  $self->{window} = $window;
  $self->{songs}  = {};
  $self->{c_direction} = +1;
  $self->{nap}    = $nap;
  $self;
}

sub nap { ${shift->{nap}} }
sub songwindow { shift->{window} }

# create widgets and bindings for the song display page
# gosh! this got awfully long
sub init {
  my $self = shift;
  my $main = shift;
  my $tl   = $main->Toplevel(-title=>'Song Browser',
			     -takefocus => 1);
  $tl->withdraw;
  $tl->packPropagate(0);
  $self->{searchstatus} = 'Ready';
  $self->{search}       = '';

  # make menu
  my $menubar = $tl->Menu;
  $tl->configure(-menu=>$menubar);
  my $file_menu = $menubar->cascade(-label=>'File',
				    -tearoff=>0,
				    -underline=>0,
				   );
  $file_menu->command(-label=>'Close',
		      -command=>[$tl=>'withdraw']);

  # popup menu for songs
  my $song_popup = $main->Menu(-type=>'normal',-tearoff=>0);
  $song_popup->command(-label=>'Fetch',-command => sub { $self->fetch_song    } );
  $song_popup->command(-label=>'Play',-command  => sub { $self->fetch_song(1) } );

  if (-e FIND_ICON) {
    my $image = $main->Pixmap(-file=>FIND_ICON);
    $tl->iconimage($image);
  }

  # frame for controls
  my $f1 = $tl->Frame->pack(-side=>'top',-fill=>'x');
  $f1->Label(-text=>'Search: ')->pack(-side=>'left');

  my $e = $f1->Entry(-textvariable=>\$self->{search})->pack(-side=>'left',-fill=>'x',-expand=>1);
  $e->bind('<KeyPress-Return>',sub {
	     return unless $e->index('end');
	     $self->clear_songs();
	     $self->{searchstatus} = 'Searching...';
	     $self->nap->search(title=>$e->get(),limit=>200);
	   });

  my $clear_b  = $f1->Button(-text     => 'Clear')->pack(-side=>'left');
  my $search_b = $f1->Button(-text     => 'Search',
			     -state    => 'disabled',
			     -command  => sub { $self->clear_songs();
						$self->nap->search(title=>$e->get(),limit=>200) },

			    )->pack(-side=>'left');

  my $italic = $main->fontCreate(-family=>'Helvetica',-slant=>'italic');
  my $bold   = $main->fontCreate(-family=>'Helvetica',-weight=>'bold');
  my $normal = $main->fontCreate(-family=>'Helvetica');

  my $f3 = $tl->Frame->pack(-side=>'bottom',-fill=>'x');
  my $f2 = $tl->LabFrame(-label=>'Search Results',
			   -labelside=>'acrosstop')->pack(-side=>'top',-fill=>'both',-expand=>1);
  my $s = $f2->Scrolled('ROText',
			-background => 'black',
			-foreground => 'yellow',
			-highlightcolor=>'blue',
			-scrollbars => 'soe',
			-insertontime => 0,
			-height     => 20,
			-font       => $normal,
			-cursor     => 'hand2',
			-wrap       => 'none',
			-tabs=>[qw(2.0i right 2.8i right 3.7i right 4.2i)]
		       )->pack(-fill=>'both',-expand=>1);
  my $songtext = $s->Subwidget('rotext');
  $songtext->tag(configure=>$_,-foreground=>'gray')   foreach qw(? UNKNOWN);
  $songtext->tag(configure=>$_,-foreground=>'red')    foreach qw(14K 28K 33K);
  $songtext->tag(configure=>$_,-foreground=>'yellow') foreach qw(56K 64K);
  $songtext->tag(configure=>$_,-foreground=>'green')  foreach qw(128K CABLE DSL);
  $songtext->tag(configure=>$_,-foreground=>'green',-font=>$bold)  foreach qw(T1 T3);
  $songtext->tag(configure=>'header',
		 -foreground=>'yellow',
		 -underline=>1);
  $songtext->tagBind('header','<1>'=>''); # nothing
  $songtext->tagConfigure('selected',-background=>'blue');
  $songtext->tagConfigure('nickname',-underline=>1,-foreground=>'sienna');
  $songtext->tagConfigure('transferring',-font=>$italic);
  $songtext->tagBind('nickname','<3>',
		     [ sub {
			 my $w = shift;
			 my $menu = shift;
			 my $xy = $Tk::event->xy;			 
			 my ($start,$end) = $w->tagNextrange('nickname',"$xy linestart","$xy lineend");
			 $users->current($w->get($start,$end));
			 $menu->Post(@_);
		       },
		       $user_popup,
		       Ev('X'),Ev('Y')]);
  $songtext->tag(bind=>'nickname','<1>',
		 sub { my $t = shift;
		       my $xy = $Tk::event->xy;
		       my ($start,$end) = $t->tagNextrange('nickname',"$xy linestart","$xy lineend");
		       $users->current($t->get($start,$end));
		     }
		);
  $songtext->tag(bind=>'nickname','<Double-Button-1>',sub { $users->info_user });

  my $transfer_frame = $f2->LabFrame(-label=>'Active Transfers',-labelside=>'top');
  $transfer_frame->Subwidget('label')->packConfigure(-anchor=>'w');
  $transfer_frame->pack(-side=>'top',-fill=>'both',-expand=>1);

  $tl->Adjuster(-foreground=>'yellow')->packAfter($s,-side=>'top');

  my $transfers = $transfer_frame->Scrolled('ROText',
					    -background => 'black',
					    -foreground => 'yellow',
					    -highlightcolor=>'blue',
					    -scrollbars => 'soe',
					    -insertontime => 0,
					    -height     => 3,
					    -font       => $normal,
					    -cursor     => 'hand2',
					    -wrap       => 'none',
					    -tabs=>[qw(0.3i 4.35i right 5.10i right 5.2i)],
					   )->pack(-fill=>'both',-expand=>1);
  my $transfer_t = $transfers->Subwidget('rotext');
  $transfer_t->tagConfigure('upload',-foreground=>'red');
  $transfer_t->tagConfigure('download',-foreground=>'yellow');
  $transfer_t->tagConfigure('done',-foreground=>'grey');

  $tl->Label(-textvariable => \$self->{searchstatus},
	     -relief       => 'ridge')->pack(-side=>'top',-fill=>'x');


  my $abort_uploads_b = $f3->Button(
				    -text    => 'Abort Uploads',
				    -command => sub { $self->abort('upload') },
				    -state => 'disabled',
				    )->pack(-side=>'left',-expand=>1);
  my $abort_downloads_b = $f3->Button(
				      -text    => 'Abort Downloads',
				      -command => sub { $self->abort('download') },
				      -state => 'disabled',
				    )->pack(-side=>'left',-expand=>1);

  my @searchbuttons;
  push @searchbuttons,$f3->Button(-text=>'Download',
				  -state=>'disabled',
				  -command=> [$self=>'fetch_song'],
				 )->pack(-side=>'left',-expand=>1);
  push @searchbuttons,$f3->Button(-text=>'Play',
				  -state=>'disabled',
				  -command => sub {$self->fetch_song(1) }
				 )->pack(-side=>'left',-expand=>1);
  $tl->protocol(WM_DELETE_WINDOW=>[$tl => 'withdraw']);

  $clear_b->configure(-command  => [$self=>'clear_all'] );

  $e->bind('<KeyPress>',sub {
	     $self->adjust_buttons;
	     $search_b->configure(-state=>length $self->{search} ? 'normal' : 'disabled')
	   });

  $songtext->bind('<1>',[
			 sub {
			   my $w = shift;
			   my $xy = $Tk::event->xy;
			   return unless $w->index("$xy linestart") > 2.0;
			   $w->tagRemove('selected','1.0','end');
			   $w->tagAdd('selected',"$xy linestart","$xy lineend");
			   $self->adjust_buttons;
			 }]);
  $songtext->bind('<Control-1>',[
			 sub {
			   my $w = shift;
			   my $xy = $Tk::event->xy;
			   if ($w->tagNextrange('selected',"$xy linestart","$xy lineend")) {
			     $w->tagRemove('selected',"$xy linestart","$xy lineend");
			   } else {
			     $w->tagAdd('selected',"$xy linestart","$xy lineend");
			   }
			   $self->adjust_buttons;
			 }]);
  $songtext->bind(ref($songtext),"<B1-Motion>",'');
  $songtext->tagBind(
		     'song',
		     '<3>',
		     [sub {
			my ($w,$menu) = (shift,shift);
			my $xy = $Tk::event->xy;
			$w->tagRemove('selected','1.0','end');
			$w->tagAdd('selected',"$xy linestart","$xy lineend");
			$self->adjust_buttons;
			$menu->Post(@_);
		      },
		      $song_popup,
		      Ev('X'),Ev('Y')]
		    );

  $self->{songtext}   = $songtext;
  $self->{buttons}    = \@searchbuttons;
  $self->{searchentry} = $e;
  $self->{searchbutton} = $search_b;
  $self->{transfer_t} = $transfer_t;
  $self->{cancel_bm}  = $transfers->Bitmap(-data=>C_BITMAP,-foreground=>'red',-background=>'white');
  $self->{abort_upload_b}  = $abort_uploads_b;
  $self->{abort_download_b}  = $abort_downloads_b;
  $e->focus;
  $tl->packPropagate(1);
  $tl;
}

sub get_selected {
  my $self = shift;
  my @ranges = $self->{songtext}->tagRanges('selected');
  my @songs;
  while (@ranges) {
    my ($start,$end) = splice(@ranges,0,2);
    my $line = $self->{songtext}->get($start,$end);
    chomp $line;
    my($owner,undef,undef,undef,$title) = split "\t",$line;
    my $song = $self->{songs}{$owner,$title};
    push @songs,$song;
  }
  return @songs;
}

sub fetch_song {
  my $self = shift;
  my $play = shift;
  my @songs = $self->get_selected;
  foreach my $song(@songs) {
    if ($play) {
      my $fh = IO::File->new('| mpg123 -');
      warn  "Couldn't open player: $! ] \n" unless $fh;
      $song->download($fh);
    } else {
      $song->download;
    }
  }
  my @selected = $self->{songtext}->tagRanges('selected');
  $self->{songtext}->tagAdd('transferring',@selected);
}

sub add_transfer {
  my $self = shift;
  my $transfer = shift;
  my ($id,$status) = $self->status($transfer);
  $self->{transfers}{$id} = $transfer;
  my $text = $self->{transfer_t};
  my $bm   = $self->{cancel_bm};
  my $button = $text->Button(-image  => $bm,
			     -command => sub { $transfer->abort }
			    );
  $text->windowCreate('end',-window=>$button);
  $text->insert('end',"\t$status\n",[$id,$transfer->direction]);
  $self->adjust_abort_buttons;
}

sub update_transfer {
  my $self = shift;
  my $transfer= shift;
  my ($id,$status) = $self->status($transfer);
  my $text = $self->{transfer_t};
  my $index = $text->index("$id.first");
  my @tags = $text->tagNames($index);
  $text->delete("$id.first","$id.last");
  $text->insert($index,"\t$status\n",\@tags);
  $text->idletasks;
  $self->adjust_abort_buttons;
}

sub done_transfer {
  my $self = shift;
  my $transfer = shift;
  my ($id,$status) = $self->status($transfer);
  my $text = $self->{transfer_t};
  $text->after(5000,sub { $self->clear_transfer($transfer) });
  $text->tagAdd('done',"$id.first","$id.last");
}

sub adjust_abort_buttons {
  my $self = shift;
  my %count;
  for my $t (values %{$self->{transfers}}) {
    next if $t->done or $t->aborted;
    $count{$t->direction}++;
  }
  $self->{abort_upload_b}->configure(-state=>$count{'upload'} ? 'normal' : 'disabled');
  $self->{abort_download_b}->configure(-state=>$count{'download'} ? 'normal' : 'disabled');
}

sub clear_transfer {
  my $self = shift;
  my $transfer = shift;
  my ($id,$status) = $self->status($transfer);
  delete $self->{transfers}{$id};
  my $text = $self->{transfer_t};
  $text->delete("$id.first linestart","$id.last lineend");
  $text->tagDelete($id);
  $self->adjust_abort_buttons;
}

sub abort {
  my $self = shift;
  my $type = shift;
  for my $t (values %{$self->{transfers}}) {
    next if $type && $t->direction ne $type;
    $t->abort;
  }
}

sub status {
  my $self = shift;
  my $transfer = shift;
  my $direction = $transfer->direction eq 'upload' ? 'uploading to' : 'downloading from';
  my $user   = $transfer->remote_user;
  my $title  = $transfer->song->title;
  substr($title,MAXLEN) = '...' if length($title) > MAXLEN;
  my $status = $transfer->status;
  my $bytes  = sprintf("%2.1f",$transfer->transferred/1_000_000);
  my $total  = sprintf("%2.1f",$transfer->size/1_000_000);
  my $transferred = $total > 0 ? "$bytes/$total M" : "-";
  my $line   = join("\t","$direction $user",$status,$transferred,$title);
  my $id     = overload::StrVal($transfer);
  return wantarray ? ($id,$line) : $line;
}

sub adjust_buttons {
  my $self = shift;
  my @songs = $self->get_selected;
  my @searchbuttons = @{$self->{buttons}};
  if (@songs == 0) {
    $_->configure(-state => 'disabled') foreach @searchbuttons;
  } else {
    $searchbuttons[0]->configure(-state => @songs    ? 'normal' : 'disabled');
    $searchbuttons[1]->configure(-state => @songs==1 ? 'normal' : 'disabled');
  }
}

sub add_song {
  my $self = shift;
  my $songwindow = $self->{window};

  unless (@_) {
    $songwindow->deiconify;
    $songwindow->raise;
    return;
  }

  my ($server,$ec,$song) = @_;
  $self->{searchfound}++;
  $self->{searchstatus} = "Searching...$self->{searchfound} found";

  my $link = $song->link;
  $link =~ s/^LINK_//;
  $link = "?" if $link eq 'UNKNOWN';

  my $songtext = $self->{songtext};
  unless (%{$self->{songs}}) {
    $songtext->insert('end',"Owner\tBitrate\tSize\tLink\tTitle\n\n",'header');
    $songwindow->deiconify;
    $songwindow->raise;
  }

  $self->{songs}{$song->owner,$song->name} = $song;

  my $string = sprintf "\t%3dkbps\t%6.2fM\t%6s\t%s\n",
    $song->bitrate,$song->size/1E6,$link,$song->name;
  my $index = $self->bsearch($songtext,$song);
  $self->{songtext}->insert($index,$song->owner,[$link,'nickname'],$string,[$link,'song']);
  $self->songwindow->parent->idletasks;
}

sub searchdone {
  my $self = shift;
  $self->{searchstatus} = "Search done $self->{searchfound} found"
}

sub clear_songs {
  my $self = shift;
  $self->{songs} = {};
  $self->{searchfound} = 0;
  $self->{searchstatus} = 'Ready';
  if (my $songtext = $self->{songtext}) {
    $songtext->delete('1.0','end');
    $_->configure(-state => 'disabled') foreach (@{$self->{buttons}},$self->{searchbutton});
  }
}

sub clear_all {
  my $self = shift;
  warn "clear all";
  $self->{searchentry}->delete(0,'end');
  $self->clear_songs;
}

sub withdraw {
  my $self = shift;
  $self->{window}->withdraw;
}

sub bsearch {
  my ($self,$t,$s) = @_;
  my ($start,$stop,$pivot) = (3,$t->index('end')-2,3);
  while ($start <= $stop) {
    $pivot = int(($start + $stop)/2);
    my $line  = $t->get("$pivot.0","$pivot.end");
    chomp $line;
    my ($owner,$bitrate,$size,$link,$title) = split "\t",$line;
    $title =~ s/\s+$//;
    my $item = $self->{songs}{$owner,$title};
    my $cmp = $self->do_cmp($s,$item);
    if ($cmp == 0) {
      $start = $pivot;
      last;
    } elsif ($cmp > 0) {
      $start = $pivot + 1;
    } else {
      $stop = $pivot - 1;
    }
  }
  return "$start.0";
}

sub do_cmp {
  my ($self,$song1,$song2) = @_;
  my $cmp;
  if (my $comparison = $self->{comparison}) {
    $self->{c_direction} ||= +1;
    $cmp = ($self->{c_direction} * ($song1->$comparison <=> $song2->$comparison))
  }
  $cmp || lc($song1->title) cmp lc($song2->title);
}

1;
