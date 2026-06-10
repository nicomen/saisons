package App::Saisons::UI;
use strict;
use warnings;
use utf8;
use POSIX qw();           # for Termios (raw terminal mode)
use Term::ANSIColor qw(colored color);
use JSON::PP ();

# Where we persist the user's selection and view mode between runs
my $STATE_FILE = "$ENV{HOME}/.config/saisons/state.json";

# ── Color helpers ─────────────────────────────────────────────────────────────
# Two kinds of helpers:
#
# _col_*()  — emit just the ANSI start code, no reset. Use inside a row that
#              ends with a single RESET. This way no mid-line \e[0m breaks an
#              outer highlight (e.g. reverse video or a background color).
#
# _str_*()  — wrap a string with start + reset. Use for standalone colored
#              strings outside of a row (headers, prompts, messages).

use constant RESET => color('reset');

sub _col_yellow  { color('yellow') }
sub _col_cyan    { color('cyan') }
sub _col_green   { color('green') }
sub _col_white   { color('white') }
sub _col_boldgrn { color('bold green') }
sub _col_sel     { color('black on_cyan') }
sub _col_active  { color('white on_blue') }

sub _str_bold    { colored($_[0], 'bold') }
sub _str_dim     { colored($_[0], 'faint') }
sub _str_boldyel { colored($_[0], 'bold yellow') }
sub _str_boldcyn { colored($_[0], 'bold cyan') }
sub _str_boldgrn { colored($_[0], 'bold green') }
sub _str_boldred { colored($_[0], 'bold red') }

sub new { bless {}, shift }

# ── Persisted state ───────────────────────────────────────────────────────────
# Saves/restores which sessions are selected and whether grouped mode is on.

sub _load_state {
    open my $fh, '<', $STATE_FILE or return {};
    my $json = do { local $/; <$fh> };
    close $fh;
    eval { JSON::PP::decode_json($json) } // {};
}

sub _save_state {
    my ($state) = @_;
    (my $dir = $STATE_FILE) =~ s|/[^/]+$||;
    mkdir $dir unless -d $dir;
    open my $fh, '>', $STATE_FILE or return;
    print $fh JSON::PP::encode_json($state);
    close $fh;
}

# ── Raw terminal mode ─────────────────────────────────────────────────────────
# We switch the terminal to raw mode so we can read individual keypresses
# without waiting for Enter. POSIX::Termios lets us do this portably.
# _init_term() saves the original settings so _restore_term() can put them back.

my ($OLD_TERM, $ROWS, $COLS);

sub _init_term {
    binmode STDOUT, ':utf8';
    STDOUT->autoflush(1);
    ($ROWS, $COLS) = _term_size();
    my $tty = \*STDIN;
    $OLD_TERM = POSIX::Termios->new;
    $OLD_TERM->getattr(fileno($tty));
    my $raw = POSIX::Termios->new;
    $raw->getattr(fileno($tty));
    # Disable ECHO (don't print typed chars) and ICANON (don't wait for newline)
    $raw->setlflag($raw->getlflag & ~(POSIX::ECHO | POSIX::ICANON));
    $raw->setcc(POSIX::VMIN, 1);   # return after 1 byte
    $raw->setcc(POSIX::VTIME, 0);  # no timeout
    $raw->setattr(fileno($tty), POSIX::TCSANOW);
}

sub _restore_term {
    $OLD_TERM->setattr(fileno(\*STDIN), POSIX::TCSANOW) if $OLD_TERM;
}

sub _term_size {
    # Ask the terminal for its dimensions via stty
    my $s = `stty size 2>/dev/null`;
    return ($s =~ /^(\d+)\s+(\d+)/) ? ($1, $2) : (40, 120);
}

# ── Keypress reader ───────────────────────────────────────────────────────────
# Reads a single keypress and returns a string name for it.
# Arrow keys and special keys send multi-byte escape sequences: ESC [ X
# We use select() with a 50ms timeout to distinguish a lone ESC keypress
# from the start of an escape sequence.

sub _read_key {
    my $c = '';
    sysread STDIN, $c, 1;

    if ($c eq "\033") {
        # Check if more bytes follow within 50ms (escape sequence vs lone ESC)
        my $rin = '';
        vec($rin, fileno(STDIN), 1) = 1;
        return 'ESC' unless select($rin, undef, undef, 0.05);

        my $c2 = '';
        sysread STDIN, $c2, 1;
        if ($c2 eq '[') {
            my $c3 = '';
            sysread STDIN, $c3, 1;
            return 'UP'    if $c3 eq 'A';
            return 'DOWN'  if $c3 eq 'B';
            return 'RIGHT' if $c3 eq 'C';
            return 'LEFT'  if $c3 eq 'D';
            if ($c3 =~ /[0-9]/) {
                # Extended sequences end with ~: e.g. ESC [ 5 ~  = Page Up
                my $c4 = ''; sysread STDIN, $c4, 1;
                return 'PGUP'   if $c3 eq '5';
                return 'PGDN'   if $c3 eq '6';
                return 'HOME'   if $c3 eq '1';
                return 'END'    if $c3 eq '4';
                return 'DELETE' if $c3 eq '3';
                return 'IGNORE';
            }
            return 'IGNORE';
        }
        return 'ESC';
    }

    return $c;
}

# ── Main interactive list ─────────────────────────────────────────────────────
# Shows a scrollable list of sessions. The user navigates with arrow keys,
# toggles selection with Enter, and opens sessions with 'o'.
# Returns a list of selected session hashrefs, or empty list if cancelled.

sub interactive_select {
    my ($self, $sessions, $running) = @_;
    $running //= {};

    # Restore previous selection and view mode
    my $state   = _load_state();
    my %sel_ids = map { $_ => 1 } @{ $state->{selected} // [] };
    my $grouped = $state->{grouped} // 0;  # 0 = flat (default)
    my $cursor  = 0;
    my $offset      = 0;   # index of the first visible row
    my $filter      = '';  # metadata filter: title/path/date (fast, no file I/O)
    my $fulltext    = '';  # full-text filter: searches message content (slower)

    my @sort_cols = qw(selected running agent date size session path title);
    my $sort_idx  = 0;   # index into @sort_cols — starts on 'selected'
    my $sort_rev  = 0;   # 0 = normal, 1 = reversed

    _init_term();
    local $SIG{INT} = sub { _restore_term(); print "\033[?25h\033[0m\n"; STDOUT->flush(); exit 0 };
    print "\033[?25l";  # hide blinking cursor

    my @result;

    while (1) {
        ($ROWS, $COLS) = _term_size();

        # Apply filters — metadata filter is instant, fulltext scans files
        my @filtered = grep { ref $_ eq 'HASH' } @$sessions;
        if ($filter) {
            my $re = eval { qr/\Q$filter\E/i } // qr/(?!)/;
            @filtered = grep {
                $_->{title} =~ $re || $_->{cwd} =~ $re || $_->{date} =~ $re
            } @filtered;
        }
        if ($fulltext) {
            @filtered = grep { _search_content($_, $fulltext) } @filtered;
        }
        my $visible_sessions = \@filtered;

        my $sort_col = $sort_cols[$sort_idx];
        my @entries = _build_entries($visible_sessions, $running, \%sel_ids, $grouped, $sort_col, $sort_rev);
        my $n       = scalar @entries;
        my $visible = $ROWS - 3 - 1;  # header + sep + footer + 1-line banner

        # Keep cursor and scroll offset within valid bounds
        $cursor = 0      if $cursor < 0;
        $cursor = $n - 1 if $cursor >= $n && $n;
        # Skip over header rows — cursor must always land on a session row
        $cursor++ while $cursor < $n - 1 && $entries[$cursor] && $entries[$cursor]{type} eq 'header';
        $cursor-- while $cursor > 0      && $entries[$cursor] && $entries[$cursor]{type} eq 'header';
        if ($n <= $visible) {
            $offset = 0;
        } else {
            my $max = $n - $visible;
            $offset = $max if $offset > $max;
            $offset = $cursor              if $cursor < $offset;
            $offset = $cursor - $visible + 1 if $cursor >= $offset + $visible;
            $offset = 0 if $offset < 0;
        }

        _render(\@entries, $cursor, $offset, $visible, \%sel_ids, $grouped, $running, $filter, $fulltext, $sort_col, $sort_rev);

        my $key = _read_key();

        if ($key eq 'UP' || $key eq 'k') {
            $cursor--;
            # Skip over group header rows — they are not selectable
            $cursor-- while $cursor > 0 && $entries[$cursor]{type} eq 'header';
        }
        elsif ($key eq 'DOWN' || $key eq 'j') {
            $cursor++;
            $cursor++ while $cursor < $n-1 && $entries[$cursor]{type} eq 'header';
        }
        elsif ($key eq 'PGUP') { $cursor -= $visible; $offset -= $visible }
        elsif ($key eq 'PGDN') { $cursor += $visible; $offset += $visible }
        elsif ($key eq 'HOME' || $key eq 'g') { $cursor = 0; $offset = 0 }
        elsif ($key eq 'END'  || $key eq 'G') { $cursor = $n - 1 }
        elsif ($key eq ' ') {
            # Toggle selection on the session under the cursor
            my $e = $entries[$cursor];
            if ($e && $e->{type} eq 'session') {
                my $id = $e->{session}{id};
                $sel_ids{$id} ? delete $sel_ids{$id} : ($sel_ids{$id} = 1);
            }
        }
        elsif ($key eq "\n" || $key eq "\r") {
            # Open selected sessions (or cursor session if none selected)
            my @to_open = _selected_sessions(\%sel_ids, $sessions);
            unless (@to_open) {
                my $e = $entries[$cursor];
                push @to_open, $e->{session} if $e && $e->{type} eq 'session';
            }
            if (@to_open) {
                my @already_running = grep { $running->{ $_->{id} } } @to_open;
                if (@already_running) {
                    my $ans = _confirm(scalar(@already_running) . " session(s) already running. Open anyway? [y/N] ");
                    next unless $ans =~ /^y/i;
                }
                _save_state({ selected => [map { $_->{id} } @to_open], grouped => $grouped });
                @result = @to_open;
                last;
            }
        }
        elsif ($key eq 'a') {
            # Select all sessions
            $sel_ids{$_->{id}} = 1 for grep { $_->{type} eq 'session' } @entries;
        }
        elsif ($key eq 'A') {
            # Deselect all
            %sel_ids = ();
        }
        elsif ($key eq 's' || $key eq 'S') {
            my $new_rev = $key eq 'S' ? 1 : 0;
            my ($new_idx) = _sort_popup(\@sort_cols, $sort_idx, $new_rev);
            if (defined $new_idx) {
                $sort_idx = $new_idx;
                $sort_rev = $new_rev;
                $cursor = 0; $offset = 0;
            }
        }
        elsif ($key eq 't') {
            # Toggle between flat (date order) and grouped (by directory) view
            $grouped = !$grouped;
            $cursor = 0; $offset = 0;
        }
        elsif ($key eq 'r') {
            # Re-scan which sessions are currently running
            my %seen;
            %$running = ();
            for my $s (@$sessions) {
                next if $seen{ref $s->{_adapter}}++;
                %$running = (%$running, $s->{_adapter}->running);
            }
        }
        elsif ($key eq 'v') {
            # View conversation history for the session under the cursor
            my $e = $entries[$cursor];
            if ($e && $e->{type} eq 'session') {
                _restore_term(); print "\033[?25h";
                _peek($e->{session});
                _init_term(); print "\033[?25l";
            }
        }
        elsif ($key eq 'd' || $key eq 'DELETE') {
            # Delete selected sessions, or the one under the cursor if none selected
            my @to_del = _selected_sessions(\%sel_ids, $sessions);
            unless (@to_del) {
                my $e = $entries[$cursor];
                push @to_del, $e->{session} if $e && $e->{type} eq 'session';
            }
            if (@to_del) {
                _do_delete(\@to_del, $sessions, \%sel_ids);
                $cursor = 0; $offset = 0;
            }
        }
        elsif ($key eq 'm') {
            # Move selected sessions to a different directory
            my @to_move = _selected_sessions(\%sel_ids, $sessions);
            if (@to_move) {
                _restore_term(); print "\033[?25h";
                _do_move(\@to_move, $sessions, \%sel_ids);
                $cursor = 0; $offset = 0;
                _init_term(); print "\033[?25l";
            }
        }
        elsif ($key eq '/' || $key eq '?') {
            # Incremental search — stay in raw mode, update list on every keystroke
            my $is_fulltext = $key eq '?';
            my $prompt      = $is_fulltext
                ? colored('?search: ', 'bold yellow')
                : colored('/filter: ', 'bold cyan');
            my $query = $is_fulltext ? $fulltext : $filter;

            while (1) {
                # For metadata filter: update list live on every keystroke.
                # For full-text search: only show current results (applied on Enter).
                my @f2 = grep { ref $_ eq 'HASH' } @$sessions;
                if (!$is_fulltext && $query) {
                    my $re = eval { qr/\Q$query\E/i } // qr/(?!)/;
                    @f2 = grep { $_->{title} =~ $re || $_->{cwd} =~ $re || $_->{date} =~ $re } @f2;
                } elsif ($is_fulltext && $fulltext) {
                    # Show previously applied fulltext results while typing new query
                    my $re = eval { qr/\Q$fulltext\E/i } // qr/(?!)/;
                    @f2 = grep { _search_content($_, $fulltext) } @f2;
                }
                ($ROWS, $COLS) = _term_size();
                my $sort_col = $sort_cols[$sort_idx];
                my @e2   = _build_entries(\@f2, $running, \%sel_ids, $grouped, $sort_col, $sort_rev);
                my $n2   = scalar @e2;
                my $vis2 = $ROWS - 3 - 1;
                my $cur2 = 0;
                $cur2++ while $cur2 < $n2 - 1 && $e2[$cur2] && $e2[$cur2]{type} eq 'header';
                _render(\@e2, $cur2, 0, $vis2, \%sel_ids, $grouped, $running,
                    ($is_fulltext ? $filter : $query),
                    ($is_fulltext ? $query  : $fulltext),
                    $sort_col, $sort_rev);
                # Overwrite footer with search prompt + current query
                print "\033[${ROWS};1H\033[K";
                my $hint = $is_fulltext ? ' (ENTER=search ESC=cancel)' : ' (ENTER=apply ESC=cancel)';
                print $prompt . colored($query, 'bold white') . colored($hint, 'faint');
                STDOUT->flush();

                my $ch = _read_key();
                if ($ch eq "\n" || $ch eq "\r") {
                    # Apply query — for fulltext this triggers the file scan
                    if ($is_fulltext) { $fulltext = $query } else { $filter = $query }
                    $cursor = 0; $offset = 0;
                    last;
                } elsif ($ch eq 'ESC') {
                    last;  # cancel — don't apply
                } elsif ($ch eq 'BACKSPACE' || $ch eq "\x7f" || $ch eq "\x08") {
                    $query = substr($query, 0, -1) if length($query);
                } elsif (length($ch) == 1 && $ch ge ' ') {
                    $query .= $ch;
                }
            }
        }
        elsif ($key eq 'ESC') {
            if ($filter || $fulltext) {
                # ESC clears active filters
                $filter = ''; $fulltext = '';
                $cursor = 0; $offset = 0;
            } else {
                _save_state({ selected => [keys %sel_ids], grouped => $grouped });
                last;
            }
        }
        elsif ($key eq 'q') {
            # Save current selection so it's restored next time
            _save_state({ selected => [keys %sel_ids], grouped => $grouped });
            last;
        }
    }

    _restore_term();
    print "\033[?25h\033[2J\033[H\033[0m";  # show cursor, clear screen, reset all attributes
    STDOUT->flush();
    return @result;
}

# Returns the session hashrefs for all currently selected session IDs
sub _selected_sessions {
    my ($sel_ids, $sessions) = @_;
    my %by_id = map { $_->{id} => $_ } @$sessions;
    return map { $by_id{$_} } grep { $by_id{$_} } keys %$sel_ids;
}

# ── Entry list builder ────────────────────────────────────────────────────────
# Converts the flat sessions array into a list of display entries.
# In grouped mode, inserts header entries before each directory's sessions.
# Each entry is either: { type => 'session', session => $hashref }
#                    or: { type => 'header',  label   => $dir_path }

my %SORT_CMP = (
    selected => sub { ($_[1]{_sel}  // 0) <=> ($_[0]{_sel}  // 0) },
    running  => sub { ($_[1]{_run}  // 0) <=> ($_[0]{_run}  // 0) },
    agent    => sub { _adapter_tag($_[0]{_adapter}, 1) cmp _adapter_tag($_[1]{_adapter}, 1) },
    date     => sub { $_[0]{date}          cmp $_[1]{date}          },
    size     => sub { ($_[0]{_size} // 0) <=> ($_[1]{_size} // 0)  },
    session  => sub { $_[0]{id}            cmp $_[1]{id}            },
    path     => sub { $_[0]{cwd}           cmp $_[1]{cwd}           },
    title    => sub { lc($_[0]{title})     cmp lc($_[1]{title})     },
);

sub _sorted {
    my ($sessions, $sort_col, $sort_rev, $sel_ids, $running) = @_;
    my $cmp = $SORT_CMP{$sort_col} // $SORT_CMP{date};
    # Annotate with sel/run flags for sorting, then strip after
    my @ann = map { { %$_, _sel => $sel_ids->{$_->{id}} ? 1 : 0,
                              _run => $running->{$_->{id}} ? 1 : 0 } } @$sessions;
    my @sorted = sort { $cmp->($a, $b) } @ann;
    # reverse when descending is requested
    @sorted = reverse @sorted if $sort_rev;
    return @sorted;
}

sub _build_entries {
    my ($sessions, $running, $sel_ids, $grouped, $sort_col, $sort_rev) = @_;
    $sort_col //= 'date';

    my @valid = grep { ref $_ eq 'HASH' } @$sessions;

    if ($grouped) {
        my %by_dir;
        push @{ $by_dir{$_->{cwd}} }, $_ for @valid;

        # Sort sessions within each group, then sort groups by their first (top) session
        my %sorted_dir;
        for my $dir (keys %by_dir) {
            $sorted_dir{$dir} = [ _sorted($by_dir{$dir}, $sort_col, $sort_rev, $sel_ids, $running) ];
        }
        my $dir_cmp = $SORT_CMP{$sort_col} // $SORT_CMP{date};
        my @dirs = sort {
            my $ann_a = { %{$sorted_dir{$a}[0]}, _sel => $sel_ids->{$sorted_dir{$a}[0]{id}} ? 1 : 0,
                                                  _run => $running->{$sorted_dir{$a}[0]{id}} ? 1 : 0 };
            my $ann_b = { %{$sorted_dir{$b}[0]}, _sel => $sel_ids->{$sorted_dir{$b}[0]{id}} ? 1 : 0,
                                                  _run => $running->{$sorted_dir{$b}[0]{id}} ? 1 : 0 };
            $dir_cmp->($ann_a, $ann_b) || $a cmp $b
        } keys %sorted_dir;
        @dirs = reverse @dirs if $sort_rev;

        my @entries;
        for my $dir (@dirs) {
            push @entries, { type => 'header', label => $dir };
            push @entries, map { { type => 'session', session => $_ } } @{ $sorted_dir{$dir} };
        }
        return @entries;
    }

    return map { { type => 'session', session => $_ } }
               _sorted(\@valid, $sort_col, $sort_rev, $sel_ids, $running);
}

# Truncates a path to fit in $width columns, adding '...' prefix if needed
sub _truncate_path {
    my ($path, $width) = @_;
    return sprintf "%-${width}s", length($path) > $width
        ? '...' . substr($path, -($width - 3))
        : $path;
}

# ── Search ────────────────────────────────────────────────────────────────────

# Returns true if the session's conversation content matches the query string.
# Uses grep for speed — no need to parse the full file in Perl.
sub _search_content {
    my ($session, $query) = @_;

    # Always match on title and path (fast, no file I/O)
    return 1 if index(lc($session->{title}), lc($query)) >= 0;
    return 1 if index(lc($session->{cwd}),   lc($query)) >= 0;

    # Search the session file for the query string (case-insensitive)
    my $file = $session->{_file} or return 0;
    return 0 unless -f $file;
    my $re = eval { qr/\Q$query\E/i } or return 0;
    open my $fh, '<', $file or return 0;
    while (<$fh>) {
        if (/$re/) { close $fh; return 1 }
    }
    close $fh;
    return 0;
}

# ── Title banner ─────────────────────────────────────────────────────────────

sub _banner {
    my ($cols) = @_;

    # Fullwidth letters have broad terminal font support unlike math italic
    my @letters = split //, "\x{FF33}\x{FF21}\x{FF29}\x{FF33}\x{FF2F}\x{FF2E}\x{FF33}";
    my @colors  = ('bold red', 'bold yellow', 'bold green', 'bold cyan', 'bold blue', 'bold magenta', 'bold red');
    my $title   = join '', map { colored($letters[$_], $colors[$_]) } 0..$#letters;

    my $author      = "v$App::Saisons::VERSION  by Nicolas Mendoza  \x{00a9} 2026";
    my $title_vis   = scalar @letters * 2;  # fullwidth chars are 2 columns wide
    my $pad         = $cols - $title_vis - length($author);
    $pad = 2 if $pad < 2;

    my $art_str = $title . _str_dim(' ' x $pad . $author) . "\033[K\n";

    return $art_str;
}

# ── Screen renderer ───────────────────────────────────────────────────────────
# Draws the full UI: header, session list, scrollbar, footer.
# Called on every keypress since the whole screen is redrawn each time.

sub _render {
    my ($entries, $cursor, $offset, $visible, $sel_ids, $grouped, $running, $filter, $fulltext, $sort_col, $sort_rev) = @_;
    $sort_col //= 'date';
    my $sort_arrow = $sort_rev ? "\x{2193}" : "\x{2191}";  # ↓ or ↑

    my $n    = scalar @$entries;
    my $cols = $COLS;

    # Title banner: 1 line (fullwidth letters + author right-aligned)
    my $banner = _banner($cols);
    my $banner_lines = 1;

    # Fixed column widths
    my $rel_w    = 8;   # "2h ago" — always the same width
    my $size_w   = 6;   # "1.2MB" — history file size
    my $id_w     = 36;  # UUID — always 36 chars
    my $tag_w    = 5;   # adapter tag: ✶ Cld / a Aid / ☁ Cdx
    my $prefix_w = 2;   # sel_mark (*) + running_bullet (●)
    my $sep_w    = 2;   # spaces between columns
    my $has_sb   = $n > $visible ? 1 : 0;
    my $usable   = $COLS - $has_sb;

    # Dynamic path width: measure actual content, cap at 40, min 20
    # Hidden in grouped mode since the directory is shown as a header row
    my $path_w = 0;
    unless ($grouped) {
        my $max_path = 0;
        for my $e (@$entries) {
            next unless $e->{type} eq 'session';
            my $len = length($e->{session}{cwd});
            $max_path = $len if $len > $max_path;
        }
        $path_w = $max_path > 40 ? 40 : $max_path < 20 ? 20 : $max_path;
    }

    # Title fills whatever space remains
    my $fixed   = $prefix_w + 1 + $tag_w + $sep_w + $rel_w + $sep_w + $size_w + $sep_w + $id_w + $sep_w
                + ($path_w ? $path_w + $sep_w : 0);
    my $title_w = $usable - $fixed;
    $title_w = 10 if $title_w < 10;

    # Build the entire frame as a single string to avoid flicker.
    # We overwrite in place with \033[H (go to top) rather than clearing first.
    my $frame = "\033[H";

    # Title banner
    $frame .= $banner;

    # Precompute scrollbar chars (drawn via cursor positioning after rows)
    my @sb_char;
    if ($has_sb) {
        my $bar_height = int($visible * $visible / $n) || 1;
        my $bar_top    = int($offset  * $visible / $n);
        for my $r (0 .. $visible - 1) {
            $sb_char[$r] = ($r >= $bar_top && $r < $bar_top + $bar_height) ? '#' : '|';
        }
    }

    # Column header row — mark the active sort column with ↑/↓
    my $hdr_col = sub {
        my ($key, $label, $w) = @_;
        my $l = $sort_col eq $key ? colored("$label$sort_arrow", 'bold yellow') : $label;
        return sprintf "%-${w}s", $l;
    };
    my $sel_mark_hdr = $sort_col eq 'selected' ? colored('*',        'bold yellow') : '*';
    my $run_mark_hdr = $sort_col eq 'running'  ? colored("\x{25cf}", 'bold yellow') : "\x{25cf}";
    my $hdr = $grouped
        ? sprintf("%s%s %s  %s  %s  %s  %s",
            $sel_mark_hdr, $run_mark_hdr,
            $hdr_col->('agent',   'Agt',     $tag_w),
            $hdr_col->('date',    'When',    $rel_w),
            $hdr_col->('size',    'Size',    $size_w),
            $hdr_col->('session', 'Session', $id_w),
            $hdr_col->('title',   'Title',   $title_w))
        : sprintf("%s%s %s  %s  %s  %s  %s  %s",
            $sel_mark_hdr, $run_mark_hdr,
            $hdr_col->('agent',   'Agt',     $tag_w),
            $hdr_col->('date',    'When',    $rel_w),
            $hdr_col->('size',    'Size',    $size_w),
            $hdr_col->('session', 'Session', $id_w),
            $hdr_col->('path',    'Path',    $path_w),
            $hdr_col->('title',   'Title',   $title_w));
    $frame .= _str_bold($hdr) . "\n";
    $frame .= _str_dim('-' x ($usable - 1)) . "\n";

    # Visible session rows
    my $end = $offset + $visible - 1;
    $end = $n - 1 if $end >= $n;

    for my $i ($offset .. $end) {
        my $entry     = $entries->[$i];
        my $active    = $i == $cursor;
        my $row_idx   = $i - $offset;        # 0-based index within visible area
        my $sb        = $sb_char[$row_idx] // '';  # scrollbar char for this row

        # Group header row — just a directory path label
        if ($entry->{type} eq 'header') {
            my $line = sprintf " %-*s", $usable - 2, $entry->{label};
            $frame .= ($active
                ? color('reverse') . _str_boldyel($line) . RESET
                : _str_boldyel($line)) . "\n";
            next;
        }

        my $session    = $entry->{session};
        my $is_sel     = $sel_ids->{ $session->{id} };
        my $is_running = $running->{  $session->{id} };

        my $sel_mark       = $is_sel     ? '*'        : ' ';
        my $running_bullet = $is_running ? "\x{25cf}" : ' ';

        # Field values padded to their column width
        my $tag   = _adapter_tag($session->{_adapter}, $active || $is_sel);
        my $when  = sprintf "%-${rel_w}s",   _rel_time($session->{epoch});
        my $size  = sprintf "%-${size_w}s",  _fmt_size($session->{_size} // 0);
        my $id    = sprintf "%-${id_w}s",    $session->{id};
        my $raw_title = substr($session->{title}, 0, $title_w);
        my $raw_path  = $grouped ? '' : _truncate_path($session->{cwd}, $path_w);

        # Highlight matching substrings in title and path (not ID) when filtering
        if ($filter && !$active) {
            my $re = eval { qr/(\Q$filter\E)/i } // qr/(?!)/;
            $raw_title =~ s/$re/colored($1, 'bold reverse')/ge;
            $raw_path  =~ s/$re/colored($1, 'bold reverse')/ge unless $grouped;
        }

        my $title    = sprintf "%-${title_w}s", $raw_title;
        my $path_sep = $grouped ? '' : $raw_path . '  ';

        my $row;
        if ($active) {
            $row = _col_active . $sel_mark
                 . ($is_running ? _col_boldgrn . $running_bullet . _col_active : ' ')
                 . " $tag  $when  $size  $id  $path_sep$title"
                 . RESET;
        } elsif ($is_sel) {
            $row = _col_sel . $sel_mark
                 . ($is_running ? _col_boldgrn . $running_bullet . _col_sel : ' ')
                 . " $tag  $when  $size  $id  $path_sep$title"
                 . RESET;
        } else {
            my $path_part = $grouped ? '' : _col_green . _truncate_path($session->{cwd}, $path_w) . '  ';
            $row = $sel_mark
                 . ($is_running ? _col_boldgrn . $running_bullet : ' ')
                 . ' ' . $tag . RESET . '  '
                 . _col_yellow . $when . '  '
                 . _col_cyan   . $size . '  '
                 . _col_cyan   . $id   . '  '
                 . $path_part
                 . _col_white  . $title
                 . RESET;
        }

        $frame .= $row . "\n";
    }

    # Pad with blank lines up to the visible area height so old content is overwritten.
    # Each padding line gets \033[K to erase any leftover characters.
    my $rows_drawn = ($end >= $offset) ? ($end - $offset + 1) : 0;
    $frame .= "\033[K\n" x ($visible - $rows_drawn) if $rows_drawn < $visible;

    # Draw scrollbar via absolute cursor positioning (avoids ANSI-width miscalculation)
    # Rows start at line: banner(1) + header(1) + sep(1) = line 4
    if ($has_sb) {
        my $sb_col = $COLS;  # rightmost column
        for my $r (0 .. $visible - 1) {
            my $screen_row = $banner_lines + 2 + 1 + $r;  # 1-based
            $frame .= "\033[${screen_row};${sb_col}H"
                   . _str_dim($sb_char[$r] // '|');
        }
    }

    # Footer on the last line — no cursor jump needed, we've written exactly
    # banner(3) + header(1) + sep(1) + visible rows = $ROWS - 1 lines above it.
    my $nsel        = scalar keys %$sel_ids;
    my $toggle_mode = $grouped ? 'flat' : 'grouped';  # what [t] will switch TO
    my $pct         = $n > $visible ? sprintf(' %d%%', int(($offset + $visible/2) / $n * 100)) : '';
    my $footer = sprintf(
        '[↑↓/jk] [PgUp/Dn] [SPC] select  [ENTER] open  [v]iew  [d]el  [m]ove  [t] →%s  [s]ort:%s  [r]efresh  [/] filter  [?] search  [a/A]  [q]uit   %d sel/%d%s%s',
        $toggle_mode, $sort_col . ($sort_rev ? '↓' : '↑'), $nsel, $n, $pct,
        ($filter   ? colored("  /filter: $filter",     'bold cyan')   : '')
      . ($fulltext ? colored("  ?search: $fulltext",   'bold yellow') : ''));
    $frame .= colored(substr($footer . ' ' x $cols, 0, $cols - 1), 'white on_blue');

    # Single write — eliminates flicker from partial screen updates
    print $frame;
    STDOUT->flush();
}

# ── Sort popup ───────────────────────────────────────────────────────────────
# Shows a small centered popup to pick a sort column.
# Returns the chosen index into @sort_cols, or undef if cancelled.

sub _sort_popup {
    my ($sort_cols, $current_idx, $reverse) = @_;

    my @labels = (
        'selected  (*)',
        'running   (●)',
        'agent',
        'date',
        'size',
        'session',
        'path',
        'title',
    );

    my $pick   = $current_idx;
    my $dir    = $reverse ? "\x{2193} descending" : "\x{2191} ascending";
    my $footer_text = ' [↑↓] move  [ENTER] ok  [ESC] cancel ';
    my $title_text  = " Sort $dir ";

    # Width fits the widest of: title, footer, labels (with 2-char padding)
    my $max_label = (sort { $b <=> $a } map { length } @labels)[0];
    my $w = (sort { $b <=> $a } length($title_text), length($footer_text), $max_label + 4)[0];

    while (1) {
        ($ROWS, $COLS) = _term_size();

        my $h    = scalar(@labels) + 4;
        my $top  = int(($ROWS - $h) / 2);
        my $left = int(($COLS - $w) / 2);

        my $popup = '';
        my $pad   = int(($w - length($title_text)) / 2);
        $popup .= "\033[${top};${left}H" . colored(' ' x $w, 'white on_blue');
        $popup .= "\033[" . ($top+1) . ";${left}H"
               . colored(' ' x $pad . $title_text . ' ' x ($w - $pad - length($title_text)), 'bold white on_blue');
        $popup .= "\033[" . ($top+2) . ";${left}H" . colored(' ' x $w, 'white on_blue');

        for my $i (0 .. $#labels) {
            my $row   = $top + 3 + $i;
            my $label = sprintf " %-*s ", $w - 2, $labels[$i];
            $popup .= "\033[${row};${left}H";
            $popup .= $i == $pick
                ? colored($label, 'black on_cyan')
                : colored($label, 'white on_blue');
        }

        my $footer_row = $top + 3 + scalar @labels;
        my $footer = sprintf "%-*s", $w, $footer_text;
        $popup .= "\033[${footer_row};${left}H" . colored($footer, 'faint on_blue');

        print $popup;
        STDOUT->flush();

        my $key = _read_key();
        if    ($key eq 'UP'   || $key eq 'k') { $pick = ($pick - 1 + @labels) % @labels }
        elsif ($key eq 'DOWN' || $key eq 'j') { $pick = ($pick + 1)           % @labels }
        elsif ($key eq "\n"   || $key eq "\r") { return $pick }
        elsif ($key eq 'ESC'  || $key eq 'q')  { return undef }
    }
}

sub _confirm {
    my ($prompt) = @_;
    print "\033[2J\033[H$prompt";
    my $ans = '';
    sysread STDIN, $ans, 1;
    return $ans;
}

# ── Peek / conversation view ──────────────────────────────────────────────────
# Shows the full conversation history for a session in a scrollable view.
# Messages are word-wrapped to fit the terminal width.

sub _peek {
    my ($session) = @_;
    my @msgs = $session->{_adapter}->load_messages($session);
    my ($rows, $cols) = _term_size();
    my $wrap = $cols - 9;  # leave room for the "  You: " / "   AI: " prefix
    $wrap = 40 if $wrap < 40;

    # Build the list of display lines up front (pre-wrapped)
    my @lines;
    push @lines, { text => _str_bold('Session: ') . $session->{title} };
    push @lines, { text => _str_bold('Path:    ') . _str_boldgrn($session->{cwd}) };
    push @lines, { text => _str_bold('ID:      ') . _str_boldcyn($session->{id}) };
    push @lines, { text => _str_dim('-' x ($cols - 2)) };

    for my $msg (@msgs) {
        my $is_user = $msg->{role} eq 'user';
        my $prefix  = $is_user ? _str_boldcyn('  You: ') : _str_boldyel('   AI: ');
        my $indent  = ' ' x 7;  # align continuation lines with text after prefix
        my $first   = 1;

        (my $text = $msg->{text}) =~ s/\r//g;
        for my $line (split /\n/, $text) {
            $line ||= ' ';

            # Word-wrap long lines
            while (length($line) > $wrap) {
                my $chunk = substr($line, 0, $wrap);
                $chunk =~ s/\s+\S+$// or substr($line, 0, $wrap) = '';
                substr($line, 0, length($chunk) + ($chunk ne substr($line,0,length($chunk)) ? 1 : 0)) = '';
                push @lines, { text => ($first ? $prefix : $indent) . $chunk };
                $first = 0;
            }
            push @lines, { text => ($first ? $prefix : $indent) . $line };
            $first = 0;
        }
        push @lines, { text => '' };  # blank line between messages
    }

    my $n      = scalar @lines;
    my $vis    = $rows - 2;
    my $offset = $n > $vis ? $n - $vis : 0;  # start scrolled to the bottom

    _init_term();
    print "\033[?25l";

    while (1) {
        ($rows, $cols) = _term_size();
        $vis = $rows - 2;
        $offset = 0          if $offset < 0;
        $offset = $n - $vis  if $n > $vis && $offset > $n - $vis;

        print "\033[H\033[J";
        my $end = $offset + $vis - 1;
        $end = $n - 1 if $end >= $n;
        print $lines[$_]{text} . "\n" for $offset .. $end;

        # Scrollbar
        if ($n > $vis) {
            my $bar_h   = int($vis * $vis / $n) || 1;
            my $bar_top = int($offset * $vis / $n);
            for my $r (0 .. $vis - 1) {
                my $ch = ($r >= $bar_top && $r < $bar_top + $bar_h) ? '█' : '│';
                print "\033[" . ($r + 1) . ";${cols}H$ch";
            }
        }

        print "\033[${rows};1H";
        print colored(
            substr('[↑↓/jk] scroll  [PgUp/Dn] page  [g/G] top/bot  [q/ESC] return' . ' ' x $cols, 0, $cols - 1),
            'white on_blue');

        my $key = _read_key();
        if    ($key eq 'UP'   || $key eq 'k') { $offset-- }
        elsif ($key eq 'DOWN' || $key eq 'j') { $offset++ }
        elsif ($key eq 'PGUP')                { $offset -= $vis }
        elsif ($key eq 'PGDN')                { $offset += $vis }
        elsif ($key eq 'HOME' || $key eq 'g') { $offset = 0 }
        elsif ($key eq 'END'  || $key eq 'G') { $offset = $n - $vis }
        elsif ($key eq 'q' || $key eq 'ESC')  { last }
    }

    _restore_term();
    print "\033[?25h";
}

# ── Delete and move ───────────────────────────────────────────────────────────

sub _do_delete {
    my ($chosen, $sessions, $sel_ids) = @_;
    print "\033[2J\033[H";
    print _str_boldred('Delete ' . scalar(@$chosen) . " session(s)?\n\n");
    for my $s (@$chosen) {
        printf "  %s\n",  _str_bold($s->{title});
        printf "  %s  %s\n", _str_boldgrn($s->{cwd}), _str_dim($s->{date});
        printf "  %s\n",  _str_dim($s->{_file} // '');
        print "\n";
    }
    print _str_boldred('[y] Delete  [n] Cancel: ');

    # Read a single keypress — stay in raw mode
    my $ans = '';
    sysread STDIN, $ans, 1;
    print "\n";

    if (lc($ans) eq 'y') {
        my %deleted_ids;
        for my $session (@$chosen) {
            $session->{_adapter}->delete_session($session);
            delete $sel_ids->{ $session->{id} };
            $deleted_ids{ $session->{id} } = 1;
        }
        @$sessions = grep { !$deleted_ids{$_->{id}} } @$sessions;
    }
}

sub _do_move {
    my ($chosen, $sessions, $sel_ids) = @_;
    print "\033[2J\033[H";
    print "Move " . scalar(@$chosen) . " session(s)\n";
    print "Current: " . _str_boldgrn($chosen->[0]{cwd}) . "\n\nNew directory: ";
    _restore_term();
    my $new_cwd = <STDIN>;
    return unless defined $new_cwd;
    chomp $new_cwd;
    $new_cwd =~ s|/$||;  # strip trailing slash
    unless ($new_cwd && -d $new_cwd) {
        print _str_boldred("Directory does not exist: $new_cwd\n");
        print "Press Enter..."; <STDIN>;
        return;
    }
    for my $session (@$chosen) {
        my ($ok, $err) = $session->{_adapter}->move_session($session, $new_cwd);
        print $ok ? _str_boldgrn("Moved $session->{id}\n") : _str_boldred("Error: $err\n");
    }
    print "Press Enter..."; <STDIN>;
}

# ── Utilities ─────────────────────────────────────────────────────────────────

sub _adapter_tag {
    my ($adapter, $active_or_sel) = @_;
    my $label = $adapter->can('tag')       ? $adapter->tag       : substr(ref($adapter) =~ s/.*:://r, 0, 5);
    my $col   = $adapter->can('tag_color') ? $adapter->tag_color : undef;
    return ($col && !$active_or_sel) ? colored($label, $col) : $label;
}

# Returns a human-readable relative time string, e.g. "2h ago", "3d ago"
sub _fmt_size {
    my ($bytes) = @_;
    return '0B'                          unless $bytes;
    return "${bytes}B"                   if $bytes < 1024;
    return sprintf('%.0fK', $bytes/1024) if $bytes < 1024*1024;
    return sprintf('%.1fM', $bytes/1024/1024);
}

sub _rel_time {
    my ($epoch) = @_;
    return 'unknown' unless $epoch;
    my $diff = time() - $epoch;
    return 'just now'                    if $diff < 60;
    return int($diff/60)       . 'm ago' if $diff < 3600;
    return int($diff/3600)     . 'h ago' if $diff < 86400;
    return int($diff/86400)    . 'd ago' if $diff < 86400 * 30;
    return int($diff/86400/30) . 'mo ago' if $diff < 86400 * 365;
    return int($diff/86400/365). 'y ago';
}

1;
