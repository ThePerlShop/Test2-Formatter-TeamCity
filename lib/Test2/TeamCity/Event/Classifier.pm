package Test2::TeamCity::Event::Classifier;

# ABSTRACT: classify T₂ events into their correct Perl test results model type

use Test2::TeamCity::Kit;

=head2 SYNOPSIS

  use Test2::TeamCity::Event::Classifier qw(classify_event);


Get string event type computed from presence/absence of facets and the values
they carry:

  ($type, $is_parent, $is_init_phase) = classify_event($facet_data_hash_ref);


=begin :list

1. C<$type> - string Perl test result type, see below

1. C<$is_parent> - C<Bool>, true if contains children, false if this is a
   C<T₂> event describing a test results tree leaf

1. C<$is_init_phase> - C<Bool|Undef>, C<undef> if not relevant. Helps
   consumers down the pipeline tell if this is begins or ends a parent.
   True if this is a parent that arrives as a pair of events and this is the
   1st event in the pair, false if it is the final event. E.g. C<script>, is a
   parent. We look at the pair of harness_job_start/exit events, which arrives
   with children appearing between them. C<$is_init_phase> tells you if this
   parent is reporting a "begin" or if it is reporting "end"

=end :list

=head2 DESCRIPTION

We classify into types are taken from Perl test result model, which tries to
model how testers think about the tree of test results emitted when they run
tests.

Possible leaves:

=begin :list

1. C<pass> - an assertion that passed

1. C<fail> - an assertion that failed

1. C<diag> - diagnostics messages

1. C<note> - like C<diag> but to C<STDOUT> not C<STDERR>

1. C<skip> - following this marker there are tests that will not be run, and
   there is a reason

1. C<crash> - unexpected error in test/implementation code

1. C<bail> - test code initiated shutdown of test session, for a reason

1. C<stderr> - captured output on C<STDERR>

1. C<stdout> - captured output on C<STDOUT>

1. C<control> - some kind of control event

=end :list

And possible containers are:

=begin :list

1. C<subtest> - the Perl test area (a code element under which you can add test
   elements), events arrive as a tree

1. C<script> - also a test area like C<subtest>, but cannot be found inside
   other scripts or C<subtest>s. Arrives as a pair of first+final marker events -
   unlike the C<subtest> element which arrives as a ready-made tree of events and
   sub-events

1. C<method> / C<class> / C<instance> - C<TCM> test method/class/parameterized
   instance. C<TCM> relies on C<subtest> elements for these, and so do we

1. C<runner> - a C<TCM> runner script, not a C<subtest>, and therefore just
   like C<script>, we hear about it as it arrives in pairs of first/final
   events

1. C<suite> - a complete C<T₂> test session - starts with the C<harness_run>
   event, but unlike C<script> and C<runner> there is no final event

=end :list

=cut

use Const::Fast qw( const );
use Data::Dumper qw( Dumper );
use Object::Tap qw( $_tap );
use Ref::Util qw( is_hashref );
use Var::Extract qw( vars_from_hash );

use Sub::Exporter -setup => { exports => [qw(classify_event)] };

# Map from: facet existence to (correct type+is_parent_is_init_phase).
# E.g. if “harness_job_start” facet is found, then the type will be
# "script_begin". This simple method of classification is too simplistic for
# events types where classification requires looking at facet values, E.g. Pass
# and Fail.

const my %FACET_TO_TYPE => (

    # facet name         event type    is_parent  is_init_phase
    # ─────────────────────────────────────────────────────────
    #
    times             => [qw( times       0           )],
    memory            => [qw( memory      0           )],
    harness_job_start => [qw( script      1         1 )],    # script begin
    harness_job_end   => [qw( script      1         0 )],    # script end
    from_tap          => [qw( crash       0           )],    # legacy crash
);

# various t2 events are a simple tagged "info" facet
# these are the "info" facet tag values we support
const my @KNOWN_INFO_TAGS => (
    qw( diag info internal launch note stderr stdout timeout ),
    'run info',
);

const my $T2_ATTACH_EVENT => 'Test2::AsyncSubtest::Event::Attach';
const my $T2_DETACH_EVENT => 'Test2::AsyncSubtest::Event::Detach';

sub classify_event ($e) {

    # some event types can be classified by existence of facet
    for my $f ( keys %$e ) {
        return $FACET_TO_TYPE{$f}->@* if exists $FACET_TO_TYPE{$f};
    }

    # TCM internals are easy to detect by the Perl package
    {
        my $p = ( $e->{about} // {} )->{details} // q{};
        return ( tcm_attach => 0, 0 ) if $p eq $T2_ATTACH_EVENT;
        return ( tcm_detach => 0, 0 ) if $p eq $T2_DETACH_EVENT;
    }

    return
          $e->{parent}    ? ( subtest => 1, 1 )
        : $e->{errors}    ? 'crash'
        : $e->{plan}      ? get_plan_type( $e->{plan} )
        : $e->{assert}    ? get_assert_type($e)
        : $e->{info}      ? get_info_type( $e->{info}, $e )
        : _is_control($e) ? get_control_type( $e->{control} )
        :                   'unknown';
}

# classify between 1. plan 2. skip
sub get_plan_type ($facet) {
    vars_from_hash( $facet, my ( $count, $skip ) );
    return defined($skip) && $skip == 1 && !$count ? 'skip' : 'plan';
}

# classify between 1. legacy_fail 2. pass 3. fail 4. unknown_asert
# we need a type "legacy_fail" because we buffer them + join them with all
# consecutive related Diag events
sub get_assert_type ($e) {
    my $assert = $e->{assert};
    return 'unknown_assert' unless exists $assert->{pass};

    my $pass    = $assert->{pass};
    my $package = ( $e->{about} || {} )->{package};

    return 'legacy_fail'
        if defined $package && $package eq 'Test2::Event::Ok' && !$pass;

    return $pass ? 'pass' : 'fail';
}

# Classify between different info types or die if unknown
sub get_info_type ( $facet, $e ) {
    state $known_info_tags = { map { ( $_ => 1 ) } @KNOWN_INFO_TAGS };

    ( lc $facet->[0]->{tag} )->$_tap( sub ($v) {
        die qq{Unknown "info" facet tag: "$v".}
            . ' Add it to @Test2::TeamCity::Event::Classifier::KNOWN_INFO_TAGS,'
            . ' and add a rendering method write_$my_info_tag_name( $self, $e )'
            . ' to Test2::TeamCity::Event::View.'
            . Dumper($e)
            unless exists $known_info_tags->{$v};
    } );
}

# For errors, control facet may be empty hash, so further care is needed to classify
sub _is_control ($e) {
    my $control = $e->{control} // return undef;
    return is_hashref($control) && scalar keys %$control;
}

# classify between 1. bail_out 2. encoding 3. genric control
sub get_control_type ($facet) {
    vars_from_hash( $facet, my ( $halt, $global, $encoding ) );
    return
           $encoding ? 'encoding' : $halt
        && $global
        && $halt == 1
        && $global == 1 ? 'bail' : 'control';
}

1;
