package MP3::Napster::Base;
require Carp;

# provide an AUTOLOAD function for stereotyped field access
sub AUTOLOAD {
  lock $AUTOLOAD;  # so that it won't change beneath us!
  my ($pack,$field_name) = $AUTOLOAD=~/(.+)::([^:]+)$/;
  my $func;

  if (exists ${"$pack\:\:RDONLY"}{$field_name}) {
    $func = <<END;
sub $AUTOLOAD : locked method {
    my \$self = shift;
    Carp::confess("Attempt to modify read-only field $field_name") if \@_;
    return \$self->{$field_name};
}
END
       ;

  } elsif (exists ${"$pack\:\:FIELDS"}{$field_name}) {
    $func = <<END;
sub $AUTOLOAD : locked method {
    my \$self = shift;
    \$self->{$field_name} = shift if \@_;
    return \$self->{$field_name};
}
END

  } else {
    Carp::confess ("Undefined subroutine $AUTOLOAD");
  }

  eval $func;
  Carp::confess ($@) if $@;
  goto &$AUTOLOAD;
}

sub DESTROY { }

sub import {
  my $pack = shift;
  my $callpack = caller;
  my %mappings = @_;
  for my $mapping (keys %mappings) {
    my $code = qq(package $callpack; use vars '\%$mapping';\n);
    while (my($key,$value) = each %{$mappings{$mapping}}) {
      $code .=  qq(sub $key { $value }\n);
      $code .=  qq(\$$mapping\{$value\} = '$key';\n);
    }
    eval $code || die $@;
  }
}

1;

__END__

=head1 NAME

MP3::Napster::Base - Autoload object accessors

=head1 SYNOPSIS

None

=head1 DESCRIPTION

This class is used internally by MP3::Napster as a base class for
MP3::Napster::Song, MP3::Napster::Channel, MP3::Napster::Transfer, and
MP3::Napster itself.  It provides autoloading facilities for accessors.

Documentation will be added if and when it becomes useful to
application developers.

=head1 AUTHOR

Lincoln Stein <lstein@cshl.org>.

=head1 COPYRIGHT

Copyright (c) 2000 Cold Spring Harbor Laboratory. All rights reserved.
This program is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<MP3::Napster>, L<MP3::Napster::Song>, L<MP3::Napster::Channel>, and
L<MPEG::Napster::Transfer>

=cut

