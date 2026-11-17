# Adding a new agent adapter

Create `lib/Saisons/Adapter/YourAgent.pm` implementing these six methods:

```perl
package App::Saisons::Adapter::YourAgent;
use strict;
use warnings;
use App::Saisons::Launcher ();

sub new       { bless {}, shift }
sub name      { 'Your Agent' }   # display name shown in UI
sub tag       { 'YrA' }          # up to 5 chars shown in the Agt column
sub tag_color { 'bold white' }   # any Term::ANSIColor color string

# Return a list of session hashrefs. Required keys:
#   id       — unique string identifier
#   title    — short description (first message, or AI-generated title)
#   date     — ISO-8601 string "YYYY-MM-DDTHH:MM:SS" (for sorting)
#   epoch    — Unix timestamp (integer, for relative time display)
#   cwd      — working directory the session was started in
#   project  — project identifier (can equal cwd)
#   _file    — path to the session file on disk
#   _size    — file size in bytes (use -s $file)
#   _adapter — $self
sub find_sessions {
    my ($self) = @_;
    return ();  # return list of hashrefs
}

# Return a flat hash of { session_id => 1 } for sessions currently running.
# Return empty list if the agent has no running-session registry.
sub running {
    return ();
}

# Open the given sessions ($sessions is an arrayref of hashrefs).
# Use App::Saisons::Launcher::launch_cmd() to handle all launchers automatically:
#   tmux, screen, gnome-terminal, iterm, terminal-app, inline
sub launch {
    my ($self, $sessions, $launcher) = @_;
    for my $s (@$sessions) {
        my $cmd = "cd \Q$s->{cwd}\E && youragent --resume \Q$s->{id}\E";
        App::Saisons::Launcher::launch_cmd($cmd, $s->{cwd}, $launcher, $s->{title});
    }
}

# Delete a single session. Return true on success.
sub delete_session {
    my ($self, $session) = @_;
    return unlink $session->{_file};
}

# Return a list of { role => 'user'|'assistant', text => '...' } hashrefs
# for the peek/view feature. Return empty list if not supported.
sub load_messages {
    my ($self, $session) = @_;
    return ();
}

1;
```

## Export and import (optional)

Two more methods let `saisons --export` / `--import` move your sessions
to another machine. Adapters without them are skipped, with a note.

```perl
# Copy the sessions' data into $dir (a folder only this adapter writes to)
# and return one hashref per session for the manifest.
# App::Saisons::Transfer::entry($session, %extra) builds it; put whatever
# import needs to find the files again in %extra.
sub export_sessions {
    my ($self, $sessions, $dir) = @_;
    return map {
        App::Saisons::Transfer::copy_file($_->{_file}, "$dir/$_->{id}.jsonl");
        App::Saisons::Transfer::entry($_, file => "$_->{id}.jsonl");
    } @$sessions;
}

# Add the exported sessions here. $map turns a path from the source
# machine into the one to use here (it swaps the home directory).
# import_each runs the sub per entry; return 'imported', 'exists' or
# ('skipped', $why). A die is reported as an error for that session.
sub import_sessions {
    my ($self, $entries, $dir, $map) = @_;
    my $rewrite = App::Saisons::Transfer::json_path_rewriter($map, 'cwd');
    return App::Saisons::Transfer::import_each($entries, sub {
        my ($e)  = @_;
        my $file = App::Saisons::Transfer::safe_rel($e->{file});
        my $dst  = "$ENV{HOME}/.youragent/$file";
        return 'exists' if -e $dst;
        App::Saisons::Transfer::copy_file("$dir/$file", $dst, rewrite => $rewrite);
        return 'imported';
    });
}
```

That's it — `saisons` uses `Module::Pluggable` to auto-discover all
`App::Saisons::Adapter::*` modules under `lib/`, so no registration is needed.
Just drop the file in place.

The `tag` and `tag_color` methods control how the adapter appears in the `Agt`
column. If omitted, the tag defaults to the first 5 characters of the class
name suffix.
