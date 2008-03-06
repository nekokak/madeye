package App::MadEye::Plugin::Worker;
use strict;
use warnings;
use base qw/Class::Component::Plugin/;
use Gearman::Worker;
use Gearman::Client;
use App::MadEye::Util;
use Params::Validate;
use English;
use App::MadEye::Util;
use POSIX ":sys_wait_h";
use Storable qw/freeze thaw/;
use YAML;

our $TIMEOUT = 60;  # TODO: configurable
our $EXPTIME = 180; # TODO: configurable

sub run_workers : Method {
    my ($self, $context) = @_;

    my $parent_pid = $PID;
    my @child_pids;
    for my $i ( 0 .. $self->config->{config}->{fork_num}- 1 ) {
        my $pid = fork();
        if ($pid) {
            # parent process
            push @child_pids, $pid;
        } elsif ( defined $pid ) {
            # child process
            $context->log('debug', "start worker $i($parent_pid)");
            $self->run_worker($context, $parent_pid);
        } else {
            die "Cannot fork: $!";
        }
    }
    $context->{child_pids} = \@child_pids;
}

sub register_job :Method {
    my ($self, $context, $args) = @_;

    my $taskset = $self->task_set($context);
    $taskset->add_task(
        'watch',
        freeze($args), +{
            on_fail => sub {
                warn "GEARMAN ERROR: " . Dump($args);
            },
            on_complete => sub {
                my $args = thaw( ${ $_[0] } );

                if ( ref $args eq 'HASH' ) {
                    # this server was dead.
                    $context->add_result(
                        plugin  => $args->{plugin},
                        target  => $args->{target},
                        message => $args->{message},
                    );
                }
                elsif ( ref $args eq 'SCALAR' && not defined $$args ) {
                    # success case
                }
                else {
                    die "invalid value: " . Dump($args);
                }
              },
        }
    );
    $taskset->wait; ## remove.
}

sub wait_jobs :Method {
    my ($self, $context) = @_;

    $self->task_set->wait;
}

sub kill_workers :Method {
    my ( $self, $context ) = @_;

    my $taskset = $self->task_set($context);
    for my $child_pid (@{ $context->{child_pids} }) {
        $taskset->add_task( "exit$child_pid", undef );
    }
}

sub task_set {
    my ($self, $context) = @_;

    $context->{task_set} ||= $self->gearman_client->new_task_set;
}

sub gearman_client {
    my $self = shift;

    $self->{client} ||= do {
        my $client = Gearman::Client->new;
        $client->job_servers( @{ $self->config->{config}->{gearman_servers} } );
        $client->prefix($PID);
        $client;
    };
}

sub wait_workers : Method {
    my ( $self, $context ) = @_;

    timeout $TIMEOUT, 'wait_children', sub {
        my $dead_children = 0;
        while ( $dead_children < $self->config->{config}->{fork_num} ) {
            my $kid = waitpid( -1, &WNOHANG );
            if ($kid) {
                $dead_children++;
            }
        }
    };
}

sub run_worker {
    my ($self, $context, $parent_pid) = @_;

    my $worker = Gearman::Worker->new;
    $worker->job_servers( @{ $self->config->{config}->{gearman_servers} } );
    $worker->prefix($parent_pid);
    $worker->register_function(
        'watch',
        sub {
            my $args = thaw( $_[0]->arg );

            $context->log( debug => "watching $args->{target} by $args->{plugin}" );

            my $result = \undef;
            timeout $TIMEOUT, "watching $args->{target} $args->{plugin}", sub {
                if ( my $message = $args->{plugin}->is_dead( $args->{target} ) ) {
                    # TODO: このあたりのルールもちゃんとつくる
                    if (
                        $self->should_notify_p(
                            target  => $args->{target},
                            context => $context,
                        )
                      )
                    {
                        $result = +{
                            message => $message,
                            plugin  => $args->{plugin},
                            target  => $args->{target},
                        };
                    }
                }
            };
            return freeze($result);
        }
    );
    $worker->register_function(
        "exit$$",
        sub {
            exit;
        }
    );
    $worker->work while 1;
}

# これはここにあるべきか？ちげーだろ。
sub should_notify_p {
    my $self = shift;
    validate(
        @_ => {
            target  => 1,
            context => 1,
        }
    );
    my %args = @_;
    my $host = $args{host};

    # ある時間帯だけスルーさせるルール
    if ( my $param = $args{opt}->{args}->{neglect_hours}->{$host} ) {
        my $now = DateTime->now;
        my %ymd = map { ( $_ => $now->$_ ) } qw(year month day);
        if (
            $now->between(
                map { DateTime->new( %ymd, %{ $param->{$_} } ) }
                  qw(start_time end_time)
            )
          )
        {
            return 0;
        }
    }

   # 再起動のタイミングとかで応答しないこともあるので、
   # 一回ぐらい落ちてても気にしないというルール
    if ( $args{opt}->{args}->{should_retry} ) {
        my $cache_key = "$host-is-dead";

        my $recent_dead_fg = $self->cache->get($cache_key) ? 1 : 0;

        # 今回死んだことをここに記す。
        $self->cache->set( $cache_key => 1, $EXPTIME );

        return $recent_dead_fg;
    }

    return 1;    # 死んでるんだからおしらせしとけや
}

1;
