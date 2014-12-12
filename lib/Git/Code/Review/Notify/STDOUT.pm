package Git::Code::Review::Notify::STDOUT;
# ABSTRACT: Notification plugin that outputs the message to STDOUT
use CLI::Helpers qw(:output);

sub send {
    shift @_ if ref $_[0] || $_[0] eq __PACKAGE__;
    my %config = @_;
    my $message = delete $config{message};
    verbose({color=>'cyan'}, "Config containted: " . join(', ', sort keys %config));
    debug_var(\%config);
    output({data=>1}, $message);
}

1;
