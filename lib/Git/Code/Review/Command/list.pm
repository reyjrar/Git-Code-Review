# ABSTRACT: Quick overview of the Audit Directory
package Git::Code::Review::Command::list;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Basename;
use File::Spec;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use YAML;

sub opt_spec {
    return (
        ['state=s',    "CSV of states to show."],
        ['all',        "Don't filter by profile."],
        ['since|s:s',  "Commit start date, none if not specified", {default => "0000-00-00"}],
        ['until|u:s',  "Commit end date, none if not specified",   {default => "9999-99-99"}],
    );
}

sub description {
    my $DESC = <<"    EOH";

    This command can be used to view the status of the audit.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    my %SHOW = exists $opt->{state} ? map { $_ => 1 } split /,|\s+/, $opt->{state} : ();
    my $audit = gcr_repo();
    my $profile = gcr_profile();
    gcr_reset();

    my @list = grep /\.patch$/, $audit->run('ls-files');
    if( @list ) {
        my %states = ();
        my %profiles = ();
        my @commits = grep { $_->{date} ge $opt->{since} && $_->{date} le $opt->{until} } map { $_=gcr_commit_info( basename $_ ) } @list;
        output({color=>'cyan'}, sprintf "-[ Commits in the Audit %s:: %s ]-",
            scalar(keys %SHOW) ? '(' . join(',', sort keys %SHOW) . ') ' : '',
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
            $states{$commit->{state}} ||= 0;
            $states{$commit->{state}}++;
            $profiles{$commit->{profile}} ||= 0;
            $profiles{$commit->{profile}}++;
            # State filter
            next if keys %SHOW && !exists $SHOW{$commit->{state}};
            # Profile filter
            next unless (exists $opt->{all} && $opt->{all}) || $commit->{profile} eq $profile;

            my $color = gcr_state_color($commit->{state});
            output({indent=>1,color=>$color}, join("\t",
                    $commit->{profile},
                    $commit->{state},
                    $commit->{date},
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
        output({color=>'cyan'}, sprintf "-[ Source  : %s ]-", gcr_origin('source') );
    }
    else {
        output({color=>'green'}, "No commits matching criteria!");
    }
    my $config = gcr_config();
    debug_var($config);
}

1;
