package Git::Code::Review::Notify;

use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use MIME::Lite;
use File::Spec;
use Sys::Hostname qw(hostname);
use Template;
use Template::Stash;

# Globals
my %HEADERS = (
    'Importance'            => 'High',
    'Priority'              => 'urgent',
    'Sensitivity'           => 'company confidential',
    'X-Automation-Program'  => $0,
    'X-Automation-Function' => 'Code Review',
    'X-Automation-Server'   => hostname(),
);
my %TEMPLATES = (
    concerns => {},
    fixed    => {},
    select   => {},
);
my $TEMPLATE_DIR = gcr_mkdir('.code-review','templates');
$Template::Stash::HASH_OPS->{nsort_by_value} = sub {
    my ($hash) = @_;
    return sort { $hash->{$a} <=> $hash->{$b} } keys %{ $hash };
};
my $TEMPLATE = Template->new({
    INCLUDE_PATH => $TEMPLATE_DIR,
});

sub email {
    shift @_ if ref $_[0];
    my ($name,$opts) = @_;
    my %config = gcr_config();

    debug({color=>'magenta'}, "calling Git::Code::Review::Notify::email");
    debug_var($opts);
    debug_var(\%config);

    # Email settings
    my %email = (
        cc      => $config{user},
        headers => \%HEADERS
    );

    if( exists $config{notification} ) {
        # First load global
        foreach my $full_name (grep /^global\./, keys %{ $config{notification} }) {
            my $path = $full_name;
            $path =~ s/^global\.//;
            _add_value(\%email,$path => $config{notification}->{$full_name});
        }
        # Now try the specifics
        foreach my $full_name (grep /^template\.$name\./, keys %{ $config{notification} }) {
            my $path = $full_name;
            $path =~ s/^template\.$name\.//;
            _add_value(\%email,$path => $config{notification}->{$full_name});
        }
        # If this is about a commit, we move reviewer to cc;
    }
    # If this about a commit, we need reviewer in the to
    if( exists $opts->{commit} && exists $opts->{commit}{author} ) {
        _add_value(\%email,to => $opts->{commit}{author});
    }

    debug_var(\%email);

    # Need valid email properties
    unless( exists $email{to} && exists $email{from} ) {
        verbose({color=>'yellow'}, "Notify/Email - Insufficient email configuration, skipping.");
        return;
    }

    my %VARIABLES = (
        %{ $opts },
        config => \%config,
    );

    # Install Templates
    my %tmpl = Git::Code::Review::Notify::Templates::_install_templates();
    die "invalid template called for notify($name)" unless exists $tmpl{$name};


    my $data = '';
    $TEMPLATE->process("$name.tt", \%VARIABLES, \$data) || die "Error processing template($name): " . $TEMPLATE->error();

    debug("Evaluated template and received: ", $data);

}

sub _add_value {
    my ($dest,$key,$value) = @_;

    # Simplest
    if(!exists $dest->{$key}) {
       $dest->{$key} = $value;
       return;
    }

    # Both are string, create an array
    if(!ref $dest->{$key} && !ref $value) {
        $dest->{$key} = [ $dest->{$key}, $value ];
        return;
    }

    # Handle arrays
    if(ref $dest->{$key} eq 'ARRAY') {
        push @{ $dest->{$key} }, ref $value eq 'ARRAY' ? @{ $value } : $value;
        return;
    }

    die "something unsuccessfully happened merging data";
}


package Git::Code::Review::Notify::Templates;
use strict;
use warnings;
use Git::Code::Review::Utilities qw(gcr_mkdir gcr_repo gcr_push);
use File::Spec;

my %_DEFAULTS = (
    concerns => q{
        Greetings,

        [% config.user %] has raised concerns with a commit ([% commit.sha1 %]).  You may be able to
        assist with that concern.

        Reason: [% reason.short %]

        [% reason.details %]

        If this was corrected please respond to this message with:

        FIX=<SHA1 of the fixing commit>

        Or reply with details for the reviewer.
    },
    fixed => q{
        Greetings,

        [% config.user %] has marked [% commit.sha1 %] as fixed!

        Reason: [% reason.short %]

        [% reason.details %]

        No further action is necessary.
    },
    select => q{
        Greetings,

        [% config.user %] has performed a selection of commits for audit.

        Reason: [% reason %]

        The pool of eligible commits was [% pool.total %] and [% pool.selected %] were
        selected from that pool.

        Pool details:
        -------------
        [% FOREACH key IN pool.matches.nsort_by_value.reverse -%]
          ~ [% key %] => [%=pool.matches.$key %]
        [% END -%]

        Selected commits:
        ----------------
        [% FOREACH commit IN pool.selection -%]
          * [% commit.sha1 %]    [% commit.date %]    [% commit.author %]
        [% END -%]
    },
);


sub _install_templates {
    my %templates = ();
    $TEMPLATE_DIR ||= gcr_mkdir('.code-review','templates');
    my $repo = gcr_repo();

    my $new = 0;
    foreach my $tmpl (keys %_DEFAULTS) {
        my $file = File::Spec->catfile($TEMPLATE_DIR, "${tmpl}.tt");
        $templates{$tmpl} = $file;
        next if -f $file;
        $new++;
        open my $fh, '>', $file or die "unable to create template file $file: $!";
        my $content = $_DEFAULTS{$tmpl};
        $content =~ s/^[ ]{8}//mg; # strip the leading spaces
        print $fh $content;
        close $fh;
        $repo->run(add => $file);
    }
    if( $new > 0 ) {
        my $details = join("\n",
            '---',
            'state: template_creation',
            'skip: true',
            ''
        );
        $repo->run(commit => '-m' => $details);
        gcr_push();
    }

    return wantarray ? %templates : { %templates };
}
