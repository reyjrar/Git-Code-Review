# ABSTRACT: Diff the files matched by old and new selection criteria.
package Git::Code::Review::Command::diff;
use strict;
use warnings;

use CLI::Helpers qw(
    output
);
use Git::Code::Review -command;
use Git::Code::Review::Utilities qw(:all);
use YAML;


sub opt_spec {
    return (
        ['old=s@',      "One of more YAML files containing selection criterion to be used for 'old'" ],
        ['new=s@',      "One of more YAML files containing selection criterion to be used for 'new'" ],
        ['combined',    "Show added, removed and common files in a single list with a prefix with an indicator to show files added (+), files removed (-) and common files ( ) without its selection criterion. Default" ],
        ['added',       "Show added files, i.e. files not matched by old, but matched by 'new' along with its selection criterion" ],
        ['removed',     "Show removed files, i.e. files matched by old, but not matched by 'new' along with its selection criterion" ],
        ['dup|duplicates',  "Show files that are selected by multiple selection criterion from 'new' YAML files" ],
        ['refresh!',    "Refresh the repositories. Use --no-refresh to skip the refresh", { default => 1 }  ],
    );
}


sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review diff [options]

    DESCRIPTION

        Diff the files matched by --old and --new selection criteria. This is very helpful to determine the exact files that have been or will be added or removed
        due to changes in the selection criterion, especially in the following cases:

        Changing a profile - making sure that important files are not removed when selection criterion is changed for a profile.
        Splitting a profile - a profile needs to be split into two or more profiles.
        Merging profiles - two or more profiles need to merged.
        Redistributing profiles - files selected by two or more profiles need to redistributed into different profiles while making sure that total set of files selected has not changed.

        The diff command can also help to speed up the auditors review of the changes to the selection criterion if you grab the new selection.yaml file and
        compare it with the old one. The --no-refresh option allows you to work with the repository at any historic state and can be used to compare the selection
        criterion impact at that time. Here is a sample script snippet:

        cp .code-review/profiles/team_awesome/selection.yaml ../selection_2016-09-01.yaml
        git checkout <hash of old version>
        cd source
        git checkout <hash of old source at date to be audited>
        cd ..
        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --new ../selection_2016-09-01.yaml --no-refresh
        git-code-review reset

        The diff command can also find if any files are selected by more than one selection criteria by using the --dup and the --new options and can help to
        clean up the selection criterion.

    EXAMPLES

        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --new ../new-selection.yaml

        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --new ../new-selection.yaml --added --removed

        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --new ../new-selection.yaml --added --removed --combined

        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --new ../selection-split1.yaml --new ../selection-split2.yaml

        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --new ../selection-split1.yaml --new ../selection-split2.yaml  --removed

        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --old .code-review/profiles/team_focused/selection.yaml --new ../selection-merged.yaml

        git-code-review diff --old .code-review/profiles/team_awesome/selection.yaml --new ../new-selection.yaml --no-refresh

        git-code-review diff --dup --new .code-review/profiles/team_awesome/selection.yaml --no-refresh

    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;
    die "Need YAML file/s for --new" unless scalar @{ $opt->{ new } ||= [] };
    die "Need YAML file/s for --old" unless scalar @{ $opt->{ old } ||= [] } || $opt->{ dup };
    $opt->{ combined } = 1 unless $opt->{ removed } || $opt->{ added } || $opt->{ dup };    # if none given, turn combined on

    # Load the selection criterion for all the specified yaml files
    my %paths;
    for my $file ( @{ $opt->{ old } }, @{ $opt->{ new } } ) {
        if ( ! $paths{ $file } ) {  # load file if we have not loaded it before as you can give the same file in old and new
            my $search = load_file( $file );
            $paths{ $file } = $search->{ path } if exists $search->{ path };
        }
    }
    output( sprintf "Loaded %d yaml files.", scalar keys %paths );

    my $source = gcr_repo( 'source' );
    if ( $opt->{ refresh } ) {
        gcr_reset( $_ ) for qw( audit source );
    }

    # Resolve each path into matched files
    my %matches;
    for my $file ( keys %paths ) {
        for my $path ( @{ $paths{ $file } } ) {
            $matches{ $path } = [ $source->run( 'ls-files', $path ) ] if ! $matches{ $path };
        }
    }
    output( sprintf "Resolved %d paths.", scalar keys %matches );

    # build list of files matched using old selection criterion
    my $old = matched_files( $opt->{ old }, \%paths, \%matches );
    my $new = matched_files( $opt->{ new }, \%paths, \%matches );

    if ( $opt->{ removed } ) {
        my $removed = 0;
        output( "Removed files:-" );
        for my $file ( sort keys %$old ) {
            if ( ! exists $new->{ $file } ) {
                output( "  - $file" );                          # show file
                output( "    - $_" ) for @{ $old->{ $file } };  # show each selection criterion that selected the file
                $removed++;
            }
        }
        output( sprintf "Removed %d files. Total %d files matched.", $removed, scalar keys %$new );
    }

    if ( $opt->{ added } ) {
        my $added = 0;
        output( "Added files:-" );
        for my $file ( sort keys %$new ) {
            if ( ! exists $old->{ $file } ) {
                output( "  - $file" );                          # show file
                output( "    - $_" ) for @{ $new->{ $file } };  # show each selection criterion that selected the file
                $added++;
            }
        }
        output( sprintf "Added %d files. Total %d files matched.", $added, scalar keys %$new );
    }

    if ( $opt->{ combined } ) {
        my ($COMMON, $ADDED, $REMOVED) = ( 0, 1, 2 );
        my @prefix = ( ' ', '+', '-' );
        my @color = ( 'white', 'green', 'red' );
        my @totals = ( 0, 0, 0 );
        my %combined = map { $_ => $REMOVED } keys %$old;
        $combined{ $_ } = exists $old->{ $_ } ? $COMMON : $ADDED for keys %$new;
        for my $file ( sort keys %combined ) {
            my $type = $combined{ $file };
            output( { color => $color[ $type ] }, $prefix[ $type ] . $file );
            $totals[ $type ]++;
        }
        output( sprintf "Added %d files, removed %d files, %d files unchanged.", $totals[ $ADDED ], $totals[ $REMOVED ], $totals[ $COMMON ] );
    }

    if ( $opt->{ dup } ) {
        my $added = 0;
        output( "Duplicate selection:-" );
        for my $file ( sort keys %$new ) {
            if ( scalar @{ $new->{ $file } } > 1 ) {
                output( "  - $file" );
                output( "    - $_" ) for @{ $new->{ $file } };
                $added++;
            }
        }
        output( sprintf "%d files matched by more than one selection criterion. Total %d files matched.", $added, scalar keys %$new );
    }
}


sub load_file {
    my ($select_file) = @_;
    die "$select_file does not exist" unless -f $select_file;
    my $data;
    eval {
        $data = YAML::LoadFile($select_file);
    };
    if( my $err = $@ ) {
        output({stderr=>1,color=>'red'}, "Error loading YAML: $err");
        exit 1;
    }
    return $data;
}


sub matched_files {
    my ($src_files, $paths, $matches) = @_;

    my %result = ();
    for my $src ( @$src_files ) {
        for my $path ( @{ $paths->{ $src } } ) {
            for my $file ( @{ $matches->{ $path } } ) {
                push @{ $result{ $file } }, sprintf( "%s: %s", $src, $path );
            }
        }
    }
    return \%result;
}


1;
