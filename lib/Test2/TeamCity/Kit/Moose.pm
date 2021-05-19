## no critic (Moose::RequireMakeImmutable)
package Test2::TeamCity::Kit::Moose;

use Test2::TeamCity::Kit;

use Moose::Exporter;

# We do this a second time to re-establish our custom warnings
use Test2::TeamCity::Kit;

use Import::Into;

use Moose                          ();
use MooseX::SemiAffordanceAccessor ();
use MooseX::StrictConstructor      ();
use namespace::autoclean           ();

my ($import) = Moose::Exporter->setup_import_methods(
    install => [ 'unimport', 'init_meta' ],
    also    => ['Moose'],
);

sub import ( $class, @ ) {
    my $for_class = caller();
    $import->( undef, { into => $for_class } );
    $class->import_extras( $for_class, 2 );
    return;
}

sub import_extras ( $, $for_class, $level ) {

    MooseX::SemiAffordanceAccessor->import( { into => $for_class } );
    MooseX::StrictConstructor->import(      { into => $for_class } );

    Test2::TeamCity::Kit->import::into($level);

    return;
}

1;
