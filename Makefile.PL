use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

require 5.6.0;

eval { require Digest::MD5 }   || die "You must have Digest::MD5 installed.  Can't continue";
eval { require MP3::Info }     || die "You must have MP3::Info installed.  Can't continue";

WriteMakefile(
	      NAME	   => 'MP3::Napster',
	      AUTHOR       => 'Lincoln Stein <lstein@cshl.org>',
	      ABSTRACT     => 'Pure Perl module for interacting with Napster MP3 servers',
	      ABSTRACT_FROM => 'Napster.pm',
	      PMLIBDIRS    => ['Napster','TkNapster'],
	      PREREQ_PM    => { Digest::MD5   => 0,            # needed for uploading files
				MP3::Info     => 0,
			      },
	      VERSION_FROM => 'Napster.pm',     # finds $VERSION
	      PL_FILES     => {
			       'eg/miniserver.PLS'      => 'eg/miniserver.pl',
			       'eg/simple_download.PLS' => 'eg/simple_download.pl',
			       'napster.PLS'            => 'napster.pl',
			       'tknapster.PLS'          => 'tknapster.pl',
			      },
	      EXE_FILES    => ['napster.pl','tknapster.pl'],
	      DISTNAME     => 'MP3-Napster',
	      linkext      => { LINKTYPE=>'' },	# no link needed
	      dist         => {'COMPRESS'=>'gzip -9f', 'SUFFIX' => 'gz',
			       'ZIP'=>'/usr/bin/zip','ZIPFLAGS'=>'-rl'}
);

