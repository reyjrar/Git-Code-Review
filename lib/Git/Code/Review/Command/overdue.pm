# ABSTRACT: Report overdue commits
package Git::Code::Review::Command::overdue;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Basename;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review::Notify;
use Git::Code::Review -command;
use Time::Local;

my $default_age = 7;
sub opt_spec {
    return (
           ['age:i',    "Age of commits in days to consider overdue default: $default_age", { default => $default_age } ],
           ['all',      "Run report for all profiles." ],
           ['notify',   "In addition to printing the list, invoke the Notify chain."],
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

    my @overdue = sort { $a->{date} cmp $b->{date} }
                    grep { days_old($_->{date}) >= $opt->{age} }
                    map { $_=gcr_commit_info(basename $_) }
                    grep /Review/, $audit->run(@ls);

    if(@overdue) {
        # Do stuff
        my %profiles =  map { $_ => { total => 0 } } $opt->{all} ? gcr_profiles() : $profile;
        foreach my $commit (@overdue) {
            my $p = exists $commit->{profile} && $commit->{profile} ? $commit->{profile} : '__UNKNOWN__';
            $profiles{$p} ||= {total => 0};
            $profiles{$p}->{total}++;
            my $month = join('-', (split /[.\-]/, $commit->{date})[0,1]);
            $profiles{$p}->{$month} ||= 0;
            $profiles{$p}->{$month}++;
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
my %_Ages;
sub days_old {
    my ($date) = @_;

    return $_Ages{$date} if exists $_Ages{$date};

    my @parts = reverse split /[\-.]/, $date;
    # Don't handle weird shit
    return unless @parts == 3;

    # Month needs to be 0 based, not 1 based.
    $parts[1]--;
    my $epoch = timelocal(0,0,0,@parts);
    my $diff  = $NOW - $epoch;

    return $_Ages{$date} = int($diff / 86400);
}

1;
