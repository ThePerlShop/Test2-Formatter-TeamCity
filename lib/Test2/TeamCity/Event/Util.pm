package Test2::TeamCity::Event::Util;

# ABSTRACT: helper functions for analyzing events

use Test2::TeamCity::Kit;

=head2 SYNOPSIS

  use Test2::TeamCity::Event::Util qw(
      are_trace_facets_related
      is_test_class_moose_class
      is_test_class_moose_runner
      join_single_facet_details
      merge_info_facets
  );

=head3 are_trace_facets_related($event_facet1, $event_facet2)

Check if both trace facets, extracted from a C<T₂> event, share a
C<uuid> or all C<signatures>:

  say 'yes' if
      are_trace_facets_related( $trace_hash_ref_1, $trace_hash_ref_2 );


=head3 is_test_class_moose_runner($filename)

Send a filename, get back a C<Bool> which will be true if the file name matches
the C<TCM> moose runner script naming convention:

  # an event where info->[0]->{details} = 't/run-test-class-moose.t'
  say is_test_class_moose_runner($e) ? 'Y': 'N'; # Y

  # an event where info->[0]->{details} = 't/01-my tet.t'
  say is_test_class_moose_runner($e) ? 'Y': 'N'; # N


=head3 is_test_class_moose_class($classname)

Send a class name, get back a C<Bool> which will be true if it matches the C<TCM>
test class name pattern of C<< ^TestFor( not colon* )::( not colon ) >>.

=head3 join_single_facet_details($single_info_facet) = String

Returns all notes in a single C<info> facet as one string or an empty
string if none found.

  # empty string if no details

  say 'joined details of this info/error or anything-with-details facet: '.
    join_single_facet_details($single_facet);


=head3 merge_info_facets(@info_facets) = String

Info facets are lists. These two functions let you merge them from one info
facet or several. Facets with no info details will be ignored, if none found,
returns empty string.

  say 'returns a single info facet array ref carrying one info facet:'.
    merge_info_facets(@list_of_info_facets);


=head3 has_errors/get_times($event)

Frames in the trace facet are given in an array reference. This will convert it
into a labeled hash reference with the same values, which is sometimes more
useful.

Check for errors and get the errors in an event:

  my @error_strings = errors($e);
  my $is_error      = has_errors($e);


Get the test time report from C<T₂>:

  my $times_str = get_times($e);


=cut

use Const::Fast qw( const );
use List::Util 1.56 qw( all mesh );

use Sub::Exporter -setup => {
    exports => [ qw(
        are_trace_facets_related
        is_test_class_moose_class
        is_test_class_moose_runner
        frame_to_hash
        get_times
        has_errors
        join_single_facet_details
        merge_info_facets
    ) ]
};

const my @FRAME_FIELD_LABELS => qw( pkg file line sub );

# from Test2::Event
sub are_trace_facets_related ( $trace_1, $trace_2 ) {
    return undef unless defined $trace_1 && defined $trace_2;
    my @traces = ( $trace_1, $trace_2 );

    my @uuids = map { $_->{uuid} } @traces;
    return $uuids[0] eq $uuids[1] if all { defined } @uuids;

    my @sigs = map { $_->{signature} } @traces;
    return ( all { defined } @sigs ) && $sigs[0] eq $sigs[1];
}

sub is_test_class_moose_class ($s) { $s =~ /^TestFor[^:]*::[^:]+/ }

sub is_test_class_moose_runner ($s) { $s =~ /run-.*\.t$/ }

sub merge_info_facets (@info_facets) {
    return [
        {
            tag     => 'DIAG',
            debug   => 1,
            details => join "\n",
            grep    { /\S/ }
                map { join_single_facet_details($_) } @info_facets,
        },
    ];
}

sub join_single_facet_details ($facet) {
    return q{} unless defined $facet;
    _strip( join "\n", map { $_->{details} // {} } @$facet );
}

sub _strip ($s) {
    for ($s) {
        s/^(?:[\s|\n|\t]+)+//;
        s/(?:[\s|\n|\t]+)+$//;
    }
    return $s;
}

sub frame_to_hash ($frame) { { mesh \@FRAME_FIELD_LABELS, $frame } }

sub has_errors ($e) { exists $e->{errors} && scalar $e->{errors}->@* }

sub get_times ($e) {
    exists $e->{times}
        ? join(
        ', ',
        map { "$_: " . $e->{times}->{$_} } sort keys $e->{times}->%*
        )
        : q{};
}

1;
