#!perl
use Config;
use File::Basename qw(&basename &dirname);
use Cwd;

$origdir = cwd;
chdir dirname($0);
$file = basename($0, '.PL');
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

use constant DEFAULT_SPEED => LINK_56K;
use constant FIND_ICON     => '/usr/X11R6/include/X11/pixmaps/app_find.xpm';

use constant BACKGROUND   => 'black';
use constant FOREGROUND   => 'yellow';
use constant BACKGROUND2  => 'gray';
use constant FOREGROUND2  => 'black';

my ($nap,
    $server,$nickname,$password,$newuser,$user_linkspeed,$userport,$linklabel,
    $channel_menu,$channel_name,$current_channel,$current_channels,
    $status,$stats,$info_dialog,$ping_dialog,$login_dialog,
    $songwindow,$search,$searchstatus,$searchfound,$songtext,
    $USER,%USERS,%SERVERS,
    %SONGS,$comparison,$c_direction,
    %CHANNELS,%JOINED_CHANNELS);

my $main = MainWindow->new(-background=>BACKGROUND);

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

my $search_menu = $menubar->cascade(-label=>'Search',
				    -underline=>0,
				    -tearoff=>0,
				    -state=>'disabled',
				    -menuitems=> [
						  [command    => 'Search for Songs'],
						 ]);
$search_menu->cget(-menu)->entryconfigure('Search for Songs',
					  -command => sub { add_song() }
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
my $user_popup = $main->Menu(-type=>'normal',-tearoff=>0);
$user_popup->command(-label=>'Info',-command=>\&info_user);
$user_popup->command(-label=>'Browse Files',-command=>\&browse_user);
$user_popup->command(-label=>'Ping',-command=>\&ping_user);
$user_popup->command(-label=>'Whisper',-command=>\&whisper_user);

# option menu for current channel

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
				  $USER = $w->get($Tk::event->xy);
				  $menu->Post(@_);
				},
				$user_popup,
				Ev('X'),Ev('Y')
			      ]);

$user_list->bind('<Button-1>',[sub {$USER = shift->get($Tk::event->xy)}]);
$user_list->bind('<Double-Button-1>',\&info_user);

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
		 $USER = $t->get($start,$end),
	       }
	  );
$text->tag(bind=>'nickname','<Double-Button-1>',\&info_user);

$text->tag(bind=>'nickname','<3>',
	   [sub {
	      my ($t,$menu) = (shift,shift);
	      my $xy = $Tk::event->xy;
	      my ($start,$end) = $t->tagNextrange('nickname',"$xy linestart","$xy lineend");
	      $USER = $t->get($start,$end),
	      $menu->Post(@_)
	    },
	    $user_popup,
	    Ev('X'),Ev('Y')]
	  );
$main->bind(ref($text->Subwidget('scrolled')),'<3>'=>'');

my $msg = $main->Label(-relief=>'groove',
		       -textvariable=>\$channel_name
		      )->pack(-side=>'top',-fill=>'x');

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
$stats = ' ';

$frame3->Label(-text=>'Status:')->pack(-side=>'left');
$frame3->Label(-textvariable=>\$status,-relief=>'groove')->pack(-side=>'left');
$status = 'disconnected';

login($main);
MainLoop;
print "done\n";

sub logout {
  my $widget = shift;
  return unless $nap;
  $nap->disconnect;
}

sub login {
  my $widget = shift;
  return if $nap;
  $userport ||= 6699;
  $login_dialog ||= create_login_dialog();
  return unless 'Connect' eq $login_dialog->Show;

  $text->delete('1.0','end');
  $status= "Connecting...";
  $widget->idletasks;
  my ($addr,$meta) = @{$SERVERS{$server}};
  my @args = $meta ? (-metaserver=>$addr) : (-server=>$addr);

  unless ($nap = MP3::Napster->new(@args,-tkmain=>$widget)) {
    $status = "Can't connect: ".MP3::Napster->error;
    return;
  }
  setup_callbacks($nap);
  if ($newuser) {
    $status = "Requesting nickname...";
    $nap->register($nickname,$password,{link=>$user_linkspeed,port=>$userport});
  } else {
    $status = "Logging in...";
    $nap->login($nickname,$password,$user_linkspeed,$userport);
  }
}

sub setup_callbacks {
  my $n = shift;

  $n->callback($_,\&debug) for (0..900);
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
  $n->callback(REGISTRATION_ACK,\&handle_registration);

  $n->callback(ALREADY_REGISTERED,
		 sub {
		   $status="Already registered";
		   $text->insert('end',"User $nickname is already registered\n",'error');
		   $nap->disconnect;
		   undef $nap;
		 });
  $n->callback(ERROR,
		 sub {
		   $status="ERROR: $_[2]";
		   $text->insert('end',"$_[2]\n",'error');
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
		   $USERS{$channel}{$user} = $user;;
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
		   delete $USERS{$c};
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
  $searchstatus = "Search done $searchfound found"
}

sub handle_login {
  $status = "Connected $_[2]";
  $file_menu->cget(-menu)->entryconfigure(0,-state => 'disabled');
  $file_menu->cget(-menu)->entryconfigure(1,-state => 'normal');
  $search_menu->configure(-state => 'normal');
  $status = "Connected. Fetching channels...";
  $_[0]->channels;
}

sub handle_registration {
  $status = "Sending new user information...";
  $nap->new_login;
  $nap->new_info;
}

sub handle_disconnect {
  $file_menu->cget(-menu)->entryconfigure(0,-state=>'normal');
  $file_menu->cget(-menu)->entryconfigure(1,-state=>'disabled');
  $search_menu->configure(-state => 'disabled');
  if (%CHANNELS) {
    $main->cget('menu')->delete('Channels');
    %CHANNELS = ();
    %JOINED_CHANNELS = ();
    %USERS = ();
    $current_channels = 'Discussion: '.channel_list();
    $current_channel = '';
    adjust_userlist();
  }
  $text->tagAdd('disabled','1.0','end');
  undef($nap);
  undef $channel_menu;
  $status = "disconnected";
  $stats = ' ';
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
  warn $server->event . ": $message\n";
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
    $USERS{$channel}{$user} = $user;
  } else {
    $text->insert('end',
		  "[$channel] " => 'channel',
		  "$user"=>[qw(nickname joins_parts)],
		  " has departed\n" =>'joins_parts');
    delete $USERS{$channel}{$user};
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
  $current_channel_menu->configure(-options=> [sort keys %USERS]);
  return unless $c;
  my @users = sort {lc $a cmp lc $b} values %{$USERS{$c}};
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
  warn $user,"\n";
}

sub browse_user {
  return unless $USER;
  $status = "browsing $USER...";
  clear_songs();
  $nap->browse($USER);
}

sub ping_user {
  return unless $USER;
  $status = "pinging $USER...";
  $nap->ping($USER);
}

sub info_user {
  return unless $USER;
  $status = "fingering $USER...";
  $nap->whois($USER);
}

sub whisper_user {
  return unless $USER;
  my $d = $main->DialogBox(-title=>'Whisper',
			   -buttons=>['OK','Cancel'],
			   -default_button => '');
  $d->add('Label',
	  -text=>"Message to $USER")->pack(-side=>'left');
  my $e = $d->add('Entry',
		  -width          => 80,
		 )->pack(-side=>'left');
  $e->bind('<KeyPress-Return>',sub { $d->Subwidget('B_OK')->invoke });
  $e->focus;
  my $button = $d->Show;
  return unless $button eq 'OK';
  $status = "Sending message to $USER...";
  $nap->private_message($USER,$e->get);
}

sub whois {
  my ($server,$code,$user) = @_;
  my $profile = $user->profile;
  $USER = $user;
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
  browse_user()  if $button eq 'Browse';
  ping_user()    if $button eq 'Ping';
  whisper_user() if $button eq 'Whisper';
}

sub pong {
  my ($server,$code,$user) = @_;
  $ping_dialog ||= $main->Dialog(-buttons=>[qw(OK)]);
  $ping_dialog->configure(-title=>'Ping Response',
			  -text=>"$user is online");
  $ping_dialog->Show;
  $status = 'Connected';
}

sub clear_songs {
  %SONGS = ();
  $searchfound = 0;
  $searchstatus = 'Ready';
  $songtext->delete('1.0','end') if $songtext;
}

sub create_login_dialog {
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
  while (<DATA>) {
    next if /^\#/;
    chomp;
    my ($label,$addr,$meta) = /^(\w+)\s+([\w.]+:\d+)\s+(\d+)$/ or next;
    $server ||= $label;
    push @servers,$label;
    $SERVERS{$label} = [$addr,$meta];
  }
  $f2->Optionmenu(-variable  => \$server,
		  -options   => \@servers,
		  -width     => 15)->pack(-side=>'top',-fill=>'x',-expand=>1);

  my $n = $f2->Entry(-textvariable=>\$nickname,
		     -width=>20)->pack(-side=>'top',-fill=>'x',-expand=>1);
  my $p = $f2->Entry(-textvariable=>\$password,-width=>20,-show=>'*')->pack(-side=>'top',-fill=>'x',-expand=>1);

  # don't pack this
  my $confirm_e = $f2->Entry(-width=>20,-show=>'*');

  my $do_check = sub {
    my $button = $ld->Subwidget('B_Connect');
    if ($newuser) {
      $button->configure(-state => $n->get()
			 && $p->get() ne ''
			 && $p->get() eq $confirm_e->get() 
			 ? 'normal' : 'disabled');
    } else {
      $button->configure(-state => $n->get() && $p->get() ? 'normal' : 'disabled');
    }
  };

  $_->bind('<KeyPress>',$do_check) foreach ($n,$p,$confirm_e);

  # link speed option menu
  ($linklabel = $LINK{$user_linkspeed = DEFAULT_SPEED}) =~ s/^LINK_//;
  my @link_speed;
  for (sort {$a<=>$b} keys %LINK) {
    (my $label = $LINK{$_}) =~ s/^LINK_//;
    push @link_speed,[$label=>$_];
  }

  my $linkspeed = $f3->Frame->pack(-side=>'top',-fill=>'both',-expand=>1);
  $linkspeed->Optionmenu(-variable     => \$linklabel,
			 -options      => \@link_speed,
			 -width        => 8,
			 -command      => sub {
			   $user_linkspeed = $linklabel;
			   $linklabel = $LINK{$linklabel};
			   $linklabel =~ s/^LINK_//;
			 },
			)->pack(-side=>'right');
  $linkspeed->Label(-text=>"Link Speed: ",-relief=>'groove')->pack(-side=>'right');

  my $port = $f3->Frame->pack(-side=>'top',-fill=>'x',-expand=>1);
  $port->Entry(-textvariable=>\$userport,-width=>6)->pack(-side=>'right');
  $port->Label(-text=>'Port: ',-relief=>'groove')->pack(-side=>'right');

  my $d = $ld->add('Checkbutton',
		   -text         => 'Register as new user',
		   -variable     => \$newuser,
		   -command      => sub {
		     if ($newuser) {
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

sub add_song {
  $songwindow ||= songwindow($main);
  $songwindow->deiconify;
  $songwindow->raise;
  return unless @_;

  my ($server,$ec,$song) = @_;
  $searchfound++;
  $searchstatus = "Searching...$searchfound found";

  my $link = $song->link_code;
  my $owner = $song->owner;
  if ($link == LINK_UNKNOWN) {
    foreach (keys %USERS) {
      if (my $u = $USERS{$_}{$owner}) {
	$link = $u->link_code;
	last;
      }
    }
    $song->link_code($link);
  }
  $link = $song->link;
  $link =~ s/^LINK_//;
  $link = "?" if $link eq 'UNKNOWN';

  unless (%SONGS) { # beginning
    $songtext->insert('end',"Owner\tBitrate\tSize\tLink\tTitle\n\n",'header');
  }

  $SONGS{$song->owner,$song->name} = $song;
  my $string = sprintf "%s\t%3dkbps\t%6.2fM\t%6s\t%s\n",
    $song->owner,$song->bitrate,$song->size/1E6,$link,$song->name;
  my $index = bsearch($songtext,$song);
  $songtext->insert($index,$string,$link);
  $main->idletasks;
}

sub songwindow {
  my $main = shift;
  my $tl   = $main->Toplevel(-title=>'Song Browser',
			     -takefocus => 1);
  $tl->withdraw;
  $searchstatus = 'Ready';

  if (-e FIND_ICON) {
    my $image = $main->Pixmap(-file=>FIND_ICON);
    $tl->iconimage($image);
  }

  # frame for controls
  my $f1 = $tl->Frame->pack(-side=>'top',-fill=>'x');
  $f1->Label(-text=>'Search: ')->pack(-side=>'left');

  my $e = $f1->Entry(-textvariable=>\$search)->pack(-side=>'left',-fill=>'x',-expand=>1);
  $e->bind('<KeyPress-Return>',sub {
	     return unless $e->index('end');
	     clear_songs();
	     $searchstatus = 'Searching...';
	     $nap->search($e->get());
	   });

  my $clear_b  = $f1->Button(-text     => 'Clear')->pack(-side=>'left');
  my $search_b = $f1->Button(-text     => 'Search',
			     -state    => 'disabled',
			     -command  => sub { clear_songs();
						$nap->search($e->get()) },
			    )->pack(-side=>'left');
  $f1->Button(-text=>'Close',-command=>[$tl => 'withdraw'])->pack(-side=>'right',-anchor=>'e');


  my $f2 = $tl->LabFrame(-label=>'Search Results',
			   -labelside=>'acrosstop')->pack(-side=>'top',-fill=>'both',-expand=>1);
  my $s = $f2->Scrolled('ROText',
			-background => 'black',
			-foreground => 'yellow',
			-highlightcolor=>'blue',
			-scrollbars => 'soe',
			-font       => $normal,
			-cursor     => 'hand2',
			-wrap       => 'none',
			-tabs=>[qw(2.0i right 2.8i right 3.7i right 4.2i)]
		       )->pack(-fill=>'both',-expand=>1);
  $songtext = $s->Subwidget('rotext');
  $songtext->tag(configure=>$_,-foreground=>'gray')   foreach qw(? UNKNOWN);
  $songtext->tag(configure=>$_,-foreground=>'red')    foreach qw(14K 28K 33K);
  $songtext->tag(configure=>$_,-foreground=>'yellow') foreach qw(56K 64K);
  $songtext->tag(configure=>$_,-foreground=>'green')  foreach qw(128K CABLE DSL);
  $songtext->tag(configure=>$_,-foreground=>'green',-font=>$bold)  foreach qw(T1 T3);
  $songtext->tag(configure=>'header',
		 -foreground=>'yellow',
		 -underline=>1);
  $songtext->tag(configure=>'selected',
		 -font=>$italic,
		 -background=>'blue');
  $songtext->bind('<1>',[
			 sub {
			   my $w = shift;
			   my $xy = $Tk::event->xy;
			   $w->tagRemove('selected','1.0','end');
			   $w->tagAdd('selected',"$xy linestart","$xy lineend");
			 }]);
  $songtext->bind("<B1-Motion>",sub {shift->tagRemove('selected','1.0','end')});

  $tl->Label(-textvariable => \$searchstatus,
	     -relief       => 'ridge')->pack(-side=>'top',-fill=>'x');

  $tl->protocol(WM_DELETE_WINDOW=>[$tl => 'withdraw']);

  $clear_b->configure(-command  => \&clear_songs );

  $e->bind('<KeyPress>',sub {
	     $search_b->configure(-state => $e->index('end') ? 'normal' : 'disabled');
	   });

  $e->focus;
  $tl;
}

sub bsearch {
  my ($t,$s) = @_;
  my ($start,$stop,$pivot) = (3,$t->index('end')-2,3);
  while ($start <= $stop) {
    $pivot = int(($start + $stop)/2);
    my $line  = $t->get("$pivot.0","$pivot.end");
    chomp $line;
    my ($owner,$bitrate,$size,$link,$title) = split "\t",$line;
    $title =~ s/\s+$//;
    my $item = $SONGS{$owner,$title};
    my $cmp = do_cmp($s,$item);
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
  my ($song1,$song2) = @_;
  my $cmp;
  if (defined $comparison) {
    $c_direction ||= +1;
    $cmp = ($c_direction * ($song1->$comparison <=> $song2->$comparison))
  }
  $cmp || lc($song1->title) cmp lc($song2->title);
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
