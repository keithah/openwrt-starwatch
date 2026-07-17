#!/bin/sh
set -eu

root="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
script="$root/starwatchd/etc/uci-defaults/99-starwatch"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

cat >"$tmp/bin/ubus" <<'EOF'
#!/bin/sh
printf '%s\n' '{}'
EOF
cat >"$tmp/bin/jsonfilter" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
	if [ "$1" = "-e" ]; then expr="$2"; shift 2; else shift; fi
done
case "$expr" in
	'@.device') printf '%s\n' "${WAN_DEVICE:-}" ;;
	'@.l3_device') printf '%s\n' "${WAN_L3_DEVICE:-}" ;;
	*'ipv4-address'*'.address') printf '%s\n' "${WAN_ADDRESS:-}" ;;
	*'ipv4-address'*'.mask') printf '%s\n' "${WAN_MASK:-}" ;;
	*route*nexthop*) printf '%s\n' "${WAN_GATEWAYS:-}" ;;
esac
EOF
cat >"$tmp/bin/ip" <<'EOF'
#!/bin/sh
case "$*" in
	"-4 route show table all") printf '%s\n' "${KERNEL_ROUTES:-}" ;;
	"-4 route get 192.168.1.1") printf '%s\n' "${STARLINK_ROUTE_GET:-}" ;;
	*) exit 1 ;;
esac
EOF
cat >"$tmp/bin/uci" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "-q" ]; then shift; fi
case "${1:-} ${2:-}" in
	"get starwatch.main.token") printf '%s\n' token ;;
	"get network.starwatch_dish") exit 1 ;;
	"show network") printf '%s\n' "${UCI_NETWORK:-}" ;;
	"batch ") cat >>"$UCI_LOG" ;;
	"set "*|"delete "*|"commit "*) printf '%s\n' "$*" >>"$UCI_LOG" ;;
esac
EOF
chmod +x "$tmp/bin/ubus" "$tmp/bin/jsonfilter" "$tmp/bin/ip" "$tmp/bin/uci"

run_case() {
	name="$1"
	shift
	log="$tmp/$name.log"
	: >"$log"
	env PATH="$tmp/bin:$PATH" UCI_LOG="$log" "$@" sh "$script"
	printf '%s\n' "$log"
}

speedify_log="$(run_case speedify \
	WAN_DEVICE=eth0 WAN_ADDRESS=192.168.1.49 WAN_MASK=24 WAN_GATEWAYS=192.0.0.1 \
	STARLINK_ROUTE_GET='192.168.1.1 dev eth0 src 192.168.1.49')"
grep -q "set network.starwatch_dish.gateway=192.168.1.1" "$speedify_log"
if grep -q '192.0.0.1' "$speedify_log"; then
	echo "Speedify tunnel gateway leaked into dish route" >&2
	exit 1
fi

configured_log="$(run_case configured \
	WAN_DEVICE=eth0 WAN_ADDRESS=192.168.1.49 WAN_MASK=24 WAN_GATEWAYS=192.168.1.254 \
	STARLINK_ROUTE_GET='192.168.1.1 dev eth0')"
grep -q "set network.starwatch_dish.gateway=192.168.1.254" "$configured_log"

link_log="$(run_case link \
	WAN_DEVICE=eth0 WAN_ADDRESS=100.64.1.2 WAN_MASK=24 WAN_GATEWAYS= \
	STARLINK_ROUTE_GET='192.168.1.1 via 100.64.1.1 dev eth0')"
if grep -q 'gateway' "$link_log"; then
	echo "gateway unexpectedly added for direct-DHCP WAN" >&2
	exit 1
fi
grep -q "set network.starwatch_dish.target='192.168.100.1/32'" "$link_log"

covered_log="$(run_case covered \
	WAN_DEVICE=eth0 WAN_ADDRESS=192.168.1.49 WAN_MASK=24 WAN_GATEWAYS=192.168.1.1 \
	"UCI_NETWORK=network.existing.target='192.168.100.1/32'")"
if [ -s "$covered_log" ]; then
	echo "existing route was modified" >&2
	exit 1
fi

covering_log="$(run_case covering \
	WAN_DEVICE=eth0 WAN_ADDRESS=192.168.1.49 WAN_MASK=24 WAN_GATEWAYS=192.168.1.1 \
	"UCI_NETWORK=network.user_route.target='192.168.100.0/24'")"
if [ -s "$covering_log" ]; then
	echo "covering UCI route was modified" >&2
	exit 1
fi

echo "uci-defaults dish route tests passed"
