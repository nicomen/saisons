package App::Saisons;
use strict;
use warnings;
our $VERSION = '0.2.1';
# Windows has no HOME; every module interpolating $ENV{HOME} loads this one
BEGIN { $ENV{HOME} //= $ENV{USERPROFILE} // '' }
# `make fatpack` stamps $main::SAISONS_BUILD (git describe) into the bundle;
# main:: survives the packer's package renaming where a package var would not
sub version_string {
    no warnings 'once';
    return $VERSION . ' (' . ($main::SAISONS_BUILD // 'dev') . ')';
}
our $QUIET = 0;   # set while the UI is up: no progress lines over the list
my %PARSE_CACHE;
# Runs $parse only when $file (or one of @also, e.g. a SQLite -wal) changed
# since the last call, so periodic rescans cost a stat per session file.
sub cached_parse {
    my ($file, $parse, @also) = @_;
    my @st = stat $file or return;
    my $key = join ';', map { my @s = stat $_; @s ? "$s[9]:$s[7]" : '-' } $file, @also;
    my $hit = $PARSE_CACHE{$file};
    return @{ $hit->[1] } if $hit && $hit->[0] eq $key;
    print STDERR "\033[2KLoading $file ...\r" unless $QUIET;
    my @r = $parse->();
    print STDERR "\033[2K\r" unless $QUIET;
    $PARSE_CACHE{$file} = [$key, \@r];
    return @r;
}
1;

__END__

=head1 NAME

App::Saisons - terminal UI for browsing and resuming AI coding agent sessions

=head1 DESCRIPTION

App::Saisons implements the L<saisons> command: one list of all the AI
coding agent sessions on the machine - Claude Code, OpenAI Codex, Gemini
CLI, Aider and opencode. Sessions can be filtered, searched, grouped and
sorted, and selected ones resume in a new tmux window, terminal tab or the
current terminal.

See L<saisons> for usage, keys and configuration.

=head1 AUTHOR

Nicolas Mendoza E<lt>mendoza@pvv.ntnu.noE<gt>

=head1 LICENSE

This software is licensed under the Artistic License 2.0.

=cut
