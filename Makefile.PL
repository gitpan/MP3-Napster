use ExtUtils::MakeMaker;
# See lib/ExtUtils/MakeMaker.pm for details of how to influence
# the contents of the Makefile that is written.

require 5.00503;

eval { require Thread }        || die "You must have a threading version of Perl installed.  Can't continue";
eval { require Digest::MD5 }   || die "You must have Digest::MD5 installed.  Can't continue";
eval { require MP3::Info }     || die "You must have MP3::Info installed.  Can't continue";

# post-modify the .pm files to handle the switch from "use attrs" to "sub foo : attrs"
sub MY::subdirs {
  return '' if $] >= 5.00562;
  return << 'END';
subdirs :: $(INST_LIBDIR)/Napster.pm $(INST_LIBDIR)/Napster/Channel.pm $(INST_LIBDIR)/Napster/User.pm $(INST_LIBDIR)/Napster/Song.pm  $(INST_LIBDIR)/Napster/Base.pm   $(INST_LIBDIR)/Napster/Transfer.pm
	$(PERL) ./fix_attr.pl
	@$(TOUCH) $@
END
}

WriteMakefile(
	      NAME	   => 'MP3::Napster',
	      AUTHOR       => 'Lincoln Stein <lstein@cshl.org>',
	      ABSTRACT     => 'Pure Perl module for interacting with Napster MP3 servers',
	      ABSTRACT_FROM => 'Napster.pm',
	      PMLIBDIRS    => ['Napster'],
	      PREREQ_PM    => { Digest::MD5   => 0,            # needed for uploading files
				MP3::Info     => 0,
				Thread        => 0,
			      },
	      VERSION_FROM => 'Napster.pm',     # finds $VERSION
	      PL_FILES     => {
			       'eg/miniserver.PL'      => 'eg/miniserver.pl',
			       'eg/simple_download.PL' => 'eg/simple_download.pl',
			       'napster.PL'            => 'napster.pl',
			      },
	      EXE_FILES    => ['napster.pl'],
	      DISTNAME     => 'MP3-Napster',
	      linkext      => { LINKTYPE=>'' },	# no link needed
	      dist         => {'COMPRESS'=>'gzip -9f', 'SUFFIX' => 'gz',
			       'ZIP'=>'/usr/bin/zip','ZIPFLAGS'=>'-rl'}
);

