# ABSTRACT: Quick overview of the Audit Directory
package Git::Code::Review::Command::list;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use File::Basename;

sub opt_spec {
    return (
        ['state=s',    "CSV of states to show."],
        ['noop',       "Just run a sample selection."],
    );
}

sub execute {
    my($cmd,$opt,$args) = @_;

    my %SHOW = map { $_ => 1 } split /,|\s+/, $opt->{state};
    my $audit = gcr_repo();
    gcr_reset();

    my @list = grep /\.patch$/, $audit->run('ls-files');
    if( @list ) {
        my %info = ();
        my @commits = map { $_=gcr_commit_info( basename $_ ) } @list;
        output({color=>'cyan'}, sprintf "-[ Commits in the Audit %s:: %s ]-",
            scalar(keys %SHOW) ? '(' . join(',', sort keys %SHOW) . ') ' : '',
            gcr_origin('audit')
        );
        foreach my $commit ( sort { $a->{date} cmp $b->{date} } @commits ) {
            $commit->{state} = 'resigned' unless gcr_not_resigned($commit->{base});
            $info{$commit->{state}} ||= 0;
            $info{$commit->{state}}++;
            next if keys %SHOW && !exists $SHOW{$commit->{state}};
            my $color = gcr_state_color($commit->{state});
            output({indent=>1,color=>$color}, join("\t", $commit->{state}, $commit->{date}, $commit->{sha1}, $commit->{author}));
        }
        output({color=>'cyan'}, sprintf "-[ Status %s from %s ]-",
            join(', ', map { "$_:$info{$_}" } sort keys %info),
            gcr_origin('source')
        );
    }
    else {
        output({color=>'green'}, "No commits flagged with concerns!");
    }
}

1;
