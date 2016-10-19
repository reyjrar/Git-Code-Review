# ABSTRACT: Manage profiles for the code selection
package Git::Code::Review::Command::profile;
use strict;
use warnings;

use CLI::Helpers qw(
    debug
    output
    prompt
);
use Git::Code::Review -command;
use Git::Code::Review::Helpers qw(
    prompt_message
);
use Git::Code::Review::Utilities qw(:all);
use YAML;


sub opt_spec {
    return (
        ['list',       "List profiles, default"],
        ['add:s',      "Create a new profile"],
        ['edit:s',     "Edit a profile"],
        ['message|m|reason|r=s@',    "Reason for mucking with this profile. If multiple -m options are given, their values are concatenated as separate paragraphs."],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review profile [options]

    DESCRIPTION

        This command allows managing of the profiles for commit selection and notifications.

    EXAMPLES

        git code-review profile

        git code-review profile --list

        git code-review profile --add team_a -m "Team A's Responsibilities"

        git code-review profile --edit team_a

    OPTIONS
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my ($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;
    die "Please give --add or --edit, not both together" if exists $opt->{ edit } && exists $opt->{ add };
    die "--add requires a profile name that is not empty" if exists $opt->{ add } && ( $opt->{ add } || '' ) !~ /\S/;
    die "--edit requires a profile name that is not empty" if exists $opt->{ edit } && ( $opt->{ edit } || '' ) !~ /\S/;
    $opt->{ list } = 1 unless exists $opt->{ edit } || exists $opt->{ add };    # if none given, turn list on

    my %cfg = gcr_config();
    my $audit = gcr_repo();
    gcr_reset();

    my %profiles;
    @profiles{gcr_profiles()} = ();

    # Run the list option
    if( exists $opt->{list} ) {
        foreach my $profile (sort keys %profiles) {
            debug("Checking profile '$profile'");
            my $total = 0;
            my %states = ();
            foreach my $file ($audit->run('ls-files', "$profile/**.patch")) {
                my $commit = gcr_commit_info($file);
                $total++;
                $states{$commit->{state}} ||=0;
                $states{$commit->{state}}++;
            }
            output({indent=>1},
                sprintf("%s - %d commits : %s",
                    $profile,
                    $total,
                    $total ? join(", ", map { "$_:$states{$_}" } sort keys %states) : 'n/a',
                )
            );
        }
        exit 0;
    }

    # We need a reason for this commit
    my $message = prompt_message( "Please provide the reason for the messing with the profile(10+ chars or empty to abort):", $opt->{ message } );
    if ( $message !~ m/\S/s ) {
        output( {stderr=>1,color=>'red'}, "Empty message, aborting." );
        exit 1;
    }

    my %files = (
        'selection.yaml'      => 'Selection Criteria',
        'notification.config' => 'Notification Configuration',
    );

    my $profile = undef;
    my $action = undef;
    my @files_to_edit = ();
    # Edit an existing profile
    if( exists $opt->{edit} ) {
        $profile = $opt->{edit};
        $action = 'edit';
        if( exists $profiles{$profile}) {
            debug("# Editing profile '$profile'");
            my $file = prompt("Which file would you like to edit?", menu => \%files);

            # Configure the default if not there
            my $filename = _default_file($profile,$file);
            unless(defined $filename && -f $filename) {
                output({stderr=>1,color=>"red"}, "Invalid config file, this shouldn't happen. ($filename)");
                exit 1;
            }
            push @files_to_edit, $filename;
        }
        else {
            output({stderr=>1,color=>'red'}, "Unknown profile '$profile', valid profiles: " .
                    join(', ', sort keys %profiles)
            );
            exit 1;
        }
    }
    elsif(exists $opt->{add}) {
        $action = 'add';
        $profile = $opt->{add};
        if( exists $profiles{$opt->{add}}) {
            output({stderr=>1,color=>'red'}, "Profile '$opt->{add}' exists, cannot add.");
            exit 1;
        }
        debug("# Adding profile $profile");
        foreach my $file ( keys %files ) {
            push @files_to_edit, _default_file( $profile, $file, \%cfg );
        }
    }
    else {
        output({stderr=>1,color=>'red'}, "No action specified, nothing to do.");
        exit 1;
    }

    # Edit files in the list.
    foreach my $filename (@files_to_edit) {
        gcr_open_editor(modify => $filename);
        $audit->run( add => $filename );
    }
    $audit->run( commit => '-m',
        join("\n", $message,
            Dump({
                reviewer => $cfg{user},
                state    => "profile_$action",
                profile  => $profile,
                files    => \@files_to_edit,
                skip     => 'true',
            }),
        )
    );
    gcr_push();
}

sub _default_file {
    my ($profile, $file, $cfg) = @_;
    my %content = (
        'selection.yaml' => [
            "# Selection Criteria for $profile",'#',
            '#  Valid options are path and author, globbing allowed.',
            '---',
            'path:',
            q{  - '**'},
        ],
        'notification.config' => [
            "; Notification Configuration for $profile",
            ";   Valid headers are global and template where template takes a name",
            '; ',
            '[global]',
            "  from = $cfg->{user}",
            '',
            ';[ignore]',
            ';  overdue = no',
            '',
            ';[template "select"]',
            ";  to = $cfg->{user}",
        ],
    );

    my $dir = gcr_mkdir('.code-review', 'profiles', $profile );
    if(exists $content{$file}) {
        my $filename = File::Spec->catfile($dir,$file);
        return $filename if -f $filename;
        open(my $fh, '>', $filename) or die "unable to create $filename: $!";
        print $fh "$_\n" for @{ $content{$file} };
        close $fh;
        return $filename;
    }
    return undef;
}
1;
