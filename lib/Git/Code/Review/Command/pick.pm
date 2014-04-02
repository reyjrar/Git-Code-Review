# ABSTRACT: Allows reviewers to select a commit for auditing
package Git::Code::Review::Command::pick;

use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;

sub execute {
    output({color=>'green'}, "Yay! This almost works!");
}

1;
