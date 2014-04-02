# ABSTRACT: Perform commit selection
package Git::Code::Review::Command::select;

use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;

sub execute {
    output({color=>'green'}, "Yay! This almost works!");
}

1;
