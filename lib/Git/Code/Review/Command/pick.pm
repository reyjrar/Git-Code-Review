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
    approve  => "[Approve] this commit.",
    concerns => "Raise a [concern] with this commit.",
    resign   => "[Resign] from this commit.",
    move     => "[Move] this commit to another profile.",
    skip     => "Skip (just exits unlocking the commit.)",
    _view    => "(View) Commit again.",
    _file    => "(View) A file mentioned in the commit.",
);
my %ACTIONS = (
    approve  => \&approve,
    concerns => \&concerns,
    resign   => \&resign,
    move     => \&move,
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
        ['order:s',    "How to order the commits picked: random, asc, or desc  (Default: random)", {default=>'random'}],
        ['since|s:s',  "Commit start date, none if not specified", {default => "0000-00-00"}],
        ['until|u:s',  "Commit end date, none if not specified",   {default => "9999-99-99"}],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Reviewers performing the audit use the 'pick' command to lock a commit for review.
    The command use Term::ReadLine to prompt the end-user for answers to how to handle
    the commit.

    You can optionally pass a SHA1 of a commit in the 'review' state that you
    haven't authored to review a specific commit, e.g.

        git code-review pick <SHA1>
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
    elsif(ref $args eq 'ARRAY' && @$args) {
        ($commit)  = map { $_=gcr_commit_info($_) } $audit->run('ls-files', "*$args->[0]*.patch");
        die "no valid commits found matching $args->[0]" unless defined $commit;
        die "Commit not in review state, it is in '$commit->{state}'" unless $commit->{state} eq 'review';
        if( $commit->{author} eq $CFG{user} ) {
            output({stderr=>1,color=>'red'}, "Nice try! You can't review your own commits.");
            exit 1;
        }
    }
    else {
        # Generate an ordered picklist w/o my commits and w/o my resignations
        my @picklist = sort { $a->{date} cmp $b->{date} }
                       grep { $_->{date} ge $opt->{since} && $_->{date} le $opt->{until} }
                       map  { $_=gcr_commit_info($_) }
                       grep { /^$PROFILE/ && gcr_not_resigned($_) && gcr_not_authored($_) }
                    $audit->run('ls-files', '*Review*');

        if(!@picklist) {
            output({color=>'green'},"All reviews completed on profile: $PROFILE!");
            exit 0;
        }
        else {
            output({color=>"cyan"}, sprintf("+ Picklist currently contains %d commits.",scalar(@picklist)));
        }
        my %idx = (
            asc    => 0,
            desc   => -1,
            random => int(rand(@picklist)),
        );
        $commit = exists $idx{lc $opt->{order}} ? $picklist[$idx{lc $opt->{order}}] : $picklist[$idx{random}];

    }
    # Move to the locked state
    gcr_change_state($commit,'locked', 'Locked.');

    # Only show "move" unless we have > 1 profile
    my %profiles = gcr_profiles();
    my $profiles = scalar(keys %profiles);
    delete $LABELS{move} unless $profiles > 1;

    # Show the Commit
    my $action ='_view';
    do{
        # View Files
        if($action eq '_view') {
            gcr_view_commit($commit);
        }
        elsif($action eq '_file') {
            gcr_view_commit_files($commit);
        }
        # Choose next action.
        $action = prompt("Action?", menu => \%LABELS);
    } until $action !~ /^_/;

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

sub move {
    my ($commit) = @_;
    verbose("+ Moving $commit->{base}");

    my %profiles = gcr_profiles();
    my $to = prompt("Which profile are you moving this commit to?", menu => [sort keys %profiles]);
    my $details = prompt("Why are you moving this to $to: ", validate => { "Really, not even 10 characters? " => sub { length $_ > 10; } });

    gcr_change_profile($commit,$to,$details);
}

1;
