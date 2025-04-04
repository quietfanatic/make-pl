#!/usr/bin/perl
=cut

MakePl - Portable drop-in build system
https://github.com/quietfanatic/make-pl
2025-03-21

USAGE: See the README in the above repo.

=====LICENSE=====

The MIT License (MIT)

Copyright (c) 2025 Lewis Wall

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

=================

=cut

package MakePl;

use v5.10;
use strict qw(subs vars);
use warnings; no warnings 'once';
use utf8;
binmode STDOUT, ':utf8';
binmode STDERR, ':utf8';
use Carp 'croak';
use subs qw(cwd chdir);

our @EXPORT = qw(
    make step rule phony subdep defaults include suggest
    targets exists_or_target
    slurp splat slurp_utf8 splat_utf8
    run which
    cwd chdir canonpath abs2rel rel2abs
);

$ENV{PWD} //= do { require Cwd; Cwd::cwd() };

# GLOBALS
    my $original_base = cwd;  # Set once only.
    our $this_is_root = 1;  # This is set to 0 when recursing.
    our $current_file;  # Which make.pl we're processing
    my $this_file = rel2abs(__FILE__);
    my $make_was_called = 0;
# RULES AND STUFF
    my @steps;  # All registered steps
    my %phonies;  # Targets that aren't really files
    my %targets;  # List steps to build each target
    my %subdeps;  # Registered subdeps by file
    my @auto_subdeps;  # Functions that generate subdeps
    my %autoed_subdeps;  # Minimize calls to the above
    my $defaults;  # undef or array ref
    my @suggestions;  # [target, description]
# SYSTEM INTERACTION
    my %modtimes;  # Cache of file modification times
# OPTIONS
    my $force = 0;
    my $verbose = 0;
    my $simulate = 0;
    my $touch = 0;
    my $jobs; # Simultaneous processes to run.

# START, INCLUDE, END

    sub import {
        my $self = shift;
        my ($package, $file, $line) = caller;
        $current_file = rel2abs($file);
         # Export symbols
        my @args = (@_ == 0 or grep $_ eq ':all' || $_ eq ':ALL', @_)
            ? @EXPORT
            : @_;
        for my $f (@args) {
            grep $_ eq $f, @EXPORT or croak "No export '$f' in MakePl.";
            *{$package.'::'.$f} = \&{$f};
        }
         # Change to directory of the calling file
        $current_file =~ /^(.*)[\/\\]/ or die "path returned by rel2abs wasn't abs. ($current_file)";
        chdir $1;
         # Also import strict and warnings.
        strict->import();
        warnings->import();
    }

     # Prevent double-inclusion; can't use %INC because it does relative paths.
    my %included = (rel2abs($0) => 1);
    sub include {
        for (@_) {
            my $file = canonpath($_);
             # Error on specific files, but skip directories.
            -e $file or croak "Cannot include $file because it doesn't exist";
            if (-d $file) {
                my $makepl = "$file/make.pl";
                next unless -e $makepl;
                $file = $makepl;
            }
            my $real = rel2abs($file);
             # Just like a C include, a subdep is warranted.
            push @{$subdeps{$real}}, { base => MakePl::cwd, to => [$real], from => [$current_file] };
             # Skip already-included files
            next if $included{$real};
            $included{$real} = 1;
             # Make new project.
            local $this_is_root = 0;
            local $current_file;
            do {
                package main;
                my $old_cwd = MakePl::cwd;
                do $file;  # This file will do its own chdir
                MakePl::chdir $old_cwd;
            };
            $@ and die status($@);
            if (!$make_was_called) {
                die "\e[31m✗\e[0m $file did not end with 'make;'\n";
            }
            $make_was_called = 0;
            $defaults = undef;
        }
    }

    sub directory_prefix {
        my ($d, $base) = @_;
        $d //= cwd;
        $base //= $original_base;
        $d =~ s/\/*$//;
        $base =~ s/\/*$//;
        return $d eq $base
            ? ''
            : '[' . abs2rel($d, $base) . '/] ';
    }
    sub status {
        say directory_prefix(), @_;
        return "\n";  # Marker to hand to die
    }

    sub do_step {
        my ($step) = @_;
        if (!$simulate and defined $step->{recipe}) {
            if ($touch) {
                for (@{$step->{to}}) {
                    utime(undef, undef, $_);
                }
            }
            else {
                if ($step->{options}{mkdir}) {
                    for (@{$step->{to}}) {
                        my $path = $step->{base};
                        while (/\G(.*?)\//g) {
                            $path .= '/' . $1;
                            mkdir $path or -d $path or die "Couldn't mkdir $path: $!\n";
                        }
                    }
                }
                $step->{recipe}->($step->{to}, $step->{from});
            }
        }
    }

    sub say_recommended_targets () {
        say "Suggested targets:";
        if (@suggestions) {
            for (@suggestions) {
                my $line = abs2rel($_->[0]);
                if (target_is_default($_->[0])) { $line .= " (default)"; }
                if (defined($_->[1])) { $line .= " : " . $_->[1]; }
                say "    ", $line;
            }
        }
        else {
            my (%nonfinal, %default);
            for my $step (@steps) {
                resolve_deps($step);
                $nonfinal{$_} = 1 for @{$step->{deps}};
            }
            if (defined $defaults) {
                for (@$defaults) {
                    $default{$_} = 1;
                }
            }
             # Gradually narrow down criteria for suggestion
             # TODO: simplify?
            my @auto = grep {
                ($default{$_} or $phonies{$_} or !$nonfinal{$_})
            } targets();
            if (@auto > 12) {
                @auto = grep {
                    $default{$_} or !$nonfinal{$_}
                } @auto;
                if (@auto > 12) {
                    @auto = grep {
                        $default{$_} or $phonies{$_}
                    } @auto;
                    if (@auto > 12) {
                        @auto = grep {
                            $default{$_}
                        } @auto;
                    }
                }
            }
            for (sort @auto) {
                say "    ", abs2rel($_), target_is_default($_) ? " (default)" : "";
            }
        }
    }

    sub make () {
        if ($make_was_called) {
            say "\e[31m✗\e[0m make was called twice in the same project.";
            exit 1;
        }
        $make_was_called = 1;
        if ($this_is_root) {
             # Finish processing the command line
             # Recognize builtin options and complain at unrecognized ones
            my @args;
            eval {
                my $no_more_options = 0;
                for (@ARGV) {
                    if ($no_more_options) {
                        push @args, $_;
                    }
                    elsif ($_ eq '--') {
                        $no_more_options = 1;
                    }
                    elsif ($_ =~ /^--jobs=(\d+)$/s) {
                        $jobs = $1;
                    }
                    elsif ($_ eq '--force') {
                        $force = 1;
                    }
                    elsif ($_ eq '--verbose') {
                        $verbose = 1;
                    }
                    elsif ($_ eq '--simulate') {
                        $simulate = 1;
                    }
                    elsif ($_ eq '--touch') {
                        $touch = 1;
                    }
                    elsif ($_ eq '--targets') {
                        for (sort keys %targets) {
                            say abs2rel($_), target_is_default($_) ? " (default)" : "";
                        }
                        exit 1;
                    }
                    elsif ($_ eq '--help') {
                        print <<END;
\e[31m✗\e[0m Usage: $0 <options> <targets>"
    --jobs=<num> : Run this many parallel jobs if the steps support it.
                   The default value is one less than the number of processors.
    --force : Skip modification time checks and always run the steps.
    --verbose : Show sub-dependencies and shell commands.
    --simulate : Show steps that would be run but don't run them.
    --touch : Update existing files' modtimes but don't actually run any steps.
    --targets : List all declared targets.
    -- : No more options.
END
                        say_recommended_targets();
                        exit 1;

                    }
                    elsif ($_ =~ /^-/s) {
                        say "\e[31m✗\e[0m Unrecognized option $_.  Use --help for options.";
                    }
                    else {
                        push @args, $_;
                    }
                }
            };
            if ($@) {
                warn $@ unless "$@" eq "\n";
                say "\e[31m✗\e[0m Nothing was done due to command-line error.";
                exit 1;
            }
             # Make a plan to build the selected or default targets
            my $plan = init_plan();
            eval {
                if (@args) {
                    grep plan_target($plan, rel2abs($_, $original_base)), @args;
                }
                elsif ($defaults) {
                    grep plan_target($plan, $_), @$defaults;
                }
                else {
                    say "\e[31m✗\e[0m No default targets.";
                    say_recommended_targets();
                    exit(1);
                }
            };
            if ($@) {
                warn $@ unless "$@" eq "\n";
                say "\e[31m✗\e[0m Nothing was done due to error.";
                exit 1;
            }
             # Execute the plan.
            my @program = @{$plan->{program}};
            if (not @steps) {
                say "\e[32m✓\e[0m Nothing was done because no steps have been declared.";
            }
            elsif (not grep defined($_->{recipe}), @program) {
                say "\e[32m✓\e[0m All up to date.";
            }
            else {
                eval {
                    if (!defined($jobs)) {
                        if (exists $ENV{NUMBER_OF_PROCESSORS}) {
                             # Windows (untested!)
                            $jobs = $ENV{NUMBER_OF_PROCESSORS} - 1;
                        }
                        elsif (-e '/proc/cpuinfo') {
                             # Linux
                            my $num = () = slurp('/proc/cpuinfo') =~ /^processor/mg;
                            $jobs = $num - 1;
                        }
                        else {
                             # Not familiar with this OS
                            $jobs = 1;
                        }
                    }
                    if ($jobs > 1) {
                        my %jobs;
                        $SIG{INT} = sub {
                            kill 2, $_ for keys %jobs;
                            die "interrupted\n";
                        };
                        $SIG{__DIE__} = sub {
                            kill 2, $_ for keys %jobs;
                            die $_[0];
                        };
                        my $do_wait;
                        $do_wait = sub {
                            keys(%jobs) > 0 or do {
                                die "Tried to wait on no jobs -- internal planner error?\n", join "\n", map show_step($_), @program;
                            };
                            my $child = wait;
                            if ($child == -1) {
                                die "Unexpectedly lost children!\n";
                            }
                            if ($?) {
                                print readline($jobs{$child}{output});
                                close $jobs{$child}{output};
                                delete $jobs{$child};
                                 # Wait for more children
                                $do_wait->() if %jobs;
                                die "\n";
                            }
                            $jobs{$child}{done} = 1;
                            print readline($jobs{$child}{output});
                            close $jobs{$child}{output};
                            delete $jobs{$child};
                        };
                        while (@program || %jobs) {
                            $do_wait->() if keys(%jobs) >= $jobs;
                            my $step;
                            for (0..$#program) {
                                next unless $program[$_]{options}{fork};
                                 # Don't run program if its deps haven't been finished
                                next if grep !$_->{done}, @{$program[$_]{follow}};
                                $step = splice @program, $_, 1;
                                last;
                            }
                            if (defined $step) {
                                chdir $step->{base};
                                status "⚙ ", show_step($step);
                                delazify($step);
                                pipe($step->{output}, my $OUTPUT) or die "pipe failed: $!\n";
                                binmode $step->{output}, ':utf8';
                                binmode $OUTPUT, ':utf8';
                                if (my $child = fork // die "Failed to fork: $!\n") {
                                     # parent
                                    $jobs{$child} = $step;
                                }
                                else {  # child
                                     # Don't fall out of the eval {} out there
                                    $SIG{__DIE__} = sub { warn @_; exit 1; };
                                    close STDOUT;
                                    open STDOUT, '>&', $OUTPUT or die "Could not reopen STDOUT: $!\n";
                                    close STDERR;
                                    open STDERR, '>&', $OUTPUT or die "Could not reopen STDERR: $!\n";
                                    do_step($step);
                                    exit 0;
                                }
                                close $OUTPUT;
                            }
                            elsif (%jobs) {
                                $do_wait->();
                            }
                            else {  # Do a non-parallel job
                                my $step = shift @program;
                                chdir $step->{base};
                                status "⚙ ", show_step($step);
                                delazify($step);
                                do_step($step);
                                $step->{done} = 1;
                            }
                        }
                    }
                    else {
                        for my $step (@program) {
                            chdir $step->{base};
                            status "⚙ ", show_step($step);
                            delazify($step);
                            do_step($step);
                        }
                    }
                };
                if ("$@" eq "interrupted\n") {
                    say "\e[31m✗\e[0m Interrupted.";
                    exit 1;
                }
                elsif ($@) {
                    warn $@ unless "$@" eq "\n";
                    say "\e[31m✗\e[0m Did not finish due to error.";
                    exit 1;
                }
                if ($simulate) {
                    say "\e[32m✓\e[0m Simulation finished.";
                }
                elsif ($touch) {
                    say "\e[32m✓\e[0m File modtimes updated.";
                }
                else {
                    say "\e[32m✓\e[0m Done.";
                }
            }
            exit 0;
        }
        1;
    }

     # Fuss if make wasn't called
    END {
        if ($? == 0 and !$make_was_called) {
            my $file = abs2rel($current_file, $original_base);
            warn "\e[31m✗\e[0m $file did not end with 'make;'\n";
        }
    }

# RULES AND DEPENDENCIES

    sub create_step {
        my ($to, $from, $recipe, $options, $package, $file, $line) = @_;
        ref $recipe eq 'CODE' or !defined $recipe or croak "Non-code recipe given to step";
        my $step = {
            caller_file => $current_file,
            caller_line => $line,
            base => cwd,
            to => [arrayify($to)],
            from => lazify($from),
            deps => undef,  # Generated from from
            recipe => $recipe,
            options => $options,
            check_stale => undef,
             # Intrusive state for planning and execution phases
            planned => 0,
            follow => [],
            done => 0,
            output => undef,
        };
        push @steps, $step;
        for (@{$step->{to}}) {
            push @{$targets{rel2abs($_)}}, $step;
        }
    }

    sub step ($$$;$) {
        create_step($_[0], $_[1], $_[2], $_[3] // {}, caller);
    }
    sub rule ($$$;$) { &step(@_); }

    sub phony ($;$$$) {
        my ($to, $from, $recipe, $options) = @_;
        for (arrayify($to)) {
            $phonies{rel2abs($_)} = 1;
        }
        create_step($to, $from, $recipe, $options // {}, caller) if defined $from;
    }

    sub subdep ($;$) {
        my ($to, $from) = @_;
        if (ref $to eq 'CODE') {  # Auto
            push @auto_subdeps, {
                base => cwd,
                code => $to
            };
        }
        elsif (defined $from) {  # Manual
            my $subdep = {
                base => cwd,
                to => [arrayify($to)],
                from => lazify($from),
            };
            for (@{$subdep->{to}}) {
                push @{$subdeps{rel2abs($_)}}, $subdep;
            }
        }
        else {
            croak 'subdep must be called with two arguments unless the first is a CODE ref';
        }
    }

    sub defaults {
        push @$defaults, map rel2abs($_), @_;
    }

    sub suggest ($;$) {
        push @suggestions, [rel2abs($_[0]), $_[1]];
    }

    sub targets {
        return keys %targets;
    }

    sub exists_or_target {
        return (-e $_[0] or exists $targets{rel2abs($_[0])});
    }

    sub arrayify {
        return ref $_[0] eq 'ARRAY' ? @{$_[0]} : $_[0];
    }
    sub lazify {
        my ($dep) = @_;
        return ref $dep eq 'CODE' ? $dep : [arrayify($dep)];
    }
    sub delazify {
         # Works on subdeps too
        my ($step) = @_;
        if (ref $step->{from} eq 'CODE') {
            $step->{from} = [$step->{from}(@{$step->{to}})];
        }
    }

    sub get_auto_subdeps {
        return map {
            my $target = $_;
            @{$autoed_subdeps{$target} //= [
                map {
                    chdir $_->{base};
                    my @got = $_->{code}($target);
                    if (grep !defined, @got) {
                        warn "Warning: function that generated auto subdeps for $target returned an undefined value\n";
                    }
                    realpaths(grep defined, @got);
                } @auto_subdeps
            ]}
        } @_;
    }
    sub push_new {
        my ($deps, @new) = @_;
        push @$deps, grep {
            my $d = $_;
            not grep $d eq $_, @$deps;
        } @new;
    }
    sub resolve_deps {
        my ($step) = @_;
        return if defined $step->{deps};
         # Get the realpaths of all dependencies and their subdeps
        chdir $step->{base};
        delazify($step);
         # Depend on the build script and this module too.
        my @deps = (realpaths(@{$step->{from}}), $step->{caller_file}, $this_file);
         # Using this style of loop because @deps will keep expanding.
        for (my $i = 0; $i < @deps; $i++) {
            defined $deps[$i] or die "Undef dependency given to step at $step->{caller_file} line $step->{caller_line}\n";
            push_new(\@deps, get_auto_subdeps($deps[$i]));
            for my $subdep (@{$subdeps{$deps[$i]}}) {
                chdir $subdep->{base};
                delazify($subdep);
                push_new(\@deps, realpaths(@{$subdep->{from}}));
            }
        }
        chdir $step->{base};
        $step->{deps} = [@deps];
    }

    sub show_step ($) {
        if ($verbose) {
            resolve_deps($_[0]);
            return "@{$_[0]{to}} ← " . join ' ', map abs2rel($_), @{$_[0]{deps}};
        }
        else {
            return "@{$_[0]{to}} ← " . join ' ', @{$_[0]{from}};
        }
    }
    sub debug_step ($) {
        return "$_[0]{caller_file}:$_[0]{caller_line}: " . directory_prefix($_[0]{base}) . show_step($_[0]);
    }

    sub target_is_default ($) {
        if (defined $defaults) {
            my $is = grep $_ eq $_[0], @$defaults;
            return $is;
        }
        else {
            return 0;
        }
    }

# SYSTEM INTERACTION

    sub cwd () {
        return $ENV{PWD};
    }
    sub chdir ($) {
        my $new = rel2abs($_[0]);
        if ($new ne cwd) {
            CORE::chdir $new or die "Failed to chdir to $new: $!\n";
            $ENV{PWD} = $new;
        }
    }
    sub fexists {
        defined $_[0] or Carp::confess "Undefined argument passed to fexists.";
        return 0 if $phonies{$_[0]};
        return -e $_[0];
    }
    sub modtime {
        return $modtimes{$_[0]} //= (fexists($_[0]) ? (stat $_[0])[9] : 0);
    }

    sub show_command (@) {
        my (@command) = @_;
        for (@command) {
            if (/\s/) {
                $_ =~ s/'/'\\''/g;
                $_ = "'$_'";
            }
        }
        return "\e[96m" . (join ' ', @command) . "\e[0m";
    }

    sub run (@) {
        if ($verbose) {
            say show_command(@_);
        }
        system(@_) == 0 or do {
            my @command = @_;
             # As per perldoc -f system
            if ($? == -1) {
                status("☢ Couldn't start command: $!");
            }
            elsif (($? & 127) == 2) {
                die "interrupted\n";
            }
            elsif ($? & 127) {
                status(sprintf "☢ Command died with signal %d, %s coredump",
                   ($? & 127),  ($? & 128) ? 'with' : 'without');
            }
            else {
                status(sprintf "☢ Command exited with value %d", $? >> 8);
            }
            die status("☢ Failed command: " . show_command(@_));
        }
    }

    sub realpaths (@) {
        return map rel2abs($_), @_;
    }

    sub canonpath {
        $_[0] eq '.' and return $_[0];
        if (index($_[0], '\\') == -1
        and index($_[0], '//') == -1
        and index($_[0], '/.') == -1
        and index($_[0], '/', length($_[0])-1) != length($_[0])-1) {
            return $_[0];
        }
        my $p = $_[0];
        $p =~ tr/\\/\//;
        1 while $p =~ s/\/(?:\.?|(?!\.\.\/)[^\/]*\/\.\.)(?=\/|$)//;
        return $p;
    }

    sub path_is_absolute {
        my ($path) = @_;
        return $path =~ /^(?:[a-zA-Z]:)?[\/\\]/;
    }

    sub rel2abs {
        my ($rel, $base) = @_;
        $base //= cwd;
        return canonpath(path_is_absolute($rel) ? $rel : "$base/$rel");
    }
    sub abs2rel {
        my ($abs, $base) = @_;
        $abs = canonpath($abs);
        path_is_absolute($abs) or return $abs;
        $base = defined($base) ? canonpath($base) : cwd;
        if ($abs eq $base) {
            return '.';
        }
        if (rindex($abs, $base . '/', 0) == 0) {
            return substr($abs, length($base) + 1);
        }
        return $abs;
    }

    sub iofail { $_[0] or croak $_[1]; undef }

    sub slurp {
        my ($file, $bytes, $fail) = @_;
        $fail //= 1;
        open my $F, '<', $file or return iofail $fail, "Failed to open $file for reading: $! in call to slurp";
        my $r;
        if (defined $bytes) {
            defined read($F, $r, $bytes) or return iofail $fail, "Failed to read $file: $! in call to slurp";
        }
        else {
            local $/; $r = <$F>;
            defined $r or return $fail, "Failed to read $file: $! in call to slurp";
        }
        close $F or return $fail, "Failed to clode $file: $! in call to slurp";
        return $r;
    }
    sub splat {
        my ($file, $string, $fail) = @_;
        $fail //= 1;
        defined $string or return iofail $fail, "Cannot splat undef to $file";
        open my $F, '>', $file or return iofail $fail, "Failed to open $file for writing: $! in call to splat";
        print $F $string or return iofail $fail, "Failed to write to $file: $! in call to splat";
        close $F or return iofail $fail, "Failed to close $file: $! in call to close";
    }
    sub slurp_utf8 {
        require Encode;
        return Encode::decode_utf8(slurp(@_));
    }
    sub splat_utf8 {
        require Encode;
        splat($_[0], Encode::encode_utf8($_[1]), $_[2]);
    }

    sub which {
        my ($cmd) = @_;
        for (split /[:;]/, $ENV{PATH}) {
            my $f = "$_/$cmd";
            return $f if -x $f;
            if (exists $ENV{PATHEXT}) {
                for my $ext (split /;/, $ENV{PATHEXT}) {
                    my $f = "$_/$cmd$ext";
                    return $f if -x $f;
                }
            }
        }
        return undef;
    }

# PLANNING

    sub init_plan {
        return {  # We had and might have more real stuff here
            stack => [],
            program => []
        };
    }

    sub plan_target {
        my ($plan, $target) = @_;
         # Make sure the file exists or there's a step for it
        unless ($targets{$target} or fexists($target)) {
            my $rel = abs2rel($target, $original_base);
            my $mess = "☢ Cannot find or make $rel ($target)" . (@{$plan->{stack}} ? ", required by\n" : "\n");
            for my $step (reverse @{$plan->{stack}}) {
                $mess .= "\t" . debug_step($step) . "\n";
            }
            die status($mess);
        }
         # In general, there should be only step per target, but there can be more.
        return grep plan_step($plan, $_), @{$targets{$target}};
    }

    sub plan_step {
        my ($plan, $step) = @_;
         # Register dependency for parallel scheduling.
        if (@{$plan->{stack}}) {
            push @{$plan->{stack}[-1]{follow}}, $step;
        }
         # detect loops
        if (not defined $step->{planned}) {
            my $mess = "☢ Dependency loop\n";
            for my $old (reverse @{$plan->{stack}}) {
                $mess .= "\t" . debug_step($old) . "\n";
                die status($mess) if $step eq $old;  # reference compare
            }
            Carp::confess $mess . "\t...oh wait, false alarm.  Which means there's a bug in MakePl.pm.\nDetected";
        }
        elsif ($step->{planned}) {
            return $step->{stale};  # Already planned
        }
         # Commit to planning
        push @{$plan->{stack}}, $step;
        $step->{planned} = undef;  # Mark that we're currently planning this

        resolve_deps($step);
         # always recurse to plan_target
        my $stale = grep plan_target($plan, $_), @{$step->{deps}};
         # chdir precisely now.
        chdir $step->{base};
        $stale ||= $force;
        $stale ||= $step->{check_stale}() if defined $step->{check_stale};
        $stale ||= grep {
            my $abs = rel2abs($_);
            !fexists($abs) or grep modtime($abs) < modtime($_), @{$step->{deps}};
        } @{$step->{to}};
        if ($stale) {
            push @{$plan->{program}}, $step;
        }
        else {
            $step->{done} = 1;  # Don't confuse parallel scheduler.
        }
         # Done planning this step
        $step->{planned} = 1;
        $step->{stale} = $stale;
        pop @{$plan->{stack}};
        return $stale;
    }

# RUNNING THIS FILE DIRECTLY

 # Generate a make.pl scaffold.
if ($^S == 0) {  # We've been called directly
    $make_was_called = 1;  # Not really but supresses warning
    if (@ARGV > 1 or (defined $ARGV[0] and $ARGV[0] =~ /-?-h(?:elp)?/)) {
        say "\e[31m✗\e[0m Usage: perl $0 <directory (default: .)>";
        exit 1;
    }
    my $loc = defined $ARGV[0] ? canonpath($ARGV[0]) : cwd;
    $loc = "$loc/make.pl" if -d $loc;
    if (-e $loc) {
        say "\e[31m✗\e[0m Did not generate $loc because it already exists.";
        exit 1;
    }
    my $dir = $loc =~ /^(.*)\/[^\/]*$/ ? $1 : cwd;
    my $path_to_pm = abs2rel(rel2abs(__FILE__), $dir);
    $path_to_pm =~ s/\/?MakePl\.pm$//;
    $path_to_pm =~ s/'/\\'/g;
    my $pathext = $path_to_pm eq '' ? '' : ".'/$path_to_pm'";
    local $/;
    my $out = <DATA>;
    $out =~ s/◀PATHEXT▶/$pathext/;
    open my $MAKEPL, '>:utf8', $loc or die "Failed to open $loc for writing: $!\n";
    print $MAKEPL $out or die "Failed to write to $loc: $!\n";
    chmod 0755, $MAKEPL or warn "Failed to chmod $loc: $!\n";
    close $MAKEPL or die "Failed to close $loc: $!\n";
    say "\e[32m✓\e[0m Generated $loc.";
}

1;

__DATA__
#!/usr/bin/perl
use lib do {__FILE__ =~ /^(.*)[\/\\]/; ($1||'.')◀PATHEXT▶};
use MakePl;

 # Sample steps
step \$program, \$main, sub {
    run 'gcc', '-Wall', $main, '-o', $program;
}
step 'clean', [], sub { unlink \$program; };

make;
