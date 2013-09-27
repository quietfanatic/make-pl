#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "$FindBin::Bin/..";
use MakePl;
use autodie;

my %config = (
    asdf => 1,
    fdsa => [3, 4],
);
config 'build-config', \%config, sub {
    warn "(Building new build-config)";
};
$config{asdf} = 1;
option('asdf', \$config{asdf});
option('fdsa0', \$config{fdsa}[0]);
option('fdsa1', \$config{fdsa}[1]);

rule 'to', ['from', 'build-config'], sub {
    run "cat from > to";
};
phony 'clean', '', sub {
    no autodie;
    unlink 'to', 'build-config';
};

make;
