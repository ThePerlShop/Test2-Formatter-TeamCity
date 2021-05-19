package Test2::TeamCity::Event::View;

# ABSTRACT: Perl test result event → TeamCity build service message on STDOUT use Test2::TeamCity::Kit::Moose;

use Test2::TeamCity::Kit::Moose;

=head2 SYNOPSIS

  use Test2::TeamCity::Event::View;

  my $capture; # for testing
  my $io = IO::Scalar->new( \$capture );
  my $view = Test2::TeamCity::Event::View->new(
      halt_on_error => 0,   # default is 1
      stdout        => $io, # for testing, default is test2_stdout()
                            # customize using T2TC_HALT_ON_ERROR
  );

  # write $some_formatter_event to STDOUT as tc build service message
  $view->write_event($some_formatter_event);

  # or write many
  $view->write_events(@some_formatter_events);


  translation table

  suite => suite - top level suite


=cut

use Const::Fast qw( const );
use Data::Dumper qw( Dumper );
use TeamCity::Message 0.02 qw( tc_message tc_timestamp );
use Test2::API qw( context test2_stdout );
use Test2::TeamCity::Event::Util qw(
    is_test_class_moose_class
    is_test_class_moose_runner
);

const my @COUNTERS => qw(
    anonymous
    classes
    diag
    fail
    errors
    note
    pass
    runners
    scripts
    skip
    subtests
    stdout
);

has halt_on_error => (
    is            => 'ro',
    isa           => 'Bool',
    default       => $ENV{T2TC_HALT_ON_ERROR} // 1,
    documentation =>
        'If true, formatter will try to halt test session on 1st error'
        . '. Default is true: tests halt on 1st error. If it is defined'
        . ', then the value is taken from the env var T2TC_HALT_ON_ERROR.',
);

has stdout => (
    is            => 'ro',
    lazy          => 1,
    default       => sub ($) { test2_stdout },
    documentation => 'Redirectable for testing',
);

has counters => (
    is      => 'ro',
    isa     => 'HashRef[Int]',
    default => sub ($) {
        +{ map { ( $_ => 0 ) } @COUNTERS };
    },
    documentation =>
        'Per-job counters kept in the view for progress reporting',
);

sub write_events ( $self, @e ) { $self->write_event($_) for @e }

sub write_event ( $self, $e ) {
    my $type = $e->type;

    # no interest in internal control messages
    return if $type eq 'unknown_control';

    my $method = $self->can("write_$type");
    die qq{Unknown event type "$type", } . Dumper($e) unless $method;
    $self->$method($e);
}

sub write_memory ( $self, $e ) { $self->_msg( $e, $e->memory_details ) }
sub write_ok     ( $self, $e ) { $self->write_pass($e) }

sub write_pass ( $self, $e ) {
    $self->_write_assert( $e, $e->assert_name, 0 );
}
sub write_plan  ( $, $ ) { }    # TC tallies for us
sub write_times ( $, $ ) { }    # and records timings
sub write_suite ( $, $ ) { }    # redundant top level suite

sub write_info     ( $self, $e ) { $self->write_note($e) }
sub write_internal ( $self, $e ) { $self->write_note($e) }

sub write_note ( $self, $e ) {
    chomp( my $details = $e->info_details // 'no details' );
    $self->_inc('note');
    $self->_msg( $e, "NOTE: $details" );
}

sub write_stdout ( $self, $e ) {
    $self->_inc('stdout');
    $self->_msg( $e, 'STDOUT ' . $e->info_details );
}

sub write_diag ( $self, $e ) {
    chomp( my $details = $e->info_details // 'no details' );
    if ( $details eq 'No tests run!' ) {
        $self->_write_error( $e, EmptyTestSuite => $details );
    }
    else {
        $self->_inc('diag');
        $self->write_note($e);
    }
}

sub write_legacy_fail ( $self, $e ) {
    $self->_write_assert(
        $e,
        $e->assert_name,
        1,
    );
}

sub write_fail ( $self, $e ) {
    $self->_write_assert(
        $e, $e->assert_name,
        1,
    );
}

# TC rule: no TC suites with different flowID in same tree, unless flowIds are
# in parent/child relationship using flowStarted/Finished.
#
# Tests will get different job ids when run in parallel. These ids are not
# yet known to them on "write_suite" event time.

sub write_job ( $self, $e ) {

    # A counter for how many times a file is mentioned in a job events.
    state $job_mention_counter = {};

    my $file = $e->file // 'No file found.';

    my $count = $job_mention_counter->{$file} // 0;
    $job_mention_counter->{$file} = ++$count;

    $self->_emit(
        $e,
        progressMessage =>
            { content => qq{JOB: $file#$count, } . $self->_counter_progress }
    );
}

sub write_script ( $self, $e ) {
    state $scripts = {};    # used to keep track of scripts seen here
    my $file      = $e->file;
    my $is_runner = is_test_class_moose_runner($file);
    $self->_inc( $is_runner ? 'runners' : 'scripts' )
        unless $scripts->{$file}++;

    # We don't want TCM runners as suites in TC because:
    #
    # 1- they mean nothing
    # 2- they are unstable
    #
    # But we still:
    #
    # 1- want to know runner of test class from log
    # 2- want another level of hierarchy to ease log loading
    #
    # This is a description of the "blockOpened/Closed" build service
    # message pair, and that is what we convert TCM runner start/stop
    # Test2 events into

    my $msg = $is_runner ? 'block' : 'testSuite';
    $self->_emit( $e, $msg => { name => $file } );
}

sub write_subtest ( $self, $e ) {
    state $classes  = {};
    state $subtests = {};
    my $name          = $e->assert_name;
    my $is_test_class = is_test_class_moose_class($name);
    $self->_inc('classes') if $is_test_class && !$classes->{$name}++;
    $self->_inc('subtests') unless $subtests->{$name}++;

    # Replace for the benefit of tc test name parser. From TC docs:
    #
    #  <suite name>:<package/namespace name>. \
    #      <class name>.<test method>(<test parameters>)
    #
    # My Tests: some.package.path.TestClass.testMethod("param1","param2")
    #
    # in the example above,
    # * suite name = "My Tests"
    # * package = some.package.path
    # * class name = TestClass
    # * test method = testMethod
    # * test parameters = ("param1","param2")
    #
    # We convert from Perl test class name so:
    #
    # * suite name = top level package (E.g. TestFor)
    # * package = everything between suite name and class name
    # * class name = bottom level package (E.g. MyTests)
    #
    # Note we do nothing for test method names (E.g. test_my_stuff): they
    # arrive as a different subtest event, and TC seeing that we are currently
    # inside some test class, will figure out that this is where they belong.

    my $tc_name = $is_test_class
        ? do {
        my @parts = split /::/, $name;
        if ( @parts > 2 ) {
            my $suite   = shift(@parts)       || 'ANONYMOUS.SUITE';
            my $class   = pop(@parts)         || 'ANONYMOUS.CLASS';
            my $package = join( '.', @parts ) || 'ANONYMOUS.PACKAGE';
            "$suite:$package.$class";
        }
        else { $name }
        }
        : $name;

    $self->_emit( $e, testSuite => { name => $tc_name } );
}

sub write_composite ( $self, $e ) {
    if ( $e->is_crash ) {
        $self->_write_assert(
            $e,
            $e->name,
            1,
            $e->error_details,
        );
        return;
    }
    $self->_write_assert(
        $e, $e->name,
        $e->is_fail
    );
}

sub write_crash ( $self, $e ) {
    $self->_write_error( $e, ExceptionFromTestCode => $e->error_details );
}

sub write_timeout ( $self, $e ) {
    $self->_write_error( $e, TestHarnessTimeout => $e->info_details );
}

sub write_bail ( $self, $e ) {
    $self->_write_error( $e, UserInitiatedBailout => $e->bail_out_reason );
}

sub write_control ( $self, $ ) { }

sub write_stderr ( $self, $e ) {
    $self->_write_error( $e, StdErr => $e->info_details );
}

sub write_launch ( $self, $ ) { }

sub write_skip ( $self, $e ) {
    $self->_emit(
        $e,
        testIgnored => {
            name    => $e->plan_details // '[NO REASON]',
            message => 'SKIP: #' . $self->_inc('skip'),
        }
    );
}

sub _write_assert (
    $self,
    $e,
    $name,
    $is_fail = 0,
    $details = $e->info_details
) {
    $name = 'anonymous #' . $self->_inc('anonymous')
        if !defined($name) || $name eq q{};
    my ( $e1, $e2, $name_pair ) = ( $e->make_markers, { name => $name } );
    $self->_emit(
        $e1,
        test => { %$name_pair, captureStandardOutput => 'true' }
    );
    $self->_emit(
        $e,
        testFailed => { %$name_pair, details => $details }
    ) if $is_fail;
    $self->_emit( $e2, test => $name_pair );
    $self->_inc( $is_fail ? 'fail' : 'pass' );
}

sub _write_error ( $self, $e, $type, $details = 'ERROR WITH NO DETAILS' ) {
    my $err_count = $self->_inc('errors');
    $self->_emit(
        $e,
        progressMessage => {
            content => 'Progress before error:' . $self->_counter_progress
        }
    );
    my $msg = qq{A test error (#$err_count) of type "$type" was thrown.}
        . qq{ Error details: [$details].};
    $self->_emit( $e, message => { text => $msg, status => 'ERROR' } );

    # No need to do anything on UserInitiatedBailout, because if
    # we got the event from T₂, then surely T₂ is going to do
    # something about it. Not to mention the infinite loop we
    # would go into, of bailing, getting the event and bailing,
    # ad infinitum.
    context()->$_tap( sub ($ctx) {
        $ctx->bail($msg);
        } )->release
        if $self->halt_on_error && $type ne 'UserInitiatedBailout';
}

# emit a teamcity build service message of type "message"
sub _msg ( $self, $e, $text ) {
    $self->_emit( $e, message => { text => $text } );
}

# actual print of tc_message happens here
sub _emit ( $self, $e, $msg_type, $content ) {
    my $init = $e->is_init_phase;
    my $final_type
        = $msg_type eq 'testFailed' ? $msg_type
        : $msg_type eq 'message'    ? 'message'
        : $msg_type
        . (
          defined($init)
        ? $init
                ? $msg_type eq 'block'
                    ? 'Opened'
                    : 'Started'
                : $msg_type eq 'block' ? 'Closed'
            : 'Finished'
        : q{}
        );

    my %new_content = (
        %$content,
        ( $e->job_id ? ( flowId => $e->job_id ) : () ),
        $self->_event_time_entry($e),
    );
    my $new_content;
    for my $k ( sort keys %new_content ) {
        ( $new_content->{$k} = $new_content{$k} ) =~ s/'/|'/g;
    }

    print { $self->stdout }
        tc_message( type => $final_type, content => $new_content );
}

sub _event_time_entry ( $self, $ ) { ( timestamp => tc_timestamp() ) }

sub _inc ( $self, $counter ) {
    my $counts = $self->counters;
    die qq{No such counter "$counter"} unless defined $counts->{$counter};
    ++$counts->{$counter};
}

sub _counter_progress ($self) {
    join(
        q{, },
        map { uc($_) . q{: } . $self->counters->{$_} } @COUNTERS
    );
}

__PACKAGE__->meta->make_immutable;

1;
