package App::Saisons::Adapter::Opencode;
use strict;
use warnings;
use App::Saisons ();
use JSON::PP ();
use POSIX qw();
use Encode qw(decode);
use App::Saisons::Launcher ();
use App::Saisons::Transfer ();
use IPC::Open3 ();
sub new { bless {}, shift }
sub name      { 'opencode' }
sub tag       { "\x{2395} Opc" }
sub tag_color { 'bold magenta' }

my $SQLITE3;

sub _sqlite3 {
    return $SQLITE3 if defined $SQLITE3;
    for my $dir (split /:/, ($ENV{PATH} // '')) {
        next unless length $dir;
        my $p = "$dir/sqlite3";
        if (-x $p && !-d $p) {
            return $SQLITE3 = $p;
        }
    }
    return $SQLITE3 = '';
}

sub _db_path {
    my $data_home = $ENV{XDG_DATA_HOME} || "$ENV{HOME}/.local/share";
    return "$data_home/opencode/opencode.db";
}

sub _q {
    my ($s) = @_;
    $s =~ s/'/''/g if defined $s;
    return $s // '';
}

sub _sqlite_out {
    my ($self, $sql, $db) = @_;
    $db //= _db_path();
    my $exe = _sqlite3() or return undef;
    return undef unless -f $db;
    my $cmd = join(' ', map(App::Saisons::Launcher::shell_quote($_), $exe), '-readonly', '-json',
                   map(App::Saisons::Launcher::shell_quote($_), $db, $sql)) . ' 2>/dev/null';
    my $out = `$cmd`;
    return undef unless $? == 0 && defined $out;
    my $rows = eval { JSON::PP::decode_json($out) };
    return $rows // [];
}

sub _sqlite_exec {
    my ($self, $sql) = @_;
    return 0 unless -f _db_path();
    my ($ok) = $self->_sqlite_try($sql);
    return $ok;
}

# Runs an SQL script (fed on stdin, so its length is not limited by the
# command line) and stops at the first error. Returns (ok, output).
sub _sqlite_try {
    my ($self, $sql, $db) = @_;
    $db //= _db_path();
    my $exe = _sqlite3() or return (0, 'sqlite3 is not installed');
    my ($in, $out);
    my $pid = eval { IPC::Open3::open3($in, $out, undef, $exe, $db) }
        or return (0, "Cannot run sqlite3: $@");
    binmode $in, ':utf8';
    print $in ".bail on\n$sql\n";
    close $in;
    my $output = do { local $/; <$out> } // '';
    waitpid $pid, 0;
    return ($? == 0, $output);
}

sub _session_title {
    my ($row) = @_;
    my $title = $row->{title} // '';
    return $title if length($title) && $title !~ /\ANew session - /;
    my $text = _first_text($row->{first_hex});
    return $text if length $text;
    return '(no title)';
}

sub _first_text {
    my ($hex) = @_;
    return '' unless defined $hex && length $hex;
    my $text;
    {
        no warnings 'utf8';
        $text = decode('UTF-8', pack('H*', $hex), Encode::FB_DEFAULT);
    }
    $text =~ s/\s+/ /g;
    $text =~ s/\A\s+//;
    $text =~ s/\s+\z//;
    $text = substr($text, 0, 79) . "\x{2026}" if length($text) > 80;
    return $text;
}

sub _SESSIONS_SQL { <<'SQL' }
SELECT s.id AS id, s.directory AS dir, s.title AS title, s.time_created AS created_ms, s.time_updated AS updated_ms, COALESCE((SELECT SUM(LENGTH(d.data)) FROM ( SELECT data FROM message WHERE session_id = s.id UNION ALL SELECT data FROM part WHERE session_id = s.id ) d), 0) AS bytes, hex((SELECT json_extract(p.data, '$.text') FROM part p JOIN message m ON m.id = p.message_id WHERE p.session_id = s.id AND json_valid(p.data) AND json_extract(p.data, '$.type') = 'text' AND json_valid(m.data) AND json_extract(m.data, '$.role') = 'user' ORDER BY p.time_created, p.id LIMIT 1)) AS first_hex FROM session s WHERE s.time_archived IS NULL ORDER BY s.time_updated DESC
SQL
sub find_sessions {
    my ($self) = @_;
    my $db = _db_path();
    my ($rows) = App::Saisons::cached_parse($db, sub { $self->_sqlite_out(_SESSIONS_SQL()) }, "$db-wal");
    return () unless $rows;
    my @sessions;
    for my $row (@$rows) {
        next unless $row->{id};
        my $ms   = $row->{updated_ms} || $row->{created_ms} || 0;
        my $epoch = int($ms / 1000);
        push @sessions, {
            id       => $row->{id},
            title    => _session_title($row),
            date     => POSIX::strftime('%Y-%m-%dT%H:%M:%S', gmtime($epoch)),
            epoch    => $epoch,
            cwd      => length($row->{dir} // '') ? $row->{dir} : $ENV{HOME},
            project  => length($row->{dir} // '') ? $row->{dir} : $ENV{HOME},
            _file    => _db_path(),
            _size    => int($row->{bytes} || 0),
            _adapter => $self,
        };
    }
    return @sessions;
}
sub running {
    my %running;
    for my $args (`ps -eo args 2>/dev/null`) {
        $running{$1} = 1 if $args =~ /\bopencode\s+.*--session[= ](\S+)/;
    }
    return %running;
}
sub launch {
    my ($self, $sessions, $launcher) = @_;
    for my $s (@$sessions) {
        my $cmd = "cd \Q$s->{cwd}\E && opencode --session \Q$s->{id}\E";
        App::Saisons::Launcher::launch_cmd($cmd, $s->{cwd}, $launcher, $s->{title});
    }
}
sub delete_session {
    my ($self, $session) = @_;
    my $id = _q($session->{id});
    return $self->_sqlite_exec(
        "DELETE FROM part WHERE session_id = '$id'; "
      . "DELETE FROM message WHERE session_id = '$id'; "
      . "DELETE FROM session WHERE id = '$id';"
    );
}
sub load_messages {
    my ($self, $session) = @_;
    my $sid = _q($session->{id});
    my $msgs = $self->_sqlite_out(
        "SELECT id AS id, data AS data FROM message "
      . "WHERE session_id = '$sid' ORDER BY time_created, id"
    ) or return ();
    my $parts = $self->_sqlite_out(
        "SELECT message_id AS mid, data AS data FROM part "
      . "WHERE session_id = '$sid' ORDER BY time_created, id"
    ) or return ();
    my %text_of;
    for my $p (@$parts) {
        my $obj = eval { JSON::PP::decode_json($p->{data}) } or next;
        next unless ($obj->{type} // '') eq 'text';
        $text_of{ $p->{mid} } .= ($obj->{text} // '');
    }
    my @messages;
    for my $m (@$msgs) {
        my $obj = eval { JSON::PP::decode_json($m->{data}) } or next;
        my $role = $obj->{role} // '';
        next unless $role eq 'user' || $role eq 'assistant';
        my $text = $text_of{ $m->{id} } // '';
        push @messages, { role => $role, text => $text } if length $text;
    }
    return @messages;
}
# Tables holding per-session rows; message before part, as part refers to it.
sub _session_tables {
    my ($self, $db) = @_;
    my $rows = $self->_sqlite_out(
        "SELECT m.name AS name FROM sqlite_master m JOIN pragma_table_info(m.name) p "
      . "WHERE m.type = 'table' AND p.name = 'session_id'", $db) // [];
    my %rank = (message => 0, part => 1);
    return sort { ($rank{$a} // 2) <=> ($rank{$b} // 2) || $a cmp $b } map { $_->{name} } @$rows;
}
sub _columns {
    my ($self, $db, $table) = @_;
    my $rows = $self->_sqlite_out("SELECT name AS name FROM pragma_table_info('" . _q($table) . "')", $db) // [];
    return map { $_->{name} } @$rows;
}
sub _in_list { join ',', map { "'" . _q($_) . "'" } @_ }
# Writes the sessions, their child sessions, their projects and every row
# that belongs to them into a small database of the same shape.
sub export_sessions {
    my ($self, $sessions, $dir) = @_;
    my $src = _db_path();
    my $ids = join ',', map { "('" . _q($_->{id}) . "')" } @$sessions;
    my $sql = "ATTACH '" . _q($src) . "' AS src;\n"
      . "CREATE TEMP TABLE ids AS WITH RECURSIVE t(id) AS (VALUES $ids "
      . "UNION SELECT s.id FROM src.session s JOIN t ON s.parent_id = t.id) SELECT id FROM t;\n"
      . "CREATE TABLE session AS SELECT * FROM src.session WHERE id IN (SELECT id FROM ids);\n"
      . "CREATE TABLE project AS SELECT * FROM src.project WHERE id IN (SELECT project_id FROM session);\n"
      . join '', map {
            qq{CREATE TABLE "$_" AS SELECT * FROM src."$_" WHERE session_id IN (SELECT id FROM ids);\n}
        } $self->_session_tables($src);
    my ($ok, $err) = $self->_sqlite_try($sql, "$dir/sessions.db");
    die "opencode export failed: $err\n" unless $ok;
    return map { App::Saisons::Transfer::entry($_, db => 'sessions.db') } @$sessions;
}
# Merges the bundle's rows into the local database. Sessions already here
# are left alone; projects already here keep their local settings.
sub import_sessions {
    my ($self, $entries, $dir, $map) = @_;
    my $db     = _db_path();
    my $bundle = "$dir/sessions.db";
    my $fail   = sub { my ($msg) = @_; map { App::Saisons::Transfer::result($_, 'error', $msg) } @$entries };
    return $fail->('sqlite3 is not installed') unless _sqlite3();
    return $fail->("no opencode database at $db; start opencode once, then import again") unless -f $db;
    my $here_rows = $self->_sqlite_out(
        'SELECT id AS id FROM session WHERE id IN (' . _in_list(map { $_->{id} } @$entries) . ')');
    my %here = map { $_->{id} => 1 } @{ $here_rows // [] };

    my ($ok, $err) = $self->_sqlite_try($self->_rewrite_paths_sql($bundle, $map), $bundle);
    return $fail->("rewriting paths failed: $err") unless $ok;

    my %local  = map { $_ => 1 } $self->_session_tables($db);
    my @tables = $self->_session_tables($bundle);
    my $copy = sub {
        my ($table) = @_;
        my %has = map { $_ => 1 } $self->_columns($db, $table);
        my $cols = join ', ', map { qq{"$_"} } grep { $has{$_} } $self->_columns($bundle, $table);
        return qq{INSERT OR IGNORE INTO main."$table" ($cols) SELECT $cols FROM x."$table";\n};
    };
    my $sql = "ATTACH '" . _q($bundle) . "' AS x;\nBEGIN;\n"
      . join('', map { qq{DELETE FROM x."$_" WHERE session_id IN (SELECT id FROM main.session);\n} } @tables)
      . "DELETE FROM x.session WHERE id IN (SELECT id FROM main.session);\n"
      . $copy->('project')
      . $copy->('session')
      . join('', map { $copy->($_) } grep { $local{$_} } @tables)
      . "COMMIT;\n";
    ($ok, $err) = $self->_sqlite_try($sql);
    return $fail->("import failed: $err") unless $ok;
    return map { App::Saisons::Transfer::result($_, $here{ $_->{id} } ? 'exists' : 'imported') } @$entries;
}
# SQL that maps session directories and project worktrees in the bundle,
# then recomputes each session's path relative to its project.
sub _rewrite_paths_sql {
    my ($self, $bundle, $map) = @_;
    my $sql = '';
    for ([session => 'directory'], [project => 'worktree']) {
        my ($table, $col) = @$_;
        my $rows = $self->_sqlite_out("SELECT DISTINCT $col AS p FROM $table", $bundle) // [];
        for my $old (map { $_->{p} } @$rows) {
            my $new = $map->($old);
            next if !defined $old || $new eq $old;
            $sql .= "UPDATE $table SET $col = '" . _q($new) . "' WHERE $col = '" . _q($old) . "';\n";
        }
    }
    return 'SELECT 1;' unless length $sql;
    my $within = "p.worktree = session.directory OR p.worktree = '/' "
               . "OR substr(session.directory, 1, length(p.worktree) + 1) = p.worktree || '/'";
    return $sql
      . "UPDATE session SET path = (SELECT CASE WHEN p.worktree = session.directory THEN '' "
      . "WHEN p.worktree = '/' THEN substr(session.directory, 2) "
      . "ELSE substr(session.directory, length(p.worktree) + 2) END "
      . "FROM project p WHERE p.id = session.project_id) "
      . "WHERE path IS NOT NULL AND EXISTS (SELECT 1 FROM project p WHERE p.id = session.project_id AND ($within));\n";
}
1;
