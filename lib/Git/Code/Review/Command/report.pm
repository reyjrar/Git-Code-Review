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
use Time::Local qw(timelocal);
use YAML;

my $_RESET=0;
END {
    # Make sure we reset
    gcr_reset() if $_RESET;
}

my $NOW = strftime('%F', localtime);
sub opt_spec {
    return (
        ['all',     "Ignore profile settings, generate report for all profiles." ],
        ['since:s', "Date to start history on, default is full history" ],
        ['until:s', "Status of the repository at this date, default today", {default => $NOW}],
        ['update',  "Check the status of commits as of today, to update old JIRA tickets."],
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

    my $audit   = gcr_repo();
    my $profile = gcr_profile();

    # Handle Profile Specific Files
    my @ls = ('ls-files');
    push @ls, $profile unless $opt->{all};

    # Start of last month
    my @parts = reverse split /-/, $opt->{until};
    $parts[-2]--;   # Adjust the Month for 0..11
    $parts[-2]--;   # Now, last month!
    $parts[0] = 1;  # The first of the month
    unshift @parts, 0,0,0;
    my $epoch_historic = timelocal(@parts);
    my $last_month = strftime('%F', localtime($epoch_historic));

    my @commits  = ();
    if( $opt->{until} ne $NOW ) {
        # Rewind the Repository to the date selected.
        my @rev = $audit->run('rev-list', '-n', 1, '--before', $opt->{until}, 'master');
        if(!@rev) {
            output({color=>'red',stderr=>1}, "No revisions in the repository at $opt->{until}!");
            exit 1;
        }
        debug({color=>'cyan'}, "+ Rewinding history to $opt->{until} with sha1:$rev[0]");
        $audit->run(checkout => $rev[0]);
        $_RESET=1;
    }
    @commits = map { basename $_ } grep /\.patch$/, $audit->run(@ls);
    verbose({color=>'cyan'}, "Generating report for Period $last_month through $opt->{until}");

    if( exists $opt->{update} && $opt->{update} ) {
        # Time travel back to the present to make note of any changes in status
        gcr_reset();
        $_RESET=0;
    }

    my %commits  = ();
    my @concerns = ();
    my %monthly  = ();
    if( @commits ) {
        # Assemble Commits
        foreach my $base (@commits) {
            my $commit;
            eval {
                $commit = gcr_commit_info($base);
            };
            if( !defined $commit ) {
                verbose({color=>'yellow'}, "Collecting information on $base failed.");
                next;
            }

            # Check Date
            next if $opt->{since} && $commit->{date} lt $opt->{since};

            # Monthly Tracking
            my $month = join('-', (split /-/,$commit->{date})[0,1] );
            my $state = $commit->{state} ne 'approved' ? 'todo' : 'complete';

            $monthly{$month}->{$state} ||= 0;
            $monthly{$month}->{$state}++;

            # Check profiles
            my $profile = exists $commit->{profile} && length $commit->{profile} ? $commit->{profile} : '*none*';

            # Commit State Tracking
            $commits{$profile} ||= {};
            $commits{$profile}->{lc $commit->{state}} ||= 0;
            $commits{$profile}->{lc $commit->{state}}++;
        }
    }

    # Concerns Information
    my @details  = ();
    my %concerns = ();
    my %selected = ();

    # Generate the log entries
    my   @log_options = qw(--reverse --stat);
    push @log_options, "--since", $opt->{since} if exists $opt->{since};
    push @log_options, '--', $profile unless $opt->{all};

    my $logs = $audit->log(@log_options);
    while(my $log = $logs->next) {
        # Details
        my $data = gcr_audit_record($log->message);
        my $date = strftime('%F',localtime($log->author_localtime));

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
            $log->extra,
        );

        # For selections, add details
        if( $data->{state} eq 'select' ) {
            my @files = map { my $p = basename($_); $p =~ s/\.patch//; $p }
                        gcr_audit_files($log->commit);
            @selected{@files} = ();
            my $source = gcr_repo('source');
            foreach my $sha1 (@files) {
                my $c = undef;
                eval {
                    $c = gcr_commit_info($sha1);
                };
                if(!defined $c) {
                    delete $selected{$sha1};
                    debug({color=>"yellow"}, "Collecting data on $sha1 failed.");
                    next;
                }
                if(exists $opt->{since} && $c->{date} lt $opt->{since}) {
                    debug("$sha1 date $c->{date} is out-of-range $opt->{since}.");
                    next;
                }
                $selected{$sha1} = [
                    $c->{date},
                    ($c->{profile} ? $c->{profile} : ''),
                    $c->{state},
                    join(' ', $source->run(qw(diff-tree --no-commit-id --name-only -r),$sha1)),
                ];
            }
        }
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

        # We have an audit commit, we might not care about.
        if( exists $opt->{since} && exists $commit->{date} && $commit->{date} lt $opt->{since} ) {
            splice @details, -1, 1;
        }


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

            if ( $data->{state} eq 'approved' && $date le $last_month ) {
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

    gcr_reset() if $_RESET--;

    output({color=>'cyan'},
        '=*'x40,
        sprintf('Git::Code::Review Report for %s through %s', $opt->{since}, $opt->{until}),
        '=*'x40,
        '',
    );

    Git::Code::Review::Notify::notify(report => {
        options  => $opt,
        month    => $last_month,
        commits  => \%commits,
        monthly  => \%monthly,
        concerns => \%concerns,
        profile  => $opt->{all} ? 'all' : $profile,
        selected => \%selected, ,
        history  => \@details,
    });
}

1;
