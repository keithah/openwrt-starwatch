#!/bin/sh
# Generate an opkg feed index (Packages + Packages.gz) for the .ipk files in
# the output dir. Portable across macOS (BSD) and Linux (GNU).
set -eu
OUT="${1:-out}"
cd "$OUT"

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
fsize()  { if stat -f%z "$1" >/dev/null 2>&1; then stat -f%z "$1"; else stat -c%s "$1"; fi; }

: > Packages
for ipk in *.ipk; do
	[ -f "$ipk" ] || continue
	ctrl="$(tar xzOf "$ipk" ./control.tar.gz 2>/dev/null | tar xzO ./control 2>/dev/null)"
	printf '%s\n' "$ctrl" | sed -e '/^[[:space:]]*$/d' >> Packages
	printf 'Filename: %s\n' "$ipk" >> Packages
	printf 'Size: %s\n' "$(fsize "$ipk")" >> Packages
	printf 'SHA256sum: %s\n' "$(sha256 "$ipk")" >> Packages
	printf '\n' >> Packages
done

gzip -9 -c Packages > Packages.gz

SIGN_KEY="${SIGN_KEY:-}"
USIGN="${USIGN:-usign}"
rm -f Packages.sig
if [ -n "$SIGN_KEY" ]; then
	command -v "$USIGN" >/dev/null 2>&1 || {
		echo "usign not found: $USIGN" >&2
		exit 1
	}
	"$USIGN" -S -m Packages -s "$SIGN_KEY" -x Packages.sig
fi

echo "wrote $OUT/Packages and $OUT/Packages.gz ($(grep -c '^Package:' Packages) packages)"
