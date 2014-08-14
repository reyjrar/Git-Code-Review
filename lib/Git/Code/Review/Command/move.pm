# ABSTRACT: Move a commit from one profile to another
package Git::Code::Review::Command::move;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use YAML;

sub opt_spec {
    return (
        ['reason|r=s', "Reason for the selection, ie '2014-01 Review'",  ],
        ['to=s',       "Profile to move the commit to. (REQUIRED)" ],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Move a commit to another profile.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub command_names {
    return qw(move mv);
}

sub execute {
    my($cmd,$opt,$args) = @_;

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();

    # We need a reason for this commit
    my $message =  exists $opt->{reason} && length $opt->{reason} > 10 ? $opt->{reason}
                : prompt(sprintf("Please provide the reason for the move%s:", exists $opt->{reason} ? '(10+ chars)' : ''),
                    validate => { "10+ characters, please" => sub { length $_ > 10 } });


    # Validate Commit
    my $commit = gcr_commit_info($args->[0]);
    gcr_change_profile($commit,$opt->{to},$message);
}

1;
