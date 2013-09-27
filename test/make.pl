#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use MakePl;
use autodie;

rule 'to', 'from', sub {
    run "cat from > to";
};
phony 'clean', '', sub {
    no autodie;
    unlink 'to';
};

make;
