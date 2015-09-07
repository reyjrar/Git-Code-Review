# ABSTRACT: Report overdue commits
package Git::Code::Review::Command::overdue;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Basename;
use Config::GitLike;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review::Notify qw(notify);
use Git::Code::Review -command;
use POSIX qw(strftime);
use Text::Wrap qw(fill);
use Time::Local;

my $default_age = 2;
sub opt_spec {
    return (
           ['age|days:i', "Age of commits in days to consider overdue default: $default_age", { default => $default_age } ],
           ['critical',   "Set high priority and enable acrimonious excess in verbage." ],
           ['all',        "Run report for all profiles." ],
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
        my %contacts = ();
        foreach my $commit (@overdue) {
            my $p = exists $commit->{profile} && $commit->{profile} ? $commit->{profile} : '__UNKNOWN__';
            $profiles{$p} ||= {total => 0};
            $profiles{$p}->{total}++;

            $profiles{$p}->{$commit->{select_date}} ||= [];
            push @{ $profiles{$p}->{$commit->{select_date}} }, $commit;
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

        # Grab contact information
        foreach my $p (keys %profiles) {
            my @configs = (
                File::Spec->catfile(gcr_dir(),'.code-review','profiles',$p,'notification.config'),
                File::Spec->catfile(gcr_dir(),'.code-review','notification.config')
            );
            my %c = ();
            foreach my $config_file(@configs) {
                next unless -f $config_file;
                my $config;
                my $rc = eval {
                    $config = Config::GitLike->load_file($config_file);
                    1;
                };
                next unless $rc == 1;
                # Remove the ignored profiles
                die "ignore.overdue setting is invalid. Use true/false, 1/0 or yes/no only." if exists $config->{ 'ignore.overdue' } && $config->{ 'ignore.overdue' } !~ m/^\s*(?:1|0|true|false|yes|no)\s*$/i;
                if ( ( $config->{ 'ignore.overdue' } || '' ) =~ m/^\s*(?:1|true|yes)\s*$/i ) {
                    # ignore it if configured to ignore unless it was specifically requested
                    if ( $opt->{all} || $p ne $profile ) {
                        output({color=>'yellow'}, "Ignoring profile $p");
                        delete $profiles{ $p };
                        next;
                    } else {
                        output({color=>'yellow'}, "Ignored profile $p was explicitly requested, so ignoring the ignore setting");
                    }
                }
                next unless exists $config->{'template.select.to'};
                $c{$_} = 1 for (ref $config->{'template.select.to'} eq 'ARRAY' ? @{ $config->{'template.select.to'} }
                                                                               : $config->{'template.select.to'}
                );
            }
            $contacts{$p} = scalar(keys %c) ? [ sort keys %c ] : [qw(NONE)];
        }
        my $total = 0;
        $total += $profiles{$_}->{total} for keys %profiles;
        if ( $total ) {
            output({color=>'cyan',clear=>1},
                '=*'x40,
                sprintf("Overdue commits (older than %d days)", $opt->{age}),
                '=*'x40,
            );
            notify(overdue => {
                priority => exists $opt->{critical} ? 'high' : 'normal',
                options  => $opt,
                profiles => \%profiles,
                concerns => \%concerns,
                contacts => \%contacts,
            });
        } else {
            my $p = $opt->{all} ? 'ALL' : $profile;
            output({color=>'green'}, sprintf "All commits %d days old and older have been reviewed in (not ignored) profile: %s",
                $opt->{age},
                $p
            );
        }
    } else {
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
