# ABSTRACT: Mark a commit previously concerned with approved
package Git::Code::Review::Command::fixed;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use POSIX qw(strftime);
use YAML;

# Globals for easy access
my $AUDITDIR = gcr_dir();
my %CFG = gcr_config();

sub command_names {
    return qw(approve fixed);
}
sub opt_spec {
    return (
        #    ['noop',       "Take no recorded actions."],
    );
}

sub description {
    my $DESC = <<"    EOH";

    This command allows reviewers to mark a commit previously flagged as a concern
    to the approved status.

    Aliased as: approve, fixed

    All necessary information will be prompted from the user.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my ($cmd,$opt,$args) = @_;
    my ($match) = @$args;

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();

    my $audit = gcr_repo();
    gcr_reset();

    if( !defined $match ) {
        output({color=>'red'}, "Please specify a sha1 or .patch file.");
        exit 1;
    }
    my @list = grep { /$match/ } $audit->run('ls-files',"*Concerns*");
    if( @list == 0 ) {
        output({color=>"red"}, "Unable to locate any flagged commits in matching '$match'");
        exit 0;
    }
    my $pick = $list[0];
    if( @list > 1 ) {
        $pick = prompt("Matched multiple commits, which would you like to approve? ", menu => \@list);
    }
    my $commit = gcr_commit_info($pick);
    debug("You searched for '$match' and got '$commit->{sha1}'");

    my %reasons = (
        'fixed'   => q{Fixed in a later commit.},
        'correct' => q{Author clarified and the commit is correct.},
        'other'   => q{Other, requires explanation.},
    );
    my %info = (
        fixed => {
            prompt => "Which commit fixed this? ",
            validate => {
                "Must be a valid SHA1 hash" => sub { /^[a-z0-9]{40}$/ ? 1 : 0 },
                "Cannot be solved by the same commit" => sub { $_ ne $commit->{sha1}; },
            },
            to => 'fixed_by',
        },
        correct => {
            prompt => "What was the clarification?",
            validate => { "Not even 10 characters?" => sub { length $_ > 10 } },
        },
        other => {
            prompt => "Explain:",
            validate => { "Not even 10 characters?" => sub { length $_ > 10 } },
        },
    );
    my $reason = prompt("Why are you setting this commit as fixed?", menu => \%reasons);
    my $details = prompt($info{$reason}->{prompt}, validate => $info{$reason}->{validate});
    my %details = (
        reason  => $reason,
        message => exists $info{$reason}->{to} ? $reasons{$reason} : $details,
    );
    $details{$info{$reason}->{to}} = $details if exists $info{$reason}->{to};

    gcr_change_state($commit, approved => \%details);
}

1;
