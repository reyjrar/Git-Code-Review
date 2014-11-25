# ABSTRACT: Notification framework
package Git::Code::Review::Notify;

use strict;
use warnings;

use CLI::Helpers qw(:all);
use Git::Code::Review::Utilities qw(:all);
use File::Spec;
use Sys::Hostname qw(hostname);
use Template;
use Template::Stash;

use Module::Pluggable (
    search_path => [ 'Git::Code::Review::Notify' ],
    except      => 'Git::Code::Review::Notify::Templates',
    sub_name    => 'notifications',
    require     => 1,
);
my $PROFILE = gcr_profile();

# Configure the Templates
my @TEMPLATE_DIR = ( gcr_mkdir('.code-review','templates') );
my $PROFILE_DIR = File::Spec->catdir(gcr_dir(), qw(.code-review profiles),$PROFILE,'templates');
unshift @TEMPLATE_DIR, $PROFILE_DIR if -d $PROFILE_DIR;
$Template::Stash::HASH_OPS->{nsort_by_value} = sub {
    my ($hash) = @_;
    return sort { $hash->{$a} <=> $hash->{$b} } keys %{ $hash };
};
my $TEMPLATE = Template->new({
    INCLUDE_PATH => \@TEMPLATE_DIR,
});

sub notify {
    shift @_ if ref $_[0];
    my ($name,$opts) = @_;
    my %config = gcr_config();

    debug({color=>'magenta'}, "called Git::Code::Review::Notify::notify");
    debug_var($opts);
    debug("Template search path");
    debug_var(\@TEMPLATE_DIR);

    # Plugin Settings
    my %Plugins = (
        cc => $config{user},
    );

    # Handle Setup
    if( exists $config{notification} ) {
        # First load global
        foreach my $full_name (grep /^global\./, keys %{ $config{notification} }) {
            my $path = $full_name;
            $path =~ s/^global\.//;
            _add_value(\%Plugins,$path => $config{notification}->{$full_name});
        }
        # Now try the specifics
        foreach my $full_name (grep /^template\.$name\./, keys %{ $config{notification} }) {
            my $path = $full_name;
            $path =~ s/^template\.$name\.//;
            _add_value(\%Plugins,$path => $config{notification}->{$full_name});
        }
        # If this about a commit, we make the author a 'to'
        if( exists $opts->{commit} && exists $opts->{commit}{author} ) {
            _add_value(\%Plugins,to => $opts->{commit}{author});
        }
    }
    $Plugins{from} = $config{user} unless exists $Plugins{from};
    debug_var(\%Plugins);

    my %VARIABLES = (
        %{ $opts },
        origins => { map { $_ => gcr_origin($_) } qw(audit source) },
        config  => \%config,
    );
    debug_var(\%VARIABLES);

    # Install Templates
    my %tmpl = Git::Code::Review::Notify::Templates::_install_templates();
    die "invalid template called for notify($name)" unless exists $tmpl{$name};

    # Generate the content of the message
    my $message = '';
    $TEMPLATE->process("$name.tt", \%VARIABLES, \$message) || die "Error processing template($name): " . $TEMPLATE->error();

    foreach my $hook (Git::Code::Review::Notify->notifications()) {
        eval {
            $hook->send(
                %Plugins,
                %{ $opts },
                name     => $name,
                message  => $message,
            );
        };
        if( my $err = $@ ) {
            output({color=>'red'}, "Error calling $hook\->send(): $err");
            next;
        }
    }
}

sub _add_value {
    my ($dest,$path,$value) = @_;

    # Determine key and the ref
    my @path = split /\./, $path;
    my $key = pop @path;
    my $ref = $dest;
    foreach my $sub (@path) {
        # Initialize the sub element
        $ref->{$sub} = exists $ref->{$sub} ? $ref->{$sub} : {};
        # Advance the pointer.
        $ref = $ref->{$sub};
    }

    # Simplest
    if(!exists $ref->{$key} || $key eq 'from') {
       $ref->{$key} = $value;
    }
    # Both are string, create an array
    elsif(!ref $ref->{$key} && !ref $value) {
        $ref->{$key} = [ $ref->{$key}, $value ];
    }
    # Handle arrays
    elsif(ref $ref->{$key} eq 'ARRAY') {
        if (ref $value eq 'ARRAY') {
            $ref->{$key} = [@{ $ref->{$key} },@{$value}];
        }
        else {
            push @{ $ref->{$key} }, ref $value eq 'ARRAY' ? @{ $value } : $value;
        }
    }
    # If we wind up with an array, de-dupe it
    if (ref $ref->{$key} eq 'ARRAY') {
        # De-dupe
        my %hash = map {$_=>1} @{ $ref->{$key} };
        $ref->{$key} = [keys %hash];
    }
}


package Git::Code::Review::Notify::Templates;
use strict;
use warnings;
use Git::Code::Review::Utilities qw(gcr_mkdir gcr_repo gcr_push);
use File::Spec;

my %_DEFAULTS = (
    concerns => q{
        Greetings,

        [% config.user %] has raised concerns with a commit ([% commit.sha1 %]).
        You may be able to assist with that concern.

        Reason: [% reason.short %]

        Details: [% reason.details %]

        If this was corrected please respond to this message with:

        FIX=<SHA1 of the fixing commit>

        Or reply with details for the reviewer.
    },
    fixed => q{
        Greetings,

        [% config.user %] has marked [% commit.sha1 %] as fixed!

        Reason: [% reason.short %]

        Details: [% reason.details %]

        No further action is necessary.
    },
    invalid_email => q{
        The email you sent to [% rcpt %] is not valid because:

        [% reason %]

        Your email was ignored was ignored by the Automaton.

        If it was a response to an email that Git::Code::Review sent you,
        please review that email and follow any instructions explicitly.

        You wanted to say:
        [% FOREACH line IN message -%]
        > [% line %]
        [% END -%]
    },
    comments => q{
        The commit [% commit.sha1 %] you flagged concerns has been commented on
        by [% commenter %].  The user did not provide a FIX hash, so please review
        those comments and take appropriate action.

        You, [% reviewer %] were determined to be the reviewer.

        You can view the history of the audit on the commit by:

            git-code-review show [% commit.sha1 %] --verbose

        You can move the commit to approved by:

            git-code-review approve [% commit.sha1 %]

        Follow the prompts to approve the commit.

        Comments by [% commenter %]:
        [% FOREACH line IN message -%]
        > [% line %]
        [% END -%]

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
    report => q{
        [% USE format -%]
        [% USE td         = format('%9s |') -%]
        [% USE th         = format('|| %12s |') -%]
        [% SET states     = [ 'approved', 'concerns', 'locked', 'review' ] -%]
        [% SET simple     = [ 'complete', 'todo' ] -%]

        Commit Status [% options.exists('since') ? options.since : '' %] through [% options.until %]
        ----
        [% IF commits.keys.size > 0 -%]
        [% th('profile') %]
        [%- FOREACH col IN states -%]
            [%- td(col) %]
        [%- END %]
        [% FOREACH profile IN commits.keys.sort -%]
            [%- NEXT IF profile.length == 0 -%]
            [%- th(profile) %]
            [%- FOREACH state IN states -%]
                [%- td(commits.$profile.exists(state) ? commits.$profile.$state : 0) %]
            [%- END %]
        [% END -%]
        [% ELSE -%]
            (i) Nothing to report.
        [% END -%]



        History [% options.exists('since') ? options.since : '' %] through [% options.until %]
        ----
        [% IF monthly.keys.size > 0 -%]
        [% th('state') %]
        [%- FOREACH month IN monthly.keys.sort -%]
            [%- td(month) %]
        [%- END %]
        [% FOREACH state IN simple -%]
            [%- th(state) -%]
            [%- FOREACH month IN monthly.keys.sort -%]
                [%- td(monthly.$month.exists(state) ? monthly.$month.$state : 0) %]
            [%- END %]
        [% END -%]
        [% ELSE -%]
            (i) Nothing to report.
        [% END -%]



        Active Concerns through [% options.until %]
        ----
        [% IF concerns.keys.size > 0 -%]
        [% FOREACH sha1 IN concerns.keys.sort -%]
            [%- SET icon = concerns.$sha1.commit.state == 'approved' ? '(/)' : '(x)' -%]

            [% icon %] [% sha1 %] is now *[% concerns.$sha1.commit.state %]*
            * [% concerns.$sha1.commit.date %] authored by [% concerns.$sha1.commit.by %]
            * [% concerns.$sha1.concern.date %] raised for *[% concerns.$sha1.concern.reason %]* by [% concerns.$sha1.concern.by %]
        [% IF concerns.$sha1.exists('log') -%]
        [% FOREACH log IN concerns.$sha1.log -%]
            * [% log.date %] [% log.state %] by [% log.by %] [% IF log.exists('reason') -%] for reason *[% log.reason %]*[% END %]
        [% END -%]
        [% END -%]
        [% END -%]
        [% ELSE -%]
            (/) No concerns raised.
        [% END -%]
    },
    overdue => q{
        # Overview of Commits older than [% options.age %] days old.

        [% FOREACH profile IN profiles.keys.sort -%]
        [% NEXT IF !profiles.$profile.exists('total') -%]
        [% NEXT IF profiles.$profile.total <= 0 -%]
        [% profile %]: [% profiles.$profile.total %]
        [% FOREACH month IN profiles.$profile.keys.sort -%]
            [%- NEXT IF month == "total" -%]
            [% month %]: [% profiles.$profile.$month %]
        [% END %]
        [% END -%]

        [% IF concerns.keys.size > 0 -%]
        [% FOREACH profile IN concerns.keys.sort -%]
        [% concerns.$profile.keys.size %] Active [% profile.ucfirst %] Concerns
        ----
        [% FOREACH sha1 IN concerns.$profile.keys.sort -%]
        [% sha1 %]
          * [% concerns.$profile.$sha1.commit.date %] authored by [% concerns.$profile.$sha1.commit.by %]
          * [% concerns.$profile.$sha1.concern.date %] raised for *[% concerns.$profile.$sha1.concern.reason %]* by [% concerns.$profile.$sha1.concern.by %]

        [% FILTER indent('  ') -%]
        [% concerns.$profile.$sha1.concern.explanation %]
        [% END -%]

        [% END -%]
        [% END -%]
        [% END -%]
    },
);

sub _install_templates {
    my %templates = ();
    my $TEMPLATE_DIR ||= gcr_mkdir('.code-review','templates');
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
