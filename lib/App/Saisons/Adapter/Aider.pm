package App::Saisons::Adapter::Aider;
use strict;
use warnings;
use App::Saisons ();
use POSIX qw();
use App::Saisons::Launcher ();
use App::Saisons::Transfer ();
use File::Basename ();
use constant HISTORY => '.aider.chat.history.md';
sub new { bless {}, shift }
sub name      { 'Aider' }
sub tag       { "a Aid" }
sub tag_color { 'bold green' }
sub find_sessions {
    my ($self) = @_;
    my @search_dirs;
    if (my $env = $ENV{SAISONS_SEARCH_DIRS}) {
        @search_dirs = split /:/, $env;
    }
    else {
        my $home = $ENV{HOME};
        @search_dirs = grep { -d $_ }
            map { "$home/$_" } qw(projects dev src work code),
            '/projects';
    }
    my @history_files = _find_history_files(\@search_dirs, 1);
    my $home_file = "$ENV{HOME}/" . HISTORY;
    push @history_files, $home_file if -f $home_file;
    my @sessions;
    for my $file (@history_files) {
        my $cwd = File::Basename::dirname($file);
        push @sessions,
            App::Saisons::cached_parse($file, sub { _parse_history_file($file, $cwd, $self) });
    }
    return @sessions;
}
sub _find_history_files {
    my ($roots, $maxdepth) = @_;
    my @result;
    my @queue = map { [$_, 0] } @$roots;
    while (my $item = shift @queue) {
        my ($dir, $depth) = @$item;
        opendir my $dh, $dir or next;
        for my $entry (readdir $dh) {
            next if $entry eq '.' || $entry eq '..';
            my $path = "$dir/$entry";
            if (-f $path && $entry eq HISTORY) {
                push @result, $path;
            }
            elsif (-d $path && !-l $path && $depth < $maxdepth) {
                push @queue, [$path, $depth + 1];
            }
        }
        closedir $dh;
    }
    return @result;
}
sub running {
    return ();
}
sub launch {
    my ($self, $sessions, $launcher) = @_;
    my %by_cwd;
    push @{ $by_cwd{$_->{cwd}} }, $_ for @$sessions;
    for my $cwd (keys %by_cwd) {
        my $cmd = "cd \Q$cwd\E && aider --restore-chat-history";
        App::Saisons::Launcher::launch_cmd($cmd, $cwd, $launcher, 'aider');
    }
}
sub delete_session {
    my ($self, $session) = @_;
    my $file = $session->{_file};
    open my $fh, '<:utf8', $file or return 0;
    my $content = do { local $/; <$fh> };
    close $fh;
    my $re = _segment_re($session->{_header});
    $content =~ s/$re//;
    open $fh, '>', $file or return 0;
    print $fh $content;
    close $fh;
    return 1;
}
sub load_messages {
    my ($self, $session) = @_;
    my @messages;
    my $in_session = 0;
    open my $fh, '<:utf8', $session->{_file} or return @messages;
    while (my $line = <$fh>) {
        chomp $line;
        if ($line eq $session->{_header}) {
            $in_session = 1;
            next;
        }
        last if $in_session && $line =~ /^# aider chat started at /;
        next unless $in_session;
        if ($line =~ /^#### (.+)$/) {
            push @messages, { role => 'user', text => $1 };
        }
        elsif ($line =~ /^[^>#\s]/ && @messages && $messages[-1]{role} eq 'user') {
            push @messages, { role => 'assistant', text => $line };
        }
        elsif (@messages && $messages[-1]{role} eq 'assistant' && $line !~ /^>/) {
            $messages[-1]{text} .= "\n$line";
        }
    }
    close $fh;
    for my $m (@messages) {
        $m->{text} =~ s/\s+$//;
    }
    return @messages;
}
sub _parse_history_file {
    my ($file, $cwd, $adapter) = @_;
    my @sessions;
    open my $fh, '<:utf8', $file or return @sessions;
    my ($header, $date, $epoch, $title, @lines);
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ /^# aider chat started at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})$/) {
            if ($header) {
                push @sessions, _make_session($header, $date, $epoch, $cwd, $file, \@lines, $adapter);
            }
            $date   = $1;
            $header = $line;
            $epoch  = _parse_epoch($date);
            @lines  = ();
            $title  = undef;
            next;
        }
        next unless $header;
        push @lines, $line;
        if (!$title && $line =~ /^#### (.+)$/) {
            $title = $1;
        }
    }
    close $fh;
    push @sessions, _make_session($header, $date, $epoch, $cwd, $file, \@lines, $adapter)
        if $header;
    return @sessions;
}
sub _make_session {
    my ($header, $date, $epoch, $cwd, $file, $lines, $adapter) = @_;
    my $cwd_sum = 0;
    $cwd_sum = ($cwd_sum * 31 + ord($_)) & 0xFFFFFFFF for split //, $cwd;
    my $id = sprintf('%08x-%04x-%04x-%04x-%012x',
        $cwd_sum,
        ($cwd_sum >> 16) & 0xFFFF,
        ($epoch >> 16)   & 0xFFFF,
        $epoch           & 0xFFFF,
        $epoch);
    my ($title) = grep { /^#### / } @$lines;
    $title = "(no messages)" unless $title;
    $title =~ s/^#### //;
    my $size = length(join "\n", @$lines);
    return {
        id       => $id,
        title    => $title,
        date     => $date,
        epoch    => $epoch,
        cwd      => $cwd,
        project  => $cwd,
        _file    => $file,
        _header  => $header,
        _size    => $size,
        _adapter => $adapter,
    };
}
sub _parse_epoch {
    my ($date) = @_;  
    return 0 unless $date =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/;
    return POSIX::mktime($6, $5, $4, $3, $2-1, $1-1900);
}
# One session's part of a history file: its header up to the next header.
sub _segment_re {
    my ($header) = @_;
    return qr/^\Q$header\E\n.*?(?=^# aider chat started at |\z)/ms;
}
sub _slurp {
    my ($file) = @_;
    open my $fh, '<:raw', $file or return undef;
    my $content = do { local $/; <$fh> };
    close $fh;
    return $content;
}
sub export_sessions {
    my ($self, $sessions, $dir) = @_;
    my $n = 0;
    return map {
        my $content = _slurp($_->{_file}) // '';
        my $re = _segment_re($_->{_header});
        my ($segment) = $content =~ /($re)/;
        my $file = sprintf 'session-%04d.md', ++$n;
        open my $out, '>:raw', "$dir/$file" or die "Cannot write $dir/$file: $!\n";
        print $out $segment // "$_->{_header}\n";
        close $out;
        App::Saisons::Transfer::entry($_, file => $file, header => $_->{_header});
    } @$sessions;
}
# Aider keeps its history inside the project folder, so a session can only
# go back once that folder exists. Sessions are merged in date order.
sub import_sessions {
    my ($self, $entries, $dir, $map) = @_;
    return App::Saisons::Transfer::import_each($entries, sub {
        my ($e) = @_;
        my $cwd = $map->($e->{cwd});
        return ('skipped', "project folder $cwd is missing") unless -d $cwd;
        my $target  = "$cwd/" . HISTORY;
        my $content = _slurp($target) // '';
        return 'exists' if $content =~ /^\Q$e->{header}\E$/m;
        my $segment = _slurp("$dir/" . App::Saisons::Transfer::safe_rel($e->{file}))
            // die "Missing $e->{file} in bundle\n";
        $segment .= "\n" unless $segment =~ /\n\z/;
        my @parts = split /(?=^# aider chat started at )/m, $content;
        my $pre   = @parts && $parts[0] !~ /^# aider chat started at / ? shift @parts : '';
        $_ .= "\n" for grep { !/\n\z/ } @parts;
        my $tmp = "$target.saisons-$$";
        open my $out, '>:raw', $tmp or die "Cannot write $tmp: $!\n";
        print $out $pre, sort { ($a =~ /^(.*)/)[0] cmp ($b =~ /^(.*)/)[0] } @parts, $segment;
        close $out or die "Cannot write $tmp: $!\n";
        rename $tmp, $target or die "Cannot write $target: $!\n";
        return 'imported';
    });
}
1;
