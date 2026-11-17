use strict;
use warnings;
use Test::More;
use File::Spec;
use File::Path qw(make_path);
use File::Temp qw(tempdir);
use File::Copy::Recursive qw(dircopy);
use lib 'lib';
use App::Saisons::Transfer ();
use App::Saisons::Adapter::Aider ();
use App::Saisons::Adapter::Claude ();
use App::Saisons::Adapter::Codex ();
use App::Saisons::Adapter::Gemini ();
use App::Saisons::Adapter::Opencode ();

my $fixtures = File::Spec->rel2abs(File::Spec->catdir('t', 'fixtures'));

sub slurp {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return '';
    local $/;
    return scalar <$fh>;
}

sub run_import {
    my ($file, %opt) = @_;
    open my $out, '>', \my $log;
    my @results = App::Saisons::Transfer::import_bundle($file, [
        map { $_->new } qw(App::Saisons::Adapter::Aider App::Saisons::Adapter::Claude
                           App::Saisons::Adapter::Codex App::Saisons::Adapter::Gemini
                           App::Saisons::Adapter::Opencode)
    ], clone => 0, out => $out, %opt);
    return ($log, @results);
}

sub statuses {
    my %n;
    $n{ "$_->{agent}:$_->{status}" }++ for @_;
    return \%n;
}

# ── helpers ──────────────────────────────────────────────────────────────────

subtest 'path_mapper' => sub {
    my $map = App::Saisons::Transfer::path_mapper('/home/user', '/Users/me');
    is($map->('/home/user'),           '/Users/me',            'home itself');
    is($map->('/home/user/src/x'),     '/Users/me/src/x',      'below home');
    is($map->('/home/username/x'),     '/home/username/x',     'only whole path components');
    is($map->('/projects/x'),          '/projects/x',          'outside home unchanged');
    my $same = App::Saisons::Transfer::path_mapper('/home/user', '/home/user');
    is($same->('/home/user/x'),        '/home/user/x',         'same home is a no-op');
};

subtest 'json_path_rewriter' => sub {
    my $map = App::Saisons::Transfer::path_mapper('/home/user', '/Users/me');
    my $rw  = App::Saisons::Transfer::json_path_rewriter($map, 'cwd');
    is($rw->(qq{{"cwd":"/home/user/p","x":"/home/user/p"}\n}),
       qq{{"cwd":"/Users/me/p","x":"/home/user/p"}\n}, 'only the named field');
    is($rw->(qq{{"cwd": "/home/user"}\n}), qq{{"cwd": "/Users/me"}\n}, 'space after colon');
};

subtest 'safe_rel' => sub {
    ok(eval { App::Saisons::Transfer::safe_rel('a/b.jsonl'); 1 }, 'plain relative path');
    ok(!eval { App::Saisons::Transfer::safe_rel('../x'); 1 },      'parent dir refused');
    ok(!eval { App::Saisons::Transfer::safe_rel('/etc/x'); 1 },    'absolute refused');
};

subtest '_norm_remote' => sub {
    my $n = \&App::Saisons::Transfer::_norm_remote;
    is($n->('git@github.com:me/repo.git'), $n->('https://github.com/me/repo'), 'ssh and https match');
    isnt($n->('git@github.com:me/a.git'),  $n->('git@github.com:me/b.git'),    'different repos differ');
};

# ── file-based agents round trip ─────────────────────────────────────────────

subtest 'export and import files' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    my $src = "$tmp/src";
    dircopy("$fixtures/claude/.claude", "$src/.claude");
    dircopy("$fixtures/gemini/.gemini", "$src/.gemini");
    dircopy("$fixtures/codex",          "$src/.codex");

    my @sessions;
    {
        local $ENV{HOME} = $src;
        local $ENV{CODEX_HOME};
        for my $class (qw(App::Saisons::Adapter::Claude App::Saisons::Adapter::Codex
                           App::Saisons::Adapter::Gemini)) {
            push @sessions, $class->new->find_sessions;
        }
    }
    is(scalar @sessions, 4, 'found the fixture sessions');

    # the fixtures' paths live under /home/user; export as if that were HOME
    my $file = "$tmp/export.tar.gz";
    my $r;
    {
        local $ENV{HOME} = '/home/user';
        local $ENV{CODEX_HOME} = "$src/.codex";
        $r = App::Saisons::Transfer::export_sessions(\@sessions, $file);
    }
    ok(-s $file, 'bundle written');
    is($r->{count}, 4, 'all sessions exported');

    my $dst = "$tmp/dst";
    make_path("$dst/myproject");
    local $ENV{HOME} = $dst;
    local $ENV{CODEX_HOME};
    my ($log, @results) = run_import($file);
    my $n = statuses(@results);
    is($n->{'claude:imported'}, 2, 'Claude imported');
    is($n->{'codex:imported'},  1, 'Codex imported');
    is($n->{'gemini:imported'}, 1, 'Gemini imported');
    like($log, qr{Paths under /home/user become \Q$dst\E}, 'reports the home rewrite');

    my $project = App::Saisons::Adapter::Claude::_project_dir_name("$dst/myproject");
    my $claude  = "$dst/.claude/projects/$project/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee.jsonl";
    ok(-f $claude, 'Claude session lands in the folder named after the new path');
    like(slurp($claude), qr{"cwd":"\Q$dst\E/myproject"}, 'Claude cwd rewritten');
    ok(-f "$dst/.claude/projects/$project/aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee/subagents/agent-subagent1.jsonl",
       'Claude subagent transcript copied');

    my ($codex) = glob "$dst/.codex/sessions/2026/01/15/rollout-*.jsonl";
    like(slurp($codex), qr{"cwd":"\Q$dst\E/myproject"}, 'Codex cwd rewritten');

    my $projects = App::Saisons::Transfer::read_json("$dst/.gemini/projects.json");
    my $slug = $projects->{projects}{"$dst/myproject"};
    ok($slug, 'Gemini project path registered');
    my ($gemini) = glob "$dst/.gemini/tmp/$slug/chats/session-*.jsonl";
    my ($first)  = split /\n/, slurp($gemini);
    like($first, qr{"directories":\["\Q$dst\E/myproject"\]}, 'Gemini directories rewritten');

    my @found = App::Saisons::Adapter::Claude->new->find_sessions;
    is(scalar @found, 2, 'imported Claude sessions are listed');

    ($log, @results) = run_import($file);
    $n = statuses(@results);
    is($n->{'claude:exists'}, 2, 'second import: Claude already here');
    is($n->{'codex:exists'},  1, 'second import: Codex already here');
};

subtest 'Aider merges into an existing history' => sub {
    my $tmp = tempdir(CLEANUP => 1);
    make_path("$tmp/home/proj");
    dircopy("$fixtures/aider/myproject", "$tmp/home/proj");
    my @sessions = do {
        local $ENV{SAISONS_SEARCH_DIRS} = "$tmp/home";
        App::Saisons::Adapter::Aider->new->find_sessions;
    };
    my $file = "$tmp/export.tar.gz";
    { local $ENV{HOME} = "$tmp/home"; App::Saisons::Transfer::export_sessions(\@sessions, $file) }

    my $dst = "$tmp/dst";
    local $ENV{HOME} = $dst;
    my (undef, @results) = run_import($file);
    is(statuses(@results)->{'aider:skipped'}, 2, 'skipped while the project folder is missing');

    make_path("$dst/proj");
    my $history = "$dst/proj/.aider.chat.history.md";
    open my $fh, '>', $history or die;
    print $fh "# aider chat started at 2026-01-15 09:00:00\n\n#### earlier\n";
    close $fh;

    (undef, @results) = run_import($file);
    is(statuses(@results)->{'aider:imported'}, 2, 'both sessions imported');
    my @headers = slurp($history) =~ /^# aider chat started at (.*)$/mg;
    is(scalar @headers, 3, 'existing session kept');
    is_deeply(\@headers, [sort @headers], 'sessions in date order');
    (undef, @results) = run_import($file);
    is(statuses(@results)->{'aider:exists'}, 2, 'second import: already here');
};

# ── opencode ────────────────────────────────────────────────────────────────

subtest 'opencode' => sub {
    plan skip_all => 'sqlite3 CLI not available'
        unless App::Saisons::Adapter::Opencode::_sqlite3();
    my $tmp    = tempdir(CLEANUP => 1);
    my $schema = <<'SQL';
CREATE TABLE project (id text PRIMARY KEY, worktree text NOT NULL);
CREATE TABLE session (id text PRIMARY KEY, project_id text NOT NULL, parent_id text,
    directory text NOT NULL, path text, title text NOT NULL,
    time_created integer NOT NULL, time_updated integer NOT NULL, time_archived integer);
CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, data text NOT NULL);
CREATE TABLE part (id text PRIMARY KEY, message_id text NOT NULL, session_id text NOT NULL,
    time_created integer NOT NULL, data text NOT NULL);
SQL
    my $data = <<'SQL';
INSERT INTO project VALUES ('global', '/'), ('p1', '/home/user/app');
INSERT INTO session VALUES ('s1', 'p1', NULL, '/home/user/app', '', 'App work', 1, 2, NULL);
INSERT INTO session VALUES ('s2', 'global', NULL, '/home/user/notes', 'home/user/notes', 'Notes', 1, 2, NULL);
INSERT INTO session VALUES ('s3', 'p1', 's1', '/home/user/app', '', 'Subagent', 1, 2, NULL);
INSERT INTO message VALUES ('m1', 's1', 1, '{"role":"user"}'), ('m3', 's3', 1, '{"role":"user"}');
INSERT INTO part VALUES ('t1', 'm1', 's1', 1, '{"type":"text","text":"hi"}');
SQL
    my $make = sub {
        my ($home, $sql) = @_;
        make_path("$home/.local/share/opencode");
        my ($ok, $err) = App::Saisons::Adapter::Opencode->new->_sqlite_try($sql, "$home/.local/share/opencode/opencode.db");
        die $err unless $ok;
    };
    $make->("$tmp/src", $schema . $data);
    $make->("$tmp/dst", $schema . "INSERT INTO session VALUES ('s2', 'global', NULL, '/x', 'x', 'Mine', 1, 2, NULL);");

    local $ENV{XDG_DATA_HOME};
    my $file = "$tmp/export.tar.gz";
    {
        local $ENV{HOME} = "$tmp/src";
        my @sessions = grep { $_->{id} ne 's3' } App::Saisons::Adapter::Opencode->new->find_sessions;
        local $ENV{HOME} = '/home/user';
        local $ENV{XDG_DATA_HOME} = "$tmp/src/.local/share";
        App::Saisons::Transfer::export_sessions(\@sessions, $file);
    }

    local $ENV{HOME} = "$tmp/dst";
    my (undef, @results) = run_import($file);
    my $n = statuses(@results);
    is($n->{'opencode:imported'}, 1, 'new session imported');
    is($n->{'opencode:exists'},   1, 'session already here left alone');

    my $o    = App::Saisons::Adapter::Opencode->new;
    my $rows = $o->_sqlite_out('SELECT id, directory, path, title FROM session ORDER BY id');
    my %s    = map { $_->{id} => $_ } @$rows;
    is($s{s1}{directory}, "$tmp/dst/app", 'session directory rewritten');
    is($s{s2}{title},     'Mine',         'existing session not overwritten');
    ok($s{s3},                            'child session came along');
    is($o->_sqlite_out("SELECT worktree FROM project WHERE id = 'p1'")->[0]{worktree},
       "$tmp/dst/app", 'project worktree rewritten');
    is($o->_sqlite_out("SELECT count(*) AS n FROM part")->[0]{n}, 1, 'parts copied');
};

# ── project folders and git ──────────────────────────────────────────────────

subtest 'project report and clone' => sub {
    plan skip_all => 'git not available'
        unless defined App::Saisons::Transfer::_capture('git', '--version');
    my $tmp = tempdir(CLEANUP => 1);
    local $ENV{GIT_CONFIG_NOSYSTEM} = 1;
    local $ENV{GIT_AUTHOR_NAME}  = local $ENV{GIT_COMMITTER_NAME}  = 'T';
    local $ENV{GIT_AUTHOR_EMAIL} = local $ENV{GIT_COMMITTER_EMAIL} = 't@example.com';
    my $git = sub { system('git', @_) == 0 or die "git @_ failed" };
    $git->('init', '-q', '--bare', "$tmp/remote.git");
    $git->('clone', '-q', "$tmp/remote.git", "$tmp/home/repo");
    $git->('-C', "$tmp/home/repo", 'commit', '-q', '--allow-empty', '-m', 'one');
    $git->('-C', "$tmp/home/repo", 'push', '-q', 'origin', 'HEAD');
    make_path("$tmp/home/repo/sub", "$tmp/home/plain");

    my $layout = do {
        local $ENV{HOME} = "$tmp/home";
        App::Saisons::Transfer::project_layout("$tmp/home/repo/sub", "$tmp/home/plain");
    };
    is($layout->{dirs}{"$tmp/home/repo/sub"}{repo}, "$tmp/home/repo", 'subdir belongs to its repo');
    is($layout->{repos}{"$tmp/home/repo"}{remote}, "$tmp/remote.git", 'remote recorded');

    my $manifest = {
        projects => $layout,
        sessions => [ { cwd => "$tmp/home/repo/sub" }, { cwd => "$tmp/home/plain" } ],
    };
    my $map   = App::Saisons::Transfer::path_mapper("$tmp/home", "$tmp/other");
    my @items = App::Saisons::Transfer::check_projects($manifest, $map);
    my %st    = map { $_->{path} => $_->{status} } @items;
    is($st{"$tmp/other/repo"},  'missing',     'repo missing, can be cloned');
    is($st{"$tmp/other/plain"}, 'missing-dir', 'plain folder missing');
    like(join("\n", App::Saisons::Transfer::project_report(@items)),
         qr{git clone .*remote\.git.*other/repo}, 'report shows the clone command');

    open my $out, '>', \my $log;
    App::Saisons::Transfer::clone_repos(\@items, $out);
    ok(-d "$tmp/other/repo/.git", 'repo cloned');
    %st = map { $_->{path} => $_->{status} } App::Saisons::Transfer::check_projects($manifest, $map);
    is($st{"$tmp/other/repo"}, 'ok', 'cloned repo is ok');

    # a commit the target has not fetched yet
    $git->('-C', "$tmp/home/repo", 'commit', '-q', '--allow-empty', '-m', 'two');
    $layout = App::Saisons::Transfer::project_layout("$tmp/home/repo/sub");
    $manifest->{projects} = $layout;
    is($layout->{repos}{"$tmp/home/repo"}{unpushed}, 1, 'unpushed commit counted');
    %st = map { $_->{path} => $_->{status} } App::Saisons::Transfer::check_projects($manifest, $map);
    is($st{"$tmp/other/repo"}, 'behind', 'target lacks the source commit');
};

done_testing;
