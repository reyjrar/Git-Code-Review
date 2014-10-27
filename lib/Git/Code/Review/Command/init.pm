# ABSTRACT: Initialization hooks for git-code-review commands
package Git::Code::Review::Command::init;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review -command;
use Git::Code::Review::Utilities qw(:all);
use YAML;

my %CFG = gcr_config();
my $AUDITDIR = gcr_dir();

sub opt_spec {
    return (
        ['repo|r=s',   "Source repository for the audit", ],
        ['branch|b=s', "Branch in the repo to track",     ],
    );
}

sub description {
    my $DESC = <<"    EOH";

    This command is used to initialize an audit repository against a source code
    repository living elsewhere.  It uses submodules to acheive this.

    Usage:

        # Create a new audit repository
        mkdir /audits/user-repo.git
        cd /audits/user-repo.git
        git init --bare

        # Clone that to a work directory
        cd ~
        git clone /audits/user-repo.git

        # Initialize the code review
        git-code-review init --repo https://github.com/user/repo.git --branch master

    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my ($cmd,$opt,$args) = @_;

    # Pull, reset onto origin:master
    gcr_reset();

    # Check that we are not already initialized
    if(gcr_is_initialized()) {
        output({color=>'green'},"Already initialized!");
        exit 0;
    }
    # Check status of this repository
    my $audit = gcr_repo();
    my @files = grep !/README/, $audit->run('ls-files');
    if(@files) {
        output({color=>'red'}, "WARNING: This repository contains files!!");
        output({indent=>1}, "Git::Code::Review is designed to track your source repository as a submodule, you should start a separate remote for audits!");
        if(!confirm("Are you ABSOLUTELY SURE you want to continue?") || !confirm("This is about to get real. Take a deep breath and think again, are you sure?")) {
            output({color=>"cyan"}, "Wisely aborting on your command.");
            exit;
        }
        else {
            output({clear=>3,color=>'yellow'}, "You have been warned, dragons are the least of your concerns.");
        }
    }

    # Grab the URI
    my $repo = exists $opt->{repo} ? $opt->{repo}
            : prompt("Enter the source repository:", validate => { "need more than 3 characters" => sub { length $_ > 3 } });
    my $branch = exists $opt->{branch} ? $opt->{branch}
            : prompt("Branch to track (default=master) :");
    $branch ||= "master";

    # Initialize the sub module
    my $sub;
    my @out;
    {
        local *STDERR = *STDOUT;
        $sub = $audit->command(
                qw(submodule add --name source -b),
                $branch,
                $repo,
                'source'
        );
        debug({color=>'yellow'},  "CMD=" . join(' ', $sub->cmdline));
        @out = $sub->final_output();
    }
    if($sub->exit != 0) {
        output({stderr=>1,color=>'red'},"Submodule init failed, please try again");
        output({stderr=>1,color=>'yellow'}, map { "--| $_" } @out);
        gcr_reset();
        exit 1;
    }
    else {
        debug(map { "--| $_" } @out);
    }
    output({color=>"magenta"}, "Pulling source repository to complete submodule initialization, may take a few minutes.");
    debug({color=>'cyan'}, $audit->run(qw(submodule --init --remote --merge)));

    # Set our config directory for our artifacts;
    gcr_mkdir('.code-review');

    my $readme = File::Spec->catfile($AUDITDIR,'.code-review','README');
    if( !-e $readme ) {
        open(my $fh, '>', $readme) or die "cannot create file: $readme";
        print $fh "This directory will be used to store templates for emails.\n";
        close $fh;
        $audit->run(add => $readme);
    }

    my %details = (
        state       => 'init',
        reviewer    => $CFG{user},
        source_repo => $repo,
        branch      => $branch,
        audit_repo  => gcr_origin('audit'),
    );
    $audit->run(qw(commit -m), join("\n","Initializing source repository.",Dump(\%details)));
    gcr_push();
    output({color=>'green'},"+ Initialized repository, to get started `git-code-review help select`");
}

1;
