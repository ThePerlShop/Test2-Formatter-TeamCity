package Test2::TeamCity::Kit;

use strict;
use warnings;

use Import::Into;

use autodie 2.25 ();
use curry ();
use experimental qw(signatures);
use feature          ();
use mro              ();
use multidimensional ();
use Object::Tap      ();
use open qw( :encoding(UTF-8) :std );
use utf8 ();

sub import {
    my $caller_level = 1;

    strict->import::into($caller_level);
    warnings->import::into($caller_level);

    my ($version) = $^V =~ /^v(5\.\d+)/;
    feature->import::into( $caller_level, ':' . $version );
    feature->unimport::out_of( $caller_level, 'indirect' );

## no critic (Subroutines::ProhibitCallsToUnexportedSubs)
    mro::set_mro( scalar caller(), 'c3' );
## use critic
    #
    utf8->import::into($caller_level);
    multidimensional->unimport::out_of($caller_level);
    'open'->import::into( $caller_level, ':encoding(UTF-8)' );
    autodie->import::into( $caller_level, ':all' );

    curry->import::into($caller_level);
    Object::Tap->import::into($caller_level);

    my @experiments = qw(
        lexical_subs
        postderef
        signatures
    );
    experimental->import::into( $caller_level, @experiments );
}

1;
