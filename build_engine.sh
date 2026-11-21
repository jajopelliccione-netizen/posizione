#!/bin/bash
# Compila il motore Rust per iPhone (e simulatore) -> App/lib
set -e
cd "$(dirname "$0")/engine"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo build --release --target aarch64-apple-ios
cargo build --release --target aarch64-apple-ios-sim
mkdir -p ../App/lib/iphoneos ../App/lib/iphonesimulator
cp target/aarch64-apple-ios/release/libposizione_engine.a ../App/lib/iphoneos/
cp target/aarch64-apple-ios-sim/release/libposizione_engine.a ../App/lib/iphonesimulator/
echo "Fatto. Ora: cd App && xcodegen && open Posizione.xcodeproj"
