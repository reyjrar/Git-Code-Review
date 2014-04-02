# ABSTRACT: View commits in "Concern" state
package Git::Code::Review::Command::concerns;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use File::Basename;

sub execute {
    my($cmd,$opt,$args) = @_;

    my $audit = gcr_repo();
    gcr_reset();

    my @list = $audit->run('ls-files',"*Concerns*");
    if( @list ) {
        my @commits = map { $_=get_commit_info( basename $_ ) } @list;
        output("Commits flagged with concerns:");
        foreach my $commit ( sort { $a->{date} cmp $b->{date} } @commits ) {
            debug_var($commit);
            output({indent=>1}, join("\t", $commit->{sha1}, $commit->{date}, $commit->{author}));
        }
    }
    else {
        output({color=>'green'}, "No commits flagged with concerns!");
    }
}

1;
