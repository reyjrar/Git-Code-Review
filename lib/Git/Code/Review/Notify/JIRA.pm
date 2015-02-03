# ABSTRACT: Notification to JIRA
package Git::Code::Review::Notify::JIRA;

use strict;
use warnings;

use CLI::Helpers qw(:all);
use Config::Auto;
use File::Spec;
use File::Temp qw(tempfile);
use Git::Code::Review::Utilities qw(:all);
use JIRA::Client;
use POSIX qw(strftime);
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
    if( exists $config{profile} && $config{profile} ne 'all' && exists $config{'jira-title'}) {
        $config{'jira-title'} = join(' : ', @config{qw(jira-title profile)});
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


    # Ticket Creation
    verbose({color=>'green'}, "JIRA Parent Ticket: $config{'jira-title'}");
    # Should we do the thing?
    unless( exists $ENV{GCR_NOTIFY_ENABLED} ) {
        output({color=>'cyan',sticky=>1}, "JIRA methods disabled, use --notify to enable.");
        return;
    }

    # Determine the Year to use for the parent ticket
    my $jira_client = JIRA::Client->new($config{'jira-url'}, @credentials{qw(username password)}) or die "Cannot create JIRA client: $@";

    my %STATUS_ID_NAME = ();
    my %STATUS_NAME_ID = ();
    foreach my $s (values %{ $jira_client->get_statuses}) {
        $STATUS_ID_NAME{$s->{id}} = $s->{name};
        $STATUS_NAME_ID{$s->{name}} = $s->{id};
    }

    # Parent Ticket
    my $parent_search = sprintf('project = %s AND summary ~ "%s" AND issuetype in standardIssueTypes() AND status != Closed', @config{qw(jira-project jira-title)});
    my $parent;
    foreach my $jira ($jira_client->filter_issues($parent_search)) {
        next unless $jira->{summary} eq $config{'jira-title'};
        $parent = $jira->{key};
        last;
    }
    if(!defined $parent) {
        eval {
            my $ticket = $jira_client->create_issue({
                project => $config{'jira-project'},
                summary => $config{'jira-title'},
                type    => 'Task',
            });
            debug({color=>'green'},"[$ticket->{key}] Created Parent Ticket: $config{'jira-title'}");

            # Set Parent
            $parent = $ticket->{key};
            # Return true
            1;
        } or die "Cannot create parent ticket for $config{'jira-project'} - $config{'jira-title'}. Error: $@";
    }
    verbose({color=>'green'}, "[$parent] - Parent Ticket Discovered.");

    # Report Ticket Search
    my $month = join('-', (split /-/, $config{month})[0,1]);
    my $report_summary = sprintf('%s - %s', $config{'jira-title'}, $month);
    my $report_search = sprintf('project = %s AND summary ~ "%s" AND issuetype in subTaskIssueTypes()',$config{'jira-project'}, $config{'jira-title'});
    my $report_ticket;
    my $report;
    my $report_created = 0;
    foreach my $jira ($jira_client->filter_issues($report_search)) {
        next unless $jira->{summary} eq $report_summary;

        die sprintf('[%s] Report ticket has been closed.', $jira->{key}) if $jira->{status} eq $STATUS_NAME_ID{Closed};

        $report = $jira->{key};
        last;
    }
    if(!defined $report) {
        eval {
            $report_ticket = $jira_client->create_issue({
                project     => $config{'jira-project'},
                summary     => $report_summary,
                assignee    => $config{'jira-assignee'},
                parent      => $parent,
                type        => 'Sub-task',
                # Build a description
                description => join("\n\n",
                    sprintf('This ticket was created automatically by "%s" on %s', $0, hostname()),
                ),
            });
            debug({color=>'green'},"[$report_ticket->{key}] Created Sub Task: $report_summary");

            # Set Parent
            $report = $report_ticket->{key};
            # Return true
            $report_created = 1;
        } or die "Cannot create monthly ticket for $report_summary: $@";
    }
    else {
        $report_ticket = $jira_client->getIssue($report);
    }
    verbose({color=>'green'}, "[$report] - Report Ticket Discovered.");

    # Retrieve comment content
    my @comments = ();
    foreach my $container ( $jira_client->getComments($report_ticket) ){
        foreach my $comment (@{ $container }) {
            push @comments, $comment->{body};
        }
    }
    debug({color=>'cyan'}, "Existing Comments");
    debug_var(\@comments);

    foreach my $table (split /\n\n\n/m, $config{message} ) {
        my ($title,$content) = split /^----$/m, $table;

        $title   =~ s/^\s+//g;
        $content =~ s/^\s+//g if defined $content;

        if(!defined $content) {
            verbose({indent=>1,color=>'yellow'}, "Comment skipped for bad formating");
            verbose({indent=>2}, $title);
            next;
        }

        my $exists = 0;
        foreach my $comment (@comments) {
            if( index($comment, $title) >= 0 ) {
                $exists=1;
                last;
            }
        }
        if(!$exists) {
            verbose({indent=>1}, "[$report] adding comment for $title");
            $jira_client->addComment($report_ticket, join("\n", 'h2. ' . $title, '----', $content));
        }
    }

    # Full log as an attachment
    my %attachments = map { $_ => 1 } @{ $report_ticket->{attachmentNames} };
    my $history_file= sprintf('history-%s.log', $config{options}->{until});
    if(!exists $attachments{$history_file} && exists $config{history}) {
        # Record in the ticket
        my ($fh,$filename) = tempfile();
        $fh->autoflush(1);
        print $fh join("\n\n", @{ $config{history}});

        seek($fh,0,0);
        eval {
            $jira_client->attach_files_to_issue($report, { $history_file => $fh });
            close($fh);
        };
        my $err = $@;
        if( $err ) {
            output({color=>'red',stdout=>1}, "ERROR Attaching file ($history_file): $err");
            unlink $filename;
            exit 1;
        }
        unlink $filename;
    }
    my $selection_file= sprintf('selection-%s.csv', $config{options}->{until});
    if(!exists $attachments{$selection_file} && exists $config{selected}) {
        # Record in the ticket
        my ($fh,$filename) = tempfile();
        $fh->autoflush(1);
        foreach my $k (sort { $config{selected}->{$a}[0] cmp $config{selected}->{$b}[0] } grep { ref $config{selected}->{$_} } keys %{ $config{selected} }) {
            printf $fh "%s\n", join(',', $k, @{ $config{selected}->{$k} });
        }

        seek($fh,0,0);
        eval {
            $jira_client->attach_files_to_issue($report, { $selection_file => $fh });
            close($fh);
        };
        my $err = $@;
        if( $err ) {
            output({color=>'red',stdout=>1}, "ERROR Attaching file($selection_file): $err");
            unlink $filename;
            exit 1;
        }
        unlink $filename;
    }
}

1;
