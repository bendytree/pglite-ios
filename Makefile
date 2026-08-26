# PGliteKit build pipeline. See README.md.

.PHONY: all module gen lib-macos xcframework resources test native-test clean

all: xcframework

# Rebuild pglite.wasi from pinned sources (Docker required).
module:
	./module/build.sh

# wasm2c the module into native/gen/ (requires: brew install wabt).
gen:
	./native/gen.sh

lib-macos: 
	./native/scripts/build-lib.sh macos

# Device + simulator + macOS static libs, packaged for the Swift package.
xcframework: gen
	./native/scripts/build-xcframework.sh

# Regenerate Swift package resources (runtime FS + pristine PGDATA) after
# a module rebuild.
resources: lib-macos
	./native/scripts/prepare-resources.sh

native-test: gen lib-macos
	rm -rf build/testroot && mkdir -p build/testroot
	tar xf module/out/pglite-wasi.tar.xz -C build/testroot
	./build/macos/native_test build/testroot

test: native-test
	swift test

clean:
	rm -rf build native/gen .build
