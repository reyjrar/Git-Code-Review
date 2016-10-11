# ABSTRACT: Show the audit history for a commit.
package Git::Code::Review::Command::show;
use strict;
use warnings;

use CLI::Helpers qw(
    debug
    debug_var
    output
);
use File::Basename;
use File::Spec;
use Git::Code::Review -command;
use Git::Code::Review::Utilities qw(:all);
use POSIX qw(strftime);
use Text::Wrap qw(fill);
use YAML;


sub opt_spec {
    return (
        ['notes!',  "Show the notes / messages for concerns and comments. Use --no-notes to suppress the notes", { default => 1 } ],
    );
}


sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review show [options] <commit hash>...

    DESCRIPTION

        This command can be used to view the audit history of a commit.

    EXAMPLES

        git-code-review show 44d3b68e

        git-code-review show --no-notes 44d3b68e

    OPTIONS
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Please specify at least one commit hash from the source repository to see history of!" unless scalar @$args;

    my $audit  = gcr_repo();
    my $source = gcr_repo('source');
    gcr_reset($_) for qw(audit source);

    for my $sha1 ( @$args ) {
        # Commit Information
        my @data = $source->run(qw(log -n 1 --stat -r),$sha1);
        output({color=>'green',clear=>1},
            '=*'x40,
            "Summary of $sha1 from Source",
            '=*'x40,
        );
        output({clear=>1},@data);
        my $commit = gcr_commit_info( $sha1 );
        debug_var( $commit );

        my @log_options = qw(--reverse --);
        push @log_options, sprintf "*/%s**", $sha1;
        my $logs = $audit->log(@log_options);
        debug({color=>'cyan'}, "Running: git log ". join(' ', map { /\s/ ? "'$_'" : $_ } @log_options));

        output({color=>'green',clear=>1},
            '#'x80,
            "Audit History of $sha1",
            '#'x80,
            '',
        );

        while(my $log = $logs->next) {
            my $date = strftime('%F %T',localtime $log->author_localtime);
            my $data = gcr_audit_record($log->message);
            if ( exists $data->{state} && $data->{ state } eq 'locked' ) {
                # save information for later
                $commit->{ locked_date } = $date;
                $commit->{ locked_author } = $log->author_email,
            }

            next if exists $data->{skip};

            my $color = exists $data->{state} ? gcr_state_color($data->{state}) : 'cyan';
            my $state = exists $data->{state} ? $data->{state}
                      : exists $data->{status} ? $data->{status}
                      : 'other';

            my @output = (
                $date,
                $log->author_email,
                $state,
            );

            foreach my $key (qw(profile reason)) {
                push @output, $data->{$key} if exists $data->{$key};
            }

            output({indent=>1,color=>$color,data=>1}, join("\t", @output));
            if($opt->{ notes } && exists $data->{message} && $state ne 'locked') {
                my $message = exists $data->{fixed_by} ? join('  ', $data->{message}, "Fixed by: $data->{fixed_by}") : $data->{message};
                output({indent=>2}, $_) for split /\r?\n/, fill("", "", $message);
            }
        }

        if ( $commit->{ state } eq 'locked' ) {
            # show information about who has currently locked the commit
            output( {indent=>1}, join( "\t", $commit->{ locked_date }, $commit->{ locked_author }, $commit->{ state }, $commit->{ profile } ) );
        }
    }
}

1;
