# ABSTRACT: Perform commit selection
package Git::Code::Review::Command::select;
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
my $TODAY = strftime('%F',localtime);
my $START = strftime('%F',localtime(time-(3600*24*30)));

# Dispatch Table for Searches
my %SEARCH = (
    path   => \&log_params_path,
    author => \&log_params_author,
);

sub opt_spec {
    return (
        ['noop',       "Just run a sample selection."],
        ['reason|r=s', "Reason for the selection, ie '2014-01 Review'",  ],
        ['since|s=s',  "Start date                     (Default: $START)",    { default => $START } ],
        ['until|u=s',  "End date                       (Default: $TODAY)",    { default => $TODAY } ],
        ['number|n=i', "Number of commits,  -1 for all (Default: 25)",        { default => 25 } ],
        ['profile|p=s',"Selection profile to use       (Default: 'default')", { default => 'default'} ],
    );
}

sub description {
    my $DESC = <<"    EOH";

    This command is used to select a sample or all of the commits in the repository
    which match a particular profile for review.

    Example:

        git code-review select --since 2014-03-01 --until 2014-04-01 --number 10 --reason "March Code Review"

    The default profile matches all commits in the repository.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my ($cmd,$opt,$args) = @_;

    # Git Log Options
    my @options = (
        q{--pretty=format:%H %ci},      # output formatting
        "--since=$opt->{since}",        # Timeframe
        "--until=$opt->{until}",        # Timeframe
        '-w'
    );

    # We need a reason for this commit
    my $message =  exists $opt->{reason} && length $opt->{reason} > 10 ? $opt->{reason}
                : prompt(sprintf("Please provide the reason for the selection%s:", exists $opt->{reason} ? '(10+ chars)' : ''),
                    validate => { "10+ characters, please" => sub { length $_ > 10 } });

    # Repositories
    my $source = gcr_repo('source');
    my $audit  = gcr_repo();

    # Reset the Source Repository
    gcr_reset('source');

    # Get the pool of commits
    my %pool = ();
    my %matches = ();
    my %search = load_profile($opt->{profile});
    foreach my $type (keys %search) {
        next unless ref $search{$type} eq 'ARRAY';
        output("Searching by $type.");
        my $matches=0;
        foreach my $term (@{ $search{$type} }) {
            my @full = get_log_params($type,\@options,$term);
            foreach my $info ($source->run(log => @full)) {
                my ($commit,$date) = split /\s+/, $info, 2;
                my $dupe = exists $pool{$commit} ? 1 : 0;
                verbose({indent=>1,color=>$dupe ? 'white' : 'cyan'}, sprintf("%sfound %s (%s)", $dupe ? '!' : '+', $commit, $date ));
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
    my @pool = keys %pool;
    my @picks=();
    while( @picks < $opt->{number} && @pool ) {
        my $index = int(rand(scalar(@pool)));
        push @picks, splice @pool, $index, 1;
        debug({indent=>1}, "picked $picks[-1]");
    }
    my $got_enough = scalar(@picks) == $opt->{number} ? 1 : 0;
    output({color=>$got_enough ? 'green' : 'red'},sprintf('%s PICKED: %d of %d', $got_enough ? '+' : '!', scalar(@picks), $opt->{number}));

    # Place the patches in the appropriate directory
    if( !exists $opt->{noop} ) {
        gcr_reset();
        foreach my $sha1 (@picks) {
            # Date Path by Year/Month
            my @sub = split /\-/, (split /\s+/, $pool{$sha1}->{date})[0];
            pop @sub;
            push @sub, 'Review';
            my $dir = $AUDITDIR;
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
                print $fh "$_\n" for $source->run(show => $sha1, '-w', '--date=iso');
                verbose("+ Added $file to the Audit.");
                close $fh;
                # remove the absolute path pieces
                my $repo_file = substr($file,length($AUDITDIR)+1);
                $audit->run(add => $repo_file);
            }
        }
        my %details = (
            state       => 'select',
            reviewer    => $CFG{user},
            criteria    => $opt,
            selected    => $got_enough ? 'random' : 'all',
            source_repo => gcr_origin('source'),
            audit_repo  => gcr_origin('audit'),
        );
        my $msg = join("\n", $message, Dump(\%details));
        $audit->run('commit', '-m', $msg);
        gcr_push();
    }
}

sub load_profile {
    my ($profile) = @_;
    my %profile = (
        path => [qw(**)],
    );
    return wantarray ? %profile : \%profile;
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
