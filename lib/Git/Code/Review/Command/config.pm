# ABSTRACT: Manage global settings and templates for the code selection
package Git::Code::Review::Command::config;
use strict;
use warnings;

use CLI::Helpers qw(
    confirm
    output
    prompt
);
use Git::Code::Review -command;
use Git::Code::Review::Helpers qw(
    prompt_message
);
use Git::Code::Review::Utilities qw(:all);
use POSIX qw(strftime);
use YAML;


sub opt_spec {
    return (
        ['message|m|reason|r=s@',    "Reason for mucking with the config. If multiple -m options are given, their values are concatenated as separate paragraphs."],
    );
}

sub description {
    my $DESC = <<"    EOH";
    SYNOPSIS

        git-code-review config [options]

    DESCRIPTION

        This command allows managing of the global config files and templates for the code review.

    EXAMPLES

        git code-review config

        git code-review config -m "Adding new user to the review alerts"

    OPTIONS
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}


sub execute {
    my ($cmd,$opt,$args) = @_;
    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();
    die "Too many arguments: " . join( ' ', @$args ) if scalar @$args > 0;

    my $audit_dir = gcr_dir();
    my %cfg = gcr_config();
    my $audit = gcr_repo();
    gcr_reset();

    # We need a reason for this commit
    my $message = prompt_message( "Please provide the reason for the messing with the config(10+ chars):", $opt->{ message } );

    my %configs = (
        'mailhandler.config'  => 'Mail Configuration',
        'notification.config' => 'Notification Configuration',
        'review.config'       => 'Review Configuration',
        'special-days.txt'    => 'Special days to exclude',
        'README'              => 'Purpose, guidelines and other information',
    );
    my %templates = (
        'concerns'            => 'Template - concerns',
        'fixed'               => 'Template - fixed',
        'invalid_email'       => 'Template - invalid_email',
        'comments'            => 'Template - comments',
        'select'              => 'Template - select',
        'report'              => 'Template - report',
        'overdue'             => 'Template - overdue',
    );

    my %files = (
        ( map { $_ => $configs{ $_ } } keys %configs ),
        ( map { File::Spec->catfile( 'templates', $_ . ".tt" ) => $templates{ $_ } } keys %templates ),
    );
    my $action = undef;
    my @files_to_edit = ();
    $action = 'edit';
    my $file = prompt("Which file would you like to edit?", menu => \%files);

    # Configure the default if not there
    my $filename = _default_file( $file, \%cfg );
    unless(defined $filename && -f $filename) {
        output({stderr=>1,color=>"red"}, "Invalid config file, this shouldn't happen. ($filename)");
        exit 1;
    }
    push @files_to_edit, $filename;

    my @confirmed_files = ();
    # Edit files in the list.
    foreach my $filename (@files_to_edit) {
        gcr_open_editor(modify => $filename);
        if ( confirm( "Are you sure you want to make this change?" ) ) {
            $audit->run( add => $filename );
            push @confirmed_files, $filename;
        } else {
            # remove the file
            my @dirty = $audit->run( qw{ status --porcelain --ignore-submodules=all -- }, $filename );
            if ( my $status = shift @dirty ) {
                if ( substr( $status, 0, 2 ) eq '??' ) {
                    # untracked file - delete it
                    unlink $filename or warn output({stderr=>1,color=>"red"}, "Could not delete $filename: $!");
                } else {
                    # check out the old version
                    $audit->run( checkout => $filename );
                }
            }
        }
    }
    if ( scalar @confirmed_files ) {
        # commit and push any changes
        $audit->run( commit => '-m',
            join("\n", $message,
                Dump({
                    reviewer => $cfg{user},
                    state    => "config",
                    files    => \@confirmed_files,
                    skip     => 'true',
                }),
            )
        );
        gcr_push();
    }
}

sub _default_file {
    my ($file, $cfg) = @_;
    my %content = (
        'mailhandler.config' => [
            "; Mailhandler configuration",
            ';',
            ';[global]',
            ';  server = imap.mailserver.com',
            ';  port = 993',
            ';  ssl = 1',
            ';  credentials-file = /etc/code-review/sox_code_review_email.conf',
            ';  folder = INBOX',
            ';  auto-approve = 1',
        ],
        'notification.config' => [
            "; Notification Configuration for audit",
            ";   Valid headers are global and template where template takes a name",
            '; ',
            ';[global]',
            ";  from = $cfg->{user}",
            ";  headers.reply-to = $cfg->{user}",
            ';  jira-url = https://jira.company.com/jira',
            ';  jira-credential-file = /etc/code-review/jira.conf',
            '',
            ';[template "select"]',
            ";  to = $cfg->{user}",
            '',
            ';[template "report"]',
            ';  jira-title = Code Review Project',
            ';  jira-project = CRP',
            ';  jira-assignee = user',
            ';  to = codereview@company.com',
        ],
        'README' => [
            "README with the purpose, guidelines and other information for the code review",
        ],
        'special-days.txt' => [
            '# This is a simple text file containing a list of dates in yyyy-mm-dd format e.g. 2015-04-01',
            '# lines that begin with a # are ignored, you can also use a # at the end of the line',
            '# you can comma separate multiple dates on a single line or on multiple lines or both',
            '# white space is usually ignored',
            '',
            '#2015-04-01  # April fools day, no we do not give holiday to people for this',
            '',
            '# 2015 public holidays',
            "2015-01-01  # New Year's Day",
            '2015-04-03  # Friday	Good Friday',
            '2015-04-05  # Sunday	Easter Sunday',
            '2015-05-25  # Monday	Whit Monday',
            '2015-12-25, 2015-12-26  # Christmas and boxing day',
            '',
            '# 2015 special days',
            '2015-06-15  # Monday    Team outing',
            '',
            '# 2016 holidays',
            '2016-01-01  # new years day for next year',
            '',
            "# that's it, pretty simple huh?",
        ],
        'review.config' => [
            ';[labels.approve]',
            ';  cosmetic    = "Cosmetic change only, no functional difference."',
            ';  correct     = "Calculations are all accurate."',
            ';  outofbounds = "Changes are not in the bounds for the audit."',
            ';  other       = "Other (requires explanation)"',
            '',
            ';[labels.concerns]',
            ';  incorrect = "Calculations are incorrect."',
            ';  unclear = "Code is not clear, requires more information from the author."',
            ';  other = "Other"',
        ],
    );

    my $dir = gcr_mkdir( '.code-review' );
    my $filename = File::Spec->catfile($dir,$file);
    return $filename if -f $filename;
    open(my $fh, '>', $filename) or die "unable to create $filename: $!";
    print $fh "$_\n" for @{ $content{$file} || [ '' ] };
    close $fh;
    return $filename;
}

1;
