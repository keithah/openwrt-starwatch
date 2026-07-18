# Builds Starwatch .ipk files without the full OpenWrt SDK.
# Requires: go (host), tar, gzip. Output in ./out.
#
# An OpenWrt .ipk is a GZIPPED TAR (not an ar/.deb archive) wrapping
# ./debian-binary + ./control.tar.gz + ./data.tar.gz. The router's opkg
# (verified on GL-X3000, opkg 2021-06-13) segfaults on the ar/.deb form.
VERSION := 0.1.1
ARCH := aarch64_cortex-a53
OUT := out
BIN := $(OUT)/starwatchd-bin
STARWATCHD_IPK := $(OUT)/starwatchd_$(VERSION)_$(ARCH).ipk
LUCI_IPK := $(OUT)/luci-app-starwatch_$(VERSION)_all.ipk
GLAPP_IPK := $(OUT)/gl-app-starwatch_$(VERSION)_all.ipk
USIGN ?= usign
SIGNING_KEY ?=
VERIFY_KEY ?= starwatch-feed.pub

# Reject destinations which could turn the pages cleanup into a root or source
# tree cleanup.  This is evaluated while make reads the file, before it can
# build feed prerequisites or run any staging recipe.
ifneq ($(filter feed-artifact signed-feed-artifact,$(MAKECMDGOALS)),)
ifeq ($(strip $(OUT)),)
$(error feed-artifact requires a non-empty OUT)
endif
ifeq ($(abspath $(OUT)),/)
$(error feed-artifact refuses OUT=/)
endif
ifeq ($(abspath $(OUT)),$(CURDIR))
$(error feed-artifact refuses OUT=$(OUT))
endif
endif

.PHONY: all clean test bin ipk-starwatchd ipk-luci ipk-glapp feed feed-artifact signed-feed-artifact

all: ipk-starwatchd ipk-luci ipk-glapp

test:
	sh tests/uci-defaults-route-test.sh
	sh tests/feed-artifact-test.sh

# feed: build all ipks + an opkg index (Packages/Packages.gz) so a router can
# `opkg update && opkg upgrade` from a hosted feed instead of manual reinstall.
# Bump VERSION (e.g. make VERSION=0.1.1 feed) so opkg sees an upgrade.
feed: all
	index_dir=$$(mktemp -d "$(OUT)/.feed-index.XXXXXX") && \
	cp $(STARWATCHD_IPK) $(LUCI_IPK) $(GLAPP_IPK) "$$index_dir/" && \
	sh mkfeed.sh "$$index_dir" && \
	cp "$$index_dir/Packages" "$$index_dir/Packages.gz" $(OUT)/ && \
	rm -rf "$$index_dir"

# feed-artifact: stage only the static files published as the opkg feed.
feed-artifact: feed
	rm -rf $(OUT)/pages
	mkdir -p $(OUT)/pages
	cp $(OUT)/Packages $(OUT)/Packages.gz $(STARWATCHD_IPK) $(LUCI_IPK) $(GLAPP_IPK) install.sh $(OUT)/pages/

# Deployable feeds retain OpenWrt's global signature checks. The public key is
# pinned by install.sh; the private key is supplied only by GitHub Actions.
signed-feed-artifact: feed-artifact
	test -n "$(SIGNING_KEY)"
	command -v "$(USIGN)" >/dev/null
	"$(USIGN)" -S -m $(OUT)/pages/Packages -s "$(SIGNING_KEY)" -x $(OUT)/pages/Packages.sig
	cp starwatch-feed.pub $(OUT)/pages/
	"$(USIGN)" -V -m $(OUT)/pages/Packages -p "$(VERIFY_KEY)" -x $(OUT)/pages/Packages.sig

bin:
	mkdir -p $(OUT)
	cd ../router && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath \
		-ldflags "-s -w" -o $(abspath $(BIN)) ./cmd/starwatchd

# Assemble an ipk from a staging dir: $1=pkgname $2=stagedir $3=arch
define make_ipk
	rm -rf $(OUT)/stage-$(1)
	cp -r $(2) $(OUT)/stage-$(1)
	mkdir -p $(OUT)/stage-$(1)/CONTROL
	# Inject VERSION into the control's Version: field so the .ipk filename,
	# the control metadata, and the feed index all agree — otherwise opkg sees
	# "same version" and won't upgrade. (-i.bak works on BSD and GNU sed.)
	sed -i.bak "s/^Version:.*/Version: $(VERSION)/" $(OUT)/stage-$(1)/CONTROL/control
	rm -f $(OUT)/stage-$(1)/CONTROL/control.bak
	# data.tar.gz = everything except CONTROL.
	# --format ustar: OpenWrt's opkg tar parser rejects pax extended headers
	#   (typeflag 'x'/0x78), which macOS BSD tar emits by default.
	# COPYFILE_DISABLE: keep BSD tar from injecting AppleDouble (._*) entries.
	COPYFILE_DISABLE=1 tar --format ustar --exclude=CONTROL -czf $(OUT)/data.tar.gz -C $(OUT)/stage-$(1) .
	COPYFILE_DISABLE=1 tar --format ustar -czf $(OUT)/control.tar.gz -C $(OUT)/stage-$(1)/CONTROL .
	echo "2.0" > $(OUT)/debian-binary
	# Outer wrapper is a gzipped ustar tar (OpenWrt ipk format), NOT ar.
	( cd $(OUT) && COPYFILE_DISABLE=1 tar --format ustar -czf $(1)_$(VERSION)_$(3).ipk \
		./debian-binary ./control.tar.gz ./data.tar.gz )
	rm -f $(OUT)/data.tar.gz $(OUT)/control.tar.gz $(OUT)/debian-binary
endef

ipk-starwatchd: bin
	rm -rf $(OUT)/stage
	mkdir -p $(OUT)/stage/usr/bin
	cp $(BIN) $(OUT)/stage/usr/bin/starwatchd
	cp -r starwatchd/etc $(OUT)/stage/
	cp -r starwatchd/CONTROL $(OUT)/stage/
	chmod +x $(OUT)/stage/etc/init.d/starwatch $(OUT)/stage/etc/uci-defaults/99-starwatch $(OUT)/stage/CONTROL/postinst
	$(call make_ipk,starwatchd,$(OUT)/stage,$(ARCH))

ipk-luci:
	rm -rf $(OUT)/stage-luci
	cp -r luci-app-starwatch $(OUT)/stage-luci
	chmod +x $(OUT)/stage-luci/usr/libexec/rpcd/starwatch
	$(call make_ipk,luci-app-starwatch,$(OUT)/stage-luci,all)

# gl-app-starwatch: native GL admin-panel (oui) iframe app. The view is served
# gzipped from /www/views (nginx gzip_static serves it for the .js request oui
# makes), so gzip the committed source bundle into the staging tree.
ipk-glapp:
	rm -rf $(OUT)/stage-gl
	mkdir -p $(OUT)/stage-gl/www/views $(OUT)/stage-gl/usr/share/oui/menu.d $(OUT)/stage-gl/usr/lib/oui-httpd/rpc
	gzip -9 -c gl-app-starwatch/www/views/gl-sdk4-ui-starwatch.common.js > $(OUT)/stage-gl/www/views/gl-sdk4-ui-starwatch.common.js.gz
	cp gl-app-starwatch/usr/share/oui/menu.d/starwatch.json $(OUT)/stage-gl/usr/share/oui/menu.d/
	cp gl-app-starwatch/usr/lib/oui-httpd/rpc/starwatch $(OUT)/stage-gl/usr/lib/oui-httpd/rpc/
	cp -r gl-app-starwatch/CONTROL $(OUT)/stage-gl/
	chmod +x $(OUT)/stage-gl/CONTROL/postinst
	$(call make_ipk,gl-app-starwatch,$(OUT)/stage-gl,all)

clean:
	rm -rf $(OUT)
