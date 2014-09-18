# ABSTRACT: Generate an Audit Report
package Git::Code::Review::Command::report;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Basename;
use File::Spec;
use Git::Code::Review::Notify;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use POSIX qw(strftime);
use YAML;

my $START = strftime('%F',localtime(time - (86400*7)));
my $END   = strftime('%F',localtime);

sub opt_spec {
    return (
        ['since|s:s',   "Commit start date, none if not specified", {default => $START}],
        ['until|u:s',   "Commit end date, none if not specified",   {default => $END}],
        ['include-meta', "Include meta actions which are normally not displayed" ],
        ['send-report', "Perform Remote Notifications" ],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Generate a report of the audit.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    debug("OPTIONS");
    debug_var($opt);

    my $audit = gcr_repo();
    #gcr_reset();

    # Grab Commit Status
    my @list = grep /\.patch$/, $audit->run('ls-files');
    my %commits = ();
    if( @list ) {
        my @commits  = grep { $_->{date} ge $opt->{since} && $_->{date} le $opt->{until} } map { $_=gcr_commit_info( basename $_ ) } @list;
        # Assemble Commits
        foreach my $commit ( sort { $a->{date} cmp $b->{date} } @commits ) {
            $commits{$commit->{state}} ||= {};
            $commits{$commit->{state}}->{$commit->{profile}} ||= 0;
            $commits{$commit->{state}}->{$commit->{profile}}++;
        }
    }
    debug({color=>'magenta'}, "Commit Status");
    debug_var(\%commits);

    # Grab Activity on the Repositories
    my $logs = $audit->log('--since', $opt->{since}, '--until', $opt->{until});
    my %activity = ();
    my %concerns = ();
    while(my $log = $logs->next) {
        my $content  = undef;
        my $freetext ='';
        foreach my $line ( split /\r?\n/, $log->message ) {
            if(!defined $content && $line eq '---') {
                $content = '';
            }
            elsif(defined $content) {
                $content .= "$line\n";
            }
            else {
                $freetext .= "$line\n";
            }
        }
        my $data = undef;
        eval {
            $data = YAML::Load($content);
        };
        if(!defined $data || !keys %{ $data }) {
            verbose({color=>'red'}, "Invalid YAML in Log Entry for ".$log->commit);
            debug({indent=>1}, split /\r?\n/, $content);
            next;
        }

        # Skip some states
        next if exists $data->{skip} && !$opt->{include_meta};

        # Profile Specific Details
        if( exists $data->{profile} ) {
            if( exists $data->{state} ) {
                $activity{$data->{profile}} ||= {};
                $activity{$data->{profile}}->{$data->{state}} ||= 0;
                $activity{$data->{profile}}->{$data->{state}}++;
            }
        }

        # Overview
        if(exists $data->{state}) {
            $activity{_all_} ||= {};
            $activity{_all_}->{$data->{state}} ||= 0;
            $activity{_all_}->{$data->{state}}++;

            # Catch concerns
            if( $data->{state} eq 'concerns' ) {
                my @commits = map { s/\.patch//; basename($_) }
                                grep { /\.patch$/ }
                                    $audit->run(qw(diff-tree --no-commit-id --name-only -r), $log->commit);
                foreach my $sha1 (@commits) {
                    if(!exists $concerns{$sha1}) {
                        my $commit = gcr_commit_info($sha1);
                        $concerns{$sha1} = {
                            state => $commit->{state},
                            date  => $commit->{date},
                        }
                    }

                }
            }
        }
    }
    debug({color=>'magenta'}, "Activity Overview");
    debug_var(\%activity);

    debug({color=>'red'}, "Concerns raised:");
    debug_var(\%concerns);
}

1;
