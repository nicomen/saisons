package App::Saisons::Adapter::Opencode;
use strict;
use warnings;
use JSON::PP ();
use POSIX qw();
use App::Saisons::Launcher ();

# opencode stores sessions under $XDG_DATA_HOME/opencode/storage/session/<projectID>/
# Each session is a directory containing message JSON files.
# The session metadata is in a file named with the session UUID.
# Resume with: opencode --session <sessionID>

sub new { bless {}, shift }

sub name      { 'opencode' }
sub tag       { "\x{2336} Opc" }
sub tag_color { 'bold magenta' }

sub find_sessions {
    my ($self) = @_;
    my $data_home = $ENV{XDG_DATA_HOME} // "$ENV{HOME}/.local/share";
    my $storage   = "$data_home/opencode/storage/session";
    return () unless -d $storage;

    my @sessions;
    opendir my $dh, $storage or return ();
    for my $project_id (readdir $dh) {
        next if $project_id =~ /^\./;
        my $project_dir = "$storage/$project_id";
        next unless -d $project_dir;
        opendir my $pdh, $project_dir or next;
        for my $file (readdir $pdh) {
            next if $file =~ /^\./;
            my $path = "$project_dir/$file";
            next unless -f $path && $file =~ /\.json$/;
            my $s = _parse_session($path, $self) or next;
            push @sessions, $s;
        }
        closedir $pdh;
    }
    closedir $dh;
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
    return unlink $session->{_file};
}

sub load_messages {
    my ($self, $session) = @_;
    my @messages;
    open my $fh, '<', $session->{_file} or return @messages;
    my $json = do { local $/; <$fh> };
    close $fh;
    my $obj = eval { JSON::PP::decode_json($json) } or return @messages;

    my $msgs = $obj->{messages} // [];
    for my $msg (@$msgs) {
        my $role = $msg->{role} // '';
        next unless $role eq 'user' || $role eq 'assistant';
        my $text = _extract_text($msg->{content});
        push @messages, { role => $role, text => $text } if length($text // '');
    }
    return @messages;
}

# ── private helpers ───────────────────────────────────────────────────────────

sub _parse_session {
    my ($file, $adapter) = @_;

    open my $fh, '<', $file or return undef;
    my $json = do { local $/; <$fh> };
    close $fh;
    my $obj = eval { JSON::PP::decode_json($json) } or return undef;

    my $id  = $obj->{id}  or return undef;
    my $cwd = $obj->{cwd} // $ENV{HOME};

    my $title = $obj->{title} // $obj->{summary};
    if (!$title) {
        for my $msg (@{ $obj->{messages} // [] }) {
            next unless ($msg->{role} // '') eq 'user';
            $title = _extract_text($msg->{content});
            last if length($title // '');
        }
    }
    $title //= '(no title)';

    my ($date_str, $epoch) = ('0000-00-00', 0);
    if (my $ts = $obj->{createdAt} // $obj->{updatedAt}) {
        if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
            $date_str = "$1-$2-$3T$4:$5:$6";
            local $ENV{TZ} = 'UTC';
            POSIX::tzset();
            $epoch = POSIX::mktime($6, $5, $4, $3, $2 - 1, $1 - 1900);
            delete $ENV{TZ};
            POSIX::tzset();
        }
    }

    return {
        id       => $id,
        title    => $title,
        date     => $date_str,
        epoch    => $epoch,
        cwd      => $cwd,
        project  => $cwd,
        _file    => $file,
        _size    => (-s $file) // 0,
        _adapter => $adapter,
    };
}

sub _extract_text {
    my ($content) = @_;
    return '' unless defined $content;
    return $content unless ref $content;
    if (ref $content eq 'ARRAY') {
        return join '', map {
            ref $_ eq 'HASH' ? ($_->{text} // '') : (ref $_ ? '' : $_)
        } @$content;
    }
    return $content->{text} // '';
}

1;
