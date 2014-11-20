# ABSTRACT: Manage replies to the code review mailbox
package Git::Code::Review::Command::mailhandler;
use strict;
use warnings;

use CLI::Helpers qw(:all);
use Config::Auto;
use DateTime::Format::Mail;
use Email::Address;
use Email::Simple;
use Email::MIME;
use File::Spec;
use Git::Code::Review::Utilities qw(:all);
use Git::Code::Review -command;
use Mail::IMAPClient;
use Mojo::DOM;
use Text::Wrap qw(fill);
use YAML;

my %CONFIG = gcr_config();
die "No mailhandler.config found!" unless exists $CONFIG{mailhandler};

sub opt_spec {
    return (
           ['server:s',           "IMAP Server",                      {default=>exists $CONFIG{mailhandler}->{'global.server'}  ? $CONFIG{mailhandler}->{'global.server'} : 'localhost' }],
           ['port:i',             "IMAP Server Port",                 {default=>exists $CONFIG{mailhandler}->{'global.port'}    ? $CONFIG{mailhandler}->{'global.port'} : 993 }],
           ['folder:s',           "IMAP Folder to scan",              {default=>exists $CONFIG{mailhandler}->{'global.folder'}  ? $CONFIG{mailhandler}->{'global.folder'} : 'INBOX' }],
           ['ssl!',               "Use SSL, default yes",             {default=>1}],
           ['credentials-file:s', "Location of the Credentials File", {default=>exists $CONFIG{mailhandler}->{'global.credentials-file'}  ? $CONFIG{mailhandler}->{'global.credentials-file'} : '/etc/code-review/mailhandler.config' }],
    );
}

sub description {
    my $DESC = <<"    EOH";

    Display information about the Git::Code::Review objects.
    EOH
    $DESC =~ s/^[ ]{4}//mg;
    return $DESC;
}

sub execute {
    my($cmd,$opt,$args) = @_;

    die "Not initialized, run git-code-review init!" unless gcr_is_initialized();

    debug({color=>'cyan'},"Git::Code::Review Mailhandler Config");
    debug_var($opt);
    debug({clear => 1}, "Defaults");
    debug(Dump $CONFIG{mailhandler});

    my @missing=();
    foreach my $required(qw(credentials_file server)) {
        push @missing, $required unless exists $opt->{$required};
    }
    if(@missing) {
        output({color=>'red',stderr=>1}, sprintf "Missing required options: %s", join(', ', map { s/\_/-/g; } @missing));
        exit 1;
    }

    # Parse the config file
    my $creds = Config::Auto::parse($opt->{credentials_file});

    # Try to grab the username/password
    my %mapping = (
            username => [qw(user username)],
            password => [qw(pass passwd password)],
    );
    my %credentials = ();
    foreach my $key (keys %mapping) {
        foreach my $try (@{ $mapping{$key} }) {
            next unless exists $creds->{$try};
            $credentials{$key} = $creds->{$try};
            last;
        }
        if(!exists $credentials{$key}) {
            output({color=>'red',stderr=>1}, "Unable to find the '$key' in $opt->{credentials_file}");
            exit 1;
        }
    }
    my $imap = Mail::IMAPClient->new(
        Server   => $opt->{server},
        Port     => $opt->{port},
        Ssl      => $opt->{ssl},
        User     => $credentials{username},
        Password => $credentials{password},
    ) or die "Unable to connect to $opt->{server}: $@";
    verbose({color=>'green'}, sprintf "Successfully connected to %s as %s.", $opt->{server}, $credentials{username});

    my @folders = $imap->folders;
    debug({indent=>1}, "+ Folders discovered: " . join(', ', @folders));

    $imap->select($opt->{folder});

    my @unseen = $imap->unseen();
    verbose({indent=>1}, sprintf "+ Found %d unread messages.", scalar(@unseen));

    # Reset these all the time
    my @EnvRelative = qw(
            GIT_AUTHOR_NAME
            GIT_AUTHOR_EMAIL
            GIT_AUTHOR_DATE
    );
    my %precedence;
    @precedence{qw(bulk junk auto_reply)} = ();

    my $refreshed = 0;
    foreach my $msg (@unseen) {
        # Reset key environment variables
        delete $ENV{$_} for @EnvRelative;
        debug({indent=>1}, "Processing $msg");
        # Basic Accessors
        my $email = Email::Simple->new($imap->message_string($msg));
        # For handling multipart messages without fucking everything up
        my $mime  = Email::MIME->new($imap->message_string($msg));

        my $body = undef;
        my @parts = $mime->subparts;
        if( @parts ) {
            foreach my $part (@parts) {
                debug({color=>'magenta'},sprintf "Subpart discovered is %s", $part->content_type);
                if ($part->content_type =~ m[text/plain]) {
                    $body = $part->body_str;
                    last;
                }
                elsif($part->content_type =~ m[text/html]) {
                    my $dom = Mojo::DOM->new($part->body);
                    $body = $dom->all_text;
                }
            }
        }
        $body ||= $mime->body_str;
        debug({color=>'magenta'}, $body);

        my %headers = $email->header_pairs;

        next if exists $headers{'X-Autoreply-Sent-To'};          # Out Of Office
        next if exists $headers{'X-Autorespond'};                # Out Of Office
        next if exists $headers{Precedence} and exists $precedence{lc $headers{Precedence}};  # Out of Office
        # Get Date
        my $received_dt = DateTime::Format::Mail->parse_datetime($headers{Date});
        next unless $received_dt;

        $ENV{GIT_AUTHOR_DATE} = $received_dt->datetime();

        # Get From Addresses
        my $addr;
        eval {
            ($addr) = Email::Address->parse($headers{From});
            debug(sprintf "Found: name='%s', email='%s' (%s)", $addr->name, $addr->address, $addr->original);
            $ENV{GIT_AUTHOR_NAME} = $addr->name;
            $ENV{GIT_AUTHOR_EMAIL} = $addr->address;
        };
        next unless $addr;
        debug("$_ => $ENV{$_}") for @EnvRelative;

        my @message = ();
        my %vars = ();
        my $fallback;
        for(split /\r?\n/, $body) {
            if ( my ($key,$value) = (/GCR_([^=]+)=(\S+)/) ) {
                $vars{lc $key} = $value;
            }
            elsif( my ($fixed) = (/FIX=([a-f0-9]{6,40})/) ) {
                $vars{fixed} = $fixed;
            }
            elsif( my ($sha1) = /^>?\s*([a-f0-9]{6,40})\s*$/ ) {
                $fallback ||= $sha1;
            }
            elsif( /^\s*>+/ || /^(?:\s*>)?\s*On.*wrote:$/  ) {
                # skip;
            }
            else {
                push @message, $_;
            }
        }
        if(!exists $vars{commit}) {
            # Try antique stuff
            if ( my ($sha1) = ($headers{Subject} =~ /COMMIT=([0-9a-f]{6,40})/) ) {
                $vars{commit} = $sha1;
            }
            elsif (defined $fallback && length $fallback == 40) {
                $vars{commit} = $fallback;
            }
        }
        next unless exists $vars{commit};
        verbose("Processing Message relating to $vars{commit}");

        # Start modifying the audit
        my $audit  = gcr_repo();
        my $source = gcr_repo('source');
        unless( $refreshed ) {
            gcr_reset($_) for qw(audit source);
            $refreshed++;
        }

        my $commit = undef;
        eval {
            $commit = gcr_commit_info($vars{commit});
        };
        if(!defined $commit) {
            $imap->deny_seeing($msg);
            output({color=>'red'}, "Unable to locate commit object $vars{commit}");
            next;
        }

        debug({color=>'cyan'}, "Commit Object");
        debug_var($commit);

        pop @message while @message and $message[-1] =~ /^\s*$/;
        $vars{message} = fill("", "", @message);

        if( exists $vars{fixed} ) {
            debug({color=>'green'}, sprintf "FIXED: audit:%s by source:%s", $vars{commit}, $vars{fixed});
            if( $commit->{state} eq 'approved' ) {
                output({color=>'yellow',indent=>1}, "Commit $vars{commit} is already approved.");
                next;
            }
            my @commits = $source->run(split /\s+/, qq{log -r $vars{fixed}  -n 1 --pretty=format:%H});
            if (@commits != 1) {
                output({color=>'red', indent=>1}, sprintf "%s commit in source repo: %s, %d entries.",
                            (@commits ? 'Ambiguous' : 'Invalid'), $vars{commit}, scalar(@commits)
                );
                if( $received_dt->epoch > time - 86400 ) {
                    $imap->deny_seeing($msg);
                }
                next;
            }
            gcr_change_state($commit, approved => { fixed_by => $commits[0], reason => 'fixed', profile => $commit->{profile}, message => $vars{message} });
        }
        else {
            # Add Comments
            my $comment_id = sprintf('%s-%s.txt', $received_dt->strftime('%F-%T'), $ENV{GIT_AUTHOR_EMAIL});
            my @comment_path = map { $_ eq 'Review' ? 'Comments' : $_ } File::Spec->splitdir($commit->{review_path});
            pop @comment_path if $comment_path[-1] =~ /\.patch$/;
            push @comment_path, $commit->{sha1};
            gcr_mkdir(@comment_path);

            my $repo_path = File::Spec->catfile(@comment_path, $comment_id);
            my $file_path = File::Spec->catfile(gcr_dir(), $repo_path);
            if (-f $file_path) {
                output({color=>'yellow'}, "Comment $repo_path already exists.");
                next;
            }
            open(my $fh,">",$file_path) or die "Cannot create comment($file_path): $!";
            print $fh $vars{message};
            close $fh;
            $audit->run(add => $repo_path);
            my $message = gcr_commit_message($commit,{state=>'comment',message=>$vars{message}});
            $audit->run(commit => '-m', $message);
            gcr_push();
        }
    }

}

1;
