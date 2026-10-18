# Build and test mead. Requires the Odin compiler and git; libcurl for GitHub discovery.
ODIN ?= odin
ODIN_FLAGS ?= -vet -strict-style
KDL_SUITE ?= build/kdl-spec

# The version defaults to the one in src/main.odin; release CI passes the tag's version.
VERSION ?= $(shell sed -n 's/^MEAD_VERSION :: #config(MEAD_VERSION, "\(.*\)")$$/\1/p' src/main.odin)
# owner/repo whose GitHub releases `mead upgrade` and install.sh use. Release CI sets it.
RELEASE_REPO ?=
DEFINES = -define:MEAD_VERSION=$(VERSION) $(if $(RELEASE_REPO),-define:MEAD_RELEASE_REPO=$(RELEASE_REPO))

# Release asset naming: mead-<os>-<arch>, matching release_asset_name in src/upgrade.odin.
DIST_OS ?= $(shell uname -s | sed 's/Linux/linux/;s/Darwin/macos/')
DIST_ARCH ?= $(shell uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
DIST_NAME = mead-$(DIST_OS)-$(DIST_ARCH)

.PHONY: all release dist test unit conformance e2e clean

all: build/mead

build/mead: $(wildcard src/*.odin) $(wildcard kdl/*.odin)
	@mkdir -p build
	$(ODIN) build src -out:build/mead $(ODIN_FLAGS) $(DEFINES)

release:
	@mkdir -p build
	$(ODIN) build src -out:build/mead -o:speed $(ODIN_FLAGS) $(DEFINES)

# Builds the release files for this platform into build/dist: the binary,
# install.sh with RELEASE_REPO filled in, and SHA256SUMS over both.
dist: release
	@test -n "$(RELEASE_REPO)" || { echo "dist needs RELEASE_REPO=owner/repo" >&2; exit 1; }
	@mkdir -p build/dist
	cp build/mead build/dist/$(DIST_NAME)
	sed 's|@RELEASE_REPO@|$(RELEASE_REPO)|' scripts/install.sh > build/dist/install.sh
	cd build/dist && sha256sum $(DIST_NAME) install.sh > SHA256SUMS

test: unit conformance e2e

# The CLI does not free memory before it exits, so leak tracking is off for unit tests.
# -vet is omitted here because core:testing does not pass it with tracking disabled.
unit:
	@mkdir -p build
	$(ODIN) test src -out:build/mead_test -strict-style -define:ODIN_TEST_TRACK_MEMORY=false

# Runs the upstream KDL test suite against mead's parser.
conformance:
	@mkdir -p build
	@test -d $(KDL_SUITE) || git clone --quiet --depth 1 https://github.com/kdl-org/kdl.git $(KDL_SUITE)
	$(ODIN) build tests/kdl_conformance -out:build/kdl_conformance $(ODIN_FLAGS)
	./build/kdl_conformance $(KDL_SUITE)/tests/test_cases

e2e: build/mead
	tests/e2e.sh build/mead
	tests/release.sh build/mead

clean:
	rm -rf build
