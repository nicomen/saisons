use strict;
use warnings;
use ExtUtils::MakeMaker;

use utf8;

WriteMakefile(
    NAME             => 'App::Saisons',
    AUTHOR           => 'Nicolas Mendoza <mendoza@pvv.ntnu.no>',
    VERSION_FROM     => 'lib/App/Saisons.pm',
    ABSTRACT         => 'Terminal UI for browsing and resuming AI coding agent sessions',
    LICENSE          => 'artistic_2',
    MIN_PERL_VERSION => '5.010',
    EXE_FILES        => ['bin/saisons'],
    PREREQ_PM        => {
        'JSON::PP'          => 0,
        'Term::ANSIColor'   => 0,
        'Module::Pluggable' => 0,
        'POSIX'             => 0,
        'Encode'            => 0,
        'Time::Local'       => 0,
        'Time::HiRes'       => 0,
    },
    TEST_REQUIRES => {
        'Test::More'            => '0.96',    # subtest
        'File::Copy::Recursive' => 0,
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
        prereqs     => {
            develop => {
                requires => {
                    'App::SlimPacker' => 0,    # provides slimpack, used by `make fatpack`
                },
            },
        },
        resources   => {
            repository => {
                type => 'git',
                url  => 'https://github.com/nicomen/saisons.git',
                web  => 'https://github.com/nicomen/saisons',
            },
            bugtracker => {
                web => 'https://github.com/nicomen/saisons/issues',
            },
        },
    },
);

package MY;
sub postamble {
    return <<'MAKE';
fatpack: bin/saisons
	@# slimpack exits 0 even when tracing fails and then packs an incomplete
	@# script, so its stderr decides; a failed build leaves saisons alone
	slimpack -o saisons.tmp bin/saisons 2> fatpack.err; status=$$?; cat fatpack.err >&2; \
	  if [ $$status -ne 0 ] || grep -Eq "compilation aborted|Can't locate" fatpack.err; then \
	    rm -f saisons.tmp fatpack.err; echo 'slimpack failed; saisons left unchanged' >&2; exit 1; \
	  fi; rm -f fatpack.err; mv saisons.tmp saisons
	perl -0777 -i -pe 'my $$b = `git describe --always`; $$b =~ s/\s+\z//; $$b .= "-dirty" if `git status --porcelain -- bin lib` =~ /\S/; s/\n/\nBEGIN{\$$main::SAISONS_BUILD=q{$$b}}\n/' saisons
	@echo "saisons is now fatpacked, minified and stamped — ready to commit"

MAKE
}
