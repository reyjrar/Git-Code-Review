# ABSTRACT: Mark a commit previously concerned as approved. Also available as fixed.
package Git::Code::Review::Command::fixed;
use strict;
use warnings;

use CLI::Helpers qw(
    debug
    output
    prompt
);
use Git::Code::Review -command;
use Git::Code::Review::Utilities qw(:all);
use POSIX qw(strftime);
use YAML;


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
    SYNOPSIS

        git-code-review approve [options] <commit hash>

    DESCRIPTION

        This command allows reviewers to mark a commit previously flagged as a concern to the approved status. All necessary information will be prompted from the user.

        Aliased as: approve, fixed

    EXAMPLES

        git-code-review approve 44d3b68e

    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my ($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    my $match = shift @$args;
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;
    if ( !defined $match ) {
        output({color=>'red'}, "Please specify a commit hash from the source repository in concerns state to approve.");
        exit 1;
    } elsif ( $match !~ /^[a-z0-9]{5,40}$/ ) {
        output({color=>'red'}, "Please specify a commit hash from the source repository in concerns state to approve. $match does not seem like a commit hash.");
        exit 1;
    }

    my $audit = gcr_repo();
    gcr_reset();

    my @list = grep { /$match/ } $audit->run('ls-files',"*Concerns*");
    if( @list == 0 ) {
        output({color=>"red"}, "Unable to locate any commits in concerns state matching '$match'.");
        my @commmits = $audit->run('ls-files', "*$match*.patch");
        die "No valid commits were found matching $match either." unless scalar @commmits;
        if ( scalar @commmits == 1 ) {
            my $commit = gcr_commit_info( $commmits[ 0 ] );
            if ( $commit->{state} eq 'approved' ) {
                output( "Commit is already approved." );
            } else {
                output( sprintf "The commit is in %s state.", $commit->{state} );
            }
        }
        output( "If the commit is not be in concerns state, you can use the review command to review and approve it" );
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
