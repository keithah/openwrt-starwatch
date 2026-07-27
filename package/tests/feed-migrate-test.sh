#!/bin/sh
set -eu

package_root="$(CDPATH= cd "$(dirname "$0")/.." && pwd)"
script="$package_root/starwatch-feed-migrate.sh"
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
}

run_case() {
	case_dir="$tmp/$1"
	shift
	env -i PATH="$case_dir/bin:$PATH" KEITHAH_ROOT="$case_dir/root" \
		/bin/sh "$script" "$@"
}

expect_fail() {
	if "$@" >/dev/null 2>&1; then
		fail "expected command to fail: $*"
	fi
}

# A failure replacing the second destination must roll back both files.
make_case atomicity
printf 'old feed\n' >"$tmp/atomicity/root/etc/opkg/customfeeds.conf"
printf 'old key\n' >"$tmp/atomicity/root/etc/opkg/keys/f6c72c675c844b91"
chmod 0640 "$tmp/atomicity/root/etc/opkg/customfeeds.conf"
chmod 0600 "$tmp/atomicity/root/etc/opkg/keys/f6c72c675c844b91"
cp -p "$tmp/atomicity/root/etc/opkg/customfeeds.conf" "$tmp/atomicity/feed.before"
cp -p "$tmp/atomicity/root/etc/opkg/keys/f6c72c675c844b91" "$tmp/atomicity/key.before"
cat >"$tmp/atomicity/bin/mv" <<'EOF'
#!/bin/sh
case "$1" in
  *.customfeeds.conf.*) case "$2" in */customfeeds.conf) exit 73 ;; esac ;;
esac
exec /bin/mv "$@"
EOF
chmod +x "$tmp/atomicity/bin/mv"
expect_fail run_case atomicity
cmp "$tmp/atomicity/feed.before" "$tmp/atomicity/root/etc/opkg/customfeeds.conf" || fail 'feed replacement failure changed feed'
cmp "$tmp/atomicity/key.before" "$tmp/atomicity/root/etc/opkg/keys/f6c72c675c844b91" || fail 'feed replacement failure changed key'
[ "$(stat -c %a "$tmp/atomicity/root/etc/opkg/customfeeds.conf")" = 640 ] || fail 'feed metadata changed on rollback'
[ "$(stat -c %a "$tmp/atomicity/root/etc/opkg/keys/f6c72c675c844b91")" = 600 ] || fail 'key metadata changed on rollback'

make_case backup_atomicity
printf 'old feed\n' >"$tmp/backup_atomicity/root/etc/opkg/customfeeds.conf"
printf 'old key\n' >"$tmp/backup_atomicity/root/etc/opkg/keys/f6c72c675c844b91"
cp -p "$tmp/backup_atomicity/root/etc/opkg/customfeeds.conf" "$tmp/backup_atomicity/feed.before"
cp -p "$tmp/backup_atomicity/root/etc/opkg/keys/f6c72c675c844b91" "$tmp/backup_atomicity/key.before"
cat >"$tmp/backup_atomicity/bin/mv" <<'EOF'
#!/bin/sh
case "$1:$2" in *f6c72c675c844b91:*backup.*) exit 74 ;; esac
exec /bin/mv "$@"
EOF
chmod +x "$tmp/backup_atomicity/bin/mv"
expect_fail run_case backup_atomicity
cmp "$tmp/backup_atomicity/feed.before" "$tmp/backup_atomicity/root/etc/opkg/customfeeds.conf" || fail 'second backup failure changed feed'
cmp "$tmp/backup_atomicity/key.before" "$tmp/backup_atomicity/root/etc/opkg/keys/f6c72c675c844b91" || fail 'second backup failure changed key'

# Missing and unsupported architecture arguments must be rejected before either
# managed file is touched.
make_case unsupported
printf 'src/gz core https://downloads.example/core' >"$tmp/unsupported/root/etc/opkg/customfeeds.conf"
printf 'existing key without newline' >"$tmp/unsupported/root/etc/opkg/keys/f6c72c675c844b91"
cp -p "$tmp/unsupported/root/etc/opkg/customfeeds.conf" "$tmp/unsupported/feeds.before"
cp -p "$tmp/unsupported/root/etc/opkg/keys/f6c72c675c844b91" "$tmp/unsupported/key.before"
expect_fail run_case unsupported
cmp -s "$tmp/unsupported/feeds.before" "$tmp/unsupported/root/etc/opkg/customfeeds.conf" || fail 'missing architecture changed feeds'
cmp -s "$tmp/unsupported/key.before" "$tmp/unsupported/root/etc/opkg/keys/f6c72c675c844b91" || fail 'missing architecture changed key'
expect_fail run_case unsupported all
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
run_case migrate aarch64_cortex-a53
printf 'src/gz keithah https://keithah.github.io/openwrt-packages\nsrc/gz old https://old.example\n  # keep spacing  \nsrc/gz tail https://tail.example' >"$tmp/migrate/expected-feeds"
cmp -s "$tmp/migrate/expected-feeds" "$tmp/migrate/root/etc/opkg/customfeeds.conf" || fail 'feed migration did not preserve unrelated bytes'
cmp -s "$public_key" "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91" || fail 'publisher key was not replaced exactly'
[ "$(stat -c %a "$tmp/migrate/root/etc/opkg/customfeeds.conf")" = 640 ] || fail 'feed mode changed'
[ "$(stat -c %a "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91")" = 600 ] || fail 'key mode changed'
[ "$(stat -c '%u:%g' "$tmp/migrate/root/etc/opkg/customfeeds.conf")" = "$feeds_owner_before" ] || fail 'feed ownership changed'
[ "$(stat -c '%u:%g' "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91")" = "$key_owner_before" ] || fail 'key ownership changed'

# BusyBox builds without a stat(1) applet (observed on GL-X3000, BusyBox
# v1.33.2) must fall back to parsing `ls -ln` to preserve mode and ownership.
make_case no_stat
printf 'src/gz keithah https://legacy.keithah\n' >"$tmp/no_stat/root/etc/opkg/customfeeds.conf"
chmod 0640 "$tmp/no_stat/root/etc/opkg/customfeeds.conf"
printf 'obsolete key\n' >"$tmp/no_stat/root/etc/opkg/keys/f6c72c675c844b91"
chmod 0600 "$tmp/no_stat/root/etc/opkg/keys/f6c72c675c844b91"
cat >"$tmp/no_stat/bin/stat" <<'EOF'
#!/bin/sh
echo "stat: not found" >&2
exit 127
EOF
chmod +x "$tmp/no_stat/bin/stat"
run_case no_stat aarch64_cortex-a53
[ "$(stat -c %a "$tmp/no_stat/root/etc/opkg/customfeeds.conf")" = 640 ] || fail 'no-stat fallback lost feed mode'
[ "$(stat -c %a "$tmp/no_stat/root/etc/opkg/keys/f6c72c675c844b91")" = 600 ] || fail 'no-stat fallback lost key mode'
[ "$(stat -c '%u:%g' "$tmp/no_stat/root/etc/opkg/customfeeds.conf")" = "$(id -u):$(id -g)" ] || fail 'no-stat fallback changed feed ownership'
cmp -s "$public_key" "$tmp/no_stat/root/etc/opkg/keys/f6c72c675c844b91" || fail 'no-stat fallback did not replace publisher key'

# Re-running is a byte-for-byte no-op.
cp -p "$tmp/migrate/root/etc/opkg/customfeeds.conf" "$tmp/migrate/feeds.once"
cp -p "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91" "$tmp/migrate/key.once"
run_case migrate aarch64_cortex-a53
cmp -s "$tmp/migrate/feeds.once" "$tmp/migrate/root/etc/opkg/customfeeds.conf" || fail 'second migration changed feeds'
cmp -s "$tmp/migrate/key.once" "$tmp/migrate/root/etc/opkg/keys/f6c72c675c844b91" || fail 'second migration changed key'

# A removed managed record at EOF must not cause the retained predecessor to
# lose its terminating newline.
make_case managed_eof
printf 'src/gz core https://downloads.example/core\nsrc/gz starwatch https://legacy.starwatch' >"$tmp/managed_eof/root/etc/opkg/customfeeds.conf"
run_case managed_eof aarch64_cortex-a53
printf 'src/gz keithah https://keithah.github.io/openwrt-packages\nsrc/gz core https://downloads.example/core\n' >"$tmp/managed_eof/expected-feeds"
cmp -s "$tmp/managed_eof/expected-feeds" "$tmp/managed_eof/root/etc/opkg/customfeeds.conf" || fail 'managed EOF record damaged retained newline'

# The package owns the installed helper, and postinst runs it only for a live
# root before Starwatch service initialization.
grep -F 'starwatch-feed-migrate.sh $(OUT)/stage/usr/libexec/starwatch-feed-migrate' "$makefile" >/dev/null || fail 'Makefile does not stage migration helper'
grep -F 'chmod 0755 $(OUT)/stage/usr/libexec/starwatch-feed-migrate' "$makefile" >/dev/null || fail 'Makefile does not make migration helper executable'
grep -F '/usr/libexec/starwatch-feed-migrate aarch64_cortex-a53' "$postinst" >/dev/null || fail 'postinst does not pass the package architecture'
if grep -F '/usr/libexec/keithah-feed-migrate' "$postinst" >/dev/null; then
	fail 'postinst retains legacy migration helper path'
fi
awk '
	/\[ -n "\$IPKG_INSTROOT" \] && exit 0/ { guard = NR }
	/\/usr\/libexec\/starwatch-feed-migrate aarch64_cortex-a53/ { migrate = NR }
	/\/etc\/uci-defaults\/99-starwatch/ { initialize = NR }
	END { exit !(guard && migrate > guard && initialize > migrate) }
' "$postinst" || fail 'postinst migration contract is missing or out of order'

# Execute the real postinst control flow with only its absolute command paths
# redirected into a harmless harness. A migration failure must be returned to
# opkg and must prevent every initialization command from running.
mkdir -p "$tmp/postinst-bin"
cat >"$tmp/postinst-bin/migrate" <<EOF
#!/bin/sh
printf 'migrate %s\n' "\$*" >>"$tmp/postinst.log"
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
	-e "s|/usr/libexec/starwatch-feed-migrate|$tmp/postinst-bin/migrate|" \
	-e "s|/etc/uci-defaults/99-starwatch|$tmp/postinst-bin/uci-defaults|" \
	-e "s|/etc/init.d/starwatch|$tmp/postinst-bin/service|" \
	"$postinst" >"$tmp/postinst"
chmod +x "$tmp/postinst"
: >"$tmp/postinst.log"
if IPKG_INSTROOT= /bin/sh "$tmp/postinst"; then
	fail 'postinst ignored a feed migration failure'
fi
printf '%s\n' 'migrate aarch64_cortex-a53' >"$tmp/expected-postinst.log"
cmp -s "$tmp/expected-postinst.log" "$tmp/postinst.log" || fail 'postinst initialized Starwatch after migration failure'

printf '%s\n' 'feed migration tests passed'
