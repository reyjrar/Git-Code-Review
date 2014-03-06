# ABSTRACT: Tools for performing code review using Git as the backend
package Git::Code::Review;
use strict;
use warnings;

# VERSION

use Getopt::Long qw(:config pass_through);
use CLI::Helpers qw(:all);
use Git::Repository;

1;
