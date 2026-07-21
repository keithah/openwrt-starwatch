#!/bin/sh
set -eu

root="$(CDPATH= cd "$(dirname "$0")/../.." && pwd)"
workflow="$root/.github/workflows/release.yml"

[ -f "$workflow" ]
grep -F "tags: ['v*']" "$workflow" >/dev/null
grep -F 'contents: write' "$workflow" >/dev/null
grep -F 'actions/checkout@v6' "$workflow" >/dev/null
grep -F 'actions/setup-go@v6' "$workflow" >/dev/null
grep -F 'make -C package VERSION="$version" all' "$workflow" >/dev/null
grep -F 'sh package/tests/release-inventory-test.sh package/out "$version"' "$workflow" >/dev/null
grep -F 'gh release view "$tag"' "$workflow" >/dev/null
grep -F 'gh release download "$tag"' "$workflow" >/dev/null
grep -F 'gh release create "$tag"' "$workflow" >/dev/null
grep -F 'python3 package/tests/compare-ipk-content.py "package/out/$asset" "$existing_dir/$asset"' "$workflow" >/dev/null
grep -F 'test -f package/install.sh' "$workflow" >/dev/null

# The immutable tag supplies the installer source to the aggregator. The release
# asset inventory itself must remain the three Starwatch packages only.
grep -F 'starwatchd_${version}_aarch64_cortex-a53.ipk' "$workflow" >/dev/null
grep -F 'luci-app-starwatch_${version}_all.ipk' "$workflow" >/dev/null
grep -F 'gl-app-starwatch_${version}_all.ipk' "$workflow" >/dev/null
if grep -E 'package/out/(Packages|Packages\.gz|Packages\.sig|[^ ]*\.pub|install-starwatch\.sh)' "$workflow" >/dev/null; then
	echo 'release workflow publishes a shared-feed or installer asset' >&2
	exit 1
fi

echo 'release workflow tests passed'
