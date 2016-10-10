# ABSTRACT: Generate an audit report and optionally update Jira tickets.
package Git::Code::Review::Command::report;
use strict;
use warnings;

use CLI::Helpers qw(
    debug
    output
    verbose
);
use File::Basename;
use File::Spec;
use Git::Code::Review -command;
use Git::Code::Review::Notify;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review::Utilities::Date qw(
    is_valid_yyyy_mm_dd
    start_of_month
);
use POSIX qw(strftime);
use YAML;


my $NOW = strftime('%F', localtime);
my $_RESET=0;
END {
    # Make sure we reset
    gcr_reset() if $_RESET;
}


sub opt_spec {
    return (
        ['all',         "Ignore profile settings, generate report for all profiles." ],
        ['since|s=s',   "Date (YYYY-MM-DD) to start history on, default is full history" ],
        ['until|u=s',   "Status of the repository at this date (YYYY-MM-DD), default today", {default => $NOW}],
        ['update',      "Check the status of commits as of today, to update old JIRA tickets."],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review report [options]

    DESCRIPTION

        Generate a report of the audit for a given period and optionally update Jira tickets.

    EXAMPLES

        git-code-review report

        git-code-review report --profile team_awesome --since 2015-01-01

        git-code-review report --profile team_awesome --since 2015-01-01 --until 2015-12-31

        git-code-review report --all

        git-code-review report --all -s 2015-01-01 -u 2015-12-31

        git-code-review report --all --update

    OPTIONS

            --profile profile   Show information for specified profile. Also see --all.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;
    die "Invalid --since date, expected date in YYYY-MM-DD format" if $opt->{ since } && ! is_valid_yyyy_mm_dd( $opt->{ since } );
    die "Invalid --until date, expected date in YYYY-MM-DD format" if $opt->{ until } && ! is_valid_yyyy_mm_dd( $opt->{ until } );

    my $profile = gcr_profile();
    my $audit   = gcr_repo();
    gcr_reset();

    # Handle Profile Specific Files
    my @ls = ('ls-files');
    push @ls, $profile unless $opt->{all};

    # Start of last month
    my $last_month = start_of_month( $opt->{ until }, -1 );
    debug({color=>'magenta'}, "MONTH DETERMINED: $last_month");

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
        sprintf('Git::Code::Review Report for %s through %s', ($opt->{since} // ''), $opt->{until}),
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
