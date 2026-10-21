package App::Saisons;
use strict;
use warnings;
our $VERSION = '0.1.0';
# `make fatpack` stamps $main::SAISONS_BUILD (git describe) into the bundle;
# main:: survives the packer's package renaming where a package var would not
sub version_string {
    no warnings 'once';
    return $VERSION . ' (' . ($main::SAISONS_BUILD // 'dev') . ')';
}
1;
