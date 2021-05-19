package Test2::TeamCity::Event::Filter;

# ABSTRACT: a filter for top-level events and one for nested events

use Test2::TeamCity::Kit::Moose;

=head2 SYNOPSIS

  use Test2::TeamCity::Event::Filter;

  $filter = Test2::TeamCity::Filter->new;

  # a filter that should be applied to all events - filters irrelevant events

  @only_tc_formatter_relevant_events = $filter->filter_events(@events);


=head2 DESCRIPTION

=head3 Filtering Irrelevant Events

C<filter_events> should be applied to every event. We filter these event types
because they are irrelevant to C<TC> formatter:

=begin :list

1. C<encoding>
1. C<memory>
1. C<times>
1. C<Diag> for C<SRand> seed
1. C<TCM> C<Attach>/C<Detach> internal events
1. C<harness_job_queued> events
1. C<plan> events

=end :list

=cut

use Const::Fast qw( const );
use List::Util qw( all );

const my @FILTER_MARKER_FACETS =>
    qw( memory harness_final harness_job_queued harness_run );

sub filter_events ( $self, @es ) {
    grep { $self->is_relevant($_) } @es;
}

sub is_relevant ( $self, $e ) {
    return 1 if $e->type eq 'composite';
    _ensure_none(
        $e,
        qw(
            plan
            encoding
            memory
            times
            seed_event
            tcm_internal
            phase_end
        )
    ) && all { !defined( $e->facet($_) ) } @FILTER_MARKER_FACETS;
}

sub _ensure_none ( $e, @predicates ) {
    all { !$e->${ \("is_$_") }() } @predicates;
}

__PACKAGE__->meta->make_immutable;

1;
