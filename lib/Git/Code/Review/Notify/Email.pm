# ABSTRACT: Notification by email
package Git::Code::Review::Notify::Email;

use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use MIME::Lite;
use File::Spec;
use Sys::Hostname qw(hostname);

# Globals
my %HEADERS = (
    'Importance'            => 'High',
    'Priority'              => 'urgent',
    'Sensitivity'           => 'company confidential',
    'X-Automation-Program'  => $0,
    'X-Automation-Function' => 'Code Review',
    'X-Automation-Server'   => hostname(),
);

sub send {
    shift @_ if ref $_[0] || $_[0] eq __PACKAGE__;
    my %config = @_;
    debug({color=>'magenta'}, "calling Git::Code::Review::Notify::Email::send");
    debug_var(\%config);

    # Need valid email properties
    unless( exists $config{to} && exists $config{from} ) {
        verbose({color=>'yellow'}, "Notify/Email - Insufficient email configuration, skipping.");
        return;
    }

    # Merge Headers
    foreach my $k (keys %HEADERS) {
        $config{headers} ||= {};
        $config{headers}->{$k} ||= $HEADERS{$k};
    }
    my $data = delete $config{message};
    die "Message empty" unless defined $data && length $data > 0;

    # Append meta-data
    if(exists $config{meta}) {
        $data .= "\n\n";
        $data .= "# $_\n" for @{ $config{meta} };
    }

    # Generate the email to send
    if( defined $data && length $data ) {
        debug("Evaluated template and received: ", $data);
        my $subject = sprintf 'Git::Code::Review [%s] on %s', $config{name}, gcr_origin('source');
        my $msg = MIME::Lite->new(
            From    => $config{from},
            To      => $config{to},
            Cc      => exists $config{cc} ? $config{cc} : [],
            Subject => $subject,
            Type    => exists $config{commit} ? 'multipart/mixed' : 'TEXT',
        );
        # Headers
        if (exists $config{headers} && ref $config{headers} eq 'HASH') {
            foreach my $k ( keys %{ $config{headers} }) {
                $msg->add($k => $config{headers}->{$k});
            }
        }

        # If this message is about a commit, let's attach it for clarity.
        if( exists $config{commit} && exists $config{commit}->{current_path} && -f $config{commit}->{current_path} ) {
            $msg->attach(
                Type => 'TEXT',
                Data => $data
            );
            $msg->attach(
                Type        => 'text/plain',
                Path        => $config{commit}->{current_path},
                Filename    => $config{commit}->{base},
                Disposition => 'attachment',
            );
        }
        else {
            $msg->data($data);
        }
        # Print out the happy email
        debug($msg->as_string);

        # Messaging
        if( exists $ENV{GCR_NOTIFY_EMAIL_DISABLED} && $ENV{GCR_NOTIFY_EMAIL_DISABLED} ){
            output({color=>'cyan',sticky=>1}, "Sending of email disable by environment variable, GCR_NOTIFY_EMAIL_DISABLED.");
            return;
        }
        verbose({color=>'cyan'}, "Sending notification email.");
        my $rc = eval {
            $msg->send();
            1;
        };
        if($rc == 1) {
            output({color=>'green'}, "Notification email sent.");
        }
    }

}

1;
