package App::Saisons::Launcher;
use strict;
use warnings;

our $batching; my @queue;

# Runs $code (which calls launch_cmd) and opens what it launched together:
# gnome-terminal gets one new window holding a tab per session, since
# separate --tab calls each open their own window when it has no focus.
sub batch {
    my ($launcher, $code) = @_;
    {
        local $batching = $launcher eq 'gnome-terminal';
        @queue = ();
        $code->();
    }
    return unless @queue;
    if (@queue == 1) {
        my ($cmd, $cwd, $title) = @{ shift @queue };
        return launch_cmd($cmd, $cwd, $launcher, $title);
    }
    my @args = ('--window');
    for my $i (0 .. $#queue) {
        my ($cmd, $cwd) = @{ $queue[$i] };
        push @args, '--tab' if $i;
        push @args, "--working-directory=$cwd", '-e', "bash --login -c " . shell_quote($cmd);
    }
    @queue = ();
    # -e is deprecated and gnome-terminal says so on stderr, over the list
    open my $err, '>&', \*STDERR;
    open STDERR, '>', '/dev/null';
    system('gnome-terminal', @args);
    open STDERR, '>&', $err;
}

sub shell_quote {
    my ($s) = @_;
    $s =~ s/'/'\\''/g;
    return "'$s'";
}

sub launch_cmd {
    my ($cmd, $cwd, $launcher, $title) = @_;
    return push @queue, [$cmd, $cwd, $title] if $batching;
    $title //= 'saisons';
    if ($launcher eq 'tmux') {
        system('tmux', 'new-window', '-c', $cwd, $cmd);
    }
    elsif ($launcher eq 'screen') {
        system('screen', '-X', 'screen', '-t', substr($title, 0, 20),
               'bash', '-c', "$cmd; exec bash");
    }
    elsif ($launcher eq 'ptyxis') {
        system('ptyxis', '--tab', '-d', $cwd, '-T', substr($title, 0, 40),
               '--', 'bash', '--login', '-c', $cmd);
    }
    elsif ($launcher eq 'tilix') {
        system('tilix', '--action=app-new-session', "--working-directory=$cwd",
               '-t', substr($title, 0, 40), '-e', "bash --login -c " . shell_quote($cmd));
    }
    elsif ($launcher eq 'gnome-terminal') {
        system('gnome-terminal', '--tab', "--working-directory=$cwd",
               '--', 'bash', '--login', '-c', $cmd);
    }
    elsif ($launcher eq 'iterm') {
        my $escaped = _applescript_quote($cmd);
        system('osascript', '-e', q'tell application "iTerm2"\ntell current window\ncreate tab with default profile\ntell current session of current tab\nwrite text $escaped\nend tell\nend tell\nend tell');
    }
    elsif ($launcher eq 'terminal-app') {
        my $escaped = _applescript_quote($cmd);
        system('osascript', '-e', q'tell application "Terminal"\ndo script $escaped\nactivate\nend tell');
    }
    else {
        system('bash', '-c', $cmd);
    }
}
sub _applescript_quote {
    my ($str) = @_;
    $str =~ s/\\/\\\\/g;
    $str =~ s/"/\\"/g;
    return q'"$str"';
}
1;
