package Test2::TeamCity::Event::Composite;

# ABSTRACT: batch multiple Perl test result leaves into a single TeamCity test

use Test2::TeamCity::Kit::Moose;

use List::Util qw( any );
use Test2::TeamCity::Event::Filter ();

has nodes => (
    isa      => 'ArrayRef[Test2::TeamCity::Event]',
    is       => 'ro',
    required => 1,
);

has subtest => (
    isa      => 'Test2::TeamCity::Event',
    is       => 'ro',
    required => 1,
);

has is_init_phase => (
    is      => 'rw',
    writer  => 'set_init_phase',
    isa     => 'Bool|Undef',
    default => 0,
);

sub type            { 'composite' }
sub pass_unfiltered { 1 }

sub clone ( $self, %args ) { ref($self)->new( %$self, %args ) }

sub error_details ($self) {
    return join "\n", grep { /\S/ }
        map { $_->error_details } ( $self->nodes->@*, $self->subtest );
}

sub filter_nodes ($self) {
    my $filter = Test2::TeamCity::Event::Filter->new;
    my @nodes  = $filter->filter_events( $self->nodes->@* );
    return ref($self)->new( nodes => \@nodes, subtest => $self->subtest );
}

sub name    ($self) { $self->subtest->assert_name }
sub is_pass ($self) { $self->subtest->is_pass }

sub is_fail ($self) {
    any { $_->is_fail } ( $self->nodes->@*, $self->subtest );
}

sub is_crash ($self) {
    any { $_->is_crash } ( $self->nodes->@*, $self->subtest );
}

sub job_id         ($self) { $self->subtest->job_id }
sub is_first_event ($self) { $self->subtest->is_first_event }

sub is_inline_parent ($self) { 1 }
sub is_composite             { 1 }
sub is_leaf                  { 1 }

sub info_details ($self) {
    join "\n", grep { /\S/ } map { $_->info_details // q{} } $self->nodes->@*;
}

sub make_begin_marker ($self) { $self->clone( is_init_phase => 1 ) }
sub make_end_marker   ($self) { $self->clone( is_init_phase => 0 ) }

sub make_markers ($self) {
    map { $self->$_ } qw( make_begin_marker make_end_marker );
}

__PACKAGE__->meta->make_immutable;

1;
