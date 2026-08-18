#!/usr/bin/perl
use strict;
use warnings;
use File::Find;
use PPI;

sub needs_space {
    my ($l, $r) = @_;
    my $lc = $l->content; my $rc = $r->content;
    my $lr = ref($l);     my $rr = ref($r);
    return 1 if $lc =~ /\w$/ && $rc =~ /^\w/;
    return 1 if $lc =~ /[\$\@\%]$/ && $rc =~ /^\w/;
    return 1 if $lc =~ /\w$/ && $rr =~ /Quote/;
    return 1 if $lr =~ /Quote/ && $rc =~ /^\w/;
    return 1 if $lr =~ /Symbol/ && $rr =~ /Symbol/;
    return 1 if $lc =~ /\w$/ && $rc =~ /^['"\/]/;
    return 1 if $lr =~ /Regexp/ && $rc =~ /^\w/;
    return 0;
}

my @_chars = ('a'..'z');
sub name_gen {
    my ($n) = @_;
    my $out = '';
    $n++;
    while ($n > 0) { $out = $_chars[($n-1)%26] . $out; $n = int(($n-1)/26) }
    return $out;
}

my %KEEP = map { $_ => 1 } qw(
    _ a b 0 1 2 3 4 5 6 7 8 9
    ENV INC ISA ARGV ARGVOUT STDOUT STDERR STDIN
    VERSION AUTOLOAD self class
);

sub process {
    my ($src) = @_;
    my $doc = PPI::Document->new(\$src) or return $src;
    $doc->prune('PPI::Token::Comment');
    $doc->prune('PPI::Token::Pod');

    my %in_string;  # names inside interpolated strings — cannot rename
    my %rename;     # original name -> short name (global per file)
    my $counter = 0;

    # Pass 1: single token walk — collect in_string names + build rename map
    my $tok = $doc->first_token;
    while ($tok) {
        my $ref = ref($tok);

        if ($ref eq 'PPI::Token::Quote::Interpolate' || $ref eq 'PPI::Token::Quote::Double') {
            while ($tok->content =~ /[\$\@]\{?(\w{2,})\b/g) { $in_string{$1} = 1 }
        }

        if ($ref eq 'PPI::Token::Word' && ($tok->content eq 'my' || $tok->content eq 'local')) {
            my $next = $tok->snext_sibling or do { $tok = $tok->next_token; next };
            my @syms;
            if ($next->isa('PPI::Token::Symbol')) {
                @syms = ($next);
            } elsif ($next->isa('PPI::Structure::List')) {
                # children() stays within the list — no escaping
                @syms = grep { $_->isa('PPI::Token::Symbol') } $next->children;
            }
            for my $sym (@syms) {
                my (undef, $name) = $sym->content =~ /^([\$\@\%])(.+)$/ or next;
                next if length($name) <= 1 || $KEEP{$name}
                     || $name =~ /^[A-Z_]+$/ || $in_string{$name};
                unless (exists $rename{$name}) {
                    my $short;
                    do { $short = name_gen($counter++) } while $KEEP{$short};
                    $rename{$name} = $short;
                }
            }
        }

        $tok = $tok->next_token;
    }

    # Pass 2: single token walk — strip whitespace + rename symbols
    $tok = $doc->first_token;
    while ($tok) {
        my $ref = ref($tok);

        if ($ref eq 'PPI::Token::Whitespace') {
            if ($tok->content =~ /\n/) {
                $tok->set_content('');
            } else {
                my $prev = $tok->previous_sibling;
                my $next = $tok->next_sibling;
                $tok->set_content(($prev && $next && needs_space($prev, $next)) ? ' ' : '');
            }
        } elsif ($ref eq 'PPI::Token::Symbol') {
            my ($sigil, $name) = $tok->content =~ /^([\$\@\%])(.+)$/ or do {
                $tok = $tok->next_token; next;
            };
            if (exists $rename{$name}) {
                $tok->set_content($sigil . $rename{$name});
            }
        }

        $tok = $tok->next_token;
    }

    return $doc->serialize;
}

# Collect .pm files from fatlib/ and lib/
my @pm_files;
File::Find::find({ wanted => sub {
    return unless /\.pm$/;
    push @pm_files, $File::Find::name;
}, no_chdir => 1 }, grep { -d } qw(fatlib lib));

my @modules;
for my $path (sort @pm_files) {
    open my $fh, '<', $path or die "Cannot read $path: $!";
    my $src = do { local $/; <$fh> };
    close $fh;
    my $out = process($src);
    $out =~ s/^#!\S+//;
    push @modules, $out;
}

my @adapter_classes = sort map { (my $p = $_) =~ s{^(?:fatlib|lib)/}{}; $p =~ s{/}{::}g; $p =~ s{\.pm$}{}; $p }
                      grep { m{/Adapter/[^/]+\.pm$} && !/HOWTO/ } @pm_files;

open my $fh, '<', 'bin/saisons' or die;
my $main = do { local $/; <$fh> };
close $fh;
$main = process($main);
$main =~ s/^#!\S+//;
$main =~ s{use lib[^;]+;}{}g;
my $adapter_list = join(',', map { "\"$_\"" } @adapter_classes);
$main =~ s{use Module::Pluggable[^;]+;}{}g;
$main =~ s{plugins\(\)}{($adapter_list)}g;

my @inc_entries;
for my $path (sort @pm_files) {
    (my $k = $path) =~ s{^(?:fatlib|lib)/}{};
    push @inc_entries, $k;
}

print "#!/usr/bin/perl\n";
print "BEGIN{" . join('', map { "\$INC{'$_'}=1;" } @inc_entries) . "}\n";
print $_ for @modules;
print $main;
