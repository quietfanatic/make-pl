#!/usr/bin/perl
use lib do {__FILE__ =~ /^(.*)[\/\\]/; ($1||'.')};
use MakePl;  # Automatically imports strict and warnings

 # Sample make.pl
 # https://github.com/quietfanatic/make-pl
 #
 # This is an sample make.pl for a C/C++ project.  If it looks a little
 # complex, that's because it contains enough intelligence to manage all
 # the dependencies of a simple project completely automatically.
 #
 # Feel free to copy, modify, and use this as you please.
 #
 # TODO: This file is not sufficiently tested!

 # Compiler flags etc. up top for easy tweaking
my $program = 'program';
my @cc = (qw(gcc -Wall));
my @cppc = (qw(g++ -Wall));
my @ld = (qw(g++ -Wall));
my @includes = (cwd);  # cwd is always where this script is

 # Create some build configs
my %configs = (
    debug => ['-ggdb'],
    release => ['-O3'],
);

 # Find all the source files
my @sources = glob '*.c *.cpp */*.c */*.cpp */*/*.c */*/*.cpp';

 # Loop over build configs
for my $config (keys %configs) {
     # Register a compile step for each source file
    my @objects;
    for my $source (@sources) {
        $source =~ /^(.*)\.c(pp)?$/ or die "Source filename wasn't a .c[pp] file: $source\n";
        my $base = $1;
        my @compiler = $2 ? @cppc : @cc;
        my $out = "tmp/$config/$base.o";
        push @objects, $out;
        step $out, $source, sub {
            run @compiler, '-c', $source, @{$configs{$config}}, '-o', $out;
        }, {fork => 1, mkdir => 1};
    }
     # Register a link step for the final program
    step "out/$config/$program", @objects, sub {
        run @ld, @{$_[1]}, '-o', $_[0][0];
    }, {mkdir => 1};
}

 # And finally a cleanup step
step 'clean', [], sub {
    require File::Path;
    File::Path::remove_tree('tmp');
    File::Path::remove_tree('out');
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
            push @r, canonpath("$I/$_") if -e("$I/$_");
        }
    }
    return @r;
};

make;
