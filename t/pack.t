#!/usr/bin/perl
use strict;
use warnings;
use Test::More;
use FindBin;

do "$FindBin::Bin/../maint/pack.pl";
die "Failed to load maint/pack.pl: $@" if $@;

# ── name_gen ──────────────────────────────────────────────────────────────
is name_gen(0),  'a',  'name_gen(0) = a';
is name_gen(1),  'b',  'name_gen(1) = b';
is name_gen(25), 'z',  'name_gen(25) = z';
is name_gen(26), 'aa', 'name_gen(26) = aa';
is name_gen(27), 'ab', 'name_gen(27) = ab';

# ── process: comment + POD stripping ──────────────────────────────────────
{
    my $out = process("use strict;\n# comment\nmy \$foo = 1;\n=head1 DOC\n=cut\nprint \"\$foo\\n\";\n");
    unlike $out, qr/comment/, 'comments stripped';
    unlike $out, qr/=head1/,  'POD stripped';
    like $out, qr/\$foo/,     'code preserved';
}

# ── process: whitespace stripping ─────────────────────────────────────────
{
    my $src = "use strict;\n\n\nuse warnings;\n";
    my $out = process($src);
    unlike $out, qr/\n\n/, 'blank lines collapsed';
}

# ── process: rename => 0 disables renaming ────────────────────────────────
{
    my $src = 'my $longname = 1; print $longname;';
    my $out = process($src, rename => 0);
    like $out, qr/\$longname/, 'rename=0 keeps variable names';
}

# ── process: renames variables ────────────────────────────────────────────
{
    my $src = 'my $longname = 1; print $longname;';
    my $out = process($src, rename => 1);
    unlike $out, qr/\$longname/, 'long variable renamed';
    like $out, qr/\$[a-z]+/,     'short name assigned';
}

# ── process: single-char names NOT renamed ────────────────────────────────
{
    my $src = 'my $x = 1; print $x;';
    my $out = process($src);
    like $out, qr/\$x/, 'single-char $x preserved';
}

# ── process: uppercase names NOT renamed ──────────────────────────────────
{
    my $src = 'my $COUNT = 1; print $COUNT;';
    my $out = process($src);
    like $out, qr/\$COUNT/, 'ALL_CAPS $COUNT preserved';
}

# ── process: %KEEP names NOT renamed ──────────────────────────────────────
{
    for my $name (qw(self class VERSION)) {
        my $src = "my \$$name = 1; print \$$name;";
        my $out = process($src);
        like $out, qr/\$$name/, "\%KEEP name \$$name preserved";
    }
}

# ── process: variables inside double-quoted strings NOT renamed ───────────
{
    my $src = q{my $title = "hello"; print "$title\n";};
    my $out = process($src);
    # $title is in a string → not renamed anywhere
    like $out, qr/\$title/, '$title preserved (in string)';
}

# ── process: variables inside m// NOT renamed ─────────────────────────────
{
    my $src = q{my $only = "foo"; $x =~ m!$only!;};
    my $out = process($src);
    like $out, qr/\$only/, '$only preserved (in regex m//)';
}

# ── process: variables inside s/// NOT renamed ────────────────────────────
{
    my $src = q{my $pkg_dir = "Foo"; $d =~ s/\Q$pkg_dir\E/$pkg_dir/i;};
    my $out = process($src);
    like $out, qr/\$pkg_dir/, '$pkg_dir preserved (in regex s///)';
}

# ── process: variables inside qr// NOT renamed ────────────────────────────
{
    my $src = q{my $file_regex = qr/\.pm$/; $f =~ /(.*$file_regex)$/;};
    my $out = process($src);
    like $out, qr/\$file_regex/, '$file_regex preserved (in qr//)';
}

# ── process: variables inside <> NOT renamed ──────────────────────────────
{
    my $src = q{my $fh = "x"; open my $fh2, '<', $fh; while (<$fh2>) { print }};
    my $out = process($src);
    # $fh2 appears in <$fh2> readline → must not be renamed
    like $out, qr/\$fh2/, '$fh2 preserved (in readline <>)';
}

# ── process: variables inside heredocs NOT renamed ────────────────────────
{
    my $src = "my \$name = \"world\"; print <<\"EOT\";\nHello \$name\nEOT\n";
    my $out = process($src);
    like $out, qr/\$name/, '$name preserved (in heredoc)';
}

# ── process: variables inside ${} interpolation NOT renamed ───────────────
{
    my $src = q{my $path = "Foo"; print "${path}::Plugin";};
    my $out = process($src);
    like $out, qr/\$path/, '$path preserved (in "${path}")';
}

# ── process: variable used ONLY in code IS renamed ────────────────────────
{
    my $src = q{my $counter = 0; $counter++; print $counter;};
    my $out = process($src);
    unlike $out, qr/\$counter/, '$counter renamed (code only)';
}

# ── process: variable used in code AND string — not renamed ───────────────
{
    my $src = q{my $widget = "hi"; print "val=$widget\n";};
    my $out = process($src);
    like $out, qr/\$widget/, '$widget preserved (used in string)';
}

# ── process: @array in string not renamed ─────────────────────────────────
{
    my $src = q{my @items = (1,2); print "@items";};
    my $out = process($src);
    like $out, qr/\@items/, '\@items preserved (in string)';
}

# ── process: %hash in string not renamed ──────────────────────────────────
{
    my $src = q{my %map = (a=>1); print "%map";};
    my $out = process($src);
    like $out, qr/\%map/, '\%map preserved (in string)';
}

# ── process: no crash on empty source ─────────────────────────────────────
{
    my $out = process("1;\n");
    like $out, qr/1;/, 'minimal valid source processed';
}

# ── process: $#array index renamed consistently with @array ───────────────
{
    my $src = 'my @letters = (1,2); print $#letters;';
    my $out = process($src);
    unlike $out, qr/\$#letters/, '$#letters renamed (matches @letters rename)';
    like $out, qr/\$#[a-z]+/,    'short $#name assigned';
}

# ── process: multiple variables with correct renaming ─────────────────────
{
    my $src = 'my $alpha = 1; my $beta = 2; print $alpha + $beta;';
    my $out = process($src);
    unlike $out, qr/\$alpha/, '$alpha renamed';
    unlike $out, qr/\$beta/,  '$beta renamed';
    # Both should get distinct short names
    my ($a1) = $out =~ /(\$[a-z]+)/;
    my @all = $out =~ /(\$[a-z]+)/g;
    ok scalar(@all) >= 2, 'multiple variables renamed';
}

done_testing;
