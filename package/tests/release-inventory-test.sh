#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
	echo "usage: $0 OUT VERSION" >&2
	exit 2
fi

out=$1
version=$2
root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' 0 HUP INT TERM

expected=$(printf '%s\n' \
	"gl-app-starwatch_${version}_all.ipk" \
	"luci-app-starwatch_${version}_all.ipk" \
	"starwatchd_${version}_aarch64_cortex-a53.ipk")
actual=$(find "$out" -maxdepth 1 -type f -name '*.ipk' -exec basename {} \; | sort)
printf '%s\n' "$expected" >"$tmp/expected"
printf '%s\n' "$actual" >"$tmp/actual"
[ "$actual" = "$expected" ] || {
	echo 'unexpected Starwatch release IPK inventory' >&2
	diff -u "$tmp/expected" "$tmp/actual" || true
	exit 1
}

inspect_control() {
	ipk=$1
	want_package=$2
	want_arch=$3
	control="$tmp/$want_package.control.tar.gz"
	tar -xOzf "$ipk" ./control.tar.gz >"$control"
	metadata=$(tar -xOzf "$control" ./control)
	[ "$(printf '%s\n' "$metadata" | sed -n 's/^Package: //p')" = "$want_package" ]
	[ "$(printf '%s\n' "$metadata" | sed -n 's/^Version: //p')" = "$version" ]
	[ "$(printf '%s\n' "$metadata" | sed -n 's/^Architecture: //p')" = "$want_arch" ]
}

inspect_control "$out/starwatchd_${version}_aarch64_cortex-a53.ipk" starwatchd aarch64_cortex-a53
inspect_control "$out/luci-app-starwatch_${version}_all.ipk" luci-app-starwatch all
inspect_control "$out/gl-app-starwatch_${version}_all.ipk" gl-app-starwatch all

data="$tmp/starwatchd.data.tar.gz"
tar -xOzf "$out/starwatchd_${version}_aarch64_cortex-a53.ipk" ./data.tar.gz >"$data"
tar -xOzf "$data" ./usr/libexec/keithah-feed-migrate >"$tmp/keithah-feed-migrate"
cmp -s "$root/keithah-feed-migrate.sh" "$tmp/keithah-feed-migrate"
tar -tzvf "$data" | awk '$1 == "-rwxr-xr-x" && $6 == "./usr/libexec/keithah-feed-migrate" { found = 1 } END { exit !found }'

echo 'release inventory tests passed'
