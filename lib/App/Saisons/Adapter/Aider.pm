package App::Saisons::Adapter::Aider;
use strict;
use warnings;
use POSIX qw();
use App::Saisons::Launcher ();

# Aider stores chat history in .aider.chat.history.md files, one per directory.
# Each file contains multiple sessions separated by:
#   # aider chat started at YYYY-MM-DD HH:MM:SS
#
# Since Aider has no UUID-based session IDs, we synthesize one from the
# directory path + session start timestamp.

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

    # Also check $HOME directly — aider run from home produces ~/.aider.chat.history.md
    my $home_file = "$ENV{HOME}/.aider.chat.history.md";
    push @history_files, $home_file if -f $home_file;

    my @sessions;
    for my $file (@history_files) {
        (my $cwd = $file) =~ s|/\.aider\.chat\.history\.md$||;
        push @sessions, _parse_history_file($file, $cwd, $self);
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
            if (-f $path && $entry eq '.aider.chat.history.md') {
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
    # Aider doesn't maintain a running-sessions registry like Claude does
    return ();
}

sub launch {
    my ($self, $sessions, $launcher) = @_;

    # Group by cwd — open one aider session per unique directory
    my %by_cwd;
    push @{ $by_cwd{$_->{cwd}} }, $_ for @$sessions;

    for my $cwd (keys %by_cwd) {
        # --restore-chat-history replays the previous conversation into context
        my $cmd = "cd \Q$cwd\E && aider --restore-chat-history";
        App::Saisons::Launcher::launch_cmd($cmd, $cwd, $launcher, 'aider');
    }
}

sub delete_session {
    my ($self, $session) = @_;
    # Aider sessions can't be individually deleted without rewriting the file.
    # We rewrite the file excluding this session's block.
    my $file = $session->{_file};
    open my $fh, '<', $file or return 0;
    my $content = do { local $/; <$fh> };
    close $fh;

    # Remove the session block — from its header line up to (but not including)
    # the next session header, or end of file
    my $header = quotemeta($session->{_header});
    $content =~ s/^$header\n.*?(?=^# aider chat started at |\z)//ms;

    open $fh, '>', $file or return 0;
    print $fh $content;
    close $fh;
    return 1;
}

sub load_messages {
    my ($self, $session) = @_;
    my @messages;
    my $in_session = 0;

    open my $fh, '<', $session->{_file} or return @messages;
    while (my $line = <$fh>) {
        chomp $line;

        # Detect start of our session
        if ($line eq $session->{_header}) {
            $in_session = 1;
            next;
        }

        # Detect start of next session — stop
        last if $in_session && $line =~ /^# aider chat started at /;

        next unless $in_session;

        # User messages start with ####
        if ($line =~ /^#### (.+)$/) {
            push @messages, { role => 'user', text => $1 };
        }
        # Assistant responses are plain text lines (not starting with > or #)
        elsif ($line =~ /^[^>#\s]/ && @messages && $messages[-1]{role} eq 'user') {
            push @messages, { role => 'assistant', text => $line };
        }
        elsif (@messages && $messages[-1]{role} eq 'assistant' && $line !~ /^>/) {
            $messages[-1]{text} .= "\n$line";
        }
    }
    close $fh;

    # Clean up trailing whitespace from assistant messages
    for my $m (@messages) {
        $m->{text} =~ s/\s+$//;
    }

    return @messages;
}

# ── private helpers ───────────────────────────────────────────────────────────

sub _parse_history_file {
    my ($file, $cwd, $adapter) = @_;
    my @sessions;

    open my $fh, '<', $file or return @sessions;

    my ($header, $date, $epoch, $title, @lines);

    while (my $line = <$fh>) {
        chomp $line;

        if ($line =~ /^# aider chat started at (\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})$/) {
            # Save previous session if any
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

        # First user message becomes the title
        if (!$title && $line =~ /^#### (.+)$/) {
            $title = $1;
        }
    }
    close $fh;

    # Save last session
    push @sessions, _make_session($header, $date, $epoch, $cwd, $file, \@lines, $adapter)
        if $header;

    return @sessions;
}

sub _make_session {
    my ($header, $date, $epoch, $cwd, $file, $lines, $adapter) = @_;

    # Synthesize a stable UUID-like ID from directory path + timestamp.
    # We encode the cwd as a hex string in the first 3 segments and the
    # epoch seconds in the last 2, giving a unique ID per session.
    my $cwd_sum = 0;
    $cwd_sum = ($cwd_sum * 31 + ord($_)) & 0xFFFFFFFF for split //, $cwd;
    my $id = sprintf('%08x-%04x-%04x-%04x-%012x',
        $cwd_sum,
        ($cwd_sum >> 16) & 0xFFFF,
        ($epoch >> 16)   & 0xFFFF,
        $epoch           & 0xFFFF,
        $epoch);

    # First user message as title, fallback to date
    my ($title) = grep { /^#### / } @$lines;
    $title = $title ? $title =~ s/^#### //r : "(no messages)";

    # Approximate size: number of lines in this session's block
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
    my ($date) = @_;  # "YYYY-MM-DD HH:MM:SS"
    return 0 unless $date =~ /^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})$/;
    return POSIX::mktime($6, $5, $4, $3, $2-1, $1-1900);
}

1;
