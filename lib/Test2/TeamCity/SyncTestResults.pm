package Test2::TeamCity::SyncTestResults;

# ABSTRACT: convert T₂ events → Perl test result stream + show it

use Test2::TeamCity::Kit::Moose;

=head2 SYNOPSIS

  use Test2::TeamCity::SyncTestResults;

  $sync = Test2::TeamCity::SyncTestResults->new;

  # you can replace any component of the pipeline
  # pipeline components are: factory, filter, joiner, view

  $sync = SyncTestResults->new( view => $my_view_object );


Call C<< $sync->write_facet_data($facet_data_hash_ref) >> to push an event
for processing through the components of the pipeline. It will eventually end
up with the final component - the view. The view should write the event and
return. When the view completes, pipeline processing is over and
C<< $sync->write_facet_data >> will return.

  # returns void, side effect in view component

  $sync->write_facet_data($facet_data_hash_ref);

  $sync->write_facet_data(@facet_data_hash_ref); # write more than one


=head3 PIPELINE INPUT

C<write_facet_data> expects a list of hash references. Each is the facet data
hash of a C<T₂> event. So these will all work as facet_data for input:

=begin :list

1. If C<$e> is a C<Test2::HarnessEvent>, which is what a L<Test2::Formatter>
   sees, calling C<< $e->facets >> will return the hash reference we require.
   This should work for any C<T₂> event just as well

1. If C<$e> is a plain event hash reference, of the type you find looking
   I<inside> C<subtest>s that C<T₂> sends to the formatter's C<write()> method,
   C<< $e->{facet_data} >> will return the hash reference required. Any hash
   reference with a key C<facet_data> will work

=end :list

=cut

use Const::Fast qw( const );
use List::Gather qw( gather );
use Test2::TeamCity::Event::Factory ();
use Test2::TeamCity::Event::Filter  ();
use Test2::TeamCity::Event::View    ();
use Try::Tiny qw( catch try );

const my $PIPELINE_PREFIX => 'Test2::TeamCity::Event';

const my @PIPELINE => (

    # executed in this order, documentation about what their role is in this
    # event processing pipeline should be found in the component docs

    # class      delegate
    # suffix     method
    # ───────────────────────────
    [ Factory => 'make_top_level_events' ],
    [ Filter  => 'filter_events' ],
    [ View    => 'write_events' ],
);

has factory => (
    isa      => 'Test2::TeamCity::Event::Factory',
    is       => 'ro',
    default  => sub { Test2::TeamCity::Event::Factory->new },
    handles  => [qw(make_top_level_events)],
    required => 1,
);

has filter => (
    isa      => 'Test2::TeamCity::Event::Filter',
    is       => 'ro',
    default  => sub { Test2::TeamCity::Event::Filter->new },
    handles  => [qw(filter_events)],
    required => 1,
);

has view => (
    isa      => 'Test2::TeamCity::Event::View',
    is       => 'ro',
    default  => sub { Test2::TeamCity::Event::View->new },
    handles  => [qw(write_events)],
    required => 1,
);

# iterate through pipeline, feed output one step as input to next
# @facet_data is list of hashes, each is the facet data of a T₂ event
sub write_facet_data ( $self, @facet_data ) {
    $self->_write_one($_) for @facet_data;
}

sub _write_one ( $self, $facet_data ) {
    my @payload = $facet_data;
    gather {
        for my $row (@PIPELINE) {
            my ( $class_suffix, $method ) = @$row;
            try { @payload = $self->$method(@payload) }
            catch { die qq{Step error "$class_suffix/$method" - $_}; };
        }
    }

}

__PACKAGE__->meta->make_immutable;

1;
