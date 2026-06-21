# Lagoon build orchestration.
#
# Local development (native macOS / Linux): `cargo` commands work directly.
# Cross-compilation: requires the musl-cross toolchain on macOS hosts —
#   brew tap filosottile/musl-cross
#   brew install filosottile/musl-cross/musl-cross
# (See .cargo/config.toml for details.)

# Apple targets compiled into the iOS/macOS app bundles.
apple_targets := "aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios aarch64-apple-darwin x86_64-apple-darwin"

# Linux target: the deploy target for lagoon-server (and a compile-time guard
# rail for lagoon-core on macOS hosts).
linux_targets := "x86_64-unknown-linux-musl"

# Target used to source UniFFI metadata for bindgen. Any Apple target works
# since the metadata is identical; we pick the host arch for speed.
bindgen_target := "aarch64-apple-darwin"

# Show available recipes
default:
    @just --list

# Fetch the all-MiniLM-L6-v2 embedding model (~91MB, not committed).
# Required for semantic search and for `just test-semantic`.
fetch-model:
    #!/usr/bin/env bash
    set -euo pipefail
    dir="models/all-MiniLM-L6-v2"
    mkdir -p "$dir"
    for f in model.safetensors tokenizer.json config.json; do
        if [ ! -f "$dir/$f" ]; then
            echo "==> $f"
            curl -sL -o "$dir/$f" \
                "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main/$f"
        fi
    done
    ls -la "$dir"

# Install the embedding model where the Linux app looks for it
# ($XDG_DATA_HOME/lagoon/models, defaulting to ~/.local/share/lagoon/models).
install-model-linux: fetch-model
    #!/usr/bin/env bash
    set -euo pipefail
    dest="${XDG_DATA_HOME:-$HOME/.local/share}/lagoon/models"
    mkdir -p "$dest"
    cp -R models/all-MiniLM-L6-v2 "$dest/"
    echo "==> installed to $dest/all-MiniLM-L6-v2"

# Run all core tests on the host
test:
    cargo test --workspace

# Run the embedding tests that need the real model (see fetch-model).
test-semantic: fetch-model
    cargo test --workspace --release -- --ignored

# Lint with clippy (warnings as errors)
lint:
    cargo clippy --workspace --all-targets -- -D warnings

# Check formatting
fmt-check:
    cargo fmt --all -- --check

# Apply formatting
fmt:
    cargo fmt --all

# Run lint + fmt-check + test (CI-style local check)
check: lint fmt-check test

# Build the apple-ffi static library for every Apple target.
# This transitively builds lagoon-core for each target as well.
build-apple:
    #!/usr/bin/env bash
    set -euo pipefail
    for t in {{apple_targets}}; do
        echo "==> $t"
        cargo build --lib -p lagoon-apple-ffi --release --target "$t"
    done

# Cross-compile the core crate to Linux as a guard rail on macOS hosts.
build-linux:
    #!/usr/bin/env bash
    set -euo pipefail
    for t in {{linux_targets}}; do
        echo "==> $t"
        cargo build --lib -p lagoon-core --release --target "$t"
    done

# Build the web frontend (bun → web/dist). Same build deploy.toml runs.
build-web:
    cd web && bun install && bun run build

# Cross-compile lagoon-server for the VPS (static musl release). Same build
# deploy.toml runs for the backend.
build-server:
    cargo build -p lagoon-server --release --target x86_64-unknown-linux-musl

# Run the web app locally: the Vite dev server (proxies /api to :8092) plus the
# backend. Start the backend in another shell with:
#   cargo run -p lagoon-server -- --config <your-local-config.toml>
dev-web:
    cd web && bun run dev

# Generate Swift bindings via the workspace-local uniffi-bindgen.
# Depends on having a built apple-ffi static lib for `bindgen_target`.
build-bindings:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --lib -p lagoon-apple-ffi --release --target {{bindgen_target}}
    rm -rf generated/swift
    mkdir -p generated/swift
    cargo run --release -p lagoon-apple-ffi --bin uniffi-bindgen -- generate \
        --library target/{{bindgen_target}}/release/liblagoon_apple_ffi.a \
        --language swift \
        --out-dir generated/swift

# Build LagoonCore.xcframework and the companion Swift bindings file in dist/.
build-xcframework: build-apple build-bindings
    #!/usr/bin/env bash
    set -euo pipefail

    rm -rf dist/LagoonCore.xcframework dist/staging dist/LagoonCore.swift
    mkdir -p dist/staging/ios-device/Headers dist/staging/ios-sim/Headers dist/staging/macos/Headers

    # iOS device slice — single arch (arm64 device).
    cp target/aarch64-apple-ios/release/liblagoon_apple_ffi.a dist/staging/ios-device/

    # iOS simulator slice — universal (arm64-sim + x86_64-sim).
    lipo -create \
        target/aarch64-apple-ios-sim/release/liblagoon_apple_ffi.a \
        target/x86_64-apple-ios/release/liblagoon_apple_ffi.a \
        -output dist/staging/ios-sim/liblagoon_apple_ffi.a

    # macOS slice — universal (arm64 + x86_64).
    lipo -create \
        target/aarch64-apple-darwin/release/liblagoon_apple_ffi.a \
        target/x86_64-apple-darwin/release/liblagoon_apple_ffi.a \
        -output dist/staging/macos/liblagoon_apple_ffi.a

    # Each slice carries an identical Headers/ directory with the C header
    # plus a module map. The modulemap is renamed to the conventional
    # `module.modulemap` so Xcode picks it up automatically.
    for slice in ios-device ios-sim macos; do
        cp generated/swift/lagoon_apple_ffiFFI.h        dist/staging/$slice/Headers/
        cp generated/swift/lagoon_apple_ffiFFI.modulemap dist/staging/$slice/Headers/module.modulemap
    done

    xcodebuild -create-xcframework \
        -library dist/staging/ios-device/liblagoon_apple_ffi.a -headers dist/staging/ios-device/Headers \
        -library dist/staging/ios-sim/liblagoon_apple_ffi.a    -headers dist/staging/ios-sim/Headers \
        -library dist/staging/macos/liblagoon_apple_ffi.a      -headers dist/staging/macos/Headers \
        -output dist/LagoonCore.xcframework

    cp generated/swift/lagoon_apple_ffi.swift dist/LagoonCore.swift
    rm -rf dist/staging

    # Stage into the Swift Package consumed by the Xcode project.
    pkg="apple/LagoonCorePackage"
    rm -rf "$pkg/Artifacts/LagoonCore.xcframework" "$pkg/Sources/LagoonCore/LagoonCore.swift"
    cp -R dist/LagoonCore.xcframework "$pkg/Artifacts/LagoonCore.xcframework"
    cp dist/LagoonCore.swift "$pkg/Sources/LagoonCore/LagoonCore.swift"

    echo ""
    echo "==> dist/LagoonCore.xcframework  (shareable artifact)"
    echo "==> dist/LagoonCore.swift        (shareable artifact)"
    echo "==> $pkg                       (consumed by the Xcode project)"

# Build the core crate for every target on every platform.
build-all: build-apple build-linux

# Compile + run a Swift smoke test against the macOS slice of the xcframework.
# Proves the full FFI chain works on macOS before we wire it into a real app.
smoke-xcframework:
    #!/usr/bin/env bash
    set -euo pipefail
    headers="dist/LagoonCore.xcframework/macos-arm64_x86_64/Headers"
    lib_dir="dist/LagoonCore.xcframework/macos-arm64_x86_64"
    if [ ! -d "$headers" ] || [ ! -f "$lib_dir/liblagoon_apple_ffi.a" ]; then
        echo "dist/LagoonCore.xcframework is missing; run \`just build-xcframework\` first." >&2
        exit 1
    fi
    bin="$(mktemp -d)/lagoon-smoke"
    swiftc -o "$bin" \
        -Xcc -fmodule-map-file="$headers/module.modulemap" \
        -Xcc -I"$headers" \
        -L "$lib_dir" \
        -llagoon_apple_ffi \
        -framework Accelerate \
        dist/LagoonCore.swift scripts/smoke-test.swift
    "$bin"

# Remove build artifacts and generated files.
clean:
    cargo clean
    rm -rf dist generated
