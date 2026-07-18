#!/bin/sh
set -eu

root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
script="$root/install.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' 0

make_case() {
	case_dir="$tmp/$1"
	mkdir -p "$case_dir/bin" "$case_dir/root/etc/opkg"
	printf '%s\n' "${2:-}" >"$case_dir/root/etc/opkg/customfeeds.conf"
	: >"$case_dir/log"
	cat >"$case_dir/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] && { printf '%s\n' "${MOCK_UID:-0}"; exit 0; }
exit 1
EOF
	cat >"$case_dir/bin/opkg" <<'EOF'
#!/bin/sh
printf 'opkg %s\n' "$*" >>"$MOCK_LOG"
if [ "$1" = print-architecture ]; then
		printf '%s\n' "${MOCK_ARCHES:-arch all 1}"
		[ "${MOCK_OPKG_ARCH_FAIL:-0}" = 1 ] && exit 1
	fi
[ "${MOCK_OPKG_UPDATE_FAIL:-0}" = 1 ] && [ "$1" = update ] && exit 1
exit 0
EOF
	cat >"$case_dir/bin/wget" <<'EOF'
#!/bin/sh
printf 'wget %s\n' "$*" >>"$MOCK_LOG"
EOF
	chmod +x "$case_dir/bin/id" "$case_dir/bin/opkg" "$case_dir/bin/wget"
}

run_case() {
	case_dir="$tmp/$1"
	shift
	env -i PATH="$case_dir/bin:$PATH" STARWATCH_ROOT="$case_dir/root" MOCK_LOG="$case_dir/log" \
		MOCK_UID=0 MOCK_ARCHES='arch all 1' MOCK_OPKG_UPDATE_FAIL=0 MOCK_OPKG_ARCH_FAIL=0 "$@" /bin/sh "$script"
}

run_without() {
	case_dir="$tmp/$1"
	missing="$2"
	rm "$case_dir/bin/$missing"
	env -i PATH="$case_dir/bin" STARWATCH_ROOT="$case_dir/root" MOCK_LOG="$case_dir/log" \
		MOCK_UID=0 MOCK_ARCHES='arch all 1' MOCK_OPKG_UPDATE_FAIL=0 MOCK_OPKG_ARCH_FAIL=0 /bin/sh "$script"
}

expect_fail() {
	if "$@" >/dev/null 2>&1; then
		echo "expected command to fail: $*" >&2
		exit 1
	fi
}

has_line() {
	awk -v wanted="$2" '$0 == wanted { found = 1 } END { exit !found }' "$1"
}

has_text() {
	awk -v wanted="$2" 'index($0, wanted) { found = 1 } END { exit !found }' "$1"
}

line_count() {
	awk -v wanted="$2" '$0 ~ wanted { count++ } END { print count + 0 }' "$1"
}

add_metadata_mocks() {
	case_dir="$tmp/$1"
	cat >"$case_dir/bin/stat" <<'EOF'
#!/bin/sh
if [ "$1" = -c ] && [ -n "${MOCK_STAT_METADATA:-}" ]; then
		printf '%s\n' "$MOCK_STAT_METADATA"
		exit 0
fi
exec /usr/bin/stat "$@"
EOF
	cat >"$case_dir/bin/chown" <<'EOF'
#!/bin/sh
printf 'chown %s\n' "$*" >>"$MOCK_LOG"
[ "${MOCK_CHOWN_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
	chmod +x "$case_dir/bin/stat" "$case_dir/bin/chown"
}

feed='https://keithah.github.io/openwrt-starwatch'
base_feeds='src/gz core https://downloads.example/core
src/gz extras https://downloads.example/extras'

make_case nonroot "$base_feeds"
expect_fail run_case nonroot MOCK_UID=1000 MOCK_ARCHES='arch aarch64_cortex-a53 10'
[ ! -s "$tmp/nonroot/log" ]
printf '%s\n' "$base_feeds" >"$tmp/expected-feeds"
cmp -s "$tmp/nonroot/root/etc/opkg/customfeeds.conf" "$tmp/expected-feeds"

make_case no_opkg "$base_feeds"
expect_fail run_without no_opkg opkg
[ ! -s "$tmp/no_opkg/log" ]

make_case isolated_opkg "$base_feeds"
if MOCK_UID=1000 run_without isolated_opkg opkg >"$tmp/isolated_opkg.err" 2>&1; then
	echo 'missing opkg unexpectedly succeeded' >&2
	exit 1
fi
has_text "$tmp/isolated_opkg.err" 'opkg is required'
[ ! -s "$tmp/isolated_opkg/log" ]

make_case no_wget "$base_feeds"
expect_fail run_without no_wget wget
[ ! -s "$tmp/no_wget/log" ]

make_case badarch "$base_feeds"
expect_fail run_case badarch MOCK_ARCHES='arch all 1'
has_line "$tmp/badarch/log" 'opkg print-architecture'
if has_text "$tmp/badarch/log" 'opkg update' || has_text "$tmp/badarch/log" 'opkg install'; then exit 1; fi
if has_text "$tmp/badarch/root/etc/opkg/customfeeds.conf" starwatch; then exit 1; fi

make_case arch_command_failed "$base_feeds"
expect_fail run_case arch_command_failed MOCK_ARCHES='arch aarch64_cortex-a53 10' MOCK_OPKG_ARCH_FAIL=1
has_line "$tmp/arch_command_failed/log" 'opkg print-architecture'
if has_text "$tmp/arch_command_failed/log" 'opkg update' || has_text "$tmp/arch_command_failed/log" 'opkg install'; then exit 1; fi
if has_text "$tmp/arch_command_failed/root/etc/opkg/customfeeds.conf" starwatch; then exit 1; fi

make_case glconfig "$base_feeds"
mkdir -p "$tmp/glconfig/root/etc/config"
: >"$tmp/glconfig/root/etc/config/glconfig"
run_case glconfig MOCK_ARCHES='arch aarch64_cortex-a53 10'
has_line "$tmp/glconfig/root/etc/opkg/customfeeds.conf" "src/gz starwatch $feed"
has_line "$tmp/glconfig/log" 'opkg install starwatchd gl-app-starwatch'

ouih_feeds='src/gz old https://old.example
src/gz starwatch https://old.feed
src/gz keep https://keep.example'
make_case ouih "$ouih_feeds"
mkdir -p "$tmp/ouih/root/usr/lib/oui-httpd"
run_case ouih MOCK_ARCHES='arch aarch64_cortex-a53 10'
[ "$(line_count "$tmp/ouih/root/etc/opkg/customfeeds.conf" '^src/gz starwatch ')" -eq 1 ]
has_line "$tmp/ouih/root/etc/opkg/customfeeds.conf" "src/gz starwatch $feed"
has_line "$tmp/ouih/root/etc/opkg/customfeeds.conf" 'src/gz old https://old.example'
has_line "$tmp/ouih/root/etc/opkg/customfeeds.conf" 'src/gz keep https://keep.example'
has_line "$tmp/ouih/log" 'opkg install starwatchd gl-app-starwatch'

make_case generic "$base_feeds"
chmod 0644 "$tmp/generic/root/etc/opkg/customfeeds.conf"
generic_arches='arch all 1
arch aarch64_cortex-a53 10'
run_case generic MOCK_ARCHES="$generic_arches"
has_line "$tmp/generic/log" 'opkg update'
has_line "$tmp/generic/log" 'opkg install starwatchd luci-app-starwatch'
if has_text "$tmp/generic/log" 'force-downgrade' || has_text "$tmp/generic/log" 'force-reinstall'; then exit 1; fi
[ "$(ls -ld "$tmp/generic/root/etc/opkg/customfeeds.conf" | awk '{ print $1 }')" = '-rw-r--r--' ]

# A second run must replace rather than append the managed feed.
run_case generic MOCK_ARCHES='arch aarch64_cortex-a53 10'
[ "$(line_count "$tmp/generic/root/etc/opkg/customfeeds.conf" '^src/gz starwatch ')" -eq 1 ]
has_line "$tmp/generic/root/etc/opkg/customfeeds.conf" 'src/gz core https://downloads.example/core'
has_line "$tmp/generic/root/etc/opkg/customfeeds.conf" 'src/gz extras https://downloads.example/extras'

make_case owner_preserved "$base_feeds"
add_metadata_mocks owner_preserved
run_case owner_preserved MOCK_ARCHES='arch aarch64_cortex-a53 10' MOCK_STAT_METADATA='644 123 456'
has_text "$tmp/owner_preserved/log" 'chown 123:456 '

make_case owner_restore_failed "$base_feeds"
add_metadata_mocks owner_restore_failed
printf '%s\n' "$base_feeds" >"$tmp/owner_restore_failed/original-feeds"
expect_fail run_case owner_restore_failed MOCK_ARCHES='arch aarch64_cortex-a53 10' MOCK_STAT_METADATA='644 123 456' MOCK_CHOWN_FAIL=1
has_text "$tmp/owner_restore_failed/log" 'chown 123:456 '
cmp -s "$tmp/owner_restore_failed/root/etc/opkg/customfeeds.conf" "$tmp/owner_restore_failed/original-feeds"
if has_text "$tmp/owner_restore_failed/log" 'opkg update' || has_text "$tmp/owner_restore_failed/log" 'opkg install'; then exit 1; fi

make_case updatefail "$base_feeds"
expect_fail run_case updatefail MOCK_ARCHES='arch aarch64_cortex-a53 10' MOCK_OPKG_UPDATE_FAIL=1
has_line "$tmp/updatefail/log" 'opkg update'
if has_text "$tmp/updatefail/log" 'opkg install '; then
	echo 'install proceeded after failed update' >&2
	exit 1
fi

echo 'installer tests passed'
