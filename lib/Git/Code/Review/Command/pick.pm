# ABSTRACT: Allows reviewers to select a commit for auditing. Also available as pick.
package Git::Code::Review::Command::pick;
use strict;
use warnings;

use CLI::Helpers qw(
    debug
    output
    prompt
    verbose
);
use Git::Code::Review -command;
use Git::Code::Review::Notify qw(notify_enabled);
use Git::Code::Review::Utilities qw(:all);

# Globals
my %LABELS = (
    approve  => "[Approve] this commit.",
    concerns => "Raise a [concern] with this commit.",
    resign   => "[Resign] from this commit.",
    move     => "[Move] this commit to another profile.",
    skip     => "Skip (just exits unlocking the commit.)",
    _view    => "View this commit again.",
    _file    => "View a file mentioned in the commit.",
    _view_readme  => "View the README with the purpose and guidelines for this review.",
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
    debug("PICK|$action - Missing Action, but have label.") unless index($action,'_') == 0;
    push @_incomplete, $action;
}
delete $ACTIONS{$_} for @_incomplete;
# Resignations
my $resigned_file;
my %_resigned;


sub command_names {
    return qw(review pick);
}

sub opt_spec {
    return (
        ['order:s',    "How to order the commits picked: random, asc, or desc  (Default: random)", {default=>'random'}],
        ['since|s:s',  "Commit start date, none if not specified", {default => "0000-00-00"}],
        ['until|u:s',  "Commit end date, none if not specified",   {default => "9999-99-99"}],
        ['unlock',     "Unlock (skip) all or matching commits locked by you"],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review review [options] [<commit hash>]

    DESCRIPTION

        Reviewers performing the audit use the 'review' command to lock a commit for review.
        This command uses Term::ReadLine to prompt the end-user for answers on how to handle
        the commit.

        You can optionally pass a commit hash in the 'review' state that you
        haven't authored to review a specific commit. If you have locked a commit, you need to
        review it first and either skip to unlock it or take one of the usual actions.

        Using the --unlock option allows you to quickly unlock all your locked commits. If you
        specify a commit hash, all matching locked commits which are locked by you will be unlocked.

        Aliased as: review, pick

    EXAMPLES

        git-code-review review

        git-code-review review 44d3b68e

        git-code-review review --order asc

        git-code-review review --order asc --since 2016-08-01

        git-code-review review --order random --since 2016-08-01 --until 2016-08-07

        git-code-review review --unlock

        git-code-review review --unlock 44d3b68e

    OPTIONS

            --profile profile   Select commits for specified profile.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    my $match = shift @$args;
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;
    if ( defined $match && $match !~ /^[a-f0-9]{5,40}$/ ) {
        output({color=>'red'}, "Please specify a commit hash from the source repository to review. $match does not seem like a commit hash.");
        exit 1;
    }

    notify_enabled();

    # Grab the audit repo handle, reset
    my %cfg = gcr_config();
    my $profile = gcr_profile();
    my $audit = gcr_repo();
    gcr_reset();

    # Get a listing of available commits;
    my @locked = $audit->run('ls-files', File::Spec->catdir('Locked',$cfg{user}));
    my $commit;
    if( @locked ) {
        if ( $opt->{ unlock } ) {
            # Give the user a super easy way to unlock all locked commits
            my @commits = map { scalar gcr_commit_info( $_ ) } @locked;
            if ( $match ) {
                # find matching commits to unlock
                @commits = grep { $_->{ sha1 } =~ m/^$match/i } @commits;
                if ( ! scalar @commits ) {
                    # No matching locked
                    output({color=>'red'}, "No commits locked by you matching $match were found.");
                    exit 1;
                }
            }
            # unlock all my locked commits
            skip( $_ ) for @commits;
            output( {color=>'green'}, sprintf "Unlocked %d commit(s).", scalar @commits );
            exit 0;
        }
        # we were not asked to unlock, so pick the locked one for review
        output({color=>'red'}, "You are currently locking commits, ignoring picklist. You can unlock the commit by choosing skip. Will continue in 1 second.");
        sleep 1;
        $commit = gcr_commit_info($locked[0]);
        if( @locked > 1 ) {
            $commit = gcr_commit_info(
                prompt("!! You are currently locking the following commits, select one to action: ", menu => \@locked)
            );
        }
    }
    elsif( $opt->{ unlock } ) {
        output( {color=>'green'}, "No commits locked by you were found." );
        exit 0;
    }
    elsif( $match ) {
        ($commit)  = map { $_=gcr_commit_info($_) } $audit->run('ls-files', "*$match*.patch");
        die "no valid commits found matching $match" unless defined $commit;
        die "Commit is in concerns state, use the approve command to approve" if $commit->{state} eq 'concerns';
        die "Commit not in review state, it is in '$commit->{state}'" unless $commit->{state} eq 'review';
        if( $commit->{author} eq $cfg{user} ) {
            output({stderr=>1,color=>'red'}, "Nice try! You can't review your own commits.");
            exit 1;
        }
    }
    else {
        # Generate an ordered picklist w/o my commits and w/o my resignations
        my @picklist = sort { $a->{date} cmp $b->{date} }
                       grep { $_->{date} ge $opt->{since} && $_->{date} le $opt->{until} }
                       grep { $_->{ profile } eq $profile }
                       map  { $_=gcr_commit_info($_) }
                       grep { /^$profile/ && gcr_not_resigned($_) && gcr_not_authored($_) }
                    $audit->run('ls-files', '*Review*');

        if(!@picklist) {
            output({color=>'green'},"All reviews completed on profile: $profile!");
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
    gcr_change_state($commit,'locked', { skip => 'true', message => 'Locked.' });

    # Only show "move" unless we have > 1 profile
    my @profiles = gcr_profiles();
    delete $LABELS{move} unless @profiles > 1;

    # Show the Commit
    my $action;
    do {
        do{
            # Choose next action.
            $action = $action ? prompt("Action?", menu => \%LABELS) : '_view';
            # View Files
            if($action eq '_view') {
                gcr_view_commit($commit);
            }
            elsif($action eq '_file') {
                gcr_view_commit_files($commit);
            }
            elsif($action eq '_view_readme') {
                gcr_view_readme();
            }
        } until $action !~ /^_/;

        output({color=>'cyan'}, "We are going to $action $commit->{base}");
    } until $ACTIONS{$action}->($commit);;
}

sub resign {
    my ($commit) = @_;

    my $cancel = 'Cancel  move and go back to previous menu.';
    my $reason = prompt("Why are you resigning for this commit? ", menu => [
        q{No experience with systems covered.},
        q{I am the author.},
        q{other},
        $cancel,
    ]);
    return 0 if $reason eq $cancel;
    if( $reason eq 'other' ) {
        $reason = prompt("Explain: ", validate => { "Please type at least 5 characters." => sub { length $_ > 5; } });
    }
    # Make sure git status is clean
    my $auditdir = gcr_dir();
    my %cfg = gcr_config();
    my $audit = gcr_repo();
    gcr_reset();
    # Create resignation directory
    gcr_mkdir('Resigned');
    $resigned_file ||= File::Spec->catfile($auditdir,'Resigned',$cfg{user});
    open(my $fh, '>>', $resigned_file) or die "unable to open $resigned_file for appending: $!";
    print $fh "$commit->{base}\n";
    close $fh;

    $_resigned{$commit->{base}} = 1;

    debug($audit->run('add',File::Spec->catfile('Resigned',$cfg{user})));
    gcr_change_state($commit,'review','Unlocked due to resignation.');
    return 1;
}

sub skip {
    my ($commit) = @_;
    verbose("+ Skipping $commit->{base}");
    gcr_change_state($commit,'review','Unlocked due to skip.');
    return 1;
}

sub approve {
    my ($commit) = @_;

    my %reasons = (
        cosmetic    => "Cosmetic change only, no functional difference.",
        correct     => "Calculations are all accurate.",
        outofbounds => "Changes are not in the bounds for the audit.",
        other       => 'Other (requires explanation)',
        _back       => 'Cancel action and go back to previous menu.'
    );
    my %cfg = gcr_config();
    override_defaults( \%reasons, $cfg{ review }, 'labels.approve.' );
    my $reason = prompt("Why are you approving this commit?", menu => \%reasons);
    my $details = $reasons{$reason};
    return 0 if $reason eq '_back';
    if ($reason eq 'other') {
        $details = prompt("Explain: ", validate => { "Really, not even 10 characters? " => sub { length $_ > 10; } });
    }
    verbose("+ Approving $commit->{sha1} for $reason");
    gcr_change_state($commit, approved => { reason => $reason, message => $details } );
    return 1;
}

sub concerns {
    my ($commit) = @_;

    my %reasons = (
        incorrect => "Calculations are incorrect.",
        unclear   => "Code is not clear, requires more information from the author.",
        other     => 'Other',
        _back     => 'Cancel action and go back to previous menu.'
    );

    my %cfg = gcr_config();
    override_defaults( \%reasons, $cfg{ review }, 'labels.concerns.' );
    my $reason = prompt("Why are you raising a concern with this commit?",menu => \%reasons);
    return 0 if $reason eq '_back';
    my $details = prompt("Explain: ", validate => { "Really, not even 10 characters? " => sub { length $_ > 10; } });
    verbose("+ Raising concern with $commit->{base} for $reason");
    gcr_change_state($commit, concerns => { reason => "$reason", message => join "\n",$reasons{$reason},$details });

    # Do notify by email
    Git::Code::Review::Notify::notify(concerns => {
        priority => 'high',
        commit => $commit,
        reason => {
            short   => $reason,
            details => $details,
        },
    });
    return 1;
}

sub move {
    my ($commit) = @_;
    verbose("+ Moving $commit->{base}");

    my $profiles = gcr_profiles();
    my $cancel = 'Cancel move and go back to previous menu.';
    push @$profiles, $cancel;
    my $to = prompt("Which profile are you moving this commit to?", menu => $profiles);
    return 0 if $to eq $cancel;
    my $details = prompt("Why are you moving this to $to: ", validate => { "Really, not even 10 characters? " => sub { length $_ > 10; } });

    gcr_change_profile($commit,$to,$details);
    return 1;
}


sub override_defaults {
    my ($defaults, $config, $prefix) = @_;
    return unless $config;
    $prefix ||= '';
    for my $key ( keys %$defaults ) {
        $defaults->{ $key } = $config->{ $prefix . $key } if exists $config->{ $prefix . $key };
    }
}


1;
