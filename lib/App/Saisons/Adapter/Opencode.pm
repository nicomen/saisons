package App::Saisons::Adapter::Opencode;
use strict;
use warnings;
use JSON::PP ();
use POSIX qw();
use App::Saisons::Launcher ();
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
    my $data_home = $ENV{XDG_DATA_HOME} // "$ENV{HOME}/.local/share";
    return "$data_home/opencode/opencode.db";
}

sub _shq {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub _q {
    my ($s) = @_;
    $s =~ s/'/''/g if defined $s;
    return $s // '';
}

sub _sqlite_out {
    my ($self, $sql) = @_;
    my $db  = _db_path();
    my $exe = _sqlite3() or return undef;
    return undef unless -f $db;
    my $cmd = join(' ', _shq($exe), '-readonly', '-json', _shq($db), _shq($sql)) . ' 2>/dev/null';
    my $out = `$cmd`;
    return undef unless $? == 0 && defined $out;
    my $rows = eval { JSON::PP::decode_json($out) };
    return $rows // [];
}

sub _sqlite_exec {
    my ($self, $sql) = @_;
    my $db  = _db_path();
    my $exe = _sqlite3() or return 0;
    return 0 unless -f $db;
    my $cmd = join(' ', _shq($exe), _shq($db), _shq($sql), '>/dev/null', '2>&1');
    return system($cmd) == 0;
}

sub find_sessions {
    my ($self) = @_;
    my $rows = $self->_sqlite_out(<<'SQL') or return ();
SELECT s.id AS id, s.directory AS dir, s.title AS title, s.time_created AS created_ms, s.time_updated AS updated_ms, COALESCE((SELECT SUM(LENGTH(d.data)) FROM ( SELECT data FROM message WHERE session_id = s.id UNION ALL SELECT data FROM part WHERE session_id = s.id ) d), 0) AS bytes FROM session s WHERE s.time_archived IS NULL ORDER BY s.time_updated DESC
SQL
    my @sessions;
    for my $row (@$rows) {
        next unless $row->{id};
        my $ms   = $row->{updated_ms} || $row->{created_ms} || 0;
        my $epoch = int($ms / 1000);
        push @sessions, {
            id       => $row->{id},
            title    => length($row->{title} // '') ? $row->{title} : '(no title)',
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
    return ();
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
1;
