#!/bin/sh
set -eu

root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' 0 HUP INT TERM
out="$tmp/out"
pages="$out/pages"
version=$(sed -n 's/^VERSION := //p' "$root/Makefile")
[ -n "$version" ]

[ ! -e /pages ]
if make -C "$root" OUT= feed-artifact >"$tmp/empty-out.log" 2>&1; then
	echo 'empty OUT unexpectedly succeeded' >&2
	exit 1
fi
[ ! -e /pages ]

mkdir -p "$out"
: >"$out/foreign_99.0_all.ipk"

make -C "$root" OUT="$out" VERSION="$version" feed-artifact

set -- "$pages/starwatchd_${version}_aarch64_cortex-a53.ipk"
[ "$#" -eq 1 ]
[ -f "$1" ]
starwatchd_ipk=$(basename "$1")

set -- "$pages/luci-app-starwatch_${version}_all.ipk"
[ "$#" -eq 1 ]
[ -f "$1" ]
luci_ipk=$(basename "$1")

set -- "$pages/gl-app-starwatch_${version}_all.ipk"
[ "$#" -eq 1 ]
[ -f "$1" ]
glapp_ipk=$(basename "$1")

printf '%s\n' Packages Packages.gz install.sh "$starwatchd_ipk" "$luci_ipk" "$glapp_ipk" | sort >"$tmp/expected-page-files"
find "$pages" -type f -exec basename {} \; | sort >"$tmp/page-files"
cmp -s "$tmp/expected-page-files" "$tmp/page-files"

gzip -cd "$pages/Packages.gz" >"$tmp/Packages"
cmp -s "$pages/Packages" "$tmp/Packages"

awk '/^Filename: / { print $2 }' "$pages/Packages" >"$tmp/filenames"
printf '%s\n' "$starwatchd_ipk" "$luci_ipk" "$glapp_ipk" | sort >"$tmp/expected-filenames"
sort "$tmp/filenames" >"$tmp/sorted-filenames"
cmp -s "$tmp/expected-filenames" "$tmp/sorted-filenames"
while IFS= read -r filename; do
	[ -f "$pages/$filename" ]
done <"$tmp/filenames"

cmp -s "$root/install.sh" "$pages/install.sh"

echo 'feed artifact tests passed'
