#!/usr/bin/perl
use strict;
use warnings;
use PPI;
use File::Find;

sub minify_file {
    my ($path) = @_;
    my $doc = PPI::Document->new($path) or return;
    $doc->prune('PPI::Token::Comment');
    $doc->prune('PPI::Token::Pod');
    my $ws = $doc->find('PPI::Token::Whitespace');
    if ($ws) {
        for my $tok (@{$ws}) {
            if ($tok->content =~ /\n/) { $tok->set_content("\n") }
            else                       { $tok->set_content(' ')  }
        }
    }
    my $out = $doc->serialize;
    $out =~ s/\n{2,}/\n/g;
    open my $fh, '>:raw', $path or die "Cannot write $path: $!";
    print $fh $out;
    close $fh;
}

File::Find::find({ wanted => sub {
    return unless /\.pm$/;
    minify_file($File::Find::name);
}, no_chdir => 1 }, 'fatlib', 'lib.stripped');

minify_file('bin/saisons.stripped');
