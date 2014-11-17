# ABSTRACT: Quick overview of the History for the Commmit
package Git::Code::Review::Command::show;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Basename;
use File::Spec;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use POSIX qw(strftime);
use Text::Wrap qw(wrap);
use YAML;

sub opt_spec {
    return (
        #['all',        "Don't filter by profile."],
    );
}

sub description {
    my $DESC = <<"    EOH";

    This command can be used to view the history of a commit in the audit.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    die "Must specify a SHA1 to see history of!" unless @{ $args };
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();

    my $sha1   = $args->[0];
    my $audit  = gcr_repo();
    my $source = gcr_repo('source');
    gcr_reset($_) for qw(audit source);

    # Commit Information
    my @data = $source->run(qw(log -n 1 --stat -r),$sha1);
    output({color=>'green',clear=>1},
        '=*'x40,
        "Summary of $sha1 from Source",
        '=*'x40,
    );
    output({clear=>1},@data);
    debug_var({gcr_commit_info($sha1)});

    my @log_options = (qw(--reverse -F -S), $sha1);
    my $logs = $audit->log(@log_options);

    output({color=>'green',clear=>1},
        '#'x80,
        "Audit History of $sha1",
        '#'x80,
        '',
    );

    while(my $log = $logs->next) {
        my $date = strftime('%F %T',localtime $log->author_localtime);
        my $data = gcr_audit_record($log->message);

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

        debug_var($data);
        output({indent=>1,color=>$color,data=>1}, join("\t", @output));
        if(exists $data->{message} && $state ne 'locked') {
            verbose({indent=>2}, $_) for split /\r?\n/, wrap("", "", $data->{message});
        }
    }
}

1;
