#!/usr/bin/perl
use strict;
use warnings;
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
    my ($src, %opts) = @_;
    my $rename_vars = $opts{rename} // 1;
    my $doc = PPI::Document->new(\$src) or return $src;
    $doc->prune('PPI::Token::Comment');
    $doc->prune('PPI::Token::Pod');

    return $doc->serialize unless $doc->children;

    my %rename;     # original name -> short name (global per file)
    my $counter = 0;

    if ($rename_vars) {
        my %in_string;

        # Pass 1a: collect variable names inside opaque tokens
        # These embed vars as text, not as PPI::Token::Symbol:
        #   Quote::Double/Interpolate  — "$var", "${var}"
        #   Regexp::Match/Substitute   — m/$var/, s/$old/$new/
        #   QuoteLike::Regexp/Readline/Backtick — qr/$var/, <$fh>, `$cmd`
        #   HereDoc                    — <<"EOF" with $var inside
        my $tok = $doc->first_token;
        while ($tok) {
            my $r = ref($tok);
            if ($r =~ /^PPI::Token::(?:Quote::(?:Interpolate|Double)|Regexp::(?:Match|Substitute)|QuoteLike::(?:Regexp|Readline|Backtick)|HereDoc)$/) {
                my $str = $tok->content;
                $str .= join('', $tok->heredoc) if $r eq 'PPI::Token::HereDoc' && $tok->can('heredoc');
                while ($str =~ /[\$\@]\{?(\w{2,})\b/g) { $in_string{$1} = 1 }
            }
            $tok = $tok->next_token;
        }

        # Pass 1b: collect rename candidates from my/local declarations
        my @decl_names;
        $tok = $doc->first_token;
        while ($tok) {
            if (ref($tok) eq 'PPI::Token::Word' && ($tok->content eq 'my' || $tok->content eq 'local')) {
                my $next = $tok->snext_sibling or do { $tok = $tok->next_token; next };
                my @syms;
                if ($next->isa('PPI::Token::Symbol')) {
                    @syms = ($next);
                } elsif ($next->isa('PPI::Structure::List')) {
                    @syms = grep { $_->isa('PPI::Token::Symbol') } $next->children;
                }
                for my $sym (@syms) {
                    my (undef, $name) = $sym->content =~ /^([\$\@\%])(.+)$/ or next;
                    next if length($name) <= 1 || $KEEP{$name}
                         || $name =~ /^[A-Z_]+$/ || $in_string{$name};
                    push @decl_names, $name unless $rename{$name};
                }
            }
            $tok = $tok->next_token;
        }

        # Pass 1c: reserve every symbol name that survives unrenamed,
        # so generated short names can never shadow or collide with them
        my %reserved;
        $tok = $doc->first_token;
        while ($tok) {
            if (ref($tok) eq 'PPI::Token::Symbol' || ref($tok) eq 'PPI::Token::ArrayIndex') {
                my (undef, $name) = $tok->content =~ /^((?:\$#|[\$\@\%]))(.+)$/;
                $reserved{$name} = 1 if defined $name && length $name;
            }
            $tok = $tok->next_token;
        }

        # Assign short names in declaration order
        for my $name (@decl_names) {
            next if exists $rename{$name};
            my $short;
            do { $short = name_gen($counter++) } while $KEEP{$short} || $reserved{$short};
            $rename{$name} = $short;
        }
    }

    # Pass 2: strip whitespace + optionally rename symbols
    my $tok = $doc->first_token;
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
        } elsif ($rename_vars && ($ref eq 'PPI::Token::Symbol' || $ref eq 'PPI::Token::ArrayIndex')) {
            my ($sigil, $name) = $tok->content =~ /^((?:\$#|[\$\@\%]))(.+)$/ or do {
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

# Only run the build when executed as a script, not when loaded for tests
unless (caller) {
    use File::Find;

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
        my $is_fatlib = ($path =~ m{^fatlib/});
        my $out = process($src, rename => !$is_fatlib);
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
}
