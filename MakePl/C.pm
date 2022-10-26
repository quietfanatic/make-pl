require MakePl;

package MakePl::C;

 # Automatically glean subdeps from #includes
sub follow_includes {
    my $includes = (@_);
    MakePl::subdep sub {
        my ($file) = @_;
         # Select only files of C-like languages
        $file =~ /\.(?:c|cpp|cxx|c\+\+|cc|h|hpp|hxx|h\+\+|hh|m|mm|tcc|icc)$/i or return ();

        my $base = ($file =~ /(.*?)[^\\\/]*$/ and $1);
        my @incs = (MakePl::slurp $file) =~ /^\s*#include\s*"([^"]*)"/gmi;
        my @r;
        inc: for (@incs) {
            for my $I (@{$includes}, $base) {
                if (-e "$I/$_") {
                    push @r, MakePl::rel2abs("$I/$_");
                    next inc;
                }
            }
             # Didn't find it?
            warn "Couldn't register include dependency from \"$file\" to \"$_\".  If that header doesn't exist in this build workflow, please use #include <...> instead of #include \"...\"\n";

        }
        return @r;
    };
}
sub import {
     # Ignore parameters
    follow_includes();
}

