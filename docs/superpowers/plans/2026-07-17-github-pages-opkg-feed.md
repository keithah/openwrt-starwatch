# GitHub Pages opkg Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a supported OpenWrt router install Starwatch and the appropriate admin-panel package with one HTTPS command, then upgrade from a GitHub Pages opkg feed.

**Architecture:** A POSIX shell bootstrap validates its environment before making changes, detects GL.iNet SDK4 by existing platform markers, and maintains one `src/gz starwatch` entry in OpenWrt's standard custom-feeds file. The existing package build creates the IPKs and index; a new staging target assembles exactly the static Pages artifact. GitHub Actions verifies all artifacts on pull requests and deploys the artifact only for version tags.

**Tech Stack:** POSIX `sh`, GNU/BSD-compatible `make`, OpenWrt `opkg`, GitHub Actions/Pages, existing Go daemon/package pipeline.

---

### Task 1: Test the bootstrap installer before adding it

**Files:**
- Create: `package/tests/install-test.sh`
- Create: `package/install.sh`

- [ ] **Step 1: Write fake-command shell tests for the installer.**
  - Create a temporary fake root with mocked `id`, `opkg`, `wget`, and filesystem paths.
  - Test root and prerequisite rejection before `opkg update` or `opkg install`.
  - Test `opkg print-architecture` accepts `aarch64_cortex-a53` and rejects another architecture without changing the feed file or invoking package actions.
  - Test GL detection through each supported marker (`/etc/config/glconfig` and `/usr/lib/oui-httpd`) selects exactly `starwatchd gl-app-starwatch`.
  - Test generic OpenWrt selects exactly `starwatchd luci-app-starwatch`.
  - Start with unrelated lines plus an obsolete `src/gz starwatch ...` line in a fake `customfeeds.conf`; assert rerunning leaves unrelated lines byte-for-byte intact and leaves exactly one updated Starwatch line.
  - Assert no forced opkg flags are present and failed `opkg update` prevents `opkg install`.

- [ ] **Step 2: Run the installer test and confirm it fails because the installer does not yet exist.**
  - Run: `cd package && sh tests/install-test.sh`
  - Expected: failure referencing missing `package/install.sh` or the missing implementation behavior.

- [ ] **Step 3: Implement the POSIX bootstrap installer.**
  - Add `package/install.sh` with `set -eu`.
  - Define the stable feed URL once: `https://keithah.github.io/openwrt-starwatch`.
  - Require root, `opkg`, `wget`, and the `aarch64_cortex-a53` entry from `opkg print-architecture` before writing the feed or asking opkg to act.
  - Detect GL SDK4 from `/etc/config/glconfig` or `/usr/lib/oui-httpd`; select `gl-app-starwatch` for GL and `luci-app-starwatch` otherwise.
  - Update only `src/gz starwatch ...` in `/etc/opkg/customfeeds.conf`: preserve all other lines, atomically replace the file, and ensure exactly one Starwatch feed entry. Do not use an unsupported `customfeeds.conf.d` directory.
  - Run `opkg update`, then `opkg install starwatchd "$ui_package"`; do not use `--force-downgrade`, `--force-reinstall`, or any routing/configuration mutation.
  - Print the selected panel package and dashboard URL only after success.

- [ ] **Step 4: Make the installer test pass.**
  - Run: `cd package && sh tests/install-test.sh`
  - Expected: all rejection, selection, idempotence, and no-force assertions pass.

- [ ] **Step 5: Commit the tested installer.**
  - Run: `git add package/install.sh package/tests/install-test.sh && git commit -m "feat: add opkg feed bootstrap installer"`

### Task 2: Stage a complete GitHub Pages feed artifact

**Files:**
- Modify: `package/Makefile`
- Create: `package/tests/feed-artifact-test.sh`

- [ ] **Step 1: Write an artifact-integrity test.**
  - Build into a caller-provided temporary output directory rather than relying on checked-in artifacts.
  - Assert the Pages staging directory contains `Packages`, `Packages.gz`, `install.sh`, and all three built IPKs.
  - Decompress `Packages.gz` and assert it matches `Packages`; assert each `Filename:` referenced by the index names a staged IPK.
  - Assert the staged installer is identical to `package/install.sh`.

- [ ] **Step 2: Run the artifact test and confirm it fails before the staging target exists.**
  - Run: `cd package && sh tests/feed-artifact-test.sh`
  - Expected: failure because `make feed-artifact` has not yet created a Pages directory.

- [ ] **Step 3: Add an explicit Pages-artifact Make target.**
  - Add a `feed-artifact` target in `package/Makefile` that depends on the existing `feed` target, recreates `out/pages`, and copies only `Packages`, `Packages.gz`, the three `.ipk` files, and `install.sh` into it.
  - Add `feed-artifact` to `.PHONY`.
  - Extend the regular `test` target to run both shell test suites, keeping the existing VPN-proof UCI-defaults test.
  - Keep `out/` ignored; do not commit package binaries or feed indexes.

- [ ] **Step 4: Verify the artifact test and package tests.**
  - Run: `cd package && make clean && make test feed-artifact`
  - Expected: shell tests pass and `out/pages/` contains a self-contained opkg feed.

- [ ] **Step 5: Commit the Pages staging support.**
  - Run: `git add package/Makefile package/tests/feed-artifact-test.sh && git commit -m "build: stage opkg feed artifact for pages"`

### Task 3: Publish validated version-tag artifacts to GitHub Pages

**Files:**
- Create: `.github/workflows/pages-feed.yml`

- [ ] **Step 1: Add the GitHub Actions workflow.**
  - Trigger verification on pull requests, pushes to `main`, version tags matching `v*`, and manual dispatch.
  - Use a pinned current Go setup action and repository checkout action.
  - Run the required router verification verbatim: `go test -race ./...`, `go vet ./...`, and `CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...` from `router/`.
  - Run `make -C package test feed-artifact` after the Go checks.
  - Upload `package/out/pages` as a Pages artifact only for a version-tag ref. Deploy that artifact only after verification succeeds, with minimal `pages: write` and `id-token: write` permissions and the GitHub Pages environment URL exported by the deploy action.
  - Ensure pull requests and ordinary `main` pushes never publish a feed.

- [ ] **Step 2: Validate the workflow locally where possible.**
  - Run: `git diff --check`
  - Run: `cd router && go test -race ./... && go vet ./... && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`
  - Run: `make -C package clean test feed-artifact`
  - Inspect: `find package/out/pages -maxdepth 1 -type f -printf '%f\n' | sort`

- [ ] **Step 3: Commit the publishing workflow.**
  - Run: `git add .github/workflows/pages-feed.yml && git commit -m "ci: publish tagged opkg feed to github pages"`

### Task 4: Replace manual-feed documentation with the public install flow

**Files:**
- Modify: `README.md`
- Modify: `docs/superpowers/specs/2026-07-17-github-pages-opkg-feed-design.md`

- [ ] **Step 1: Update the README installation section.**
  - Add the exact one-line command: `wget -qO- https://keithah.github.io/openwrt-starwatch/install.sh | sh`.
  - State the first-release architecture limit (`aarch64_cortex-a53`) and that the installer stops safely on another architecture.
  - Explain automatic GL SDK4 versus generic LuCI selection and retain the existing GL 4.x `luci-theme-bootstrap` note.
  - Replace the placeholder self-hosted feed instructions with the Pages URL and normal `opkg update && opkg upgrade starwatchd <selected-ui-package>` instructions.
  - State that the installer preserves other custom feeds and does not force downgrades or overwrite Starwatch configuration.

- [ ] **Step 2: Align the design record with the deployed behavior.**
  - Keep the correction that the installer manages a marked entry in `/etc/opkg/customfeeds.conf`, not a nonexistent `conf.d` loader.

- [ ] **Step 3: Verify documentation references.**
  - Run: `rg -n 'your-host|customfeeds\.conf\.d|install\.sh|aarch64_cortex-a53|gl-app-starwatch|luci-app-starwatch' README.md docs/superpowers/specs/2026-07-17-github-pages-opkg-feed-design.md package/install.sh`
  - Expected: no obsolete self-hosted example or `customfeeds.conf.d` reference remains.

- [ ] **Step 4: Commit documentation.**
  - Run: `git add README.md docs/superpowers/specs/2026-07-17-github-pages-opkg-feed-design.md && git commit -m "docs: document github pages opkg installation"`

### Task 5: Final verification and publish

**Files:**
- Verify: all files above

- [ ] **Step 1: Run the complete release-quality checks from a clean package output.**
  - Run: `git status --short`
  - Run: `cd router && go test -race ./... && go vet ./... && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build ./...`
  - Run: `make -C package clean test feed-artifact`
  - Run: `gzip -dc package/out/pages/Packages.gz | cmp package/out/pages/Packages -`
  - Run: `git diff --check && git status --short`
  - Expected: checks pass; only ignored `package/out/` exists after build.

- [ ] **Step 2: Review the final commits and push.**
  - Run: `git log --oneline origin/main..HEAD`
  - Run: `git push origin main`
  - Confirm the version-tag workflow after tagging is the only path that deploys Pages; do not manually copy package artifacts into the repository.
