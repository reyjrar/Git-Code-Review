# ABSTRACT: Initialization hooks for git-code-review commands
package Git::Code::Review::Command::init;

use CLI::Helpers qw(:all);
use Git::Code::Review -command;
use Git::Code::Review::Utilities qw(:all);
use URI;
use YAML;

my %CFG = gcr_config();
my $AUDITDIR = gcr_dir();

sub description {
    my $DESC = <<"    EOH";
    git-code-review init - Initialize an audit repository

    This command is used to initialize an audit repository against a source code
    repository living elsewhere.  It uses submodules to acheive this.
    EOH
    $DESC =~ s/^\s{4}//mg;
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

    # Grab the URI
    my $uri;
    my $user_string = prompt "Enter the source repository:", validate => {
        "not a valid URI" => sub {
            $uri = URI->new($_);
            if(!defined $uri->scheme) {
                return -d $uri->as_string;
            }
            return 1;
        },
    };

    # Initialize the sub module
    my $audit = gcr_repo();
    my $cmd;
    my @out;
    {
        local *STDERR = *STDOUT;
        $cmd = $audit->command(
                qw(submodule add --name source),
                $uri->as_string,
                'source'
        );
        debug({color=>'yellow'},  "CMD=" . join(' ', $cmd->cmdline));
        @out = $cmd->final_output();
    }
    if($cmd->exit != 0) {
        output({stderr=>1,color=>'red'},"Submodule init failed, please try again");
        output({stderr=>1,color=>'yellow'}, map { "--| $_" } @out);
        gcr_reset();
        exit 1;
    }
    else {
        debug(map { "--| $_" } @out);
    }

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
        state => 'init',
        reviewer => $CFG{user},
        source_repo => $url,
        audit_repo => gcr_origin('audit'),
    );
    $audit->run(qw(commit -m), join("\n","Initializing source repository.",Dump(\%details)));
    gcr_push();
    output({color=>'green'},"+ Initialized repository, to get started `git-code-review help select`");
}

1;
