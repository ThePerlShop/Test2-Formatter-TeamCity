package Test2::TeamCity::Event::Factory;

# ABSTRACT: wrap T₂ event facet data with a helpful decorator

use Test2::TeamCity::Kit::Moose;

=head2 SYNOPSIS

  use Test2::TeamCity::Event::Factory;

  $factory = Test2::TeamCity::Event::Factory->new;

  # top level events are events recieved at T₂ formatter
  # they require different filtering than nested events

  @es = $factory->make_top_level_events(@list_of_facet_data_hash_refs);

  # and for events that are not top level (received from harness):

  @es = $factory->make_events( $inital_tree_level, @list_of_facet_data_hash_refs);

  # now we can go wild with the events we got
  say $_->type for @es;


=head2 DESCRIPTION

Call C<make_events> with a list of facet data hash references. Returns C<1…n>
L<Test2::TeamCity::Event>s. Most types of facet data received will translate
1-to-1 to an event. C<Subtest>s however, will get an extra event for _end
subtest_, required because we are serializing a tree into a stream, and in
between the C<begin> and C<end> events, we add all of the C<subtest>'s children
recursively.

The end result is a depth-first tour C<subtest>s.

=head3 Filtering Events to Avoid Duplication

C<T₂> events arrive multiple times at the formatter. To avoid confusing
C<TC> with duplicate assertions, for example, we filter the every event
we get from the test harness, or that we find inside a
L<Test2::Event::Subtest>. C<from_one_facet> checks that:

  $event_level, computed from: $event → “frame” facet → “nested” field

  must be equal to the:

  $cursor_level, starts at 0 for top-level harness events, increase by one
  on each subtest we are expanding


When we are at level N we filter all events that are I<not> at level N.

=cut

use Clone qw( clone );
use List::SomeUtils qw( any part );
use Test2::TeamCity::Event::Classifier qw( classify_event );
use Test2::TeamCity::Event::Composite ();
use Test2::TeamCity::Event            ();

has _top_level_leaf_buffer => (
    is      => 'rw',
    isa     => 'ArrayRef',
    lazy    => 1,
    default => sub { [] },
    writer  => '_set_top_level_leaf_buffer',
);

sub make_top_level_events ( $self, @things ) {
    $self->_make_events( 0, @things );
}

sub _make_events ( $self, $level, @things ) {
    map { $self->_make_event( $level, $_ ) } @things;
}

sub _make_event ( $self, $level, $thing ) {
    my $blessed_facet_data = clone _normalize($thing);

    # we must unbless the facets to avoid test2 overloading as we inspect
    # facet data in future steps
    my %facet_data = map { ( $_, _unbless( $blessed_facet_data->{$_} ) ) }
        keys %$blessed_facet_data;

    my ( $type, $is_parent, $is_init_phase ) = classify_event( \%facet_data );
    my $new = Test2::TeamCity::Event->new(
        wrap          => \%facet_data,
        type          => $type,
        is_parent     => $is_parent // 0,
        is_init_phase => $is_init_phase,
    );

    return $level == $new->level
        ? $self->_maybe_open_parent( $level + 1, $new )
        : ();
}

# Recursively serialize a tree in depth 1st order.
sub _maybe_open_parent ( $self, $level, $e ) {
    return ($e) unless $e->is_inline_parent;

    my @children = $self->_make_events( $level, $e->children );

    # If this is a subtest of only leaves, batch them together.
    return ( Test2::TeamCity::Event::Composite->new(
        subtest => $e, nodes => \@children
    ) )
        if $e->is_leaf_subtest;

    # If we are a mixed subtest of leaves and child subtests, create
    # synthetic test.
    if ( !$e->is_leafless_subtest ) {
        my ( $for_suite, $for_test )
            = part { $_->is_inline_parent ? 0 : 1 } @children;

        @children
            = ( $self->_make_synthetic_test( $e, @$for_test ), @$for_suite );
    }

    # Now we know we have a leafless subtest we must wrap children with a
    # begin/end marker.
    return ( $e->make_begin_marker, @children, $e->make_end_marker );
}

sub _make_synthetic_test ( $self, $parent, @children ) {
    my $has_fails = any { $_->is_fail } @children;
    my $one_child = @children == 1;

    my $test = Test2::TeamCity::Event->new(
        wrap => {
            assert => {
                details => $one_child
                ? $children[0]->assert_name // "${parent}__anonymous_test"
                : $parent->assert_name . '__child_tests'
            },
            harness => $parent->facet('harness'),
        },
        type => $has_fails ? 'fail' : 'pass'
    );

    return Test2::TeamCity::Event::Composite->new(
        subtest => $test,
        nodes   => \@children,
    );
}

# goal: return plain hash ref of facet data for all forms of events thrown at it
#
# if a harness or other T₂ event, we load the facets and return them
# else we get the key “facet_data” and return it, or if not found, we assume
# $thing itelf is the facet data hash ref and return it

sub _normalize ($thing) {
    blessed $thing
        ? $thing->isa('Test2::Event')
            ? $thing->facets
            : die qq{Unknown T2 event "$thing"}
        : ref($thing) eq 'HASH' ? ( $thing->{facet_data} // $thing )
        :                         die qq{Expected hash ref but got "$thing"};
}

sub _unbless ($v) { ref($v) && blessed($v) ? {%$v} : $v }

__PACKAGE__->meta->make_immutable;

1;
