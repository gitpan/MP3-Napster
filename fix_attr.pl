#!perl

use File::Find;
find(\&wanted,'./blib');

sub wanted {
  return unless /\.pm$/;
  open(F,$_) || return;
  unlink($_);
  open(OUT,">$_");
  select(OUT);
  while (defined ($_ = <F>) ) {
    s/^(sub\s+\$?\w+)\s*:\s*locked[, ]method\s*(\{.*)/$1 $2\n  use attrs qw(locked method);/x;
    s/^(sub\s+\$?\w+)\s*:\s*locked\s*(\{.*)/$1 $2\n  use attrs qw(locked);/x;
  } continue {
    print;
  }
  1;
}
