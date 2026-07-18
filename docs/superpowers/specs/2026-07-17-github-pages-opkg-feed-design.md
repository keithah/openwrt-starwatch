# GitHub Pages opkg Feed and Bootstrap Installer

## Goal

Let a supported Starwatch router install and later upgrade through one
copy-and-paste command, while using normal `opkg` feed semantics after the
initial install.

The target reader is an OpenWrt or GL.iNet administrator. After following the
README command over SSH, they can open the appropriate local Starwatch entry
and later run `opkg upgrade` without manually copying IPKs.

## Supported scope

The first feed supports only the verified `aarch64_cortex-a53` architecture.
The installer must inspect `opkg print-architecture` rather than `uname -m`;
unsupported routers fail before changing feeds or packages. Additional
architectures are a later extension.

The installer detects GL.iNet SDK4 through `/etc/config/glconfig` or
`/usr/lib/oui-httpd`. GL.iNet gets `starwatchd` and `gl-app-starwatch`.
Other supported OpenWrt routers get `starwatchd` and `luci-app-starwatch`.

## User flow

The README presents one command:

```sh
wget -qO- https://keithah.github.io/openwrt-starwatch/install.sh | sh
```

The script requires root, `opkg`, `wget`, and the supported architecture. It
writes exactly one managed feed file,
`/etc/opkg/customfeeds.conf.d/starwatch.conf`, containing the GitHub Pages
feed URL. It then runs `opkg update` and installs or upgrades the daemon plus
the detected UI package. It ends by reporting the local dashboard URL and the
selected UI.

Re-running the script is safe: it rewrites only its own feed file, refreshes
the index, and asks `opkg` to install the same package set. It never uses
force-downgrade or force-reinstall, modifies other feeds, overwrites the
Starwatch UCI configuration, or changes routing/firewall state.

## Publishing model

GitHub Actions builds the release IPKs, runs the existing feed-index generator,
and publishes a Pages artifact containing:

- `Packages` and `Packages.gz`
- the three release IPKs
- `install.sh`

The Pages deployment is tied to an explicit version tag. The bootstrap script
is also published from Pages so it and the feed are released together. A tag
must not publish until the Go tests, vet, Linux ARM64 build, package build, and
feed-index validation succeed.

## Installer behavior and failures

The installer uses `set -eu`, creates its feed directory when OpenWrt has not
created it, downloads through HTTPS, and stops on any failed command. It
prints actionable errors for non-root use, missing prerequisites, unsupported
architecture, feed refresh failure, and package install failure. It does not
attempt to infer a fallback architecture or UI package after an error.

`opkg` remains responsible for conffile preservation and normal version
ordering. Administrators who deliberately need a downgrade use a separate,
documented manual recovery command rather than the bootstrap script.

## Verification

- Shell tests exercise architecture rejection, GL.iNet detection, generic
  OpenWrt selection, idempotent feed-file replacement, and failure before any
  package action.
- A package/feed test confirms `Packages.gz` references each published IPK and
  that the Pages artifact contains the installer.
- A GitHub Actions workflow test builds the artifact without publishing on
  pull requests; tag pushes publish the Pages feed.
- README instructions are checked against the installer URL and package names.
