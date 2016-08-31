# ABSTRACT: Show the Git::Code::Review::Tutorial
package Git::Code::Review::Command::tutorial;
use strict;
use warnings;

use Git::Code::Review -command;
use Git::Code::Review::Tutorial;
use Pod::Find qw( pod_where );
use Pod::Usage;

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review tutorial

    DESCRIPTION

        Show the git-code-review tutorial.

    EXAMPLES

        git-code-review tutorial

    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my ($cmd,$opt,$args) = @_;

    pod2usage( -verbose => 2, -input => pod_where( { -inc => 1 }, 'Git::Code::Review::Tutorial' ) );
}

1;
