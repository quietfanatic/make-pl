#!/usr/bin/perl
use lib do {__FILE__ =~ /^(.*)[\/\\]/; ($1||'.')};
use MakePl;  # Automatically imports strict and warnings
use Cwd 'realpath';

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
my @includes = (cwd);

 # Link all .o files into the final program
rule $program, sub { grep /\.o$/, targets }, sub {
    run "$ld @{$_[1]} -o $_[0][0]";
};

 # Register a pair of .c and .o files
sub module {
    my ($file) = @_;
    $file =~ /^(.*)\.c(pp)?$/ or die "Filename given to module() wasn't a .c[pp] file: $file\n";
    my $base = $1;
    my $compiler = $2 ? $cppc : $cc;
    rule "$base.o", $file, sub {
        run "$compiler -c \Q$file\E -o \!$base.o";
    }
}

 # Find all C/C++ files and declare a rule for them
module($_) for glob '*.c *.cpp */*.c */*.cpp */*/*.c */*/*.cpp';

 # An finally a cleanup rule
rule 'clean', [], sub {
    unlink $program, grep /\.o$/, targets;
};

 # Let's generate subdependencies from #include statements.
 # This only scans #includes with quotes (not angle brackets).
subdep sub {
    my ($file) = @_;
     # Select only C++ files
    $file =~ /\.(?:c|cpp|h)$/ or return ();
    my $base = ($file =~ /(.*?)[^\\\/]*$/ and $1);
     # Only bother reading first 2k
    my @incs = (slurp $file, 2048) =~ /^\s*#include\s*"([^"]*)"/gmi;
    my @r;
    for (@incs) {
        for my $I (@includes, $base) {
            push @r, realpath("$I/$_") if -e("$I/$_");
        }
    }
    return @r;
};

make;
