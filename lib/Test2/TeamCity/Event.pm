package Test2::TeamCity::Event;

# ABSTRACT: wraps a T2 event with its facets, helps analyzing events

use Test2::TeamCity::Kit::Moose;

=head2 DESCRIPTION

Create through a factory from a C<T₂> facet data hash:

  use Test2::TeamCity::Event::Factory;

  $event = Test2::TeamCity::Event::Factory->make_event($some_t2_facet_data_hash_ref);


Common queries useful for event analysis and classification:

  $orig_event    = $event->wrap;       # the T₂ event hash we are wrapping

  $label_str     = $e->label;          # specialized to event type - short
                                       # string describing the event to
                                       # someone who knows the event type

  $type_str      = $e->type;           # computed from facets of event
                                       # without consulting package name

  $package       = $e->t2_package;     # t2 event package, or if none:
                                       # Test2::Event::Generic

  $lc_suffix     = $e->short_package;  # lc package suffix, eg: “generic”

  @facet_names   = $e->facet_names;    # list of found facets
  %name_to_facet = $e->facets;         # hash of facet objects
  $facet         = $e->facet($name)    # named facet object or undef

  $should_begin  = $e->is_init_phase;  # non-parent    → undef
                                       # parent begin  → ⊤
                                       # parent end    → ⊥

  say $e->is_parent                    # E.g. true for subtests/scripts/,
    ? 'has children':                  # but false for ok
    : 'no sub-events';

  say $e->is_inline_parent;            # tcm classes + methods + subtests are
                                       # all heard as T₂ subtest events and
                                       # they are the only parents that hold
                                       # their tree of children inside a facet

  @children = $e->children;            # children are T₂ event hash refs
                                       # you need a factory to convert
                                       # them into object of this class

  # assuming this is an event where is_inline_parent is true, E.g. subtest, and
  # that it is the begin marker of this parent when serialized, then return a
  # clone of the given begin marker, changed in one way: it is now an end
  # marker. Useful for converting a subtest, which we get from C<T₂> formatter
  # as a single event with all its children inline, into a begin/end event
  # pair. C<TC> requires we print such a pair if we want it to create the C<TC>
  # test result element we use for all parent types - the I<Suite>.

  $end_marker = $e->make_end_marker;

  # a facet accessor will return undef if not carried by the event

  my  $assert_facet = $e->assert_facet;
  my    $info_facet = $e->info_facet;
  my  $errors_facet = $e->errors_facet;
  my  $parent_facet = $e->parent_facet;
  my   $trace_facet = $e->trace_facet;

  # event details, or q{} if no info facet found
  say $info_e->info_details;

  # true if event is a T2::Event::Ok carrying a test failure
  # these are the events we merge with Diag events satisfying is_related()
  say $e->is_legacy_fail ? 'ok(0,…)': 'something else';

  say $e->is_modern_fail ? 'Fail(…)': 'something else';
  say 'first' if $e->is_first_event; # 1st in this test session
  say $assert_e->is_pass ? 'pass': 'fail';
  say $assert_e->is_fail ? 'fail': 'pass'; # legacy or modern
  say 'a diag event' if $e->is_diag;
  say $assert_e->is_seed_event ? 'this is T₂ srand seed event': 'an event';
  say $harness_job_exit_e->is_exit_ok ? 'zero exit code': '!';

  $code   = $harness_job_exit_e->exit_code; # exit code if harness job exit event
  $level  = $e->level;                      # test nesting level, 0 for top-level
  $str    = $e->bail_out_reason;            # if bail-out, why?
  $num    = $e->plan_count;                 # assert count in plan
  $job_id = $e->job_id;                     # original test job id
                                            # or harness id if not from job

  # true if is_legacy_fail is true for this event, and the event we attempting
  # to merge 1) has some info details 2) created by same test tool at same
  # point in the trace, I.e. the two events belong to the same assert

  say 'me ↔ some other event info'
      if $e->is_related($some_other_e);

  # this is how we group multiple related fail diagnostics into one event,
  # convert the legacy fail event (C<Ok(0, …)>) into a modern C<Fail> event,
  # and drop the C<Diag>s as they are no longer needed:

  my $merged_modern_fail = $legacy_fail_e->merge(@list_of_diags);


=cut

use Data::Focus qw( focus );
use List::Util qw( all none );
use Test2::TeamCity::Event::Util qw(
    are_trace_facets_related
    join_single_facet_details
    merge_info_facets
);

has wrap => (
    is            => 'ro',
    isa           => 'HashRef',
    required      => 1,
    documentation => 'T2 event facets hash by name',
);

has type => (
    is            => 'ro',
    isa           => 'Str',
    required      => 1,
    documentation => q{Event type taken from Perl result model, e.g. "diag"},
);

has is_parent => (
    is            => 'ro',
    isa           => 'Bool',
    default       => 0,
    documentation => 'True if this is the a container, E.g. subtest',
);

has is_init_phase => (
    is            => 'rw',
    writer        => 'set_init_phase',
    isa           => 'Bool|Undef',
    default       => 0,
    documentation =>
        'True if this is the init event of a container, false if it is the'
        . 'the final event of the container, undef if this is no container',
);

has parent_event => (
    is            => 'rw',
    writer        => 'set_parent_event',
    isa           => 'Test2::TeamCity::Event|Undef',
    documentation =>
        'If this is a child event of an inline parent, E.g. a subtest or'
        . ' ok, this is how you navigate to that parent event',
);

has child_events => (
    is            => 'ro',
    isa           => 'ArrayRef[Test2::TeamCity::Event]',
    lazy          => 1,
    default       => sub { [] },
    documentation =>
        'If this is an inline parent, E.g. subtest, this will hold its'
        . 'child events, and they will be of same class as this object',
);

sub is_related ( $self, $e ) {
    return undef unless $self->is_legacy_fail && $e->is_diag;
    return are_trace_facets_related( map { $_->trace_facet } $self, $e );
}

sub merge ( $self, @merge ) {
    my $info_facets = [ map { $_->info_facet } $self, @merge ];
    ref($self)->new(
        is_parent     => 0,
        is_init_phase => undef,
        type          => 'fail',
        wrap => { $self->wrap->%*, info => merge_info_facets(@$info_facets) },
    );
}

sub children ($self) {    # filters children with no facet data
    my $parent = $self->parent_facet // return ();
    grep { defined } $parent->{children}->@*;
}

sub info_details ($self) {
    join_single_facet_details( $self->info_facet // return q{} );
}

sub error_details ($self) {
    join_single_facet_details( $self->errors_facet // return q{} );
}

sub assert_name       ($self) { $self->get(qw( assert details )) // q{} }
sub level             ($self) { $self->get(qw( trace nested ))   // 0 }
sub bail_out_reason   ($self) { $self->get(qw( control details )) }
sub plan_details      ($self) { $self->get(qw( plan details )) }
sub plan_count        ($self) { $self->get(qw( plan count )) }
sub t2_package        ($self) { $self->get(qw( about package ))  // '-' }
sub job_id            ($self) { $self->get(qw( harness job_id )) // '-' }
sub short_package     ($self) { lc [ split qr/::/, $self->t2_package ]->[-1] }
sub exit_code         ($self) { $self->raw->{harness_job_exit}->{exit_code} }
sub is_inline_parent  ($self) { defined $self->parent_facet }
sub is_exit_ok        ($self) { $self->exit_code == 0 }
sub make_begin_marker ($self) { $self->clone( is_init_phase => 1 ) }
sub make_end_marker   ($self) { $self->clone( is_init_phase => 0 ) }

sub is_tcm_internal ($self) {
    $self->type eq 'tcm_attach' || $self->type eq 'tcm_detach';
}

sub is_pass ($self) {
    exists $self->wrap->{assert}{pass} && $self->wrap->{assert}{pass};
}

sub is_fail ($self) {
    exists $self->wrap->{assert}{pass} && !$self->wrap->{assert}{pass};
}

sub assert_facet ($self) { $self->facet('assert') }
sub errors_facet ($self) { $self->facet('errors') }
sub info_facet   ($self) { $self->facet('info') }
sub parent_facet ($self) { $self->facet('parent') }
sub trace_facet  ($self) { $self->facet('trace') }

sub is_first_event ($self) { $self->type eq 'suite' && $self->is_init_phase }
sub is_suite       ($self) { $self->type eq 'suite' }
sub is_encoding    ($self) { $self->type eq 'encoding' }
sub is_memory      ($self) { $self->type eq 'memory' }
sub is_times       ($self) { $self->type eq 'times' }
sub is_diag        ($self) { $self->type eq 'diag' }
sub is_note        ($self) { $self->type eq 'note' }
sub is_plan        ($self) { $self->type eq 'plan' }
sub is_modern_fail ($self) { $self->type eq 'fail' }
sub is_legacy_fail ($self) { $self->type eq 'legacy_fail' }
sub is_crash       ($self) { $self->wrap->{errors} }
sub facet_names    ($self) { keys $self->wrap->%* }

sub is_stdout ($self) {
    my $facet = $self->info_facet // return undef;
    my $head  = $facet->[0]       // return undef;
    return $head->{details} && $head->{tag} eq 'STDOUT';
}

sub is_phase_end ($self) {
    my $phase = $self->get(qw( control phase )) // return undef;
    return $phase eq 'END';
}

sub is_seed_event ($self) {
    return $self->is_note && $self->info_details =~ /^Seeded srand with seed/;
}

sub rel_file ($self) {
    my $root = $self->is_init_phase ? 'harness_job_start' : 'harness_job_end';
    return $self->get( $root, 'rel_file' ) // 'UNKNOWN FILE';

}

sub file ($self) {
    return join(
        ':',
        ( $_->get(qw( harness_settings finder search )) // ['UNKNOWN FILE'] )
            ->@*
    ) if $self->is_suite;

    my $get = sub ( $n = undef ) {
        $self->get( 'harness_job' . ( $n ? "_$n" : q{} ), 'file' );
    };

    my $file = $get->('start') // $get->() // $get->('exit') // $get->('end')
        // '[UNKNOWN FILE]';

    return $file;
}

sub make_markers ($self) {
    map { $self->$_ } qw( make_begin_marker make_end_marker );
}

sub harness_job_exit_error ($self) {
    my ( $details, $exit_code, $stderr, $file )
        = map { $self->get( harness_job_exit => $_ ) // '?' }
        qw( details code stderr file );
    return
        "Harness error: $details, exit: $exit_code, file: $file, stderr: $stderr";
}

sub is_leaf_subtest ($self) {
    $self->is_inline_parent
        && ( all { !defined( $_->{parent} ) } $self->children );
}

sub is_leafless_subtest ($self) {
    $self->is_inline_parent
        && ( none { !defined( $_->{parent} ) } $self->children );
}

sub clone ( $self, %args ) { ref($self)->new( %$self, %args ) }
sub facet ( $self, $name ) { $self->wrap->{$name} }
sub get   ( $self, @path ) { focus( $self->wrap )->get(@path) }

sub pass_unfiltered { 0 }
sub is_composite    { 0 }

sub is_assert     ($self) { $self->is_pass || $self->is_fail }
sub is_leaf       ($self) { !$self->is_parent }
sub is_script_end ($self) { $self->type eq 'script' && !$self->is_init_phase }

__PACKAGE__->meta->make_immutable;

1;
