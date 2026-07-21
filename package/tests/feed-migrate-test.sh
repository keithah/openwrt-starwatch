#!/bin/sh
set -eu

package_root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
script="$package_root/keithah-feed-migrate.sh"
postinst="$package_root/starwatchd/CONTROL/postinst"
makefile="$package_root/Makefile"
public_key="$package_root/starwatch-feed.pub"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' 0 HUP INT TERM

fail() {
	printf 'feed migration test: %s\n' "$*" >&2
	exit 1
}

make_case() {
	case_dir="$tmp/$1"
	mkdir -p "$case_dir/bin" "$case_dir/root/etc/opkg/keys"
	: >"$case_dir/root/etc/opkg/customfeeds.conf"
	cat >"$case_dir/bin/opkg" <<'EOF'
#!/bin/sh
[ "$1" = print-architecture ] || exit 1
printf '%s\n' "${MOCK_ARCHES:-arch all 1}"
[ "${MOCK_ARCH_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
	chmod +x "$case_dir/bin/opkg"
}

run_case() {
	case_dir="$tmp/$1"
	shift
	env -i PATH="$case_dir/bin:$PATH" KEITHAH_ROOT="$case_dir/root" \
		MOCK_ARCHES='arch aarch64_cortex-a53 10' MOCK_ARCH_FAIL=0 "$@" \
		/bin/sh "$script"
}

expect_fail() {
	if "$@" >/dev/null 2>&1; then
		fail "expected command to fail: $*"
	fi
}

# Unsupported targets must be rejected before either managed file is touched.
make_case unsupported
printf 'src/gz core https://downloads.example/core' >"$tmp/unsupported/root/etc/opkg/customfeeds.conf"
printf 'existing key without newline' >"$tmp/unsupported/root/etc/opkg/keys/f6c72c675c844b91"
cp -p "$tmp/unsupported/root/etc/opkg/customfeeds.conf" "$tmp/unsupported/feeds.before"
cp -p "$tmp/unsupported/root/etc/opkg/keys/f6c72c675c844b91" "$tmp/unsupported/key.before"
expect_fail run_case unsupported MOCK_ARCHES='arch all 1'
cmp -s "$tmp/unsupported/feeds.before" "$tmp/unsupported/root/etc/opkg/customfeeds.conf" || fail 'unsupported architecture changed feeds'
cmp -s "$tmp/unsupported/key.before" "$tmp/unsupported/root/etc/opkg/keys/f6c72c675c844b91" || fail 'unsupported architecture changed key'

# Collapse every managed alias, preserve unrelated records byte-for-byte, and
# retain an unrelated missing final newline.
make_case migrate
printf 'src/gz old https://old.example\n  # keep spacing  \nsrc/gz starwatch https://legacy.starwatch\nsrc/gz wattline https://legacy.wattline\nsrc/gz keithah https://legacy.keithah\nsrc/gz tail https://tail.example' >"$tmp/migrate/root/etc/opkg/customfeeds.conf"
chmod 0640 "$tmp/migrate/root/etc/opkg/customfeeds.conf"
printf 'obsolete key\n' >"$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91"
chmod 0600 "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91"
feeds_owner_before=$(stat -c '%u:%g' "$tmp/migrate/root/etc/opkg/customfeeds.conf")
key_owner_before=$(stat -c '%u:%g' "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91")
run_case migrate
printf 'src/gz keithah https://keithah.github.io/openwrt-packages\nsrc/gz old https://old.example\n  # keep spacing  \nsrc/gz tail https://tail.example' >"$tmp/migrate/expected-feeds"
cmp -s "$tmp/migrate/expected-feeds" "$tmp/migrate/root/etc/opkg/customfeeds.conf" || fail 'feed migration did not preserve unrelated bytes'
cmp -s "$public_key" "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91" || fail 'publisher key was not replaced exactly'
[ "$(stat -c %a "$tmp/migrate/root/etc/opkg/customfeeds.conf")" = 640 ] || fail 'feed mode changed'
[ "$(stat -c %a "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91")" = 600 ] || fail 'key mode changed'
[ "$(stat -c '%u:%g' "$tmp/migrate/root/etc/opkg/customfeeds.conf")" = "$feeds_owner_before" ] || fail 'feed ownership changed'
[ "$(stat -c '%u:%g' "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91")" = "$key_owner_before" ] || fail 'key ownership changed'

# Re-running is a byte-for-byte no-op.
cp -p "$tmp/migrate/root/etc/opkg/customfeeds.conf" "$tmp/migrate/feeds.once"
cp -p "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91" "$tmp/migrate/key.once"
run_case migrate
cmp -s "$tmp/migrate/feeds.once" "$tmp/migrate/root/etc/opkg/customfeeds.conf" || fail 'second migration changed feeds'
cmp -s "$tmp/migrate/key.once" "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91" || fail 'second migration changed key'

# A removed managed record at EOF must not cause the retained predecessor to
# lose its terminating newline.
make_case managed_eof
printf 'src/gz core https://downloads.example/core\nsrc/gz starwatch https://legacy.starwatch' >"$tmp/managed_eof/root/etc/opkg/customfeeds.conf"
run_case managed_eof
printf 'src/gz keithah https://keithah.github.io/openwrt-packages\nsrc/gz core https://downloads.example/core\n' >"$tmp/managed_eof/expected-feeds"
cmp -s "$tmp/managed_eof/expected-feeds" "$tmp/managed_eof/root/etc/opkg/customfeeds.conf" || fail 'managed EOF record damaged retained newline'

# The package owns the installed helper, and postinst runs it only for a live
# root before Starwatch service initialization.
grep -F 'cp keithah-feed-migrate.sh $(OUT)/stage/usr/libexec/keithah-feed-migrate' "$makefile" >/dev/null || fail 'Makefile does not stage migration helper'
grep -F 'chmod 0755 $(OUT)/stage/usr/libexec/keithah-feed-migrate' "$makefile" >/dev/null || fail 'Makefile does not make migration helper executable'
awk '
	/\[ -n "\$IPKG_INSTROOT" \] && exit 0/ { guard = NR }
	/\/usr\/libexec\/keithah-feed-migrate/ { migrate = NR }
	/\/etc\/uci-defaults\/99-starwatch/ { initialize = NR }
	END { exit !(guard && migrate > guard && initialize > migrate) }
' "$postinst" || fail 'postinst migration contract is missing or out of order'

# Execute the real postinst control flow with only its absolute command paths
# redirected into a harmless harness. A migration failure must be returned to
# opkg and must prevent every initialization command from running.
mkdir -p "$tmp/postinst-bin"
cat >"$tmp/postinst-bin/migrate" <<EOF
#!/bin/sh
printf '%s\n' migrate >>"$tmp/postinst.log"
exit 23
EOF
for command in uci-defaults service; do
	cat >"$tmp/postinst-bin/$command" <<EOF
#!/bin/sh
printf '%s\n' "$command \$*" >>"$tmp/postinst.log"
exit 0
EOF
done
chmod +x "$tmp/postinst-bin/migrate" "$tmp/postinst-bin/uci-defaults" "$tmp/postinst-bin/service"
sed \
	-e "s|/usr/libexec/keithah-feed-migrate|$tmp/postinst-bin/migrate|" \
	-e "s|/etc/uci-defaults/99-starwatch|$tmp/postinst-bin/uci-defaults|" \
	-e "s|/etc/init.d/starwatch|$tmp/postinst-bin/service|" \
	"$postinst" >"$tmp/postinst"
chmod +x "$tmp/postinst"
: >"$tmp/postinst.log"
if IPKG_INSTROOT= /bin/sh "$tmp/postinst"; then
	fail 'postinst ignored a feed migration failure'
fi
printf '%s\n' migrate >"$tmp/expected-postinst.log"
cmp -s "$tmp/expected-postinst.log" "$tmp/postinst.log" || fail 'postinst initialized Starwatch after migration failure'

printf '%s\n' 'feed migration tests passed'
