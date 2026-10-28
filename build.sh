#!/bin/bash
# Build TranscriptTab.dylib (Apple silicon + Intel) and the release zip in dist/.
set -e
cd "$(dirname "$0")"
VERSION=$(python3 -c 'import json; print(json.load(open("plugin.json"))["version"])')
mkdir -p build dist
clang -arch arm64 -arch x86_64 -mmacosx-version-min=14.0 -dynamiclib -fobjc-arc \
      -framework AppKit -framework CoreMedia -Wl,-undefined,dynamic_lookup \
      -o build/TranscriptTab.dylib TranscriptTab.m
codesign -s - -f build/TranscriptTab.dylib
# ctcalign: the word aligner Detect runs (CoreML only; uses the Parakeet CTC model FluidAudio keeps
# in ~/Library/Application Support/FluidAudio/Models). Without it Detect keeps Parakeet's times.
# Apple silicon only (it uses Float16, and SpliceKit's Parakeet tools are Apple silicon only too).
swiftc -O -target arm64-apple-macos14.0 -o build/ctcalign ctcalign/main.swift
codesign -s - -f build/ctcalign
# The zip holds the plugin folder exactly as it goes into SpliceKit's plugins folder.
STAGE=build/stage/com.innerparakeet.transcript-tab
rm -rf build/stage && mkdir -p "$STAGE"
cp build/TranscriptTab.dylib build/ctcalign plugin.json "$STAGE/"
rm -f "dist/TranscriptTab-$VERSION.zip"
(cd build/stage && zip -qr "../../dist/TranscriptTab-$VERSION.zip" com.innerparakeet.transcript-tab)
echo "Built dist/TranscriptTab-$VERSION.zip"
