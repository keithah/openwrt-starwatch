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

mkdir -p "$tmp/starwatchd-data"
tar -xOzf "$1" ./data.tar.gz >"$tmp/data.tar.gz"
tar -xzf "$tmp/data.tar.gz" -C "$tmp/starwatchd-data"
cmp -s "$root/keithah-feed-migrate.sh" "$tmp/starwatchd-data/usr/libexec/keithah-feed-migrate"
tar -tzvf "$tmp/data.tar.gz" | awk '$1 == "-rwxr-xr-x" && $6 == "./usr/libexec/keithah-feed-migrate" { found = 1 } END { exit !found }'

set -- "$pages/luci-app-starwatch_${version}_all.ipk"
[ "$#" -eq 1 ]
[ -f "$1" ]
luci_ipk=$(basename "$1")

set -- "$pages/gl-app-starwatch_${version}_all.ipk"
[ "$#" -eq 1 ]
[ -f "$1" ]
glapp_ipk=$(basename "$1")

printf '%s\n' Packages Packages.gz install-starwatch.sh "$starwatchd_ipk" "$luci_ipk" "$glapp_ipk" | sort >"$tmp/expected-page-files"
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

cmp -s "$root/install.sh" "$pages/install-starwatch.sh"

cat >"$tmp/usign" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>'$tmp/usign.log'
output=''
while [ "\$#" -gt 0 ]; do
	if [ "\$1" = '-x' ]; then output="\$2"; shift 2; else shift; fi
done
[ -n "\$output" ]
printf 'test signature\n' >"\$output"
EOF
chmod +x "$tmp/usign"
printf 'test private key\n' >"$tmp/feed.sec"

make -C "$root" OUT="$out" VERSION="$version" SIGN_KEY="$tmp/feed.sec" USIGN="$tmp/usign" feed-artifact
[ -s "$pages/Packages.sig" ]
grep -F -- "-S -m Packages -s $tmp/feed.sec -x Packages.sig" "$tmp/usign.log" >/dev/null

if make -C "$root" OUT="$out" signed-feed-artifact >"$tmp/unsigned.log" 2>&1; then
	echo 'signed artifact unexpectedly succeeded without a signing key' >&2
	exit 1
fi

echo 'feed artifact tests passed'
