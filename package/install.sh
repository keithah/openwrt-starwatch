#!/bin/sh
# Install the Starwatch packages from the project-maintained opkg feed.
set -eu

feed_url='https://keithah.github.io/openwrt-starwatch'
target_root="${STARWATCH_ROOT:-/}"
feeds_file="$target_root/etc/opkg/customfeeds.conf"
keys_dir="$target_root/etc/opkg/keys"
feed_key_file="$keys_dir/f6c72c675c844b91"
feed_key='untrusted comment: Starwatch opkg feed
RWT2xyxnXIRLkZzbs1HvD+48GPkSqoNPCZVCOw49GUdTg2O7Cv9LzMtx'

fail() {
	printf '%s\n' "starwatch installer: $*" >&2
	exit 1
}

[ "$(id -u)" = 0 ] || fail 'must be run as root'
command -v opkg >/dev/null 2>&1 || fail 'opkg is required'
command -v wget >/dev/null 2>&1 || fail 'wget is required'

if ! architectures=$(opkg print-architecture); then
	fail 'could not determine package architectures'
fi
if ! printf '%s\n' "$architectures" | awk '$2 == "aarch64_cortex-a53" { found = 1 } END { exit !found }'; then
	fail 'this installer requires aarch64_cortex-a53'
fi

[ -d "$target_root/etc/opkg" ] || fail "missing $target_root/etc/opkg"
[ -d "$keys_dir" ] || fail "missing $keys_dir"
[ -f "$feeds_file" ] || : >"$feeds_file"

if [ -e "$target_root/etc/config/glconfig" ] || [ -e "$target_root/usr/lib/oui-httpd" ]; then
	ui_package='gl-app-starwatch'
	dashboard_url='http://router-address:9633/'
else
	ui_package='luci-app-starwatch'
	dashboard_url='http://router-address:9633/'
fi

feeds_dir=$(dirname "$feeds_file")
tmp_file=$(mktemp "$feeds_dir/.customfeeds.conf.XXXXXX")
key_tmp=$(mktemp "$keys_dir/.starwatch-key.XXXXXX")
trap 'rm -f "$tmp_file" "$key_tmp"' 0 HUP INT TERM

printf '%s\n' "$feed_key" >"$key_tmp"
chmod 0644 "$key_tmp"
mv "$key_tmp" "$feed_key_file"

# This feed is managed exclusively by this installer. Keep every other feed
# line byte-for-byte while replacing all previous managed entries with one.
awk '$1 == "src/gz" && $2 == "starwatch" { next } { print }' "$feeds_file" >"$tmp_file"
printf 'src/gz starwatch %s\n' "$feed_url" >>"$tmp_file"

# mktemp normally creates mode 0600. Retain the existing file's access mode
# and owner when the platform's stat format can provide them.
if metadata=$(stat -c '%a %u %g' "$feeds_file" 2>/dev/null); then
	set -- $metadata
	chmod "$1" "$tmp_file"
	chown "$2:$3" "$tmp_file" 2>/dev/null || fail 'could not preserve feed file ownership'
elif metadata=$(stat -f '%Lp %u %g' "$feeds_file" 2>/dev/null); then
	set -- $metadata
	chmod "$1" "$tmp_file"
	chown "$2:$3" "$tmp_file" 2>/dev/null || fail 'could not preserve feed file ownership'
fi
mv "$tmp_file" "$feeds_file"
trap - 0 HUP INT TERM

opkg update
opkg install starwatchd "$ui_package"

printf 'Installed Starwatch with %s. Dashboard: %s\n' "$ui_package" "$dashboard_url"
