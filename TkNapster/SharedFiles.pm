package MP3::TkNapster::SharedFiles;

use strict;
use Tk;
use IO::Dir;
use Tk::Tree;
use File::Path 'mkpath';
use File::Basename qw(basename dirname);
use Carp 'croak';
use strict;

sub new {
  my $class = shift;
  my %args = @_;
  my $public_dirs = shift;
  my $self = bless {
		    downloads => $args{-download},
		    shared    => $args{-upload},
		   },$class;
  $self->{window} = $self->init($args{-main});
  $self;
}

sub window      { shift->{window}  }
sub dirs        { shift->{dirs}    }

sub show {
  my $w = shift->{window};
  $w->deiconify;
  $w->raise;
}

# create widgets and bindings for the song display page
sub init {
  my $self = shift;
  my $main = shift;
  my $tl   = $main->Toplevel(-title=>'Folders',
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
  $file_menu->command(-label=>'Refresh',
		      -command => sub {
			$self->refresh('shared');
			$self->refresh('downloads')
		      }
		     );
  $file_menu->separator;
  $file_menu->command(-label=>'Close',
		      -command=>[$tl=>'withdraw']);

  my $tree = $tl->Scrolled('Tree',
			   -separator => '/',
			   -itemtype => 'imagetext',
			   -selectmode => 'browse',
			   -scrollbars => 'osoe',
			   -background => 'lightblue',
			   -width => 120,
			   -height => 30,
#			   -browsecmd => sub { print shift,"\n" },
			   -command   => sub { print $self->translate($_[0]),"\n"; }
			 );

  $tree->add('/',-text=>'Local Directories');
  for my $type ([downloads=>'folder'],[shared=>'folder']) {
    my $dir = $self->{$type->[0]};
    mkpath($dir) or croak "Can't create $type directory $dir: $!"
      unless -d $dir;
    my $node = uc('/'.$type->[0]);
    $tree->add($node,-text=>"\U$type->[0]\E ($dir)",-image=>$tree->Getimage($type->[1]));
    $self->dir_list($dir,$dir,$node,$tree);
    $tree->setmode($node,'close');
    $tree->close($node);
  }
  $tree->add("/REMOTE",-text=>'REMOTE SONGS',-image=>$tree->Getimage('winfolder'));
  $tree->setmode("/REMOTE",'close');
  $tree->close("/REMOTE");

  $tree->setmode('/','none');
  $tree->autosetmode;
  $tree->pack(-side=>'bottom',-expand=>1,-fill=>'both');
  $self->{tree} = $tree;

  $self->setbindings();

  $tl->protocol(WM_DELETE_WINDOW=>[$tl => 'withdraw']);
  $tl->packPropagate(1);
  $tl;
}

sub refresh {
  my $self = shift;
  my $type = shift;  # 'shared', 'downloads' or 'remote'
  my $dir = $self->{$type};
  my $tree = $self->{tree};
  my $node = uc("/$type");
  my %modes;
  $self->getmodes($node,\%modes);
  $tree->delete( offsprings => $node);
  $self->dir_list($dir,$dir,$node,$tree);

  $tree->autosetmode;
  foreach (keys %modes) {
    next unless $tree->info(exists=>$_);
    if ($modes{$_} eq 'close') {
      $tree->open($_);
    } elsif ($modes{$_} eq 'open') {
      $tree->close($_);
    }
  }
}

sub getmodes {
  my $self = shift;
  my ($node,$modes) = @_;
  my $tree = $self->{tree} or return;
  return unless $tree->info(exists=>$node);
  my $state = $tree->getmode($node);
  $modes->{$node} = $state;
  foreach ($tree->info(children=>$node)) {
    $self->getmodes($_,$modes);
  }
}


sub dir_list {
  my $self = shift;
  my ($dir,$root,$public,$tree) = @_;
  my $d = IO::Dir->new($dir) or return;
  my (@list,%directory,$open,$contains_an_open_dir);

  while (defined($_ = $d->read)) {
    next if /^\./;
    next if -l "$dir/$_";
    if (-d _) {
      push @list, $_;
      $directory{$_}++;
    } elsif (-f _ && /\.mp3/i) {
      push @list,$_;
      $open++;
    }
  }

  for my $e (sort @list) {
    my $image = $directory{$e} ? 'folder' : 'file';
    my $node = "$dir/$e";
    $node =~ s/^$root/$public/;
    $tree->add($node,-text=>$e,-image=>$tree->Getimage($image));
    if ($directory{$e}) {
      my $o = $self->dir_list("$dir/$e",$root,$public,$tree);
      $tree->setmode($node,'close');
      $tree->close($node); #  unless $o;  # this does autoopening - which i don't like
      $contains_an_open_dir ||= $o;
    }
  }
  return $open || $contains_an_open_dir;
}

sub translate {
  my $self = shift;
  my $path = shift;
  $path =~ s!^/SHARED!$self->{shared}!;
  $path =~ s!^/DOWNLOADS!$self->{downloads}!;
  $path;
}

sub setbindings {
  my $self = shift;
  my $tree = $self->{tree} or return;

  $tree->bind('<1>',
	      sub {
		my $w = shift;
		my $e = $w->XEvent;
		my $X = $e->X - 8;
		my $Y = $e->Y - 8;
		my $entry = $w->nearest($e->y);
		return if $entry =~ m[^/(SHARED|DOWNLOADS|REMOTE)$];

		$self->{source} = $entry;
		return unless -e (my $selected = $self->translate($entry));

		my $image = $w->Getimage(-d $selected ? 'folder' : 'file');
		my $f = $w->Toplevel;
		$f->Label(-image=>$image)->pack;
		$f->overrideredirect(1);
		$f->geometry("+$X+$Y");
		$tree->bind('<B1-Motion>',[$self => 'move', $w, $f]);
		$tree->bind('<ButtonRelease>',sub {
			      $f->destroy;
			      $tree->bind('<B1-Motion>'=>'');
			      $tree->bind('<ButtonRelease>'=>'');
			    });
		});

}

sub move {
  my $self = shift;
  my $tree = shift;
  my $icon = shift;

  my $e = $tree->XEvent;
  my $X = $e->X-8;
  my $Y = $e->Y-8;
  $icon->MoveToplevelWindow($X,$Y);

  my $entry    = $tree->nearest($e->y);
  my $current  = $self->translate($entry);
  my $source   = $self->{source};

  my $source_parent = $tree->info(parent=>$source);
  my $parent = $tree->info(parent=>$entry);
  my $selection = -d $current ? $entry : $parent;
  return if $selection eq $source_parent;

  $tree->selectionClear;
  $tree->selectionSet($selection);
}


1;
