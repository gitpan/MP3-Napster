#!perl
use Config;
use File::Basename qw(&basename &dirname);
use Cwd;

$origdir = cwd;
chdir dirname($0);
$file = basename($0, '.PLS');
$file .= $^O eq 'VMS' ? '.com' : '.pl';

open OUT,">$file" or die "Can't create $file: $!";

print "Extracting $file (with variable substitutions)\n";

print OUT <<"!GROK!THIS!";
$Config{startperl} -w
!GROK!THIS!

# In the following, perl variables are not expanded during extraction.

print OUT <<'!NO!SUBS!';
use strict;
use Tk 8.0;
use Tk::widgets qw/ROText HList Dialog DialogBox LabEntry LabFrame Adjuster/;

use lib './blib/lib';
use MP3::Napster;
use MP3::Napster::MessageCodes;
use MP3::TkNapster::Globals;
use MP3::TkNapster::Users;

use constant BACKGROUND   => 'black';
use constant FOREGROUND   => 'yellow';
use constant BACKGROUND2  => 'gray';
use constant FOREGROUND2  => 'black';

my ($login,
    $channel_menu,$channel_name,$current_channel,$current_channels,
    $info_dialog,$ping_dialog,$alert_dialog,
    %SERVERS,%CHANNELS,%JOINED_CHANNELS,%MEMBERS);

# main is global
$main = MainWindow->new(-background=>BACKGROUND);

###################################
# create menus
###################################
my $menubar = $main->Menu;
$main->configure(-menu=>$menubar,
		-background=>BACKGROUND);
my $file_menu = $menubar->cascade(-label=>'File',
				  -tearoff=>0,
				  -underline=>0,
				 );
$file_menu->command(-label=>'~Login',
		    -command=>[\&login,$main]);;
$file_menu->command(-label=>'Lo~gout',
		    -state=>'disabled',
		    -command=>[\&logout,$main]);;
$file_menu->separator;
$file_menu->command(-label=>'~Quit', -command=>[\&exit]);

my $edit_menu = $menubar->cascade(-label=>'Edit',
				  -underline=>0,
				  -tearoff=>0,
				  -state=>'normal',
				  -menuitems=> [
						[command    => 'Cut'],
						[command    => 'Copy'],
						[command    => 'Clear'],
					       ]);

my $search_menu = $menubar->cascade(-label=>'Songs',
				    -underline=>0,
				    -tearoff=>0,
				    -state=>'disabled',
				    -menuitems=> [
						  [command    => 'Search...'],
						  [command    => 'Shared Files...'],
						 ]);
$search_menu->cget(-menu)->entryconfigure('Search...',
					  -command => sub { add_song() }
					 );
$search_menu->cget(-menu)->entryconfigure('Shared Files...',
					  -command => sub { shared_files() }
					 );

my $help = $menubar->cascade(-label=>'Help',
			     -underline=>0,
			     -menuitems=> [
					   [command    => '~About'],
					  ]);
my $ABOUT = $main->Dialog(
			  -title          => 'About widget',
			  -bitmap         => 'info',
			  -default_button => 'OK',
			  -buttons        => ['OK'],
			  -text           => "tknapster\n\nLincoln Stein 12/2000"
			 );
$help->cget(-menu)->entryconfigure('About',
				   -command => [$ABOUT => 'Show'],
				  );

# popup menu for users
$user_popup = $main->Menu(-type=>'normal',-tearoff=>0);
$user_popup->command(-label=>'Info',-command=>sub {$users->info_user});
$user_popup->command(-label=>'Browse Files',-command=>sub {$users->browse_user});
$user_popup->command(-label=>'Ping',-command=>sub { $users->ping_user});
$user_popup->command(-label=>'Whisper',-command=>sub {$users->whisper_user});

###################################
# configure main window
###################################

# create the console window and the text
my $italic = $main->fontCreate(-family=>'Helvetica',-slant=>'italic');
my $bold   = $main->fontCreate(-family=>'Helvetica',-weight=>'bold');
my $normal = $main->fontCreate(-family=>'Helvetica');

my $frame1 = $main->Frame(-background => BACKGROUND2,
			  -foreground => FOREGROUND2,
			 )->pack(-fill=>'both',-side=>'top'); # labels
my $frame2 = $main->Frame()->pack(-fill=>'both',-side=>'top',-expand=>1); # text and list
my $frame3 = $main->Frame()->pack(-fill=>'both',-side=>'bottom'); # status bars

my $frame1a = $frame1->Frame(-background => BACKGROUND2,
			     -foreground => FOREGROUND2,
			    )->pack(-side=>'right',-fill=>'x',-expand=>0);
my $current_channel_menu
  = $frame1a->Optionmenu(
			 -options => [],
			 -variable => \$current_channel,
			 -command  => \&adjust_userlist,
			 -background => BACKGROUND2,
			  -foreground => FOREGROUND2,
			 -width=>12,
			)->pack(-side=>'right',-fill=>'x');
$frame1a->Label(-text=>'Members',
		-background => BACKGROUND2,
		-foreground => FOREGROUND2,
	       )->pack(-side=>'right',-fill=>'x',-expand=>1);

$frame1->Label(-textvariable=>\$current_channels,
	       -background => BACKGROUND2,
	       -foreground => FOREGROUND2,
	      )->pack(-side=>'left',-fill=>'x',-expand=>1);
$current_channels = 'Discussions: '. channel_list();

my $text = $frame2->Scrolled('ROText',
			     -scrollbars=>'oe',
			     -takefocus=>0,
			     -wrap => 'word',
			     -font=>$normal,
			     -background=>BACKGROUND,
			     -foreground=>FOREGROUND,
			     -highlightcolor=>'blue')->pack(-fill=>'both',-side=>'left',-expand=>1);

#my $adjuster = $frame2->Adjuster(-widget=>$text,-foreground=>'yellow',-side=>'left')->pack(-side=>'left','fill'=>'y');
my $user_list = $frame2->Scrolled('Listbox',
				  -background=>'white',
				  -foreground=>'sienna',
				  -highlightcolor=>'blue',
				  -cursor => 'hand2',
				  -background=>BACKGROUND,
				  -scrollbars=>'oe')->pack(-fill=>'both',-side=>'right');
$user_list->bind('<Button-3>',[ sub {
				  my $w = shift;
				  my $menu = shift;
				  $users->current($w->get($Tk::event->xy));
				  $menu->Post(@_);
				},
				$user_popup,
				Ev('X'),Ev('Y')
			      ]);

$user_list->bind('<Button-1>',[sub {$users->current(shift->get($Tk::event->xy))}]);
$user_list->bind('<Double-Button-1>',sub { $users->info_user });

$text->tag(configure=>'nickname',-underline=>1,-foreground=>'sienna');
$text->tag(configure=>'channel',-foreground=>'yellow');
$text->tag(configure=>'public_message',-foreground=>'blue');
$text->tag(configure=>'private_message',-foreground=>'green');
$text->tag(configure=>'joins_parts',-foreground=>'#808080',-font=>$italic);
$text->tag(configure=>'debug',-foreground=>'red');
$text->tag(configure=>'motd',-foreground=>'violet');
$text->tag(configure=>'channel_motd',-font=>$bold);
$text->tag(configure=>'error',-font=>$bold,-foreground=>'red');
$text->tag(configure=>'disabled',-foreground=>'#A0A0A0');

$text->tagRaise('error');

$text->tag(bind=>'nickname','<Enter>',[configure=>qw/-cursor hand2/]);
$text->tag(bind=>'nickname','<Leave>',[configure=>qw/-cursor xterm/]);

$text->tag(bind=>'nickname','<Button-1>',
	   sub { my $t = shift;
		 my $xy = $Tk::event->xy;
		 my ($start,$end) = $t->tagNextrange('nickname',"$xy linestart","$xy lineend");
		 $users->current($t->get($start,$end));
	       }
	  );
$text->tag(bind=>'nickname','<Double-Button-1>',sub { $users->info_user } );

$text->tag(bind=>'nickname','<3>',
	   [sub {
	      my ($t,$menu) = (shift,shift);
	      my $xy = $Tk::event->xy;
	      my ($start,$end) = $t->tagNextrange('nickname',"$xy linestart","$xy lineend");
	      $users->current($t->get($start,$end));
	      $menu->Post(@_);
	    },
	    $user_popup,
	    Ev('X'),Ev('Y')]
	  );
$main->bind(ref($text->Subwidget('scrolled')),'<3>'=>'');

my $msg = $main->Label(-relief=>'groove',
		       -textvariable=>\$channel_name
		      )->pack(-side=>'top',-fill=>'x');


##################################
# configure edit menu
##################################
$edit_menu->cget(-menu)->entryconfigure('Cut',
					  -command => sub { $text->clipboardColumnCut}
					 );
$edit_menu->cget(-menu)->entryconfigure('Copy',
					  -command => sub { $text->clipboardColumnCopy }
					);
$edit_menu->cget(-menu)->entryconfigure('Clear',
					  -command => sub { $text->delete('sel.first','sel.last') }
					);


##################################
# entry for typing public messages
##################################
my $entry = $main->Text(-height=>1,-takefocus=>1)->pack(-fill=>'both');
$entry->focus;
$entry->bind('<KeyPress-Return>',[\&handle_return,$text]);

##################################
# status line
##################################
$frame3->Label(-textvariable=>\$stats,-relief=>'groove')->pack(-side=>'right');
$frame3->Label(-text=>'Server Stats:')->pack(-side=>'right');

$frame3->Label(-text=>'Status:')->pack(-side=>'left');
$frame3->Label(-textvariable=>\$status,-relief=>'groove')->pack(-side=>'left');

my $f31 = $frame3->Frame->pack(-side=>'left',-expand=>1);

$f31->Label(-text=>'Pending Downloads:')->pack(-side=>'left');
$f31->Label(-textvariable=>\$downloads,-relief=>'groove')->pack(-side=>'left');

$f31->Label(-text=>'Pending Uploads:')->pack(-side=>'left');
$f31->Label(-textvariable=>\$uploads,-relief=>'groove')->pack(-side=>'left');

$main->idletasks;
login($main);
MainLoop;
print "done\n";

sub logout {
  my $widget = shift;
  return unless $nap;
  $songwindow->abort if defined $songwindow;
  $nap->disconnect;
}

sub login {
  my $widget = shift;
  require MP3::TkNapster::Login;

  $login ||= MP3::TkNapster::Login->new($widget);
  return unless 'Connect' eq $login->show;
  $text->delete('1.0','end');
  $status= "Connecting...";
  $widget->idletasks;
  my ($addr,$meta) = $login->server;
  my @args = $meta ? (-metaserver=>$addr) : (-server=>$addr);

  unless ($nap = MP3::Napster->new(@args,-tkmain=>$widget)) {
    $status = "Can't connect: ".MP3::Napster->error;
    return;
  }
  $nap->debug(1);
  $nap->download_dir('./tmp');
  setup_callbacks($nap);
  if ($login->newuser) {
    $status = "Requesting nickname...";
    $nap->register($login->nickname,
		   $login->password,
		   {link=>$login->link,port=>$login->port});
  } else {
    $status = "Logging in...";
    $nap->login($login->nickname,
		$login->password,
		$login->link,
		$login->port);
  }
}

sub setup_callbacks {
  my $n = shift;

  $n->callback($_,\&debug) for (0..900,2000..2007,9999);
  $n->callback(MOTD,\&motd);
  $n->callback(CHANNEL_MOTD,\&channel_motd);
  $n->callback(PONG,\&pong);
  $n->callback(WHOIS_RESPONSE,\&whois);
  $n->callback(PUBLIC_MESSAGE,\&public_msg);
  $n->callback(PRIVATE_MESSAGE,\&private_msg);
  $n->callback(USER_JOINS,\&joins_parts);
  $n->callback(USER_DEPARTS,\&joins_parts);
  $n->callback(DISCONNECTED,\&handle_disconnect);
  $n->callback(LOGIN_ACK,\&handle_login);
  $n->callback(TRANSFER_STARTED,\&transfer_started);
  $n->callback(TRANSFER_IN_PROGRESS,\&transfer_in_progress);
  $n->callback(TRANSFER_STATUS,\&transfer_in_progress);
  $n->callback(TRANSFER_DONE,\&transfer_done);

  $n->callback(ALREADY_REGISTERED,
		 sub {
		   $status="Already registered";
		   my $nick = $login->nickname;
		   $text->insert('end',"User $nick is already registered\n",'error');
		   $nap->disconnect;
		   undef $nap;
		 });
  $n->callback(ERROR,
		 sub {
		   $status="ERROR: $_[2]";
		   $text->insert('end',"$_[2]\n",'error');
		 });
  $n->callback(LOGIN_ERROR,
		 sub {
		   $status="ERROR: $_[2]";
		   $text->insert('end',"$_[2]\n",'error');
		 });
  $n->append_callback(QUEUE_LIMIT,
		      sub {
			my $e = $nap->error;
			$text->insert('end',"QUEUE LIMIT: $e\n",'error');
			alert($e);
		      });
  $n->callback(INVALID_NICKNAME,
		 sub {
		   $status="Invalid nickname.  Try another.";
		   $text->insert('end',"$status\n",'error');
		 });
  $n->callback(INVALID_ENTITY,
		 sub {
		   $status="$_[2]";
		   $text->insert('end',"$_[2]\n",'error');
		 });
  $n->callback(SERVER_STATS,
		 sub {
		   my ($users,$files,$gigs) = split /\s+/,$_[2];
		   $stats="$users users, $files files, $gigs gigabytes";
		 });
  $n->callback(CHANNEL_ENTRY,
		 sub {
		   my ($server,$code,$channel) = @_;
		   $CHANNELS{$channel} = $channel;
		 }
		);
  $n->callback(CHANNEL_USER_ENTRY,
		 sub {
		   my ($server,$code,$user) = @_;
		   my $channel = channel($user->current_channel);
		   $MEMBERS{$channel}{$user} = $user;
		   $users->add($user);
		 }
		);
  $n->callback(CHANNEL_USER_END,
		 sub {
		   my ($server,$code,$channel) = @_;
		   adjust_userlist();
		   $status = 'Connected.';
		 }
	      );
  $n->callback(LIST_CHANNELS,
		 sub {
		   unless ($channel_menu) {
		     $channel_menu = $menubar->cascade(-label=>'~Channels',
						       -tearoff=>1
						      );
		     $channel_menu->cget('-menu')->bind('<<MenuSelect>>',
						      sub {
							my $w = $Tk::event->W;
							return unless $w->type('active');
							return unless $w->type('active') eq 'checkbutton';
							my $label = $w->entrycget('active','-label');
							my $c = $CHANNELS{$label} || return;
							$channel_name = "$c: " . $c->topic;
							$main->idletasks;
						      });
		     $channel_menu->cget('-menu')->bind('<Leave>', sub {$channel_name = '' });
		   }
		   my @channels = sort keys %CHANNELS;
		   my $col = int(2*sqrt(@channels));
		   for (my $i=0;$i<@channels;$i++) {
		     $channel_menu->checkbutton(
						-label       => $channels[$i],
						-columnbreak => $i && ($i % $col) == 0,
						-variable    => \$JOINED_CHANNELS{$channels[$i]},
						-command     => \&set_channel);
		     $status = 'Connected.';
		   }
		 });
  $n->callback(JOIN_ACK,
		 sub {
		   my ($server,$event,$chan) = @_;
		   warn "joining $chan";
		   my $c = channel($chan) or return;
		   $channel_name="$c: " . $c->topic;
		   $JOINED_CHANNELS{$c} = 1;
		   warn "setting current_channel to $c";
		   $current_channel = "$c";
		   $current_channels = 'Discussion: '.channel_list();
		   adjust_userlist();
		   $status = 'Connected.';
		 });

  $n->callback(PART_CHANNEL,
		 sub {
		   my ($server,$event,$chan) = @_;
		   warn "parting $chan";
		   my $c = channel($chan) or return;
		   $JOINED_CHANNELS{$c} = 0;
		   $current_channel = channel($nap->channel);
		   $channel_name="$current_channel: " . $CHANNELS{$current_channel}->topic
		     if $current_channel;
		   $users->delete(keys %{$MEMBERS{$c}});
		   delete $MEMBERS{$c};
		   $current_channels = 'Discussion: '.channel_list();
		   adjust_userlist();
		   $status = 'Connected.';
		 });
  $n->callback(BROWSE_RESPONSE,\&add_song);
  $n->callback(SEARCH_RESPONSE,\&add_song);
  $n->callback(BROWSE_RESPONSE_END,\&searchdone);
  $n->callback(SEARCH_RESPONSE_END,\&searchdone);

}

sub searchdone {
  $status = 'Connected';
  $songwindow && $songwindow->searchdone;
}

sub handle_login {
  $status = "Connected $_[2]";
  $users = new MP3::TkNapster::Users;
  $file_menu->cget(-menu)->entryconfigure(0,-state => 'disabled');
  $file_menu->cget(-menu)->entryconfigure(1,-state => 'normal');
  $search_menu->configure(-state => 'normal');
  $status = "Connected. Fetching channels...";
  $_[0]->channels;
}

sub handle_disconnect {
  $file_menu->cget(-menu)->entryconfigure(0,-state=>'normal');
  $file_menu->cget(-menu)->entryconfigure(1,-state=>'disabled');
  $search_menu->configure(-state => 'disabled');
  if (%CHANNELS) {
    $main->cget('menu')->delete('Channels');
    %CHANNELS = ();
    %JOINED_CHANNELS = ();
    %MEMBERS = ();
    undef $users;
    $current_channels = 'Discussion: '.channel_list();
    $current_channel = '';
    adjust_userlist();
  }
  $text->tagAdd('disabled','1.0','end');
  undef($nap);
  undef $channel_menu;
  $status = "disconnected";
  $stats = 'none';
  if (defined $songwindow) {
    $songwindow->clear_songs();
    $songwindow->withdraw;
  }
  $songwindow->abort() if defined $songwindow;
}

sub set_channel {
  my $w = $Tk::event->W;
  my $label = $w->entrycget('active','-label');
  $JOINED_CHANNELS{$label} = 0;  # force it off
  my $c = $CHANNELS{$label} || return;
  if ($nap->channel_hash->{$c}) {
    $status = "departing $c....";
    $nap->part_channel($c);
    $channel_name = $nap->channel ? $nap->channel . ": " . $CHANNELS{$nap->channel}->topic : '';
  } else {
    $status = "joining $c....";
    $nap->join_channel($c);
  }
}

sub channel_list {
  my @h = grep {$JOINED_CHANNELS{$_}} sort keys %JOINED_CHANNELS;
  return '('.join(', ',@h).')' if @h;
  return '(-none-)';
}

sub debug {
  my($server,$ec,$message) = @_;
  my $event = $server->event;
  $event .= ": $message" if defined $message;
  warn $event,"\n";
};

sub motd {
  my($server,$ec,$message) = @_;
  my $event = $server->event;
  $text->insert('end',"$message\n",'motd');
  $text->see('end');
}

sub channel_motd {
  my($server,$ec,$message) = @_;
  $message =~ s/^\S+\s//;
  $message =~ s/^"//;
  $message =~ s/"$//;
  $text->insert('end',"$message\n",'channel_motd');
  $text->see('end');
}

sub public_msg {
  my ($nap,$ec,$message) = @_;
  my ($channel,$nickname,$mess) = $message =~/^(\S+) (\S+) (.*)/;
  my $c = channel($channel);  # get canonical name
  $text->insert('end',"[$c]"=>'channel',
		" <" =>'',
		"$nickname"=>'nickname',
		"> " => '',
		"$mess\n"=>'public_message');
  $text->see('end');
}

sub private_msg {
  my ($nap,$ec,$message) = @_;
  my ($nickname,$mess) = $message =~/^(\S+) (.*)/;
  $text->insert('end',"[PRIVATE MESSAGE]"=>'channel',
		" <" =>'',
		"$nickname"=>'nickname',
		"> " => '',
		"$mess\n"=>'private_message');
  $text->see('end');
}

sub joins_parts {
  my ($nap,$ec,$user) = @_;
  my $channel = channel($user->current_channel);
  my $sharing = $user->sharing;
  my $link    = $user->link;
  if ($ec == USER_JOINS) {
    $text->insert('end',
		  "[$channel] " => 'channel',
		  "$user"       => [qw(nickname joins_parts)],
		  " has joined sharing $sharing files on a $link line\n"
		                => 'joins_parts');
    $MEMBERS{$channel}{$user} = $user;
    $users->add($user);
  } else {
    $text->insert('end',
		  "[$channel] " => 'channel',
		  "$user"=>[qw(nickname joins_parts)],
		  " has departed\n" =>'joins_parts');
    delete $MEMBERS{$channel}{$user};
    $users->delete($user);
  }
  $text->see('end');
  adjust_userlist() if $channel eq $current_channel;
}

sub channel {
  my $chan = shift;
  return unless defined $chan;
  return $CHANNELS{$chan} if exists $CHANNELS{$chan};
  # didn't match, so maybe it is an "alternative1" affair
  # remove the terminal digit and canonicalize
  (my $c = $chan) =~ s/\d+$//;
  $c = ucfirst lc $c;
  return $CHANNELS{$c} if $CHANNELS{$c};
  # still didn't match, so maybe it is "#channel"
  $c = "#$chan";
  $CHANNELS{$c};
}

sub adjust_userlist {
  $user_list->delete(0,'end');
  my $c = $current_channel;
  $current_channel_menu->configure(-options=> [sort keys %MEMBERS]);
  return unless $c;
  my @users = sort {lc $a cmp lc $b} values %{$MEMBERS{$c}};
  $user_list->insert('end',@users);
  $current_channel = $c;
  $channel_name = channel($c)->topic;
}

sub handle_return {
  my $entry = shift;
  my $text = shift;
  my $data = $entry->get('0.0','end');
  chomp($data);
  $entry->delete('0.0','end');
  $nap->public_message($data);
}

sub set_select {
  my $text = shift;
  my $xy = $Tk::event->xy;
  my $user = $text->get("$xy wordstart","$xy wordend");
}

sub whois {
  my ($server,$code,$user) = @_;
  my $profile = $user->profile;
  $users->current($user);
  unless ($info_dialog) {
    $info_dialog = $main->Dialog(
				 -title => $user,
				 -text => $profile,
				 -buttons=>[qw(Browse Ping Whisper OK)],
				 -default_button => 'OK',
				);
  }
  $info_dialog->configure(-title=>$user,
			  -text=>$profile);
  my $button = $info_dialog->Show;
  $status = 'Connected';
  $users->browse_user()  if $button eq 'Browse';
  $users->ping_user()    if $button eq 'Ping';
  $users->whisper_user() if $button eq 'Whisper';
}

sub pong {
  my ($server,$code,$user) = @_;
  $ping_dialog ||= $main->Dialog(-buttons=>[qw(OK)]);
  $ping_dialog->configure(-title=>'Ping Response',
			  -text=>"$user is online");
  $ping_dialog->Show;
  $status = 'Connected';
}

sub alert {
  my $message = shift;
  unless ($alert_dialog) {
    $alert_dialog = $main->Dialog(
				  -title => 'Alert',
				  -buttons=>['OK'],
				  -default_button => 'OK',
				);
  }
  $alert_dialog->configure(-text=>$message);
  $alert_dialog->Show;
}

sub shared_files {
  require MP3::TkNapster::SharedFiles;
  $sharedwindow ||= MP3::TkNapster::SharedFiles->new;
  $sharedwindow->show;
}

# Clear the song list
sub clear_songs {  $songwindow && $songwindow->clear_songs }

sub add_song {
  require MP3::TkNapster::Songlist;
  $songwindow ||= MP3::TkNapster::Songlist->new($main,\$nap);

  # hack to fix missing link codes
  if (my ($server,$ec,$song) = @_) {
    $song->link_code($users->object($song->owner)->link_code)
      if ($song->link_code == LINK_UNKNOWN and $users->object($song->owner));
  }
  $songwindow->add_song(@_);
}


sub transfer_started {
  my ($nap,$code,$transfer) = @_;
  $transfer->interval(50000);
  $songwindow->add_transfer($transfer) if defined $songwindow;
  if ($transfer->direction eq 'download') {
    $downloads++;
  }  else {
    $uploads++;
  }
}

sub transfer_in_progress {
  my ($nap,$code,$transfer) = @_;
  $songwindow->update_transfer($transfer) if defined $songwindow;
}

sub transfer_done {
  my ($nap,$code,$transfer) = @_;
  $songwindow->done_transfer($transfer) if defined $songwindow;
  if ($transfer->direction eq 'download') {
    $downloads--;
  }  else {
    $uploads--;
  }
}

__DATA__
# name     address:port              metaserver
Napster    server.napster.com:8875     1
BitchX     bitchx.dimension6.com:8888  0
Chemlab    mp3.chemlab.org:8888        0
Localhost  localhost:9999              0
!NO!SUBS!
close OUT or die "Can't close $file: $!";
chmod 0755, $file or die "Can't reset permissions for $file: $!\n";
exec("$Config{'eunicefix'} $file") if $Config{'eunicefix'} ne ':';
chdir $origdir;
