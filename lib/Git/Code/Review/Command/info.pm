# ABSTRACT: Quick overview of the Audit
package Git::Code::Review::Command::info;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use YAML;

sub opt_spec {
    return (
    #       ['state=s',    "CSV of states to show."],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Display information about the Git::Code::Review objects.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    my %config = gcr_config();
    foreach my $s (qw(source audit)) {
        no warnings;
        $config{origin}->{$s} = gcr_origin($s);
    }

    output({color=>'cyan'},"Git::Code::Review Config:");
    output(Dump \%config);
}

1;
