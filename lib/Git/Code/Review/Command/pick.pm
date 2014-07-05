# ABSTRACT: Allows reviewers to select a commit for auditing
package Git::Code::Review::Command::pick;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use Git::Code::Review::Notify;

# Globals
my $AUDITDIR = gcr_dir();
my %CFG = gcr_config();
my $PROFILE = gcr_profile();
my %LABELS = (
    approve  => "Approve this commit.",
    concerns => "Raise a concern with this commit.",
    resign   => "Resign from this commit.",
    skip     => "Skip (just exits unlocking the commit.)"
);
my %ACTIONS = (
    approve  => \&approve,
    concerns => \&concerns,
    resign   => \&resign,
    skip     => \&skip,
);
my @_incomplete;
foreach my $action (keys %LABELS) {
    next if exists $ACTIONS{$action};
    debug("PICK|$action - Missing Action, but have label.");
    push @_incomplete, $action;
}
delete $ACTIONS{$_} for @_incomplete;
# Resignations
my $resigned_file;
my %_resigned;

sub opt_spec {
    return (
        ['since|s:s',  "Commit start date, none if not specified", {default => "0000-00-00"}],
        ['until|u:s',  "Commit end date, none if not specified",   {default => "9999-99-99"}],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Reviewers performing the audit use the 'pick' command to lock a commit for review.
    The command use Term::ReadLine to prompt the end-user for answers to how to handle
    the commit.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();

    # Grab the audit repo handle, reset
    my $audit = gcr_repo();
    gcr_reset();

    # Get a listing of available commits;
    my @locked = $audit->run('ls-files', File::Spec->catdir('Locked',$CFG{user}));
    my $commit;
    if( @locked ) {
        output({color=>'red'}, "You are currently locking commits, ignoring picklist. Will continue in 1 second.");
        sleep 1;
        $commit = gcr_commit_info($locked[0]);
        if( @locked > 1 ) {
            $commit = gcr_commit_info(
                prompt("!! You are currently locking the following commits, select one to action: ", menu => \@locked)
            );
        }
    }
    else {
        my @picklist = grep { $_->{date} ge $opt->{since} && $_->{date} le $opt->{until} }
                       map { $_=gcr_commit_info($_) }
                       grep { /^$PROFILE/ && gcr_not_resigned($_) && gcr_not_authored($_) }
                    $audit->run('ls-files', '*Review*');

        if(!@picklist) {
            output({color=>'green'},"All reviews completed on profile: $PROFILE!");
            exit 0;
        }
        else {
            output({color=>"cyan"}, sprintf("+ Picklist currently contains %d commits.",scalar(@picklist)));
        }
        $commit = splice @picklist, int(rand(@picklist)), 1;
    }
    # Move to the locked state
    gcr_change_state($commit,'locked', 'Locked.');

    # Show the Commit
    gcr_view_commit($commit);
    my $action = prompt("Action?", menu => \%LABELS);

    output({color=>'cyan'}, "We are going to $action $commit->{base}");
    $ACTIONS{$action}->($commit);
}

sub resign {
    my ($commit) = @_;

    my $reason = prompt("Why are you resigning for this commit? ", menu => [
        q{No experience with systems covered.},
        q{I am the author.},
        q{other},
    ]);
    if( $reason eq 'other' ) {
        $reason = prompt("Explain: ", validate => { "Please type at least 5 characters." => sub { length $_ > 5; } });
    }
    # Make sure git status is clean
    my $audit = gcr_repo();
    gcr_reset();
    # Create resignation directory
    gcr_mkdir('Resigned');
    $resigned_file ||= File::Spec->catfile($AUDITDIR,'Resigned',$CFG{user});
    open(my $fh, '>>', $resigned_file) or die "unable to open $resigned_file for appending: $!";
    print $fh "$commit->{base}\n";
    close $fh;

    $_resigned{$commit->{base}} = 1;

    debug($audit->run('add',File::Spec->catfile('Resigned',$CFG{user})));
    gcr_change_state($commit,'review','Unlocked due to resignation.');
}

sub skip {
    my ($commit) = @_;
    verbose("+ Skipping $commit->{base}");
    gcr_change_state($commit,'review','Unlocked due to skip.');
}

sub approve {
    my ($commit) = @_;

    my %reasons = (
        cosmetic    => "Cosmetic change only, no functional difference.",
        correct     => "Calculations are all accurate.",
        outofbounds => "Changes are not in the bounds for the audit.",
        other       => 'Other (requires explanation)',
    );
    my $reason = prompt("Why are you approving this commit?", menu => \%reasons);
    my $details = $reasons{$reason};
    if ($reason eq 'other') {
        $details = prompt("Explain: ", validate => { "Really, not even 10 characters? " => sub { length $_ > 10; } });
    }
    verbose("+ Approving $commit->{sha1} for $reason");
    gcr_change_state($commit, approved => { reason => $reason, message => $details } );
}

sub concerns {
    my ($commit) = @_;

    my %reasons = (
        incorrect => "Calculations are incorect.",
        unclear   => "Code is not clear, requires more information from the author.",
        other     => 'Other',
    );

    my $reason = prompt("Why are you raising a concern with this commit?",menu => \%reasons);
    my $details = prompt("Explain: ", validate => { "Really, not even 10 characters? " => sub { length $_ > 10; } });
    verbose("+ Raising concern with $commit->{base} for $reason");
    gcr_change_state($commit, concerns => { reason => "$reason", message => join "\n",$reasons{$reason},$details });

    # Do notify by email
    Git::Code::Review::Notify::notify(concerns => {
        commit => $commit,
        reason => {
            short   => $reason,
            details => $details,
        },
    });
}

1;
