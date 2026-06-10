use strict;
use warnings;
use ExtUtils::MakeMaker;

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
    },
    TEST_REQUIRES => {
        'Test::More' => 0,
    },
    META_MERGE => {
        'meta-spec' => { version => 2 },
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
	fatpack trace bin/saisons
	perl -MModule::CoreList -e 'while(<STDIN>){chomp;(my$$m=$$_)=~s|/|::|g;$$m=~s|\.pm$$||;print "$$_\n" unless Module::CoreList::is_core($$m)}' < fatpacker.trace > non-core.trace
	fatpack packlists-for $$(cat non-core.trace) > packlists
	fatpack tree $$(cat packlists)
	perl -MPerl::Stripper -MFile::Find -e 'my $$s=Perl::Stripper->new(maintain_linum=>0,strip_comment=>1,strip_pod=>1,strip_ws=>1); File::Find::find(sub{ return unless /\.pm$$/; open my $$f,"<",$$_ or die; my $$src=do{local $$/;<$$f>}; close $$f; my $$min=$$s->strip($$src); open $$f,">",$$_ or die; print $$f $$min; close $$f }, "fatlib", "lib")'
	fatpack file bin/saisons > saisons
	chmod +x saisons
	rm -f fatpacker.trace non-core.trace packlists
	rm -rf fatlib
	@echo "saisons is now fatpacked and minified — ready to commit"

MAKE
}
