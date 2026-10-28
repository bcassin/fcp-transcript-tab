#!/bin/bash
# Build from source and install into SpliceKit's plugins folder. Restart Final Cut Pro afterwards.
set -e
cd "$(dirname "$0")"
./build.sh
DEST="$HOME/Library/Application Support/SpliceKit/plugins/com.innerparakeet.transcript-tab"
mkdir -p "$DEST"
# Never overwrite the dylib in place while Final Cut Pro is running: FCP has it mapped, and
# changing the file under it invalidates its code signature and macOS terminates FCP. Copy to a
# temp file and rename it over the old one instead; the new build loads on the next launch.
cp build/TranscriptTab.dylib "$DEST/.TranscriptTab.dylib.new"
mv -f "$DEST/.TranscriptTab.dylib.new" "$DEST/TranscriptTab.dylib"
cp build/ctcalign "$DEST/.ctcalign.new" && mv -f "$DEST/.ctcalign.new" "$DEST/ctcalign"
cp plugin.json "$DEST/plugin.json"
echo "Installed to $DEST — restart Final Cut Pro to load it."
