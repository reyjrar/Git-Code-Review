# ABSTRACT: Tools for performing code review using Git as the backend
package Git::Code::Review::Utilities;
use strict;
use warnings;

# VERSION

# Utility Modules
use CLI::Helpers qw(:all);
use Config::GitLike;
use Cwd;
use File::Basename;
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long qw(:config pass_through);
use Git::Repository qw( Log );
use Hash::Merge;
use POSIX qw(strftime);
use Sys::Hostname;
use YAML;

# Setup the exporter
use Sub::Exporter -setup => {
    exports => [qw(
        gcr_dir
        gcr_is_initialized
        gcr_config
        gcr_mkdir
        gcr_repo
        gcr_origin
        gcr_reset
        gcr_push
        gcr_profile
        gcr_profiles
        gcr_open_editor
        gcr_view_commit
        gcr_view_commit_files
        gcr_change_profile
        gcr_change_state
        gcr_not_resigned
        gcr_not_authored
        gcr_commit_exists
        gcr_commit_info
        gcr_commit_message
        gcr_commit_profile
        gcr_audit_commit
        gcr_audit_files
        gcr_audit_record
        gcr_state_color
    )],
};

# Global Options
our $_OPTIONS_PARSED;
my %_OPTIONS=();
if( !$_OPTIONS_PARSED ) {
    GetOptions(\%_OPTIONS,
        'profile:s'
    );
}


# Global Lexicals
my $GITRC = Config::GitLike->new(confname => 'gitconfig');
my $AUDITDIR = getcwd();

# Editors supported
my %EDITOR = (
    vim   => { readonly => [qw(-R)], modify => [] },
    vi    => { readonly => [qw(-R)], modify => [] },
    nano  => { readonly => [qw(-R)], modify => [] },
    emacs => { __POSTFIX__ => 1 , readonly => ['--eval','(setq buffer-read-only t)'], modify => [] },
);
# States of a Commit
my %STATE = (
    'locked'   => { type => 'user',   name  => 'Locked',      color => 'cyan'   },
    'review'   => { type => 'reset',  field => 'review_path', color => 'yellow' },
    'approved' => { type => 'global', name  => 'Approved',    color => 'green'  },
    'concerns' => { type => 'global', name  => 'Concerns',    color => 'red'    },
    'comment'  => { type => 'global', name  => 'Comments',    color => 'white'  },
);
# General Config options
my %CFG = (
    editor => exists $ENV{EDITOR} && exists $EDITOR{$ENV{EDITOR}} ? $ENV{EDITOR} : 'vim',
);
my %PATHS   = (
    audit  => getcwd(),
    source => File::Spec->catdir($AUDITDIR,'source'),
);
my %ORIGINS = ();
my %REPOS   = ();

=func gcr_dir()

Returns the audit directory

=cut
sub gcr_dir {
    return $AUDITDIR;
}

=func gcr_profile(exists => 1)

Return the user's requested profile based on:
  ~/.gitconfig
  --profile
  default

You can override the exists functionality by passing exists => 0;

=cut
my $_profile;
sub gcr_profile {
    my %checks = (
        exists => 1,
        @_
    );
    return $_profile if defined $_profile;

    $_profile = $GITRC->get(key => 'code-review.profile');
    $_profile = $_OPTIONS{profile} if exists $_OPTIONS{profile};
    if( $_profile && $checks{exists} && $_profile ne 'default' ) {
        my $profile_dir = File::Spec->catdir($AUDITDIR,qw{.code-review profiles},$_profile);
        if( !-d $profile_dir ) {
            output({stderr=>1,color=>'red'}, "Invalid profile: $_profile, missing $profile_dir");
            exit 1;
        }
    }
    $_profile ||= 'default';

    return $_profile;
}

=func gcr_profiles()

Returns a list of profiles with a selection file available

=cut

sub gcr_profiles {
    my $repo = gcr_repo();
    my @files = $repo->run('ls-files', '*/selection.yaml');
    my %profiles = (default => 1);
    foreach my $file (@files) {
        my @parts = File::Spec->splitdir($file);
        $profiles{$parts[-2]} = 1;
    }
    return wantarray ? sort keys %profiles : [ sort keys %profiles ];
}

=func gcr_config()

Returns a copy of our configuration as a hash or hash ref.

=cut
my %_config = ();
sub gcr_config {

    my $merge = Hash::Merge->new('STORAGE_PRECEDENT');
    if(!keys %_config) {
        %_config = %CFG;

        my %gitrc = qw(
            user.email              user
            code-review.record_time record_time
        );

        foreach my $k (keys %gitrc) {
            my $v = $GITRC->get(key => $k);
            next unless defined $v;
            $_config{$gitrc{$k}} = $v;
        }

        foreach my $sub (qw(notification)) {
            my @files = (
                File::Spec->catfile($AUDITDIR,'.code-review',"${sub}.config"),
                File::Spec->catfile($AUDITDIR,qw(.code-review profiles),gcr_profile(exists => 0),"${sub}.config")
            );
            debug("attempting to config for $sub");
            my @configs = ();
            foreach my $file (@files) {
                next unless -f $file;
                eval {
                    my $c = Config::GitLike->load_file($file);
                    push @configs, $c;
                };
            }
            next unless @configs;
            $_config{$sub} = @configs > 1 ? $merge->merge(@configs) : $configs[0];
        }

        %CFG = %_config;
    }
    return wantarray ? %_config : { %_config };
}

=func gcr_is_initialized()

=cut
sub gcr_is_initialized {
    my $audit = gcr_repo();
    my $url = $audit->run(qw(config submodule.source.url));
    my $submodule_init = !!(defined $url && length $url);

    # Initialized and happy return
    return $submodule_init if $submodule_init;

    # Try to initialize the submodule
    eval {
        $audit->run(qw(submodule init));
    };
    if(my $err = $@) {
        die "git submodule init failed: $err";
    }
    # Try again.
    $url = $audit->run(qw(config submodule.source.url));
    return !!(defined $url && length $url);
}

=func gcr_repo()

Returns the Git::Repository object for audit or source repos

=cut
sub gcr_repo {
    my ($type) = @_;
    $type ||= 'audit';
    return unless exists $PATHS{$type};
    return $REPOS{$type} if exists $REPOS{$type};
    my $repo;
    eval {
        gcr_config();
        $repo = Git::Repository->new( work_tree => $PATHS{$type} );
    };
    die "invalid repository/path($type=$PATHS{$type}) : $@" unless defined $repo;
    return $REPOS{$type} = $repo;
}

=func gcr_mkdir(@path)

Takes a directory path as a list and creates the path inside the audit directory.

=cut
sub gcr_mkdir {
    my (@input) = @_;
    my @path = ();
    push @path, File::Spec->splitdir($_) for @input;
    my $dir = $AUDITDIR;
    foreach my $sub (@path) {
        $dir = File::Spec->catdir($dir,$sub);
        mkdir($dir,0755) unless -d $dir;
    }
    debug("audit_mkdir() created $dir");
    return $dir;
}

=func gcr_origin($type)

Lookup the remote 'origin' for 'audit' or 'source'

=cut
sub gcr_origin {
    my ($type) = @_;
    my $audit = gcr_repo();

    return unless exists $PATHS{$type};
    return $ORIGINS{$type} if exists $ORIGINS{$type};

    my @remotes;
    if ($type eq 'audit') {
        @remotes = $audit->run(qw(config remote.origin.url));
    }
    elsif($type eq 'source') {
        @remotes = $audit->run(qw(config submodule.source.url));
    }
    else {
        # I don't know what you're trying, but something isn't going to succesfully happen
        warn "invalid origin lookup '$type' (must be audit or source)";
    }
    my $url = @remotes ? $remotes[0] : undef;
    $ORIGINS{$type} = $url if defined $url;
    return $url;
}

=func gcr_reset()

Reset the audit directory to origin:master, stash weirdness.  Most operations call this first.

=cut
sub gcr_reset {
    my ($type) = @_;
    $type ||= 'audit';
    my $audit = gcr_repo('audit');
    # Stash any local changes, and pull master
    if( $type eq 'audit' ) {
        verbose({color=>'magenta'},"+ [$type] Reseting repository any changes will be stashed.");
        my $origin = gcr_origin('audit');
        if(defined $origin) {
            verbose({level=>2},"= Found origin, checking working tree status.");
            my @dirty = $audit->run(qw{status -s});
            if( @dirty ) {
                verbose({color=>'yellow'},"! Audit working tree is dirty, stashing files");
                $audit->run($type eq 'audit' ? qw{stash -u} : qw(reset --hard));
            }
            verbose({level=>2,color=>'cyan'},"= Swithcing to master branch.");
            eval {
                $audit->run(qw(checkout master));
            };
            if( my $err = $@ ) {
                if( $err !~ /A branch named 'master'/ ) {
                    output({stderr=>1,color=>'red'}, "Error setting to master branch: $err");
                    exit 1;
                }
                debug({color=>'red'}, "!! $err");
            }
            verbose({level=>2,color=>'cyan'},"+ Initiating pull from $origin");
            local *STDERR = *STDOUT;
            my @output = $audit->run(
                $type eq 'audit' ? qw(pull origin master) : 'pull'
            );
            debug({color=>'magenta'}, @output);
        }
        else {
            die "no remote 'origin' available!";
        }
    }
    elsif( $type eq 'source' ) {
        # Submodule reset includes incrementing the submodule pointer.
        output({color=>'magenta'}, "Pulling the source repository.");
        debug({color=>'cyan'},$audit->run(qw(submodule update --init --remote --merge)));
    }
    else {
        output({stderr=>1,color=>'red'}, "gcr_reset('$type') is not known, going to kill myself to prevent bad things.");
        exit 1;
    }
}

=func gcr_push()

Push any modifications upstream.

=cut
sub gcr_push {
    my $audit = gcr_repo();
    # Safely handle the push to the repository
    gcr_reset();
    output({color=>"cyan"},"+ Pushing to origin:master");
    local *STDERR = *STDOUT;
    debug($audit->run(qw(push origin master)));
}

=func gcr_commit_exists($sha1 | $partial_sha1 | $path)

Returns 1 if the commit is in the audit already, or 0 otehrwise

=cut
sub gcr_commit_exists {
    my ($object) = @_;
    my $audit = gcr_repo();
    my @matches = $audit->run('ls-files', "*$object*");
    return @matches > 0;
}


=func gcr_commit_info($sha1 | $partial_sha1 | $path)

Retrieves all relevant Git::Code::Review details on the commit
that mataches the string passed in.

=cut
sub gcr_commit_info {
    my ($object) = @_;
    my $audit = gcr_repo();
    # Object can be a sha1, path in the repo, or patch
    my ($_line,$_sub) = (caller 1)[2,3];

    my @matches = $audit->run('ls-files', "*$object*");
    if( @matches != 1 ) {
        die sprintf('gcr_commit_info("%s") %s commit object: %s line %d', $object, (@matches > 1 ? 'ambiguous' : 'unknown'), $_sub, $_line);
    }
    my %commit = (
        base         => basename($matches[0]),
        date         => _get_commit_date($matches[0]),
        current_path => $matches[0],
        review_path  => _get_review_path($matches[0]),
        review_time  => 'na',
        state        => _get_state($matches[0]),
        author       => _get_author($matches[0]),
        profile      => _get_commit_profile($matches[0]),
        reviewer     => $CFG{user},
        source_repo  => gcr_origin('source'),
        audit_repo   => gcr_origin('audit'),
        sha1         => _get_sha1(basename($matches[0])),
    );

    return wantarray ? %commit : \%commit;
}

=func gcr_commit_profile(sha1)

Find and return the profile for the commit.

=cut
sub gcr_commit_profile {
    my ($object) = @_;
    my ($_line,$_sub) = (caller 1)[2,3];

    die "Invalid call to gcr_commit_profile() from  $_sub at $_line" unless $object;

    my $audit = gcr_repo();
    # Object can be a sha1, path in the repo, or patch
    my @matches = $audit->run('ls-files', "*$object*");
    if( @matches != 1 ) {
        verbose({color=>'yellow',indent=>1}, sprintf 'gcr_commit_profile("%s") %s commit object from %s line %d', $object, (@matches > 1 ? 'ambiguous' : 'unknown'), $_sub, $_line);
        return;
    }

    return _get_commit_profile($matches[0]);
}

=func gcr_open_editor( mode => file )

    Mode can be: readonly, modify

    File is the file to be opened

=cut
my %timing=();
sub gcr_open_editor {
    my ($mode,$file) = @_;

    local $SIG{CHLD} = 'IGNORE';
    my $start = time;
    my $pid = fork();
    if(!defined $pid ) {
        die "Unable to fork for editor process";
    }
    elsif($pid == 0 ) {
        my @CMD = $CFG{editor};
        my $opts = $EDITOR{$CFG{editor}}->{$mode};
        if( exists $EDITOR{$CFG{editor}}->{__POSTFIX__} ) {
            shift @{ $opts };
            push @CMD, $file, @{$opts};
        }
        else {
            push @CMD, @{$opts}, $file;
        }
        exec(@CMD);
    }
    else {
        # Wait for the editor
        my $rc = waitpid($pid,0);
        debug("Child process $pid exited with $rc");
        my $diff = time - $start;
        $timing{$file} ||= 0;
        $timing{$file} +=  $diff;
        return sprintf('%dm%ds',$timing{$file}/60,$timing{$file}%60);
    }
    return; # Shouldn't get here.
}

=func gcr_view_commit($commit_info)

View the contents of the commit in the $commit_info,
stores time spent in editor as review_time in the hash.

=cut
sub gcr_view_commit {
    my ($commit) = @_;
    $commit->{review_time} = gcr_open_editor(readonly => File::Spec->catfile($AUDITDIR,$commit->{current_path}));
}

=func gcr_view_commit_files

Display a menu containing the files mentioned in the commit with the ability to view
the contents of one of those files.

=cut
sub gcr_view_commit_files {
    my ($commit) = @_;
    die "Source submodule is broken!" unless gcr_is_initialized();

    # Grab source repository
    my $source = gcr_repo('source');
    # Pull source
    gcr_reset('source');

    my @files  = $source->run(qw(diff-tree --no-commit-id --name-only -r), $commit->{sha1});

    die "Weird, no files referenced in $commit->{sha1}" unless @files;

    my $selection = prompt("Which file would you like to view?", menu => \@files);
    my $filename = File::Spec->catfile($AUDITDIR,'source',$selection);

    if( -f $filename ) {
        gcr_open_editor(readonly => $filename);
    }
    else {
        output({color=>'yellow'}, "!! Selected file doesn't exist in the most recent checkout: $selection");
    }
    return;
}


=func gcr_change_profile($commit_info,$profile,$details)

$commit_info is a hash attained from gcr_commit_info()
$profile is a string representing the desired profile
$details can be either a string, the commit message, or a hash reference
including a 'message' item to become the commit message.  The rest of the keys
will be added to the YAML generated.

=cut

sub gcr_change_profile {
    my($commit,$profile,$info) = @_;
    my $audit = gcr_repo();
    debug("gcr_change_profile('$commit->{sha1}','$profile')");

    if(!ref $info) {
        my %tmp;
        $tmp{message} = $info;
        $info = \%tmp;
    }

    # Already in profile
    if ($commit->{profile} eq $profile) {
        debug("! $commit->{sha1} is already in profile $profile, noop");
        return;
    }

    # Validate Profile
    my %profiles;
    @profiles{gcr_profiles()} = ();
    if(!exists $profiles{$profile}) {
        output({stderr=>1,color=>"red"}, "Profile '$profile' doesn't exist. (Available: " . join(', ', sort keys %profiles));
        exit 1;
    }

    # To / From
    my $orig = $commit->{current_path};
    my $prev = $commit->{profile};

    # Build directories
    my @path = File::Spec->splitdir($commit->{review_path});
    my $file = pop @path;
    splice @path, 0, 1, $profile;
    gcr_mkdir(@path);

    # Moves require that we keep the same base name
    push @path, $commit->{base} unless $path[-1] eq $commit->{base};
    my $target = File::Spec->catfile(@path);

    pop @path;  # Remove the filename from the path
    gcr_mkdir(@path);
    if( $orig ne $target ) {
        verbose("+ Moving from $orig to $target : $info->{message}");
        debug($audit->run('mv', $orig, $target));
        my %details = (
            status => 'move',
            profile_previous => $prev,
            profile => $profile,
            %$info
        );
        my $message = gcr_commit_message($commit,\%details);
        $audit->run('commit', '-m', $message);
        gcr_push();
    }
    else {
        debug("gcr_change_profile() already at $target");
    }

    $commit->{profile} = $profile;
    $commit->{current_path} = $target;
}


=func gcr_change_state($commit_info,$state,$details)

$commit_info is a hash attained from gcr_commit_info()
$state is a string representing the state
$details can be either a string, the commit message, or a hash reference
including a 'message' item to become the commit message.  The rest of the keys
will be added to the YAML generated.

=cut

sub gcr_change_state {
    my($commit,$state,$info) = @_;
    my $audit = gcr_repo();
    debug("gcr_change_state('$commit->{sha1}','$state')");

    if(!ref $info) {
        my %tmp;
        $tmp{message} = $info;
        $info = \%tmp;
    }

    # Already in state
    if ($commit->{state} eq $state) {
        debug("! $commit->{sha1} is already in state $state, noop");
        return;
    }

    # Check for valid state
    die "invalid state: $state" unless exists $STATE{$state};

    # To / From
    my $orig = $commit->{current_path};
    my $prev = $commit->{state};

    my $sdir = exists $STATE{$state}->{name} ? $STATE{$state}->{name} : $state;
    my @path = ();
    if ($STATE{$state}->{type} eq 'user') {
        push @path, $sdir, $CFG{user}, $commit->{base};
    }
    elsif ($STATE{$state}->{type} eq 'global') {
        @path = File::Spec->splitdir($commit->{review_path});
        splice @path, -2, 1, $sdir;  # Change State
    }
    elsif($STATE{$state}->{type} eq 'reset') {
        die "no review_path for reset" unless( exists $commit->{review_path} && length $commit->{review_path});
        @path = File::Spec->splitdir($commit->{review_path});
    }
    # Moves require that we keep the same base name
    push @path, $commit->{base} unless $path[-1] eq $commit->{base};
    my $target = File::Spec->catfile(@path);

    pop @path;  # Remove the filename from the path
    gcr_mkdir(@path);
    if( $orig ne $target ) {
        verbose("+ Moving from $orig to $target : $info->{message}");
        debug($audit->run('mv', $orig, $target));
        my %details = (
            profile        => gcr_profile(),
            commit         => $commit->{sha1},
            commit_date    => $commit->{date},
            state_previous => $prev,
            state          => $state,
            %$info
        );
        my $message = gcr_commit_message($commit,\%details);
        $audit->run('commit', '-m', $message);
        gcr_push();
    }
    else {
        debug("gcr_change_state() already at $target");
    }

    $commit->{state} = $state;
    $commit->{current_path} = $target;
}


=func gcr_commit_message($commit_info,\%details)

Creates the YAML commit message.  If $details{message} exists
it will be used as the YAML header text/comment.

=cut
sub gcr_commit_message {
    my($commit,$info) = @_;
    my %details = (
        context => {
            pid      => $$,
            hostanme => hostname(),
            pwd      => getcwd,
        },
    );
    my %cfg = gcr_config();
    #
    # Grab from Commit Object
    my @fields = qw(author date reviewer);
    push @fields, 'review_time' if exists $cfg{record_time};
    foreach my $k (@fields) {
        next unless exists $commit->{$k};
        next unless $commit->{$k};
        next if $commit->{$k} eq 'na';
        $details{$k} = $commit->{$k};
    }

    my $message = exists $info->{message} ? delete $info->{message} : undef;
    $message .= "\n" if defined $message;
    $message .= Dump({ %details, %{$info} });
    return $message;
}

=func gcr_audit_commit($AuditSHA1)

Returns the SHA1 from the source repository given the SHA1 from the
the Audit Repository.

=cut
sub gcr_audit_commit {
    my($audit_sha1) = @_;
    my $audit = gcr_repo();
    my ($_line,$_sub) = (caller 1)[2,3];

    # Get a list of files in the commit that end in .patch
    my %c = map { $_ => 1 }
            map { s/\.patch//; basename($_) }
            gcr_audit_files($audit_sha1);

    my @commits = keys %c;
    if(@commits != 1) {
        verbose({color=>'red',indent=>1}, sprintf "gcr_audit_commit('%s') contains %d source commits (%s - line %d)\n", $audit_sha1, scalar(@commits), $_sub, $_line );
        return;
    }

    return $commits[0];
}

=func gcr_audit_files($AuditSHA1)

Returns the list of files modified by the Audit SHA1
the Audit Repository.

=cut
sub gcr_audit_files {
    my($audit_sha1) = @_;
    my $audit = gcr_repo();
    my ($_line,$_sub) = (caller 1)[2,3];

    # Get a list of files in the commit that end in .patch
    my @files = grep { /\.patch$/ } $audit->run(qw(diff-tree --no-commit-id --name-only -r), $audit_sha1);
    return @files;
}


=func gcr_audit_record(@lines)

Converts a GCR Message into the structure:
{
    message => 'FreeText',
    date => 'blah',
    author => 'blah',
}
=cut
sub gcr_audit_record {
    my (@lines) = @_;
    my %details = ();
    my $yaml_raw = undef;
    foreach my $line (map { split /\r?\n/, $_ } @lines) {
        if(!defined $yaml_raw && $line eq '---')  {
            $yaml_raw = '';
        }
        elsif(defined $yaml_raw) {
            $yaml_raw .= "$line\n";
        }
        else {
            $details{message} ||= '';
            $details{message} .= "$line\n";
        }
    }
    if(defined $yaml_raw) {
        my $d = undef;
        eval {
            $d = YAML::Load($yaml_raw);
        };
        if($@) {
            debug({color=>'red',stderr=>1}, "Error retrieving YAML details from:", $yaml_raw);
        }
        if(ref $d eq 'HASH') {
            map { $details{$_} = $d->{$_} } grep { $_ ne 'message' } keys %{ $d };
        }
    }
    return wantarray ? %details : { %details };
}

=func gcr_not_resigned($commit)

Returns true unless the author resigned from the commit.

=cut
my $resigned_file;
my %_resigned;
sub gcr_not_resigned {
    my($path) = @_;
    my $commit = basename($path);

    $resigned_file ||= File::Spec->catfile($AUDITDIR,'Resigned',$CFG{user});
    return 1 unless -f $resigned_file;

    # Read the file
    if( !keys %_resigned ) {
        open(my $fh, "<", $resigned_file) or die "unable to read $resigned_file: $!";
        %_resigned = map { chomp; $_ => 1 } <$fh>;
    }
    return 1 unless exists $_resigned{$commit};
    return 0;
}

=func gcr_not_authored($path)

Returns true unless the reviewer authored the commit.

=cut
sub gcr_not_authored {
    my($path) = @_;
    my $author = _get_author($path);
    return $author ne $CFG{user};
}

=func gcr_state_color($state)

Make coloring consistent in this function.

=cut
sub gcr_state_color {
    my ($state) = @_;

    return exists $STATE{$state} ? $STATE{$state}->{color} : 'magenta';
}

=func _get_review_path($path)

Figure out the review path from a file path.

=cut
sub _get_review_path {
    my ($current_path) = @_;

    my $base = basename($current_path);
    my $profile = (File::Spec->splitdir($current_path))[0];
    my $path = File::Spec->catfile($AUDITDIR,$current_path);
    die "get_review_path(): nothing here $path" unless -f $path;

    my $ISO = _get_commit_date($current_path);
    my @full = split /\-/, $ISO;
    my @date = @full[0,1];
    die "Something went wrong in calculating date" unless @date == 2;

    return File::Spec->catfile($profile,@date,'Review',$base);
}

=func _get_commit_date($path)

Figure out the commit date.

=cut
sub _get_commit_date {
    my ($current_path) = @_;
    my $base = basename($current_path);
    my $path = File::Spec->catfile($AUDITDIR,$current_path);
    die "get_review_path(): nothing here $path" unless -f $path;

    open(my $fh, "<", $path) or die "_get_commit_date() cannot open $path: $!";
    my $ISO=undef;
    while( !$ISO ) {
        local $_ = <$fh>;
        last unless defined $_;
        next unless /^Date:/;
        $ISO = (split /\s+/)[1];
    }
    return $ISO;
}

=func _get_commit_profile($path)

Return the profile name

=cut
sub _get_commit_profile {
    my ($path) = @_;

    my $part = (File::Spec->splitdir($path))[0];
    return $part eq 'Locked' ? undef : $part;
}

=func _get_author($path)

Figure out the commit author.

=cut
sub _get_author {
    my ($current_path) = @_;

    my $path = File::Spec->catfile($AUDITDIR,$current_path);
    die "get_author_email(): nothing here $path" unless -f $path;

    open(my $fh, "<", $path) or die "_get_author() cannot open $path: $!";
    my $author;
    while( !$author ) {
        local $_ = <$fh>;
        last unless defined $_;
        next unless /^Author:/;
        chomp;
        $author = (split /:\s+/)[1];
        if( $author =~ /\<([^>]+)\>/ ) {
            $author = $1;
        }
    }
    die "Something went wrong figuring out author" unless $author;

    return $author;
}

=func _get_sha1($path)

Extract the SHA1 from the file path

=cut
sub _get_sha1 {
    local $_ = shift;
    if( /([a-f0-9]+)\.patch/ ) {
        return $1;
    }
    return;
}
=func _get_state($path)

Figure out the state from the current path.

=cut
sub _get_state {
    local $_ = shift;

    return 'locked'   if /locked/i;
    return 'review'   if /review/i;
    return 'concerns' if /concerns/i;
    return 'approved' if /approved/i;
    return 'unknown';
}

1;
