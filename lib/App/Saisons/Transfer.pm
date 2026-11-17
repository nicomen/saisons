package App::Saisons::Transfer;
use strict;
use warnings;
use App::Saisons ();
use App::Saisons::Launcher ();
use Encode ();
use File::Basename ();
use File::Find ();
use File::Path ();
use File::Spec ();
use File::Temp ();
use JSON::PP ();
use POSIX ();
use Sys::Hostname ();

# Bundle layout, inside a .tar.gz:
#   saisons-export/manifest.json     sessions, source $HOME, project layout
#   saisons-export/<agent>/...       whatever each adapter's export wrote
use constant FORMAT => 1;
use constant TOP    => 'saisons-export';

# ── small helpers shared by the adapters ─────────────────────────────────────

sub _decode_path { Encode::decode('UTF-8', $_[0] // '', Encode::FB_DEFAULT) }

sub home { _decode_path($ENV{HOME}) }

sub agent_key {
    my ($adapter) = @_;
    (my $key = ref($adapter) || $adapter) =~ s/.*:://;
    return lc $key;
}

sub default_file {
    (my $host = Sys::Hostname::hostname()) =~ s/\..*//;
    return sprintf 'saisons-%s-%s.tar.gz', $host, POSIX::strftime('%Y%m%d-%H%M', localtime);
}

sub read_json {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return undef;
    my $json = do { local $/; <$fh> };
    close $fh;
    return eval { JSON::PP::decode_json($json) };
}

sub write_json {
    my ($file, $data, $indent) = @_;
    my $json = JSON::PP->new->utf8->canonical->pretty->indent_length($indent // 2);
    File::Path::make_path(File::Basename::dirname($file));
    open my $fh, '>:raw', $file or die "Cannot write $file: $!\n";
    print $fh $json->encode($data);
    close $fh or die "Cannot write $file: $!\n";
}

# Paths read from a bundle land under our own directories; refuse anything
# that could climb out of them.
sub safe_rel {
    my ($rel) = @_;
    die "Unsafe path in bundle: " . ($rel // '(none)') . "\n"
        if !defined $rel || $rel eq ''
        || File::Spec->file_name_is_absolute($rel)
        || grep { $_ eq '..' } split m{[/\\]}, $rel;
    return $rel;
}

# Returns a sub that maps a path from the source machine to this one by
# swapping the leading $from (the source $HOME) for $to.
sub path_mapper {
    my ($from, $to) = @_;
    return sub {
        my ($p) = @_;
        return $p if !defined $p || !length($from // '') || $from eq $to;
        return $to if $p eq $from;
        return $to . substr($p, length $from) if index($p, "$from/") == 0;
        return $p;
    };
}

# Returns a line filter that maps every "field":"path" JSON value in it.
sub json_path_rewriter {
    my ($map, @fields) = @_;
    my $alt = join '|', map { quotemeta } @fields;
    return sub {
        my ($line) = @_;
        $line =~ s{("(?:$alt)"\s*:\s*")([^"\\]*)"}
                  {$1 . Encode::encode('UTF-8', $map->(_decode_path($2))) . '"'}ge;
        return $line;
    };
}

# Copies $src to $dst, creating directories. With rewrite => sub, each line
# goes through it. With keep => 1 an existing $dst is left alone.
sub copy_file {
    my ($src, $dst, %o) = @_;
    return 0 if $o{keep} && -e $dst;
    File::Path::make_path(File::Basename::dirname($dst));
    my $tmp = "$dst.saisons-$$";
    open my $in,  '<:raw', $src or die "Cannot read $src: $!\n";
    open my $out, '>:raw', $tmp or die "Cannot write $tmp: $!\n";
    while (my $line = <$in>) {
        $line = $o{rewrite}->($line) if $o{rewrite};
        print $out $line;
    }
    close $in;
    close $out or die "Cannot write $tmp: $!\n";
    rename $tmp, $dst or die "Cannot write $dst: $!\n";
    my @st = stat $src;
    utime $st[8], $st[9], $dst if @st;
    return 1;
}

sub copy_tree {
    my ($src, $dst, %o) = @_;
    return unless -d $src;
    File::Find::find({ no_chdir => 1, wanted => sub {
        return unless -f $_;
        copy_file($_, "$dst/" . File::Spec->abs2rel($_, $src), %o);
    } }, $src);
}

# What an adapter's export puts in the manifest for one session.
sub entry {
    my ($s, %extra) = @_;
    return {
        id    => $s->{id},
        title => $s->{title},
        cwd   => $s->{cwd},
        date  => $s->{date},
        %extra,
    };
}

sub result {
    my ($e, $status, $msg) = @_;
    chomp $msg if defined $msg;
    return {
        agent  => $e->{agent},
        id     => $e->{id},
        title  => $e->{title},
        status => $status,
        (defined $msg ? (msg => $msg) : ()),
    };
}

# Runs $code->($entry) for each entry; it returns a status ('imported',
# 'exists', 'skipped') and an optional message. A die becomes an error.
sub import_each {
    my ($entries, $code) = @_;
    return map {
        my $e = $_;
        my ($status, $msg) = eval { $code->($e) };
        ($status, $msg) = ('error', $@) unless defined $status;
        result($e, $status, $msg);
    } @$entries;
}

# ── running external tools ───────────────────────────────────────────────────

# Output of a command (chomped), or undef if it failed.
sub _capture {
    my $cmd = join(' ', map { App::Saisons::Launcher::shell_quote($_) } @_)
            . ' 2>' . File::Spec->devnull;
    my $out = `$cmd`;
    return undef if $? || !defined $out;
    chomp $out;
    return $out;
}

sub _git { my ($dir, @args) = @_; return _capture('git', '-C', $dir, @args) }

sub _tar {
    my (@args) = @_;
    system('tar', @args) == 0 or die "tar @args failed\n";
}

# ── project layout: what each session's directory was on the source ─────────

sub project_layout {
    my (@cwds) = @_;
    my (%dirs, %repos);
    my %seen;
    for my $cwd (grep { defined && !$seen{$_}++ } @cwds) {
        my $d = { exists => (-d $cwd ? JSON::PP::true : JSON::PP::false) };
        if (-d $cwd and my $root = _git($cwd, 'rev-parse', '--show-toplevel')) {
            $root = _decode_path($root);
            $d->{repo} = $root;
            $repos{$root} //= _repo_info($root);
        }
        $dirs{$cwd} = $d;
    }
    return { dirs => \%dirs, repos => \%repos };
}

sub _repo_info {
    my ($root) = @_;
    my @remotes = split /\n/, (_git($root, 'remote') // '');
    my ($name)  = (grep({ $_ eq 'origin' } @remotes), @remotes);
    my $status  = _git($root, 'status', '--porcelain') // '';
    my @changed = grep { length } split /\n/, $status;
    return {
        remote   => ($name ? _git($root, 'remote', 'get-url', $name) : undef),
        branch   => _git($root, 'symbolic-ref', '--short', '-q', 'HEAD'),
        head     => _git($root, 'rev-parse', 'HEAD'),
        dirty    => scalar @changed,
        unpushed => (@remotes ? (_git($root, 'rev-list', '--count', 'HEAD', '--not', '--remotes') // 0) + 0 : undef),
    };
}

# host/path form, so git@host:a/b.git and https://host/a/b compare equal
sub _norm_remote {
    my ($url) = @_;
    return '' unless defined $url;
    $url = lc $url;
    $url =~ s{^[a-z+]+://}{};
    $url =~ s{^[^@/]+@}{};
    $url =~ s{^([^/:]+):(?!\d)}{$1/};
    $url =~ s{\.git/?$}{};
    $url =~ s{/+$}{};
    return $url;
}

# One item per source repo, and per session directory outside a repo, with
# what is there on this machine: ok, behind, other-repo, not-git, missing
# (cloneable), missing-local (repo without remote) or missing-dir.
sub check_projects {
    my ($manifest, $map) = @_;
    my $layout = $manifest->{projects} // {};
    my $dirs   = $layout->{dirs}  // {};
    my $repos  = $layout->{repos} // {};
    my %count;
    $count{ $_->{cwd} // '' }++ for @{ $manifest->{sessions} // [] };
    my (%repo_sessions, @items);
    for my $cwd (sort keys %$dirs) {
        my $d = $dirs->{$cwd};
        if (my $root = $d->{repo}) {
            $repo_sessions{$root} += $count{$cwd} // 0;
            next;
        }
        my $target = $map->($cwd);
        push @items, {
            path     => $target,
            sessions => $count{$cwd} // 0,
            status   => (-d $target ? 'ok' : 'missing-dir'),
            gone     => !$d->{exists},
        };
    }
    for my $root (sort keys %$repos) {
        my $info   = $repos->{$root};
        my $target = $map->($root);
        my $item   = { path => $target, sessions => $repo_sessions{$root} // 0, repo => $info };
        if (!-d $target) {
            $item->{status} = $info->{remote} ? 'missing' : 'missing-local';
        }
        elsif (!_git($target, 'rev-parse', '--show-toplevel')) {
            $item->{status} = 'not-git';
        }
        else {
            my %here = map { _norm_remote((split ' ', $_)[1]) => 1 }
                       split /\n/, (_git($target, 'remote', '-v') // '');
            if ($info->{remote} && %here && !$here{ _norm_remote($info->{remote}) }) {
                $item->{status} = 'other-repo';
            }
            elsif ($info->{head} && !defined _git($target, 'cat-file', '-e', "$info->{head}^{commit}")) {
                $item->{status} = 'behind';
            }
            else {
                $item->{status} = 'ok';
            }
        }
        push @items, $item;
    }
    return sort { $a->{path} cmp $b->{path} } @items;
}

# quoted only when it has to be, so the command reads like one typed by hand
sub _sh {
    my ($word) = @_;
    return $word =~ m{^[\w./:@%+=,~-]+$} ? $word : App::Saisons::Launcher::shell_quote($word);
}

sub _clone_cmd {
    my ($item) = @_;
    my $r = $item->{repo};
    return join ' ', map { _sh($_) }
        'git', 'clone', ($r->{branch} ? ('-b', $r->{branch}) : ()), $r->{remote}, $item->{path};
}

my %LABEL = (
    'ok'            => 'ok',
    'cloned'        => 'cloned',
    'behind'        => 'behind',
    'other-repo'    => 'other repo',
    'not-git'       => 'not git',
    'missing'       => 'missing',
    'missing-local' => 'missing',
    'missing-dir'   => 'missing',
    'clone-failed'  => 'failed',
);

sub project_report {
    my (@items) = @_;
    my @lines;
    for my $it (@items) {
        my $r = $it->{repo} // {};
        push @lines, sprintf "  %-10s %s  (%d session%s)",
            $LABEL{ $it->{status} }, $it->{path}, $it->{sessions}, $it->{sessions} == 1 ? '' : 's';
        my @hints;
        my $s = $it->{status};
        if    ($s eq 'missing' || $s eq 'clone-failed') { push @hints, _clone_cmd($it) }
        elsif ($s eq 'missing-local') { push @hints, 'repo has no remote; copy it from the source machine' }
        elsif ($s eq 'missing-dir')   {
            push @hints, $it->{gone} ? 'was already gone on the source machine'
                                     : 'not a git repo; copy it from the source machine';
        }
        elsif ($s eq 'behind') {
            push @hints, sprintf 'source was at %s, not here yet: git -C %s pull',
                substr($r->{head}, 0, 7), _sh($it->{path});
        }
        elsif ($s eq 'other-repo') { push @hints, "source was a clone of $r->{remote}" }
        elsif ($s eq 'not-git')    { push @hints, 'exists but is not a git repo; source was a clone of ' . ($r->{remote} // 'a local repo') }
        push @hints, "source had $r->{dirty} uncommitted change(s), which git does not carry over"
            if $r->{dirty};
        push @hints, "source had $r->{unpushed} unpushed commit(s)"
            if $r->{unpushed};
        push @lines, map { "             $_" } @hints;
    }
    return @lines;
}

sub clone_repos {
    my ($items, $out) = @_;
    for my $it (grep { $_->{status} eq 'missing' } @$items) {
        my $r = $it->{repo};
        File::Path::make_path(File::Basename::dirname($it->{path}));
        print $out "Cloning $r->{remote} into $it->{path}\n";
        my @branch = $r->{branch} ? ('-b', $r->{branch}) : ();
        my $ok = system('git', 'clone', @branch, $r->{remote}, $it->{path}) == 0;
        # the branch may not exist on the remote (never pushed)
        $ok ||= @branch && !-d $it->{path}
             && system('git', 'clone', $r->{remote}, $it->{path}) == 0;
        $it->{status} = $ok ? 'cloned' : 'clone-failed';
    }
}

# ── export ───────────────────────────────────────────────────────────────────

sub export_sessions {
    my ($sessions, $file) = @_;
    my $stage = File::Temp::tempdir('saisons-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    my $root  = "$stage/" . TOP;
    my (%by_agent, @entries, %skipped);
    push @{ $by_agent{ agent_key($_->{_adapter}) } }, $_ for @$sessions;
    for my $agent (sort keys %by_agent) {
        my $group   = $by_agent{$agent};
        my $adapter = $group->[0]{_adapter};
        unless ($adapter->can('export_sessions')) {
            $skipped{ $adapter->name } = scalar @$group;
            next;
        }
        File::Path::make_path("$root/$agent");
        for my $e ($adapter->export_sessions($group, "$root/$agent")) {
            $e->{agent} = $agent;
            push @entries, $e;
        }
    }
    write_json("$root/manifest.json", {
        format   => FORMAT,
        saisons  => App::Saisons::version_string(),
        host     => Sys::Hostname::hostname(),
        home     => home(),
        created  => POSIX::strftime('%Y-%m-%dT%H:%M:%SZ', gmtime),
        sessions => \@entries,
        projects => project_layout(map { $_->{cwd} } @entries),
    });
    my $abs = File::Spec->rel2abs($file);
    _tar('-czf', $abs, '-C', $stage, TOP);
    return { file => $abs, count => scalar(@entries), skipped => \%skipped };
}

sub export_summary {
    my ($r) = @_;
    my @lines = sprintf 'Exported %d session(s) to %s', $r->{count}, $r->{file};
    push @lines, sprintf '  %s: %d session(s) skipped, export not supported', $_, $r->{skipped}{$_}
        for sort keys %{ $r->{skipped} };
    push @lines, '', 'On the other machine: saisons --import ' . File::Basename::basename($r->{file});
    return @lines;
}

# ── import ───────────────────────────────────────────────────────────────────

sub read_bundle {
    my ($file) = @_;
    -f $file or die "No such file: $file\n";
    my $stage = File::Temp::tempdir('saisons-XXXXXX', TMPDIR => 1, CLEANUP => 1);
    _tar('-xzf', File::Spec->rel2abs($file), '-C', $stage);
    my $root     = "$stage/" . TOP;
    my $manifest = read_json("$root/manifest.json")
        or die "$file is not a saisons export (no manifest)\n";
    die "$file was made by a newer saisons (format $manifest->{format}); upgrade to import it\n"
        if ($manifest->{format} // 0) > FORMAT;
    return ($root, $manifest);
}

# %opt: clone (1, 0 or undef to ask on a terminal), dry_run, out (filehandle)
sub import_bundle {
    my ($file, $adapters, %opt) = @_;
    my $out = $opt{out} // \*STDOUT;
    my ($root, $manifest) = read_bundle($file);
    my $map = path_mapper($manifest->{home}, home());
    my @sessions = @{ $manifest->{sessions} // [] };

    printf $out "%d session(s) from %s, exported %s\n", scalar @sessions,
        $manifest->{host} // 'unknown host', $manifest->{created} // '?';
    printf $out "Paths under %s become %s\n", $manifest->{home}, home()
        if ($manifest->{home} // '') ne home();

    my @items = check_projects($manifest, $map);
    if (@items) {
        print $out "\nProject folders\n", map { "$_\n" } project_report(@items);
    }
    my @cloneable = grep { $_->{status} eq 'missing' } @items;
    if (@cloneable && !$opt{dry_run}) {
        my $clone = $opt{clone};
        if (!defined $clone && -t STDIN) {
            printf $out "\nClone %d missing repo(s) now? [y/N] ", scalar @cloneable;
            $clone = (<STDIN> // '') =~ /^y/i;
        }
        if ($clone) {
            print $out "\n";
            clone_repos(\@items, $out);
            print $out "\n", map { "$_\n" } project_report(grep { $_->{status} =~ /^clone/ } @items);
        }
    }
    return if $opt{dry_run};

    my %adapter_for = map { agent_key($_) => $_ } @$adapters;
    my (%by_agent, @results);
    push @{ $by_agent{ $_->{agent} } }, $_ for @sessions;
    for my $agent (sort keys %by_agent) {
        my $entries = $by_agent{$agent};
        my $adapter = $adapter_for{$agent};
        if (!$adapter || !$adapter->can('import_sessions')) {
            push @results, map { result($_, 'error', "this saisons cannot import $agent sessions") } @$entries;
            next;
        }
        push @results, $adapter->import_sessions($entries, "$root/" . safe_rel($agent), $map);
    }
    print $out "\n", map { "$_\n" } import_summary(@results);
    return @results;
}

sub import_summary {
    my (@results) = @_;
    my %n;
    $n{ $_->{status} }++ for @results;
    my @lines = sprintf 'Imported %d session(s)%s%s%s.',
        $n{imported} // 0,
        ($n{exists}  ? ", $n{exists} already here"  : ''),
        ($n{skipped} ? ", $n{skipped} skipped"       : ''),
        ($n{error}   ? ", $n{error} failed"          : '');
    # one line per distinct problem, not one per session
    my (%group, @order);
    for my $r (grep { $_->{status} eq 'skipped' || $_->{status} eq 'error' } @results) {
        my $key = join "\0", $r->{status}, $r->{agent}, $r->{msg} // '';
        push @order, $key unless $group{$key};
        push @{ $group{$key} }, $r;
    }
    for my $key (@order) {
        my $rs = $group{$key};
        my ($status, $agent, $msg) = split /\0/, $key, 3;
        my $what = @$rs == 1 ? ($rs->[0]{title} // $rs->[0]{id}) : scalar(@$rs) . ' sessions';
        push @lines, sprintf '  %s %s %s: %s', $status, $agent, $what, $msg;
    }
    push @lines, 'Run the import again once the missing folders are there.'
        if $n{skipped};
    return @lines;
}

1;
