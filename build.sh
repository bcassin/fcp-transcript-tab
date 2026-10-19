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
# The zip holds the plugin folder exactly as it goes into SpliceKit's plugins folder.
STAGE=build/stage/com.innerparakeet.transcript-tab
rm -rf build/stage && mkdir -p "$STAGE"
cp build/TranscriptTab.dylib plugin.json "$STAGE/"
(cd build/stage && zip -qr "../../dist/TranscriptTab-$VERSION.zip" com.innerparakeet.transcript-tab)
echo "Built dist/TranscriptTab-$VERSION.zip"
