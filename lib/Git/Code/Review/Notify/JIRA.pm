# ABSTRACT: Notification by email
package Git::Code::Review::Notify::JIRA;

use strict;
use warnings;

use CLI::Helpers qw(:all);
use Config::Auto;
use File::Spec;
use Git::Code::Review::Utilities qw(:all);
use JIRA::Client;
use Sys::Hostname qw(hostname);

sub send {
    shift @_ if ref $_[0] || $_[0] eq __PACKAGE__;
    my %config = @_;
    debug({color=>'magenta'}, "calling Git::Code::Review::Notify::JIRA::send");
    debug_var(\%config);

    # Check that JIRA is configured properly
    my @missing = ();
    foreach my $field (qw(jira-assignee jira-credential-file jira-project jira-title jira-url)) {
        push @missing, $field unless exists $config{$field} && defined $config{$field};
    }
    if(@missing) {
        verbose({color=>'yellow'}, "Notify/JIRA - Missing configuration parameters: "
            . join(', ', sort @missing)
        );
        return;
    }

    # Need valid JIRA properties
    if( !-f $config{'jira-credential-file'} ) {
        verbose({color=>'yellow'}, "Notify/JIRA - Missing a valid jira-credential-file, skipping.");
        return;
    }

    # Parse the config file
    my $jira_config = Config::Auto::parse($config{'jira-credential-file'});

    # Try to grab the username/password
    my %mapping = (
            username => [qw(user username)],
            password => [qw(pass passwd password)],
    );
    my %credentials = ();
    foreach my $key (keys %mapping) {
        foreach my $try (@{ $mapping{$key} }) {
            next unless exists $jira_config->{$try};
            $credentials{$key} = $jira_config->{$try};
            last;
        }
        if(!exists $credentials{$key}) {
            verbose({color=>'red'}, "Notify/JIRA - Unable to find the '$key' in $config{'jira-credential-file'}.");
            return;
        }
    }

    # Determine the Year to use for the parent ticket

}

1;
