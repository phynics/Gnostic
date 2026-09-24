#!/usr/bin/env bash

set -euo pipefail

root_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
version=${CHIBI_VERSION:-0.12}
expected_sha256=${CHIBI_SHA256:-b70a1147bc70a0f90df3fb6081bc99808237fd17a9accf9ee7a2cc20d95a4df0}
prefix=${PREFIX:-/usr/local}
build_dir=$(mktemp -d)
archive="$build_dir/chibi-${version}.tar.gz"
trap 'rm -rf "$build_dir"' EXIT INT TERM

curl --fail --location --silent --show-error \
    "https://codeload.github.com/ashinn/chibi-scheme/tar.gz/refs/tags/${version}" \
    -o "$archive"
printf '%s  %s\n' "$expected_sha256" "$archive" | shasum -a 256 -c -
mkdir "$build_dir/source"
tar --extract --gzip --strip-components=1 --directory "$build_dir/source" --file "$archive"
patch -d "$build_dir/source" -p1 < "$root_dir/.devcontainer/patches/chibi-cell-timeout.patch"

perl - "$build_dir/source/include/chibi/features.h" <<'PERL'
use strict;
use warnings;

my $features = shift @ARGV;
open my $input, '<', $features or die "cannot read $features: $!";
local $/;
my $text = <$input>;
close $input;

my %replacements = (
    '/* #define SEXP_USE_NO_FEATURES 1 */' => "#define SEXP_USE_NO_FEATURES 1
#define SEXP_USE_GREEN_THREADS 1
#define SEXP_USE_CHECK_STACK 1
#define SEXP_USE_GROW_STACK 0
#define SEXP_INIT_STACK_SIZE 8192
#define SEXP_USE_FLONUMS 1
#define SEXP_USE_BIGNUMS 1
#define SEXP_USE_MATH 1
#define SEXP_USE_RATIOS 0
#define SEXP_USE_COMPLEX 0",
    '/* #define SEXP_USE_MODULES 0 */' => '#define SEXP_USE_MODULES 0',
    '/* #define SEXP_USE_STATIC_LIBS_EMPTY 1 */' => '#define SEXP_USE_STATIC_LIBS_EMPTY 1',
    '/* #define SEXP_USE_STRICT_TOPLEVEL_BINDINGS 0 */' => '#define SEXP_USE_STRICT_TOPLEVEL_BINDINGS 1',
);
for my $old (keys %replacements) {
    my $count = () = $text =~ /\Q$old\E/g;
    die "expected one '$old' in $features, found $count\n" unless $count == 1;
    my $new = $replacements{$old};
    $text =~ s/\Q$old\E/$new/;
}
my $limited_malloc = '#ifndef SEXP_USE_LIMITED_MALLOC';
my $count = () = $text =~ /\Q$limited_malloc\E/g;
die "expected one '$limited_malloc' in $features, found $count\n" unless $count == 1;
$text =~ s/\Q$limited_malloc\E/#define SEXP_USE_LIMITED_MALLOC 1\n$limited_malloc/;
open my $output, '>', $features or die "cannot write $features: $!";
print {$output} $text;
close $output;
PERL

features="$build_dir/source/include/chibi/features.h"
for guard in \
    'SEXP_USE_NO_FEATURES 1' \
    'SEXP_USE_GREEN_THREADS 1' \
    'SEXP_USE_CHECK_STACK 1' \
    'SEXP_USE_GROW_STACK 0' \
    'SEXP_INIT_STACK_SIZE 8192' \
    'SEXP_USE_FLONUMS 1' \
    'SEXP_USE_BIGNUMS 1' \
    'SEXP_USE_MATH 1' \
    'SEXP_USE_RATIOS 0' \
    'SEXP_USE_COMPLEX 0' \
    'SEXP_USE_MODULES 0' \
    'SEXP_USE_STATIC_LIBS_EMPTY 1' \
    'SEXP_USE_LIMITED_MALLOC 1' \
    'SEXP_USE_STRICT_TOPLEVEL_BINDINGS 1'; do
    grep -Fq "#define $guard" "$features"
done
grep -Fq 'gnostic_cell_timeout_armed && top > gnostic_cell_timeout_stack_limit' "$build_dir/source/vm.c"
grep -Fq 'sexp_context_interruptp(ctx) || gnostic_cell_timeout_pending' "$build_dir/source/vm.c"
grep -Fq 'sigaction(SIGUSR1, &action, NULL)' "$build_dir/source/main.c"

if [[ -n "${JOBS:-}" ]]; then
    jobs=$JOBS
elif [[ "$(uname -s)" == Darwin ]]; then
    jobs=$(sysctl -n hw.ncpu)
else
    jobs=$(getconf _NPROCESSORS_ONLN)
fi
make -C "$build_dir/source" -j"$jobs" SEXP_USE_DL=0 PREFIX="$prefix" chibi-scheme-static
install -d "$prefix/bin" "$prefix/share/chibi"
install -m 0755 "$build_dir/source/chibi-scheme-static" "$prefix/bin/chibi-scheme"
install -m 0644 "$build_dir/source/lib/init-7.scm" "$prefix/share/chibi/init-7.scm"
"$prefix/bin/chibi-scheme" -p '(+ 2 3)' | grep -Fxq 5
