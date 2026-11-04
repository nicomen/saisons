use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib 'lib';
use App::Saisons::UI;

my $dir = tempdir(CLEANUP => 1);

sub touch {
    my ($path, $mtime) = @_;
    open my $fh, '>', $path or die "$path: $!";
    print $fh "x";
    close $fh;
    utime $mtime, $mtime, $path;
    return $path;
}

my $now = time;
my $fresh = touch("$dir/fresh.jsonl", $now);
my $stale = touch("$dir/stale.jsonl", $now - 300);
my $db    = touch("$dir/shared.db",   $now);

my @sessions = (
    { id => 'work',  _file => $fresh },
    { id => 'wait',  _file => $stale },
    { id => 'off',   _file => $stale },
    { id => 'dbnew', _file => $db, epoch => $now },
    { id => 'dbold', _file => $db, epoch => $now - 300 },
);
my %running = (work => 1, wait => 1, dbnew => 1, dbold => 1);

App::Saisons::UI::annotate_running(\@sessions, \%running);

is $running{work},  'working', 'fresh transcript means working';
is $running{wait},  'waiting', 'stale transcript means waiting';
ok !exists $running{off}, 'not-running session untouched';
is $running{dbnew}, 'working', 'shared db file: fresh epoch means working';
is $running{dbold}, 'waiting', 'shared db file: old epoch means waiting';

# a stale main transcript with a freshly written subagent file is working
my $subdir = "$dir/sub";
mkdir $subdir;
my $main = touch("$dir/main.jsonl", $now - 300);
touch("$subdir/agent.jsonl", $now);
my @s2 = ({ id => 'sub', _file => $main, _dir => $subdir });
my %r2 = (sub => 1);
App::Saisons::UI::annotate_running(\@s2, \%r2);
is $r2{sub}, 'working', 'fresh subagent file means working';

done_testing;
