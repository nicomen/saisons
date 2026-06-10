package App::Saisons::Launcher;
use strict;
use warnings;

# Launch a shell command in a new terminal tab/window according to $launcher.
# $title is used as the tab/window title where supported.
sub launch_cmd {
    my ($cmd, $cwd, $launcher, $title) = @_;
    $title //= 'saisons';

    if ($launcher eq 'tmux') {
        system('tmux', 'new-window', '-c', $cwd, $cmd);
    }
    elsif ($launcher eq 'screen') {
        system('screen', '-X', 'screen', '-t', substr($title, 0, 20),
               'bash', '-c', "$cmd; exec bash");
    }
    elsif ($launcher eq 'gnome-terminal') {
        system('gnome-terminal', '--tab', "--working-directory=$cwd",
               '--', 'bash', '--login', '-c', $cmd);
    }
    elsif ($launcher eq 'iterm') {
        my $escaped = _applescript_quote($cmd);
        my $script = qq{
            tell application "iTerm2"
                tell current window
                    create tab with default profile
                    tell current session of current tab
                        write text $escaped
                    end tell
                end tell
            end tell
        };
        system('osascript', '-e', $script);
    }
    elsif ($launcher eq 'terminal-app') {
        my $escaped = _applescript_quote($cmd);
        my $script = qq{
            tell application "Terminal"
                do script $escaped
                activate
            end tell
        };
        system('osascript', '-e', $script);
    }
    else {
        system('bash', '-c', $cmd);
    }
}

sub _applescript_quote {
    my ($str) = @_;
    $str =~ s/\\/\\\\/g;
    $str =~ s/"/\\"/g;
    return qq{"$str"};
}

1;
