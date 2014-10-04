# ABSTRACT: Generate an Audit Report
package Git::Code::Review::Command::report;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Basename;
use File::Spec;
use Git::Code::Review::Notify;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use POSIX qw(strftime);
use YAML;

my $NOW           = strftime('%F', localtime);
my $THIRTYDAYSAGO = strftime('%F', localtime(time - (86400*30)));

sub opt_spec {
    return (
        ['history-start:s',  "Date to start history on, default is full history" ],
        ['concerns-start:s', "Date to start display of commits with conerns in approved state, default is $THIRTYDAYSAGO", {default=>$THIRTYDAYSAGO}],
        ['at:s',             "Status of the repository at this date, default today", {default => $NOW}],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Generate a report of the audit.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    gcr_reset();

    my $audit = gcr_repo();

    my @commits  = ();
    if( $opt->{at} ne $NOW ) {
        # Rewind the Repository
        my @rev = $audit->run('rev-list', '-n', 1, '--before', $opt->{at}, 'master');
        if(!@rev) {
            output({color=>'red',stderr=>1}, "No revisions in the repository at $opt->{at}!");
            exit 1;
        }
        debug({color=>'cyan'}, "+ Rewinding history to $opt->{at} with sha1:$rev[0]");
        $audit->run(checkout => $rev[0]);
        @commits = map { basename $_ } grep /\.patch$/, $audit->run('ls-files');
        gcr_reset();
    }
    else {
        @commits = map { basename $_ } grep /\.patch$/, $audit->run('ls-files');
    }

    my %commits  = ();
    my @concerns = ();
    my %monthly  = ();
    if( @commits ) {
        # Assemble Commits
        foreach my $base (@commits) {
            my $commit;
            debug("Getting info on $base");
            eval {
                $commit = gcr_commit_info($base);
            };
            next unless defined $commit;
            debug({indent=>1,color=>'green'}, "+ Success!");
            my $profile = exists $commit->{profile} ? $commit->{profile} : undef;
            # Skip commits without profile
            next unless $profile;
            # Skip commits which are locked
            next if $profile eq 'Locked';

            # Make sure we care about it
            next if $opt->{history_start} && $commit->{date} lt $opt->{history_start};

            # Commit State Tracking
            $commits{$profile} ||= {};
            $commits{$profile}->{$commit->{state}} ||= 0;
            $commits{$profile}->{$commit->{state}}++;

            # Monthly Tracking
            my $month = join('-', (split /-/,$commit->{date})[0,1] );
            my $state = $commit->{state} ne 'approved' ? 'todo' : 'complete';

            $monthly{$month}->{$state} ||= 0;
            $monthly{$month}->{$state}++;
        }
    }
    debug({color=>'magenta'}, "Commit Status");
    debug_var(\%commits);

    # Concerns Information
    my @details  = ();
    my %concerns = ();
    my @log_options = qw(--reverse);
    push @log_options, "--since", $opt->{history_start} if exists $opt->{history_start};
    my $logs = $audit->log(@log_options);
    while(my $log = $logs->next) {
        # Details
        my $data = gcr_audit_record($log->message);

        # Skip some states
        next if exists $data->{skip};
        next unless exists $data->{state};

        # Record this commit
        my @record = (
            sprintf("commit  %s", $log->commit),
            sprintf("Author: %s <%s>", $log->author_name, $log->author_email),
            sprintf("Date:   %s", strftime('%F %T',localtime($log->author_localtime))),
            '',
            $log->raw_message,
        );

        # For selections, add details
        push @record, '', $audit->run(qw(diff-tree --stat -r), $log->commit)
            if $data->{state} eq 'select';

        # Add to our details
        push @details, join("\n", @record);

        # Get the SHA1
        my $sha1 = gcr_audit_commit($log->commit);

        # Profile Specific Details
        my $commit;
        if( defined $sha1 ) {
            $data->{profile} ||= gcr_commit_profile($sha1);
            eval { $commit = gcr_commit_info($sha1) };
        }
        # If there's no commit in play, skip this.
        next unless defined $commit;

        my $date = strftime('%F',localtime($log->author_localtime));

        # Parse History for Commits with Concerns
        if( $data->{state} eq 'concerns' ) {
            $concerns{$sha1} = {
                concern => {
                    date        => $date,
                    explanation => $data->{message},
                    reason      => $data->{reason},
                    by          => $data->{reviewer},
                },
                commit => {
                    state => $commit->{state},
                    date  => $commit->{date},
                    by    => $data->{author},
                },
            };
        }
        elsif( $data->{state} eq 'approved' || $data->{state} eq 'comments' ) {
            next unless exists $concerns{$sha1};

            if ( $data->{state} eq 'approved' && $date le $opt->{concerns_start} ) {
                delete $concerns{$sha1};
            }
            else {
                $concerns{$sha1}->{log} ||= [];
                push @{$concerns{$sha1}->{log}}, {
                    date        => $date,
                    state       => $data->{state},
                    reason      => $data->{reason},
                    by          => $data->{reviewer},
                    explanation => $data->{message},
                };
            }
        }
    }
    debug({color=>'red'}, "Concerns raised:");
    debug_var(\%concerns);

    Git::Code::Review::Notify::notify(report => {
        options  => $opt,
        commits  => \%commits,
        monthly  => \%monthly,
        concerns => \%concerns,
        history  => \@details,
    });
}

1;
