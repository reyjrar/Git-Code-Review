# ABSTRACT: Report overdue commits
package Git::Code::Review::Command::overdue;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Basename;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review::Notify;
use Git::Code::Review -command;
use POSIX qw(strftime);
use Text::Wrap qw(fill);
use Time::Local;

my $default_age = 2;
sub opt_spec {
    return (
           ['age|days:i', "Age of commits in days to consider overdue default: $default_age", { default => $default_age } ],
           ['all',        "Run report for all profiles." ],
           ['notify',     "In addition to printing the list, invoke the Notify chain."],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Give a break down of the commits that are older than a certain age and unactioned.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    gcr_reset();

    my $profile = gcr_profile();
    my $audit   = gcr_repo();

    my @ls = ( 'ls-files' );
    push @ls, $opt->{all} ? '**.patch' : sprintf('%s/**.patch', $profile);

    # Look for commits that aren't approved and older than X days
    my @overdue = sort { $a->{select_date} cmp $b->{select_date} }
                    grep { days_old($_->{select_date}) >= $opt->{age} }
                    map { $_=gcr_commit_info(basename $_) }
                    grep !/Approved/, $audit->run(@ls);

    if(@overdue) {
        # Calculate how many are overdue by profile
        my %profiles =  map { $_ => { total => 0 } } $opt->{all} ? gcr_profiles() : $profile;
        my %current_concerns = ();
        foreach my $commit (@overdue) {
            my $p = exists $commit->{profile} && $commit->{profile} ? $commit->{profile} : '__UNKNOWN__';
            $profiles{$p} ||= {total => 0};
            $profiles{$p}->{total}++;
            my $month = join('-', (split '-', $commit->{select_date})[0,1]);
            $profiles{$p}->{$month} ||= 0;
            $profiles{$p}->{$month}++;
            $current_concerns{$commit->{sha1}} = 1 if $commit->{state} eq 'concerns';
        }

        # Generate the log entries
        my   @log_options = qw(--reverse -F --grep concerns);
        push @log_options, '--', $profile unless $opt->{all};

        my $logs = $audit->log(@log_options);
        my %concerns = ();
        while(my $log = $logs->next) {
            # Details
            my $data = gcr_audit_record($log->message);
            my $date = strftime('%F',localtime($log->author_localtime));

            # Skip some states
            next if exists $data->{skip};
            next unless exists $data->{state};

            # Get the SHA1
            my $sha1 = gcr_audit_commit($log->commit);

            # Only handle commits still in "concerns"
            next unless defined $sha1 and exists $current_concerns{$sha1};

            # Profile Specific Details
            my $commit;
            if( defined $sha1 ) {
                $data->{profile} ||= gcr_commit_profile($sha1);
                eval { $commit = gcr_commit_info($sha1) };
            }
            # If there's no commit in play, skip this.
            next unless defined $commit;

            # Parse History for Commits with Concerns
            $concerns{$commit->{profile}}{$sha1} = {
                concern => {
                    date        => $date,
                    explanation => fill("", "", $data->{message}),
                    reason      => $data->{reason},
                    by          => $data->{reviewer},
                },
                commit => {
                    profile => $data->{profile},
                    state   => $commit->{state},
                    date    => $commit->{date},
                    by      => $data->{author},
                },
            };
        }
        # Disable some notifications
        foreach my $remote (qw(JIRA EMAIL)) {
            $ENV{"GCR_NOTIFY_${remote}_DISABLED"} = 1 unless $opt->{notify};
        }

        output({color=>'cyan',clear=>1},
            '=*'x40,
            sprintf("Overdue commits (older than %d days)", $opt->{age}),
            '=*'x40,
        );
        Git::Code::Review::Notify::notify(overdue => {
            options  => $opt,
            profiles => \%profiles,
            commits  => \@overdue,
            concerns => \%concerns,
        });
    }
    else {
        my $p = $opt->{all} ? 'ALL' : $profile;
        output({color=>'green'}, sprintf "All commits %d days old and older have been reviewed in profile: %s",
            $opt->{age},
            $p
        );
    }

}

my $NOW = timelocal(0,0,0,(localtime)[3,4,5]);
my %_Ages = ();
sub days_old {
    my ($date) = @_;

    return $_Ages{$date} if exists $_Ages{$date};

    # Get Y, M, D parts.
    my @parts = reverse split '-', $date;
    # Decrement Month
    $parts[1]--;

    my $epoch = timelocal(0,0,0,@parts);
    my $diff  = $NOW - $epoch;
    my $days_old = int($diff / 86400);

    return $_Ages{$date} = $days_old;
}

1;
