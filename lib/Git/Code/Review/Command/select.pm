# ABSTRACT: Select commits for review as per the configured selection criterion.
package Git::Code::Review::Command::select;
use strict;
use warnings;

use CLI::Helpers qw(
    debug
    debug_var
    output
    verbose
);
use Git::Code::Review -command;
use Git::Code::Review::Helpers qw(
    prompt_message
);
use Git::Code::Review::Notify qw(notify_enabled);
use Git::Code::Review::Utilities qw(:all);
use POSIX qw(strftime);
use YAML;


# Globals for easy access
my $TODAY = strftime('%F',localtime);
my $START = strftime('%F',localtime(time-(3600*24*30)));
my %METRICS = ();

# Dispatch Table for Searches
my %SEARCH = (
    path   => \&log_params_path,
    author => \&log_params_author,
);


sub opt_spec {
    return (
        ['noop',       "Select in dry-run mode and do not commit any changes."],
        ['message|m|reason|r=s@', "Reason for the selection, ie '2014-01 Review'. If multiple -m options are given, their values are concatenated as separate paragraphs.",],
        ['since|s=s',  "Start date                     (Default: $START)",    { default => $START } ],
        ['until|u=s',  "End date                       (Default: $TODAY)",    { default => $TODAY } ],
        ['number=i',   "Number of commits to select, skip this option or use 0 for all commit (Default: all)"],
        ['all',        "Deprecated. By default all commits will be selected unless --number says otherwise. So you can simple stop giving --all",],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review select [options]

    DESCRIPTION

        This command is used to select a sample or all of the commits in the repository
        which match a particular profile for review.

        The default profile matches all commits in the repository.

    EXAMPLES

        git code-review select --profile team_awesome --since 2016-10-15 -m "Weekly code review" --noop

        git code-review select --profile team_awesome --since 2016-10-15 -m "Weekly code review"

        git code-review select --profile team_awesome --since 2016-09-01 --number 20  -m "Random sampled code review"

        git code-review select --since 2014-03-01 --until 2014-04-01 --number 10 -m "March Code Review"

        git code-review select --since 2014-03-01 --until 2014-04-01 --number 10 --message "March Code Review"

    OPTIONS

            --profile profile   Select commits for specified profile.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my ($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;
    my $all = $opt->{ number } && $opt->{ number } > 0 ? 0 : 1;
    if ( $opt->{ all } ) {
        # still support the deprecated option for now.
        $all = 1;
        output( {color=>'red'}, "--all has been deprecated, by default all commits will be selected." );
    }

    # We need a reason for this commit
    my $message = prompt_message( "Please provide the reason for the selection(10+ chars or empty to abort):", $opt->{ message } );
    if ( $message !~ m/\S/s ) {
        output( {stderr=>1,color=>'red'}, "Empty message, aborting." );
        exit 1;
    }

    notify_enabled();

    # Config and Repositories
    my $auditdir = gcr_dir();
    my %cfg = gcr_config();
    my $profile = gcr_profile();
    my $audit  = gcr_repo();
    my $source = gcr_repo('source');
    # Reset the Audit and Source Repositories
    gcr_reset();    # gcr_reset() as the commit could have been selected already
    gcr_reset('source');

    # Git Log Options
    my @options = (
        '--no-merges',                  # No merge commits
        q{--pretty=format:%H %ci},      # output formatting
        "--since=$opt->{since}",        # Timeframe
        "--until=$opt->{until}",        # Timeframe
        '-w'
    );

    # Get the pool of commits
    my %pool = ();
    my %matches = ();
    my %search = gcr_load_profile($profile);
    foreach my $type (keys %search) {
        next unless ref $search{$type} eq 'ARRAY';
        verbose("Searching by $type.");
        my $matches=0;
        foreach my $term (@{ $search{$type} }) {
            my @full = get_log_params($type,\@options,$term);
            debug("Running: git log " . join(' ', @full));
            foreach my $info ($source->run(log => @full)) {
                my ($commit,$date) = split /\s+/, $info, 2;
                my $dupe = exists $pool{$commit} ? 1 : 0;
                verbose({indent=>1,color=>$dupe ? 'white' : 'cyan'}, sprintf("%s found %s (%s)", $dupe ? '!' : '+', $commit, $date ));
                $pool{$commit} ||= { date => $date };
                $pool{$commit}->{$type}=1;
                $matches{"$type:$term"} ||= 0;
                $matches{"$type:$term"}++;
                $matches++;
            }
        }
        output({color=>'green'}, sprintf("= Matched %d from %d search terms.", $matches,scalar(@{$search{$type}})));
    }
    # Debug, highlight where matches came from.
    foreach my $search (sort { $matches{$b} <=> $matches{$a} } keys %matches) {
        debug({indent=>1,color=>"yellow"},"~ $search => $matches{$search}");
    }
    # Perform the pick!
    my @picks=();
    my $method = 'random';
    my $exists = 0;
    if( $all ) {
        @picks = grep { !gcr_commit_exists($_) } keys %pool;
        $exists = ( scalar keys %pool ) - ( scalar @picks );
        debug({indent=>1}, "picked $_") for @picks;
        output({color=>scalar(@picks) ? 'green' : 'red'},sprintf('%s PICKED: %d', scalar(@picks) ? '+' : '!', scalar(@picks)));
        $method = 'all';
    }
    else {
        my @pool = keys %pool;
        while( @picks < $opt->{number} && @pool ) {
            my $index = int(rand(scalar(@pool)));
            my($pick) = splice @pool, $index, 1;
            if( gcr_commit_exists($pick) ) {
                debug({indent=>1,color=>'yellow'}, "Commit $pick has already been added to the audit, skipping.");
                $exists++;
                next;
            }
            push @picks, $pick;
            debug({indent=>1}, "picked $pick");
        }
        my $got_enough = scalar(@picks) == $opt->{number} ? 1 : 0;
        $method = 'all' if !$got_enough;
        output({color=>$got_enough ? 'green' : 'red'},sprintf('%s PICKED: %d of %d', $got_enough ? '+' : '!', scalar(@picks), $opt->{number}));
    }

    $METRICS{ matched } = scalar keys %pool;
    $METRICS{ selected } = scalar @picks;
    $METRICS{ existed } = $exists;

    # We don't have enough
    if(@picks < 1) {
        output({color=>'green'}, "All commits from $opt->{since} to $opt->{until} for the $profile profile are already in the audit.");
    } else {
        # Place the patches in the appropriate directory
        if( !exists $opt->{noop} ) {
            gcr_reset();
            foreach my $sha1 (@picks) {
                # Date Path by Year/Month
                my @sub = (split /\-/, (split /\s+/, $pool{$sha1}->{date})[0])[0];
                unshift @sub, $profile;
                push @sub, 'Review';
                my $dir = $auditdir;
                while( @sub ) {
                    $dir = File::Spec->catdir($dir,shift @sub);
                    if( !-d $dir ) {
                        mkdir($dir,0755);
                        debug({indent=>1,color=>'yellow'},"+ created directory: $dir");
                    }
                }
                # Build the file name
                my $file = File::Spec->catfile($dir, $sha1 . '.patch' );
                my $fh = IO::File->new();
                if( $fh->open($file,"w") ) {
                    # Add the content
                    print $fh "$_\n" for $source->run(show => $sha1, '-w', '--date=iso', '--pretty=fuller', '--find-renames');
                    verbose("+ Added $file to the Audit.");
                    close $fh;
                    # remove the absolute path pieces
                    my $repo_file = substr($file,length($auditdir)+1);
                    $audit->run(add => $repo_file);
                }
            }
            my %details = (
                state       => 'select',
                profile     => $profile,
                reviewer    => $cfg{user},
                criteria    => { %$opt },
                selected    => $method,
                source_repo => gcr_origin('source'),
                audit_repo  => gcr_origin('audit'),
            );
            my $msg = join("\n", $message, Dump(\%details));
            $audit->run('commit', '-m', $msg);
            gcr_push();

            # Notify
            Git::Code::Review::Notify::notify(select => {
                priority => 'high',
                pool => {
                    matches   => \%matches,
                    total     => scalar(keys %pool),
                    selected  => scalar(@picks),
                    selection => [
                        map { { gcr_commit_info($_) } } @picks
                    ],
                },
                reason => $message,
            });
        } else {
            $METRICS{ selected } = 0;   # since this is a noop, we are not selecting anything
        }
    }
    debug_var( \%METRICS );
}

sub get_log_params {
    my ($type,$opts,$term) = @_;
    return unless exists $SEARCH{$type};
    return $SEARCH{$type}->($opts,$term);
}

sub log_params_path {
    my ($opts,$term) = @_;
    return @{ $opts }, '--', $term;
}

sub log_params_author {
    my($opts,$term) = @_;
    return @{ $opts }, '--author', $term;
}

1;
