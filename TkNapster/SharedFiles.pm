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
  for my $type ([downloads=>'folder'],[shared=>'openfolder']) {
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
  foreach (keys %modes) {
    next unless $tree->info(exists=>$_);
    warn "$node is $modes{$_}\n";
    if ($modes{$_} eq 'open') {
      $tree->setmode($_,'open');
      $tree->open($_);
    } elsif ($modes{$_} eq 'close') {
      $tree->setmode($_,'close');
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
    $self->getmodes("$node/$_",$modes);
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


1;
