#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use if !$^S, lib => "$FindBin::Bin/.";
use MakePl;

 # Sample make.pl
 # https://github.com/quietfanatic/make-pl
 #
 # This is an sample make.pl for a C/C++ project.  If it looks a little
 # complex, that's because it contains enough intelligence to manage all
 # the dependencies of a simple project completely automatically.
 #
 # Feel free to copy, modify, and use this as you please.

 # Globals at top for easy tweaking
my $program = 'program';
my $cc = 'gcc -Wall';
my $cppc = 'g++ -Wall';
my $ld = 'g++ -Wall';

 # Register a pair of .c and .o files
sub module {
    my ($file) = @_;
    $file =~ /^(.*)\.c(pp)?$/ or die "Filename given to object() wasn't a .c file: $file\n";
    my $base = $1;
    my $compiler = $2 ? $cppc : $cc;
    rule "$base.o", $file, sub {
        run "$compiler -c \Q$file\E -o \!$base.o";
    }
}

 # Let's generate subdependencies from #include statements.  This only scans
 # #includes with quotes (not angle brackets) and they should all be relative
 # to the file doing the including.
sub scan_includes {
    use File::Spec::Functions qw(:ALL);
    my ($file) = @_;
    $file =~ /\.(?:c|cpp|h)$/ or return ();
    my @vdf = splitpath($file);
    my $base = catpath($vdf[0], $vdf[1], '');
    open my $F, '<', $file or (warn "Could not open $file: $!\n" and return);
    read $F, my $head, 2048;  # Only bother scanning first 2k
    close $F;
    my @r;
    for ($head =~ /^\s*#include\s*"([^"]*)"/gmi) {
        push @r, rel2abs($_, $base);
    }
    return @r;
}

workflow {

    rule $program, sub { targetmatch(qr/\.o$/) }, sub {
        run "$ld @{$_[1]} -o $_[0][0]";
    }

    module($_) for glob '*.c *.cpp */*.c */*.cpp */*/*.c */*/*.cpp';

    rule 'clean', [], sub {
        unlink $program, targetmatch(qr/\.o$/);
    }

    subdep \&scan_includes;

};
