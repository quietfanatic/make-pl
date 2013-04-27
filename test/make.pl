#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use if !$^S, lib => "$FindBin::Bin/..";
use Make_pl;
use autodie;

workflow {
    rule 'to', 'from', sub {
        run 'cat from > to';
    };
    phony 'clean', '', sub {
        unlink 'to';
    }
}

