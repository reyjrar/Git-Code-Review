# ABSTRACT: Manage profiles for the code selection
package Git::Code::Review::Command::profile;
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

sub opt_spec {
    return (
            ['list',       "List profiles"],
            ['add=s',      "Create a new profile"],
            ['edit=s',     "Edit a profile"],
            ['reason|r=s', "Reason for mucking with this profile"],
    );
}

sub description {
    my $DESC = <<"    EOH";

    This command allows managing of the profiles for commit selection and notifications.

        git code-review profile --list

        git code-review profile --add team_a --reason "Team A's Responsibilities"

    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my ($cmd,$opt,$args) = @_;
    my ($match) = @$args;

    debug("Options Parsed.");
    debug_var($opt);

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();

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
    my $message =  exists $opt->{reason} && length $opt->{reason} > 10 ? $opt->{reason}
                : prompt(sprintf("Please provide the reason for the messing with the profile%s:", exists $opt->{reason} ? '(10+ chars)' : ''),
                    validate => { "10+ characters, please" => sub { length $_ > 10 } });

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
            push @files_to_edit, _default_file($profile,$file);
        }
    }

    # Edit files in the list.
    foreach my $filename (@files_to_edit) {
        gcr_open_editor(modify => $filename);
        $audit->run( add => $filename );
    }
    $audit->run( commit => '-m',
        join("\n", $message,
            Dump({
                reviewer => $CFG{user},
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
    my ($profile,$file) = @_;
    my %content = (
        'selection.yaml' => [
            "Selection Criteria for $profile",'',
            '  Valid options are path and author, globbing allowed.',
            '---',
            'path:',
            '  - **',
        ],
        'notification.config' => [
            "; Notification Configuration for $profile",
            ";   Valid headers are global and template where template takes a name",
            '; ',
            '[global]',
            "  from = $CFG{user}",
            '',
            ';[template "select"]',
            ";  to = $CFG{user}",
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
