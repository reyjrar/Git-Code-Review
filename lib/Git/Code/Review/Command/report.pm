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

my $START = strftime('%F',localtime(time - (86400*7)));
my $END   = strftime('%F',localtime);

sub opt_spec {
    return (
        ['since|s:s',   "Commit start date, none if not specified", {default => $START}],
        ['until|u:s',   "Commit end date, none if not specified",   {default => $END}],
        ['all',         "Ignore profile settings, generate report for all profiles." ],
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
    debug("OPTIONS");
    debug_var($opt);

    gcr_reset();
    my $profile = gcr_profile();
    my $audit   = gcr_repo();

    # Handle Profile Specific Files
    my @ls = ('ls-files');
    push @ls, $profile unless $opt->{all};

    # Grab Commit Status
    my @list = map { $_=gcr_commit_info($_) } grep /\.patch$/, $audit->run(@ls);
    my %commits = ();
    my %overall = ();
    if( @list ) {
        # Assemble Commits
        foreach my $commit ( sort { $a->{date} cmp $b->{date} } @list ) {
            my $profile = exists $commit->{profile} ? $commit->{profile} : undef;
            # Skip commits without profile
            next unless $profile;
            # Skip commits which are locked
            next if $profile eq 'Locked';

            $overall{$profile} ||= {};
            $overall{$profile}->{$commit->{state}} ||= 0;
            $overall{$profile}->{$commit->{state}}++;

            # Commits In Scope Check
            next if $commit->{date} lt $opt->{since};
            last if $commit->{date} gt $opt->{until};

            # Commit State Tracking
            $commits{$profile} ||= {};
            $commits{$profile}->{$commit->{state}} ||= 0;
            $commits{$profile}->{$commit->{state}}++;
        }
    }
    debug({color=>'magenta'}, "Commit Status");
    debug_var(\%commits);

    debug({color=>'green'}, "Overall Status");
    debug_var(\%overall);

    # Grab Activity on the Repositories
    my $logs = $audit->log('--since', $opt->{since}, '--until', $opt->{until});
    my %activity = ();
    my %concerns = ();
    while(my $log = $logs->next) {
        #debug({indent=>1,color=>'cyan'}, sprintf "+ Evaluating activity log: %s", $log->commit);
        # Details
        my $data = gcr_audit_record($log->message);

        # Skip some states
        next if exists $data->{skip};

        # Get the SHA1
        my $sha1 = gcr_audit_commit($log->commit);

        # Profile Specific Details
        $data->{profile} ||= defined $sha1 ? gcr_commit_profile($sha1) : undef;
        next unless defined $data->{profile};
        next if !$opt->{all} && $data->{profile} ne $profile;

        my $increment = 1;
        if($data->{state} eq 'select') {
            my @files = gcr_audit_files($log->commit);
            $increment = @files;
        }

        if( exists $data->{profile} ) {
            if( exists $data->{state} ) {
                $activity{$data->{profile}} ||= {};
                $activity{$data->{profile}}->{$data->{state}} ||= 0;
                $activity{$data->{profile}}->{$data->{state}} += $increment;
            }
        }

        # Overview
        if(exists $data->{state}) {
            $activity{_all_} ||= {};
            $activity{_all_}->{$data->{state}} ||= 0;
            $activity{_all_}->{$data->{state}} += $increment;

            # Catch concerns
            if( $data->{state} eq 'concerns' ) {
                if(!exists $concerns{$sha1}) {
                    my $commit = gcr_commit_info($sha1);
                    $concerns{$sha1} = {
                        concern => {
                            date => strftime('%F',localtime($log->author_localtime)),
                            explanation => $data->{message},
                            reason => $data->{reason},
                            by => $data->{reviewer},
                        },
                        commit => {
                            state => $commit->{state},
                            date  => $commit->{date},
                            by => $data->{author},
                        },
                    };
                    foreach my $s (qw(comment approved)) {
                        my @results = $audit->log(qw(-F --grep), $s, '--', '**' . $sha1 . '.patch');
                        foreach my $r (@results) {
                            $concerns{$sha1}->{log} ||= [];
                            my $d = gcr_audit_record($r->message);
                            push @{$concerns{$sha1}->{log}}, {
                                state  => $s,
                                reason => $d->{reason},
                                date   => strftime('%F',localtime($r->author_localtime)),
                                by     => $d->{reviewer},
                                explanation => $d->{message},
                            }
                        }
                    }
                }
            }
        }
    }
    debug({color=>'magenta'}, "Activity Overview");
    debug_var(\%activity);

    debug({color=>'red'}, "Concerns raised:");
    debug_var(\%concerns);

    output({color=>'cyan'},
        '=*'x40,
        sprintf('Git::Code::Review Report for %s through %s', $opt->{since}, $opt->{until}),
        '=*'x40,
        '',
    );

    Git::Code::Review::Notify::notify(report => {
        options => $opt,
        commits  => \%commits,
        overall  => \%overall,
        activity => \%activity,
        concerns => \%concerns,
        profile  => $opt->{all} ? 'all' : $profile,
    });
}

1;
