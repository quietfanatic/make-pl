#!/usr/bin/perl

 # MakePl - Portable drop-in build system
 # https://github.com/quietfanatic/make-pl
 # (Just copy this into your project directory somewhere)

=cut
The MIT License (MIT)

Copyright (c) 2013 Lewis Wall

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
=cut

package MakePl;

use strict;
use warnings; no warnings 'once';
use feature qw(switch say);
use autodie;
no autodie 'chdir';
use Exporter;
use Carp qw(croak);
use Cwd qw(realpath);
use subs qw(cwd chdir);
use File::Spec::Functions qw(:ALL);

our @ISA = 'Exporter';
our @EXPORT = qw(make rule rules phony subdep defaults include option cwd chdir targetmatch run);
our %EXPORT_TAGS = ('all' => \@EXPORT);


##### GLOBALS
 # Caches the current working directory
our $cwd = Cwd::cwd();
 # This variable is only defined inside a workflow definition.
our %workflow;
 # This is set to 0 when recursing.
our $this_is_root = 1;
 # Set once only.
our $original_base = cwd;
 # Prevent double-inclusion; can't use %INC because it does relative paths.
our @included = realpath($0);
 # A cache of file modification times.  It's probably safe to keep until exit.
my %modtimes;
 # For preventing false error messages
my $died_from_no_make = 0;
 # Defined later
my %builtin_options;
##### DEFINING WORKFLOWS


sub import {
    %workflow and croak "workflow was called inside a workflow (did you use 'do' instead of 'include'?)";
    my ($package, $file, $line) = caller;
    %workflow = (
        caller_package => $package,
        caller_file => $file,
        caller_line => $line,
        rules => [],
        targets => {},
        subdeps => {},
        auto_subdeps => [],
        autoed_subdeps => {},
        phonies => {},
        defaults => undef,
        options => {%builtin_options},
        made => 0,
    );
     # Get directory of the calling file, which may not be cwd
    my @vdf = splitpath(rel2abs($file));
    my $base = catpath($vdf[0], $vdf[1], '');
    my $old_cwd = cwd;
    chdir $base;
    MakePl->export_to_level(1, @_);
}

sub make () {
    $workflow{made} = 1;
    if ($this_is_root) {
        exit(!run_workflow(@ARGV));
    }
    1;
}

END {
    if (!$died_from_no_make and !$workflow{made}) {
        warn "\e[31m✗\e[0m $workflow{caller_file} did not end with 'make;'\n";
    }
}

### DECLARING RULES

 # caller abstracted out because phony() delegates to this as well.
sub rule_with_caller ($$$$$$) {
    my ($package, $file, $line, $to, $from, $recipe) = @_;
    ref $recipe eq 'CODE' or croak "Non-code recipe given to rule";
    my $rule = {
        base => cwd,
        to => [arrayify($to)],
        from => lazify($from),
        recipe => $recipe,
        caller_file => $file,
        caller_line => $line,
        planned => 0,  # Intrusive state for the planning phase
    };
    push @{$workflow{rules}}, $rule;
    for my $to (@{$rule->{to}}) {
        push @{$workflow{targets}{realpath($to)}}, $rule;
    }
}
sub rule ($$$) {
    %workflow or croak "rule was called outside of a workflow";
    my ($to, $from, $recipe) = @_;
    my ($package, $file, $line) = caller;
    rule_with_caller($package, $file, $line, $to, $from, $recipe);
}
sub phony ($;$$) {
    %workflow or croak "phony was called outside of a workflow";
    @_ == 2 and croak "phony was given 2 arguments, but it must have either 1 or 3";
    my ($phony, $from, $recipe) = @_;
    for my $p (arrayify($phony)) {
        $workflow{phonies}{realpath($p)} = 1;
    }
    if (defined $from) {
        my ($package, $file, $line) = caller;
        rule_with_caller($package, $file, $line, $phony, $from, $recipe);
    }
}
sub rules ($$) {
    %workflow or croak "rules was called outside of a workflow";
    my ($tofroms, $recipe) = @_;
    ref $tofroms eq 'ARRAY' or croak "First argument to rules wasn't an ARRAY ref";
    for (@{$tofroms}) {
        @$_ == 2 or croak "Each of the elements of the first argument to rules must have two elements";
        my ($package, $file, $line) = caller;
        rule_with_caller($package, $file, $line, $_->[0], $_->[1], $recipe);
    }
}
sub subdep ($;$) {
    %workflow or croak "subdep was called outside of a workflow";
    my ($to, $from) = @_;
    if (ref $to eq 'CODE') {
        push @{$workflow{auto_subdeps}}, {
            base => cwd,
            code => $to
        };
    }
    elsif (defined $from) {
        my $subdep = {
            base => cwd,
            to => [arrayify($to)],
            from => lazify($from),
        };
        for my $to (@{$subdep->{to}}) {
            my $rp = realpath($to);
            push @{$workflow{subdeps}{$rp}}, $subdep;
        }
    }
    else {
        croak 'subdep must be called with two arguments unless the first is a CODE ref';
    }
}
sub arrayify {
    return ref $_[0] eq 'ARRAY' ? @{$_[0]} : $_[0];
}
sub lazify {
    my ($dep) = @_;
    return ref $dep eq 'CODE' ? $dep : [arrayify($dep)];
}
sub delazify {
    my ($dep, @args) = @_;
    return ref $dep eq 'CODE' ? $dep->(@args) : @$dep;
}


##### OTHER DECLARATIONS

sub defaults {
    push @{$workflow{defaults}}, map realpath($_), @_;
}
sub include {
    for (@_) {
        my $file = $_;
        -e $file or croak "Cannot include $file because it doesn't exist";
        if (-d $file) {
            my $makepl = catfile($file, 'make.pl');
            next unless -e $makepl;
            $file = $makepl;
        }
         # Skip already-included files
        my $real = realpath($file);
        next if grep $real eq $_, @included;
        push @included, $real;

        my $this_workflow = \%workflow;
        local $this_is_root = 0;
        local %workflow;
        do {
            package main;
            my $old_cwd = MakePl::cwd;
            do $file;
            MakePl::chdir $old_cwd;
            $@ and die_status $@;
        };
        if (!$workflow{made}) {
            $died_from_no_make = 1;
            die "\e[31m✗\e[0m $workflow{caller_file} did not end with 'make;'\n";
        }
        return unless %workflow;  # Oops, it wasn't a make.pl, but we did it anyway
         # merge workflows
        push @{$this_workflow->{rules}}, @{$workflow{rules}};
        for (keys %{$workflow{targets}}) {
            push @{$this_workflow->{targets}{$_}}, @{$workflow{targets}{$_}};
        }
        $this_workflow->{phonies} = {%{$this_workflow->{phonies}}, %{$workflow{phonies}}};
        for (keys %{$workflow{subdeps}}) {
            push @{$this_workflow->{subdeps}{$_}}, @{$workflow{subdeps}{$_}};
        }
         # Our options override included options
        $this_workflow->{options} = {%{$workflow{options}}, %{$this_workflow->{options}}};
        push @{$this_workflow->{auto_subdeps}}, @{$workflow{auto_subdeps}};
    }
}

##### CONFIGURATION

%builtin_options = (
    help => {
        ref => sub {
            say "\e[31m✗\e[0m Usage: $0 <options> <targets>";
            my @custom = grep $workflow{options}{$_}{custom}, keys %{$workflow{options}};
            if (@custom) {
                say "Custom options:";
                for (sort @custom) {
                    if (defined $workflow{options}{$_}{desc}) {
                        say "    $workflow{options}{$_}{desc}";
                    }
                    else {
                        say "    --$_";
                    }
                }
            }
            my @general = grep !$workflow{options}{$_}{custom}, keys %{$workflow{options}};
            if (@general) {
                say "General options:";
                for (sort @general) {
                    say "    $workflow{options}{$_}{desc}";
                }
            }
            say "Final targets (use --list-targets to see all targets):";
            for (sort grep target_is_final($_), keys %{$workflow{targets}}) {
                say "    ", abs2rel($_), target_is_default($_) ? " (default)" : "";
            }
            exit 1;
        },
        desc => "--help - show this help message",
        custom => 0
    },
    'list-targets' => {
        ref => sub {
            say "\e[31m✗\e[0m All targets:";
            for (sort keys %{$workflow{targets}}) {
                say "    ", abs2rel($_), target_is_default($_) ? " (default)" : "";
            }
            exit 1;
        },
        desc => "--list-targets - list all declared targets",
        custom => 0
    },
);

sub option ($$;$) {
    %workflow or croak "option was called outside of a workflow";
    my ($name, $ref, $desc) = @_;
    if (ref $name eq 'ARRAY') {
        &option($_, $ref, $desc) for @$name;
    }
    elsif (ref $ref eq 'SCALAR' or ref $ref eq 'CODE') {
        $workflow{options}{$name} = {
            ref => $ref,
            desc => $desc,
            custom => 1
        };
    }
    else {
        croak "Second argument to option is not a SCALAR or CODE ref";
    }
}

##### DIRECTORY HANDLING
 # Cwd::cwd is super slow, so we should do it as little as possible.
sub cwd () {
    return $cwd;
}
sub chdir ($) {
    $cwd eq $_[0] or Cwd::chdir($cwd = $_[0]);
}

##### UTILITIES

sub targetmatch {
    my ($rx) = @_;
    return grep $_ =~ $rx, map abs2rel($_), keys %{$workflow{targets}};
}

sub run (@) {
    system(@_) == 0 or do {
        my @command = @_;
        ref $_[0] eq 'ARRAY' and shift @command;
        for (@command) {
            if (/\s/) {
                $_ =~ s/'/'\\''/g;
                $_ = "'$_'";
            }
        }
         # As per perldoc -f system
        if ($? == -1) {
            status(print "☢ Couldn't start command: $!");
        }
        elsif ($? & 127) {
            status(sprintf "☢ Command died with signal %d, %s coredump",
               ($? & 127),  ($? & 128) ? 'with' : 'without');
        }
        else {
            status(sprintf "☢ Command exited with value %d", $? >> 8);
        }
        die_status("☢ Failed command: @command");
    }
}
sub realpaths (@) {
    return map {
        my $r = realpath($_);
        unless (defined $r) {
            my $abs = rel2abs($_);
            croak "\"$abs\" doesn't seem to be a real path";
        }
        $r;
    } @_;
}

sub target_is_final ($) {
    my $old_cwd = cwd;
    for (@{$workflow{rules}}) {
        chdir $_->{base};
        for (delazify($_->{from}, $_->{to})) {
            if (realpath($_) eq $_[0]) {
                chdir $old_cwd;
                return 0;
            }
        }
    }
    chdir $old_cwd;
    return 1;
}

sub target_is_default ($) {
    if (defined $workflow{defaults}) {
        my $is = grep $_ eq $_[0], @{$workflow{defaults}};
        return $is;
    }
    else {
        my $rule = $workflow{rules}[0];
        defined $rule or return 0;
        my $old_cwd = cwd;
        chdir $rule->{base};
        for (@{$rule->{to}}) {
            if (realpath($_) eq $_[0]) {
                chdir $old_cwd;
                return 1;
            }
        }
        chdir $old_cwd;
        return 0;
    }
}

##### PRINTING ETC.

sub directory_prefix {
    my ($d, $base) = @_;
    $d //= cwd;
    $base //= $original_base;
    return $d eq $base
        ? ''
        : '[' . abs2rel($d, $base) . '/] ';
}
sub status {
    say directory_prefix(), @_;
}
sub die_status {
    status @_;
    die "\n";
}
sub show_rule ($) {
    return "@{$_[0]{to}} ← " . join ' ', delazify($_[0]{from}, $_[0]{to});
}
sub debug_rule ($) {
    return "$_[0]{caller_file}:$_[0]{caller_line}: " . directory_prefix($_[0]{base}) . show_rule($_[0]);
}

##### FILE INSPECTION UTILITIES
 # These work with absolute paths.

sub fexists {
    return 0 if $workflow{phonies}{$_[0]};
    return -e $_[0];
}
sub modtime {
    return $modtimes{$_[0]} //= (fexists($_[0]) ? (stat $_[0])[9] : 0);
}

##### PLANNING

sub init_plan {
    return {  # We had and might have more real stuff here
        stack => [],
        program => []
    };
}

sub plan_target {
    my ($plan, $target) = @_;
     # Make sure the file exists or there's a rule for it
    my $rel = abs2rel($target, $original_base);
    unless ($workflow{targets}{$target} or fexists($target)) {
        my $mess = "☢ Cannot find or make $rel" . (@{$plan->{stack}} ? ", required by\n" : "\n");
        for my $rule (reverse @{$plan->{stack}}) {
            $mess .= "\t" . debug_rule($rule) . "\n";
        }
        die_status $mess;
    }
     # In general, there should be only rule per target, but there can be more.
    return grep plan_rule($plan, $_), @{$workflow{targets}{$target}};
}

sub get_auto_subdeps {
    my $old_cwd = cwd;
    my @r = map {
        my $target = $_;
        @{$workflow{autoed_subdeps}{$target} //= [
            map {
                chdir $_->{base};
                realpaths($_->{code}($target));
            } @{$workflow{auto_subdeps}}
        ]}
    } @_;
    chdir $old_cwd;
    return @r;
}

sub add_subdeps {
    my @deps = @_;
    my $old_cwd = cwd;
     # Using this style of loop because @deps will keep expanding.
    for (my $i = 0; $i < @deps; $i++) {
        push @deps, grep { my $d = $_; not grep $d eq $_, @deps } get_auto_subdeps($deps[$i]);
        for my $subdep (@{$workflow{subdeps}{$deps[$i]}}) {
            chdir $subdep->{base};
            $subdep->{from} = [delazify($subdep->{from}, $subdep->{to})];
            push @deps, grep { my $d = $_; not grep $d eq $_, @deps } realpaths(@{$subdep->{from}});
        }
    }
    chdir $old_cwd;
    return @deps;
}

sub resolve_deps {
    my ($rule) = @_;
     # Get the realpaths of all dependencies and their subdeps
    chdir $rule->{base};
    $rule->{from} = [delazify($rule->{from}, $rule->{to})];
    return add_subdeps(realpaths(@{$rule->{from}}));
}

sub plan_rule {
    my ($plan, $rule) = @_;
    chdir $rule->{base};
     # detect loops
    if (not defined $rule->{planned}) {
        my $mess = "☢ Dependency loop\n";
        for my $old (reverse @{$plan->{stack}}) {
            $mess .= "\t" . debug_rule($old) . "\n";
            die_status $mess if $rule eq $old;  # reference compare
        }
        Carp::confess $mess . "\t...oh wait, false alarm.  Which means there's a bug in make.pm.\nDetected";
    }
    elsif ($rule->{planned}) {
        return 1;  # Already planned, but we'll still cause updates
    }
    push @{$plan->{stack}}, $rule;
    $rule->{planned} = undef;  # Mark that we're currently planning this

     # Now is when we officially collapse lazy dependencies and stuff like that
    my @deps = resolve_deps($rule);
     # always recurse to plan_target
    my $stale = grep plan_target($plan, $_), @deps;
    $stale ||= grep {
        my $abs = realpath(rel2abs($_, $rule->{base}));
        !fexists($abs) or grep modtime($abs) < modtime($_), @deps;
    } @{$rule->{to}};
    push @{$plan->{program}}, $rule if $stale;
     # Done planning this rule
    $rule->{planned} = 1;
    pop @{$plan->{stack}};
    return $stale;
}

sub plan_workflow(@) {
    my (@args) = @_;
    my $plan = init_plan();
    if (@args) {
        grep plan_target($plan, realpath($_)), @args;
    }
    elsif ($workflow{defaults}) {
        grep plan_target($plan, $_), @{$workflow{defaults}};
    }
    else {
        plan_rule($plan, $workflow{rules}[0]);
    }
    return @{$plan->{program}};
}

##### RUNNING

sub run_workflow {
    my $double_minus = 0;
    my @args;
    eval {
        for (@_) {
            if ($double_minus) {
                push @args, $_;
            }
            elsif ($_ eq '--') {
                $double_minus = 1;
            }
            elsif (/^--([^=]*)(?:=(.*))?$/) {
                my ($name, $val) = ($1, $2);
                my $optop = $workflow{options}{$name};
                if (not defined $optop) {
                    if (%{$workflow{options}}) {
                        say "\e[31m✗\e[0m Unrecognized option --$name.  Try --help to see available options.";
                    }
                    else {
                        say "\e[31m✗\e[0m Unrecognized option --$name.  This script takes no options.";
                    }
                    exit 1;
                }
                elsif (ref $optop->{ref} eq 'SCALAR') {
                    ${$optop->{ref}} = $val;
                }
                else {  # CODE
                    $optop->{ref}($val);
                }
            }
            else {
                push @args, $_;
            }
        }
    };
    if ($@) {
        warn $@ unless "$@" eq "\n";
        say "\e[31m✗\e[0m Nothing was done due to command-line error.";
        return 0;
    }
    if (not @{$workflow{rules}}) {
        say "\e[32m✓\e[0m Nothing was done because no rules have been declared.";
        return 1;
    }
    my @program = eval { plan_workflow(@args) };
    if ($@) {
        warn $@ unless "$@" eq "\n";
        say "\e[31m✗\e[0m Nothing was done due to error.";
        return 0;
    }
    if (not @program) {
        say "\e[32m✓\e[0m All up to date.";
        return 1;
    }
    my $old_cwd = cwd;
    for my $rule (@program) {
        chdir rel2abs($rule->{base});
        status "⚙ ", show_rule($rule);
        eval { $rule->{recipe}->($rule->{to}, $rule->{from}) };
        if ($@) {
            warn $@ unless "$@" eq "\n";
            say "\e[31m✗\e[0m Did not finish due to error.";
            chdir $old_cwd;
            return 0;
        }
    }
    say "\e[32m✓\e[0m Done.";
    chdir $old_cwd;
    return 1;
}


##### Generate a make.pl scaffold

if ($^S == 0) {  # We've been called directly
    if (@ARGV != 1 or $ARGV[0] eq '--help') {
        say "\e[31m✗\e[0m Usage: perl $0 <directory (default: .)>";
        exit 1;
    }
    my $loc = $ARGV[0];
    defined $loc or $loc = cwd;
    my $dir;
    if (-d $loc) {
        $loc = "$loc/make.pl";
        $dir = $loc;
    }
    elsif (-e $loc) {
        say "\e[31m✗\e[0m Did not generate $loc because it already exists.";
        exit 1;
    }
    elsif ($loc =~ /^(.*)\/[^\/]*$/) {
        $dir = $1;
    }
    else {
        $dir = cwd;
    }
    require FindBin;
    my $path_to_pm = abs2rel($FindBin::Bin, $dir);
    open my $MAKEPL, '>', "$loc";
    print $MAKEPL <<"END";
#!/usr/bin/perl
use strict;
use warnings;
use FindBin;
use lib "\$FindBin::Bin/$path_to_pm";
use MakePl;

 # Sample rules
rule \$program, \$main, sub {
    run "gcc -Wall \\Q\$main\\E -o \\Q\$program\\E";
};
rule 'clean', [], sub { unlink \$program; };

make;
END
    chmod 0755, $MAKEPL;
    close $MAKEPL;
    say "\e[32m✓\e[0m Generated $loc.";
}

1;