#!/usr/bin/perl -w

# Before `make install' is performed this script should be runnable with
# `make test'. After `make install' it should work as `perl test.pl'
use lib '../blib/lib';

######################### We start with some black magic to print on failure.
BEGIN { $| = 1; print "1..6\n"; }
END {print "not ok 1\n" unless $loaded;}
use MP3::Napster;
$loaded = 1;
print "ok 1\n";
######################### End of black magic.

my $test_num = 2;
sub test {
    local($^W) = 0;
    my($true,@msg) = @_;
    print($true ? "ok $test_num\n" : ("not ok $test_num ",@msg,"\n"));
    $test_num++;
}

# basic tests of functionality
$MP3::Napster::DEBUG_LEVEL = 0;

test(defined(&WHOIS_RESPONSE),'imported message constants not defined');
test($MP3::Napster::MESSAGES{WHOIS_RESPONSE()} eq 'WHOIS_RESPONSE','reverse mapped constants not defined');
test(defined(&LINK_14K),'imported linkspeed constants not defined');
test(!defined(MP3::Napster->new('localhost:0')),"shouldn't connect but did!");
test(MP3::Napster->error eq 'connection refused',"wrong error message on failed connect, got ",MP3::Napster->error);

