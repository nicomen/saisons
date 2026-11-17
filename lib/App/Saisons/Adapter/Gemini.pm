package App::Saisons::Adapter::Gemini;
use strict;
use warnings;
use JSON::PP ();
use Time::Local ();
use App::Saisons ();
use App::Saisons::Launcher ();
use App::Saisons::Transfer ();
use Digest::SHA ();
use Encode ();
use File::Basename ();
sub new { bless {}, shift }
sub name      { 'Gemini' }
sub tag       { "\x{2726} Gem" }
sub tag_color { 'bold blue' }
sub find_sessions {
    my ($self) = @_;
    my $tmp = _tmp_dir();
    return () unless -d $tmp;
    my @sessions;
    opendir my $dh, $tmp or return ();
    for my $slug (readdir $dh) {
        next if $slug =~ /^\./;
        my $chats_dir = "$tmp/$slug/chats";
        next unless -d $chats_dir;
        opendir my $cdh, $chats_dir or next;
        for my $file (readdir $cdh) {
            next unless $file =~ /^session-.*\.jsonl$/;
            my $path = "$chats_dir/$file";
            my ($s) = App::Saisons::cached_parse($path, sub { _parse_session($path, $self) });
            next unless $s;
            push @sessions, $s;
        }
        closedir $cdh;
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
        my $cmd = "cd \Q$s->{cwd}\E && gemini --resume \Q$s->{id}\E";
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
    open my $fh, '<:utf8', $session->{_file} or return @messages;
    my $first = 1;
    while (my $line = <$fh>) {
        if ($first) { $first = 0; next }  
        my $obj  = eval { App::Saisons::decode_json_line($line) } or next;
        my $type = $obj->{type} // '';
        next unless $type eq 'user' || $type eq 'gemini';
        my $role = $type eq 'user' ? 'user' : 'assistant';
        my $text = $obj->{displayContent} // _extract_text($obj->{content});
        push @messages, { role => $role, text => $text } if length($text // '');
    }
    close $fh;
    return @messages;
}
sub _parse_session {
    my ($file, $adapter) = @_;
    open my $fh, '<:utf8', $file or return undef;
    my ($id, $title, $date_str, $epoch, $cwd);
    my $first = 1;
    while (my $line = <$fh>) {
        my $obj = eval { App::Saisons::decode_json_line($line) } or next;
        if ($first) {
            $first = 0;
            $id  = $obj->{sessionId} or return undef;
            $title = $obj->{summary} if $obj->{summary};
            if (my $ts = $obj->{startTime} // $obj->{lastUpdated}) {
                if ($ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/) {
                    $date_str = "$1-$2-$3T$4:$5:$6";
                    # not POSIX::tzset: it is unimplemented on Windows
                    $epoch = Time::Local::timegm($6, $5, $4, $3, $2 - 1, $1);
                }
            }
            $cwd = $ENV{HOME};
            if (ref $obj->{directories} eq 'ARRAY' && @{ $obj->{directories} }) {
                $cwd = $obj->{directories}[0];
            }
            next;
        }
        if (!$title && ($obj->{type} // '') eq 'user') {
            my $text = _extract_text($obj->{content});
            $title = $text if length($text // '');
            last;
        }
    }
    close $fh;
    return undef unless $id;
    $date_str //= '0000-00-00';
    $epoch    //= 0;
    $title    //= '(no title)';
    $cwd      //= $ENV{HOME};
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
        return join '', map { ref $_ eq 'HASH' ? ($_->{text} // '') : '' } @$content;
    }
    return $content->{text} // '';
}
sub _tmp_dir       { "$ENV{HOME}/.gemini/tmp" }
sub _projects_file { "$ENV{HOME}/.gemini/projects.json" }
# Gemini keeps each project's chats in tmp/<slug>/chats and maps project
# paths to slugs in projects.json.
sub export_sessions {
    my ($self, $sessions, $dir) = @_;
    my $known = App::Saisons::Transfer::read_json(_projects_file()) // {};
    my %path_of = reverse %{ $known->{projects} // {} };
    return map {
        my $file = File::Basename::basename($_->{_file});
        my $slug = File::Basename::basename(File::Basename::dirname(File::Basename::dirname($_->{_file})));
        App::Saisons::Transfer::copy_file($_->{_file}, "$dir/$slug/$file");
        # without a directories entry the session's cwd is only a guess
        my $cwd = $_->{cwd} eq $ENV{HOME} && $path_of{$slug} ? $path_of{$slug} : $_->{cwd};
        App::Saisons::Transfer::entry($_, cwd => $cwd, slug => $slug, file => $file);
    } @$sessions;
}
sub import_sessions {
    my ($self, $entries, $dir, $map) = @_;
    my $known = App::Saisons::Transfer::read_json(_projects_file()) // {};
    my $slugs = $known->{projects} //= {};
    my %taken = map { $_ => 1 } values %$slugs;
    my $changed;
    my @results = App::Saisons::Transfer::import_each($entries, sub {
        my ($e) = @_;
        my $file = App::Saisons::Transfer::safe_rel($e->{file});
        my $src  = "$dir/" . App::Saisons::Transfer::safe_rel($e->{slug}) . "/$file";
        my $cwd  = $map->($e->{cwd});
        my $slug = $slugs->{$cwd} // do {
            my ($base, $n, $s) = ($e->{slug}, 1, $e->{slug});
            $s = $base . '-' . ++$n while $taken{$s};
            $taken{$s} = 1;
            $changed = 1;
            $slugs->{$cwd} = $s;
        };
        my $dst = _tmp_dir() . "/$slug/chats/$file";
        return 'exists' if -e $dst;
        App::Saisons::Transfer::copy_file($src, $dst, rewrite => _header_rewriter($map, $cwd));
        return 'imported';
    });
    App::Saisons::Transfer::write_json(_projects_file(), $known) if $changed;
    return @results;
}
# The first line holds the session header: its projectHash is the SHA-256
# of the project path, and directories lists the workspace paths.
sub _header_rewriter {
    my ($map, $cwd) = @_;
    my $first = 1;
    return sub {
        my ($line) = @_;
        return $line unless $first;
        $first = 0;
        my $obj = eval { JSON::PP::decode_json($line) } or return $line;
        $obj->{projectHash} = Digest::SHA::sha256_hex(Encode::encode('UTF-8', $cwd))
            if exists $obj->{projectHash};
        $obj->{directories} = [ map { $map->($_) } @{ $obj->{directories} } ]
            if ref $obj->{directories} eq 'ARRAY';
        return JSON::PP->new->utf8->canonical->encode($obj) . "\n";
    };
}
1;
