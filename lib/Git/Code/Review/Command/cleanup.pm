# ABSTRACT: Fix any oddities in the structure
package Git::Code::Review::Command::cleanup;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use File::Spec;
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

    Cleanup the repository from any artifacts from bugs in previous versions.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    gcr_reset();
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    my $audit = gcr_repo();

    # START CHECK
    my $check = 'Orphanned commits in "Locked/" from pre 1.1 versions.';
    my $changes = 0;
    my $changed = 0;
    debug({color=>'cyan'}, sprintf '[CHECK] %s', $check);
    foreach my $file ($audit->run(qw(ls-files Locked/**.patch))) {
        my @path = File::Spec->splitdir($file);
        if(@path > 3) {
            my $profile = gcr_lookup_profile($path[-1]);
            my @new = @path;
            splice @new, 0, 1, $profile;
            my $new_path = File::Spec->catfile(@new);
            pop @new;
            gcr_mkdir(@new);
            debug({indent=>1}, "+ Moving $file to $new_path");
            $audit->run(mv => $file => $new_path);
            $changes++;
        }
    }
    if($changes) {
        $changed=1;
        my $message = "$check\n" . Dump({skip=>'true',state=>'cleanup'});
        $audit->run(commit => '-m' => $message);
        output({color=>'yellow'}, "Problems Corrected for: $check");
    }
    # END CHECK

    # PUSH
    if( $changed ) {
        output({color=>'magenta'}, "Pushing fixes upstream.");
        gcr_reset();
        gcr_push();
    }
    else {
        output({color=>'green'}, "No bug artifacts found, tree is clean. :)");
    }
}

1;
