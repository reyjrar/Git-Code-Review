# ABSTRACT: Comment on a commit in the audit
package Git::Code::Review::Command::comment;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use File::Temp qw(tempfile);
use File::Spec;
use POSIX qw(strftime);
use YAML;

# Globals for easy access
my $AUDITDIR = gcr_dir();
my %CFG = gcr_config();

sub opt_spec {
    return (
        #    ['noop',       "Take no recorded actions."],
    );
}

sub description {
    my $DESC = <<"    EOH";

    This command allows a reviewer or author to comment on a commit and have
    that comment tracked in the audit.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my ($cmd,$opt,$args) = @_;
    my ($match) = @$args;

    my $audit = gcr_repo();
    gcr_reset();

    if( !defined $match ) {
        output({color=>'red'}, "Please specify a sha1 or .patch file to comment on.");
        exit 1;
    }
    my @list = grep { !/Locked/ } $audit->run('ls-files',"*$match*");
    if( @list == 0 ) {
        output({color=>"red"}, "Unable to locate any unlocked files matching '$match'");
        exit 0;
    }
    my $pick = $list[0];
    if( @list > 1 ) {
        $pick = prompt("Matched multiple commits, which would you like to comment on? ",menu => \@list);
    }
    my $commit = gcr_commit_info($pick);

    # Add the comment!
    my ($fh,$tmpfile) = tempfile();
    print $fh "\n"x2, map {"$_\n"}
        "# Commenting on $commit->{sha1}",
        "#  at $commit->{current_path}",
        "#  State is $commit->{state}",
        "# Lines begining with a '#' will be skipped.",
    ;
    close $fh;
    gcr_open_editor( modify => $tmpfile );
    # should have contents
    open($fh,"<", $tmpfile) or die "Tempfile($tmpfile) problems: $!";
    my @content = ();
    my $len = 0;
    my $blank = 0;
    while( <$fh> )  {
        next if /^#/;
        # Reduce blank lines to 1
        if ( /^\s*$/ ) {
            $blank++;
            next if $blank > 1;
        }
        else {
            $blank = 0;
        }
        $len += length;
        push @content, $_;
    }
    close $fh;
    eval {
        unlink $tmpfile;
    };
    my $comment_id = sprintf("%s-%s.txt",strftime('%F-%T',localtime),$CFG{user});
    my @comment_path = map { $_ eq 'Review' ? 'Comments' : $_; } File::Spec->splitdir( $commit->{review_path} );
    pop @comment_path if $comment_path[-1] =~ /\.patch$/;
    push @comment_path, $commit->{sha1};
    gcr_mkdir(@comment_path);

    my $repo_path = File::Spec->catfile(@comment_path,$comment_id);
    my $file_path = File::Spec->catfile($AUDITDIR,$repo_path);
    open($fh,">",$file_path) or die "Cannot create commment($file_path): $!";
    print $fh $_ for @content;
    close $fh;
    $audit->run( add => $repo_path );
    my $message = gcr_commit_message($commit,{state=>"comment",message=>join('',@content)});
    $audit->run( commit => '-m', $message);
    gcr_push();

}

1;
