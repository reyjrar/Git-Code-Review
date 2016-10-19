# ABSTRACT: Show selection criteria and configuration details for the profile/audit.
package Git::Code::Review::Command::info;
use strict;
use warnings;

use CLI::Helpers qw(
    output
    verbose
);
use File::Spec;
use Git::Code::Review -command;
use Git::Code::Review::Notify qw(notify_config);
use Git::Code::Review::Utilities qw(:all);
use YAML;


sub opt_spec {
    return (
        ['files',       "Show the list of files selected by the selection criterion" ],
        ['history',     "Show the change history for the selection criterion, refine with --since and --until" ],
        ['since|s:s',   "Date to start history on, default is full history" ],
        ['until|u:s',   "Date to stop history on, default today" ],
        ['refresh!',    "Refresh the repositories. Use --no-refresh to skip the refresh", { default => 1 }  ],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review info [options]

    DESCRIPTION

        Display information about the Git::Code::Review configuration and profiles. Use --verbose to see even more details.
        If you give --since or --until or --history, the history of changes to the selection criteria is also shown.
        Use --files to see the actual files that will be selected by the selection criteria for specified profile.

    EXAMPLES

        git-code-review info --profile team_awesome --files --since 2016-01-01 --until 2016-12-31

        git-code-review info

        git-code-review info --profile team_awesome

        git-code-review info --profile team_awesome --files

        git-code-review info --profile team_awesome --history

        git-code-review info --profile team_awesome --history --no-refresh

        git-code-review info --profile team_awesome --since 2016-01-01

        git-code-review info --profile team_awesome --since 2015-01-01 --until 2015-12-31

    OPTIONS

            --profile profile       Show information for specified profile.
            --verbose               Show even more information.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;

    my $profile = gcr_profile();
    my %config = gcr_config();
    my $source = gcr_repo('source');
    gcr_reset( 'audit') if $opt->{ refresh };

    foreach my $s (qw(source audit)) {
        $config{origin}->{$s} = gcr_origin($s) || '';
    }

    $config{profiles} = gcr_profiles();

    output({color=>'cyan'},"Git::Code::Review Config for (profile:$profile):");
    output(Dump \%config);

    foreach my $section (qw(select overdue)) {
        verbose({color=>'cyan'}, "\nNotification settings for $section");
        my %notify = notify_config($section);
        verbose(Dump \%notify);
    }

    # Show the selection criterion for the profile
    output({color=>'cyan'},"\nGit::Code::Review Selection Config for (profile:$profile):");
    my %search = gcr_load_profile( $profile );
    foreach my $type (sort keys %search) {
        next unless ref $search{ $type } eq 'ARRAY';
        output("$type:");
        for my $term ( @{ $search{ $type } } ) {
            if ( $type eq 'path' ) {
                # show all files matched by the term
                my @files = $source->run( 'ls-files', $term );
                output(sprintf "  - '$term' (matches %d files)", scalar @files );
                if ( $opt->{ files } ) {
                    output("    - $_") for sort @files;
                }
            } else {
                output("  - $term");
            }
        }
    }

    if ( $opt->{ history } || $opt->{ since } || $opt->{ until } ) {
        # Show the commit log for the selection.yaml file
        output({color=>'cyan'},"\nGit::Code::Review Selection Config Commit history for (profile:$profile):");
        my $select_file = File::Spec->catfile( qw( .code-review profiles ), $profile, 'selection.yaml' );
        my $audit  = gcr_repo();
        my @log_options = ( '-p' );
        push @log_options, "--since=$opt->{since}" if $opt->{since};
        push @log_options, "--until=$opt->{until}" if $opt->{until};
        push @log_options, "--";
        push @log_options, $select_file;
        output( $_ ) for $audit->run( log => @log_options );
    }

    if ( !( $opt->{ files } || $opt->{ history } || $opt->{ since } || $opt->{ until } ) ) {
        output( "Did you know that --files and --history can provide more details? See info --help or help info for more details." );
    }
}

1;
