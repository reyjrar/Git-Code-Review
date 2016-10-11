# ABSTRACT: List commits available in the audit.
package Git::Code::Review::Command::list;
use strict;
use warnings;

use CLI::Helpers qw(
    debug
    debug_var
    output
);
use File::Basename;
use File::Spec;
use Git::Code::Review -command;
use Git::Code::Review::Utilities qw(:all);
use YAML;


sub opt_spec {
    return (
        ['state=s@',   sprintf( "Commit audit states to list. Multiple --state options can be given or even comma separated. Available states are: %s.", join( ', ', sort( gcr_get_states() ) ) )],
        ['all',        "Don't filter by profile."],
        ['since|s:s',  "Commit start date, none if not specified", {default => "0000-00-00"}],
        ['until|u:s',  "Commit end date, none if not specified",   {default => "9999-99-99"}],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review list [options]

    DESCRIPTION

        This command can be used to view the status of all commits in the audit that match the specified criteria of profile, period and state.

    EXAMPLES

        git-code-review list

        git-code-review list --all

        git-code-review list --all --state concerns

        git-code-review list --all --since 2016-06-01 --until 2016-06-30

        git-code-review list --profile team_awesome --since 2015-01-01 --until 2015-12-31

    OPTIONS

            --profile profile   Show information for specified profile. Also see --all.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;

    my %show = exists $opt->{state} ? map { $_ => 1 } split /,|\s+/, join( ',', @{ $opt->{state} } ) : ();
    if ( scalar %show ) {
        # validate the supplied states
        my %available_states = map { $_ => 1 } gcr_get_states();
        my @invalid_states = grep { ! exists $available_states{ $_ } } keys %show;
        die sprintf("Invalid state/s '%s'. Valid states can be a subset of '%s'.", join(', ', @invalid_states), join( ', ', sort keys %available_states) ) if scalar @invalid_states;
    }

    my $profile = gcr_profile();
    my $audit = gcr_repo();
    gcr_reset();

    my $header =  join( "\t", 'Profile', 'State', 'Authored:yyyy-mm-dd', 'Selected:yyyy-mm-dd', 'Commit hash                             ', 'Author', '(comments)' );
    my @list = $audit->run(qw(ls-files -- **.patch));
    if( @list ) {
        my %states = ();
        my %profiles = ();
        my @commits = grep { $_->{select_date} ge $opt->{since} && $_->{select_date} le $opt->{until} }
                        map { debug("getting info $_"); $_=gcr_commit_info( basename $_ ) } @list;
        output({color=>'cyan'}, sprintf "-[ Commits in the Audit %s:: %s ]-",
            scalar(keys %show) ? '(' . join(',', sort keys %show) . ') ' : '',
            gcr_origin('audit')
        );
        # Assemble Comments
        my %comments = ();
        foreach my $comment ($audit->run('ls-files', qq{*/Comments/*})) {
            my @path = File::Spec->splitdir($comment);
            $comments{$path[-2]} ||= 0;
            $comments{$path[-2]}++;
        }
        # Assemble Commits
        foreach my $commit ( sort { $a->{date} cmp $b->{date} } @commits ) {
            $commit->{state} = 'resigned' unless gcr_not_resigned($commit->{base});
            # Profile filter
            next unless exists $commit->{profile} && length $commit->{profile};
            next unless (exists $opt->{all} && $opt->{all}) || $commit->{profile} eq $profile;

            # Count them
            $states{$commit->{state}} ||= 0;
            $states{$commit->{state}}++;
            $profiles{$commit->{profile}} ||= 0;
            $profiles{$commit->{profile}}++;

            # State filter
            next if keys %show && !exists $show{$commit->{state}};

            if ( $header ) {
                output( {indent=>1,data=>1}, $header );
                $header = undef;
            }

            my $color = gcr_state_color($commit->{state});
            output({indent=>1,color=>$color,data=>1}, join("\t",
                    $commit->{profile},
                    $commit->{state},
                    'authored:' . $commit->{date},
                    'selected:' . $commit->{select_date},
                    $commit->{sha1},
                    $commit->{author},
                    exists $comments{$commit->{sha1}} ? "(comments:$comments{$commit->{sha1}})" : "",
                )
            );
            debug_var($commit);
        }
        output({color=>'cyan'}, sprintf "-[ Status  : %s ]-",
            join(', ', map { "$_:$states{$_}" } sort keys %states)
        );
        output({color=>'cyan'}, sprintf "-[ Profile : %s ]-",
            join(', ', map { "$_:$profiles{$_}" } sort keys %profiles)
        );
        output({color=>'cyan'}, sprintf "-[ Source  : %s %s%s]-",
            gcr_origin('source'),
            $opt->{since} eq '0000-00-00' ? '' : "from $opt->{since} ",
            $opt->{until} eq '9999-99-99' ? '' : "until $opt->{until} ",
        );
    }
    else {
        output({color=>'green'}, "No commits matching criteria!");
    }
    my $config = gcr_config();
    debug_var($config);
}

1;
