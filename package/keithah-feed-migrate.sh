#!/bin/sh
# Migrate legacy Keith package feeds to the publisher-neutral signed feed.
set -eu

target_root="${KEITHAH_ROOT:-/}"
feeds_file="$target_root/etc/opkg/customfeeds.conf"
keys_dir="$target_root/etc/opkg/keys"
feed_key_file="$keys_dir/f6c72c675c844b91"
feed_url='https://keithah.github.io/openwrt-packages'
feed_key='untrusted comment: Keith OpenWrt package feed
RWT2xyxnXIRLkZzbs1HvD+48GPkSqoNPCZVCOw49GUdTg2O7Cv9LzMtx'

fail() {
	printf 'keithah feed migration: %s\n' "$*" >&2
	exit 1
}

command -v opkg >/dev/null 2>&1 || fail 'opkg is required'
if ! architectures=$(opkg print-architecture); then
	fail 'could not determine package architectures'
fi
if ! printf '%s\n' "$architectures" |
	awk '$2 == "aarch64_cortex-a53" { found = 1 } END { exit !found }'; then
	fail 'this feed supports aarch64_cortex-a53 only'
fi

# Everything above this point is read-only: unsupported targets cannot acquire
# a key, a feed entry, or even a newly created configuration file.
[ -d "$target_root/etc/opkg" ] || fail "missing $target_root/etc/opkg"
[ -d "$keys_dir" ] || fail "missing $keys_dir"

feeds_dir=$(dirname "$feeds_file")
feeds_tmp=''
trim_tmp=''
key_tmp=''

cleanup() {
	[ -z "$feeds_tmp" ] || rm -f "$feeds_tmp" || :
	[ -z "$trim_tmp" ] || rm -f "$trim_tmp" || :
	[ -z "$key_tmp" ] || rm -f "$key_tmp" || :
}

handle_signal() {
	status=$1
	trap - 0 HUP INT TERM
	cleanup
	exit "$status"
}

trap 'cleanup' 0
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

feeds_tmp=$(mktemp "$feeds_dir/.customfeeds.conf.XXXXXX")
trim_tmp=$(mktemp "$feeds_dir/.customfeeds.conf.trim.XXXXXX")
key_tmp=$(mktemp "$keys_dir/.keithah-key.XXXXXX")

printf '%s\n' "$feed_key" >"$key_tmp"

# Put the neutral record first. This lets an unrelated, unterminated final
# record remain the final bytes of the file without joining the managed entry.
printf 'src/gz keithah %s\n' "$feed_url" >"$feeds_tmp"
if [ -f "$feeds_file" ]; then
	awk '$1 == "src/gz" && ($2 == "starwatch" || $2 == "wattline" || $2 == "keithah") { next } { print }' \
		"$feeds_file" >>"$feeds_tmp"

	# awk terminates emitted records. Remove only the newline it synthesizes
	# for an unrelated final record that was unterminated in the source.
	input_size=$(wc -c <"$feeds_file")
	trim_final_newline=no
	if [ "$input_size" -gt 0 ]; then
		dd if="$feeds_file" of="$trim_tmp" bs=1 skip=$((input_size - 1)) count=1 2>/dev/null
		last_byte_newlines=$(wc -l <"$trim_tmp")
		if [ "$last_byte_newlines" -eq 0 ] &&
			awk 'END { exit ($1 == "src/gz" && ($2 == "starwatch" || $2 == "wattline" || $2 == "keithah")) }' \
				"$feeds_file"; then
			trim_final_newline=yes
		fi
	fi
	if [ "$trim_final_newline" = yes ]; then
		output_size=$(wc -c <"$feeds_tmp")
		dd if="$feeds_tmp" of="$trim_tmp" bs=1 count=$((output_size - 1)) 2>/dev/null
		mv "$trim_tmp" "$feeds_tmp"
		trim_tmp=''
	fi
fi

preserve_metadata() {
	source_file=$1
	temporary_file=$2
	default_mode=$3
	if [ -e "$source_file" ]; then
		if metadata=$(stat -c '%a %u %g' "$source_file" 2>/dev/null); then
			set -- $metadata
			chmod "$1" "$temporary_file"
			chown "$2:$3" "$temporary_file" 2>/dev/null || fail "could not preserve ownership for $source_file"
		elif metadata=$(stat -f '%Lp %u %g' "$source_file" 2>/dev/null); then
			set -- $metadata
			chmod "$1" "$temporary_file"
			chown "$2:$3" "$temporary_file" 2>/dev/null || fail "could not preserve ownership for $source_file"
		else
			fail "could not read metadata for $source_file"
		fi
	else
		chmod "$default_mode" "$temporary_file"
	fi
}

preserve_metadata "$feeds_file" "$feeds_tmp" 0644
preserve_metadata "$feed_key_file" "$key_tmp" 0644

mv "$key_tmp" "$feed_key_file"
key_tmp=''
mv "$feeds_tmp" "$feeds_file"
feeds_tmp=''
rm -f "$trim_tmp"
trim_tmp=''
trap - 0 HUP INT TERM
