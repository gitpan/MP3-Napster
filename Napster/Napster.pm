package MP3::Napster;

use strict;
use vars qw($VERSION);

use IO::Socket;
use IO::Poll 0.04;
use Exporter;
use base 'MP3::Napster::IOLoop';

use MP3::Napster::MessageCodes;
use MP3::Napster::UserCommand;
use MP3::Napster::Server;

$VERSION = '0.00001';
sub import {
  my $pkg = shift;
  my $callpkg = caller;
  Exporter::export 'MP3::Napster::MessageCodes', $callpkg, @_;
}

sub new {
  my $class = shift;
  my $server = shift;

  my $self = $class->SUPER::new(@_) or return;
  $self->{server} =  MP3::Napster::Server->new($server,$self) or return;
  $self;
}


1;

__END__
