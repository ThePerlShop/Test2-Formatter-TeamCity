package Test2::Formatter::TeamCity;

use Test2::TeamCity::Kit;

=head1 SYNOPSIS

    # use the formatter when running a test suite through yath

    shell$ yath test --formatter TeamCity my_tests.t

=cut

use Test2::TeamCity::SyncTestResults ();

use Test2::Util::HashBase qw(sync);
use Try::Tiny qw( catch try );

BEGIN {
    require Test2::Formatter;
    ## no critic (ClassHierarchies/ProhibitExplicitISA)
    our @ISA = qw(Test2::Formatter);    ## use critic
}

our $VERSION = '1.000000';

sub init ( $self, @ ) {
    $self->{ +SYNC }
        = Test2::TeamCity::SyncTestResults->new( $self->sync_args );
}

## no critic (Subroutines/ProhibitBuiltinHomonyms)
sub write ( $self, $e, @ ) {    ## use critic
    try { $self->sync->write_facet_data( $e->facet_data ) }
    catch { die "Formatter error - $_" };
}

# default=1 do not send formatter messages until they leave buffer
sub hide_buffered { 1 }

sub encoding { 'utf8' }

sub sync_args ($self) { () }

1;
