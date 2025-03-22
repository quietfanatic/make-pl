MakePl
======

Very portable build system in Perl
https://github.com/quietfanatic/make-pl

### About

- Don't make your users type more than one command to build.
- Don't make your users download and install some obscure build system.
- Program your build system in a real programming language.
- `./make.pl && run`

### Installation

Just clone this repo and stuff it in your project directory.
This has no dependencies besides Perl >= 5.10 and its core modules.
Alternatively, use this repo as a git submodule.

### Usage

To run a make.pl:
```
./make.pl <options> <targets>
```
To generate a bare-bones make.pl:
```
perl MakePl.pm <directory (defaults to .)>
```
### Quick Reference
```
make;
```
- Put this at the end of the script, whether standalone or included.
```
step <targets>, <dependencies>, <routine>, <options>?;
```
- Defines a compilation step like in a Makefile.
   - `<targets>` can be a single filename or an array ref of filenames.
   - `<dependencies>` can be a single filename, an array ref of filenames,
          or a subroutine which returns filenames.
   - The compile routine (AKA the recipe) is given two array refs as
          arguments containing the targets and the dependencies.
   - Here are the available options:
       - `fork => 1`
           - This step can be run in parallel with other forkable steps.
       - `mkdir => 1`
           - Automatically generate the directory structures of all
             targets of this step.
```
phony <targets>, <dependencies>?, <routine>?, <options>?;
```
- like step, but the target(s) do not correspond to actual files.  They will
  always be considered stale.
```
subdep <targets>, <dependencies>;
```
- Establishes that anything that depends on the target(s) also depends
  on the given dependencies, e.g. because of an `#include` statement.
```
subdep <routine>;
```
- Provides a way to automatically deduce subdeps.  The routine will be called
  with a filename and is expected to return some more filenames.  See
  `sample_make.pl` in this repo for a function that'll scan C/C++ files for
  `#include` statements.
```
defaults <targets...>;
```
- With no arguments, make.pl will build these targets.  The default default is
  to run the first step given in the workflow.
```
suggest <target> <description>?;
```
- Suggest this target in the usage documentation.
```
targets
```
- Returns all files or phonies that are the target of any step that has
  been declared so far.
```
exists_or_target <filename>
```
- Checks if the file exists or there's a target for it.
```
include <filenames...>;
```
- Include the targets and steps in another make.pl.  Relative filenames, working
  directories, etc. all do The Right Thing.  Cyclical includes are fine and even
  encouraged.
```
chdir <directory>;
```
- Please use this instead of `CORE::chdir` or `Cwd::chdir`.
```
run <command>;
```
- Like the builtin `system()`, but aborts the build process if the command gives a
  non-zero exit status, and also prints the command when the `--verbose` option is
  active.
```
slurp <filename>, <length>?, <fail>?
```
- Just returns the contents of the file as a string.  If `<length>` is given, it
  only reads the first `<length>` bytes.  Dies on failure unless `<fail>` is
  provided and false.
```
splat <filename>, <string>, <fail>?;
```
- Writes the string to the filename, clobbering any previous contents.  Dies on
  failure unless `<fail>` is false.
```
slurp_utf8 <filename>, <length>?, <fail>?
splat_utf8 <filename>, <string>, <fail>?;
```
- Like slurp and splat, but with UTF-8-encoded files.  This may become the
  default soon.
```
which <command>
```
- Like `which` on UNIX and `where` on Windows.  Searches the PATH for the
  executable file providing the given command and returns it, or undef if it
  wasn't found.
```
canonpath <filename>
```
- Gets rid of extraneous ..s and things like that.  Also changes all backslashes
  into forward slashes.
```
rel2abs <filename>, <base>?
abs2rel <filename>, <base>?
```
- Convert between relative and absolute filenames, relative to the current
  working directory if `<base>` is not provided.

### Working Directories

MakePl tries to make working directories a lexical concept, so that things
just work how you expect them to.

- All relative filenames given to the API are relative to the current working
  directory.
- When you import `MakePl`, the working directory is always set to the same
  directory that the make.pl is in, no matter where you invoked it from.
- All recipes will be run in the same working directory that the step was
  defined in.
- Even if one make.pl includes another make.pl, each uses filenames relative to
  its own directory.  That is, if `./make.pl` says `modules/cake/lime` and
  `modules/cake/make.pl` says `lime`, they are talking about the same file.
- Filenames given on the command line are relative to the current working
  directory of the command line, not of the make.pl.
- If you want to manually change directories, use the chdir provided by this
  module.  Using `CORE::chdir` will desync `$ENV{PWD}`.

### Configuration

There are two recommended ways to do local build configuration:

- You can declare different build configurations (debug, release, etc) and
  duplicate targets between them.  Each unused target only adds about 20
  microseconds to the script runtime.
- For more detailed configuration (compiler flags, library locations, etc) it's
  recommended to put global variables at the top of your build script where they
  can be easily changed.  The build script's modification time is monitored by
  the dependency tracker, so if you change it, everything will be properly
  rebuilt.

### Recommendations

- It's best to die if something fails.  The autodie pragma is useful.
- A basic knowledge of Perl is recommended.  Knowledge of GNU `make` and
  Makefiles is not required, but knowledge of why people use them is.
- If your program is large and has good modularity, do take advantage of the
  include functionality.  If two make.pl files mutually include one another, you
  can invoke either one to do stuff; the following commands would be equivalent:
```
$ ./make.pl modules/cake/lime
$ modules/cake/make.pl modules/cake/lime
$ cd modules/cake; ./make.pl lime
```
  This does cause one counterintuitive effect.  If you want to use a phony
  target belonging to a make.pl in a different directory, you must prefix
  the phony target with that directory (as if it's actually a file).
```
$ modules/cake/make.pl clean  # oops, this cleans the whole project
$ modules/cake/make.pl modules/cake/clean  # just clean the cake
$ ./make.pl modules/cake/clean  # this works too
```
- After the previous point it goes without saying, but you can invoke a
  make.pl from any directory, not just the one it's in, provided the make.pl
  is correctly formed.  To make sure your make.pl can be run anywhere, put
```
use lib do {__FILE__ =~ /^(.*)[\/\\]/; ($1||'.')◀path▶};
use MakePl;
```
  where `◀path▶` is nothing if `MakePl.pm` is in the same directory, or
  something like `.'/tools'` if `MakePl.pm` is in the directory `tools`. If you
  used `perl MakePl.pm` to generate a make.pl, it'll have done this for you.

- Because your build script is in a real programming language and not a DSL, you
  can actually do real abstraction.  See `sample_make.pl` for some examples.
- This module is entirely symlink-ignorant.  If you use functions that reduce
  symlinks like `Cwd::realpath`, you may cause confusion.
- This module won't work if you have filenames with backslashes in them.  I
  haven't decided whether this is a bug or a feature.

### BONUS

- If you `use MakePl::C`, the build system will follow `#include "file"` directives
  in your C and C++ files, so if you update a header, all files that include it
  will be rebuilt.  It will not follow `#include <file>` directives.

### Known Issues

- On Windows, unicode console output might be busted.  The behavior of the
  program should still work fine.
- Sometimes, when doing parallel builds, if a process fails with a long error
  message (hundreds of lines), the build will hang and not print the message.
  If this happens, a workaround is to rerun the same build with `--jobs=1`.
