package TkNapster::Config;
BEGIN {
   @AnyDBM_File::ISA = qw(DB_File GDBM_File NDBM_File)
}
use AnyDBM_File;
use Tk;
use Tk::LabEntry;

sub new {
  my $class = shift;
  my ($main,$config_file) = @_;
  $config_file ||= (getpwuid($<))[7] . "/.tknapstercfg";
  my %h;
  dbmopen(%h,$config_file,0622) or return;
  my $self = bless {
		    config => \%h,
		    window => undef,
		   },$class;
  $self->{window} = $self->init($main);
  return $self;
}

# configuration info
sub init {
  my $self = shift;
  my $main = shift;
  my $tl   = $main->Toplevel(-title=>'Configuration',
			     -takefocus => 1);
  my $p = [-side=>'left',-anchor=>'w'];
  $tl->LabEntry(-label=>'first',-labelPack=>$p,-textvariable=>\$self->{config}{first})->pack(-fill=>'x',-expand=>1);
  $tl->LabEntry(-label=>'second',-labelPack=>$p,-textvariable=>\$self->{config}{second})->pack(-fill=>'x',-expand=>1);
  $tl->LabEntry(-label=>'third',-labelPack=>$p,-textvariable=>\$self->{config}{third})->pack(-fill=>'x',-expand=>1);
  $tl->Button(-text=>'Done',-command=>[$tl => 'withdraw'])->pack;
  $tl->protocol(WM_DELETE_WINDOW=>[$tl => 'withdraw']);
  return $tl;
}

sub show {
  my $self = shift;
  $self->{window}->deiconify;
  $self->{window}->raise;
}

1;

