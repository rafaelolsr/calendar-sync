#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
swift build -c release --product CalendarSync "$@"

APP_DIR=".build/CalendarSync.app"
CONTENTS="$APP_DIR/Contents"
ICONSET=".build/CalendarSyncIcon.iconset"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp .build/release/CalendarSync "$CONTENTS/MacOS/CalendarSync"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp Resources/CalendarSyncIcon.png "$CONTENTS/Resources/CalendarSyncIcon.png"
mkdir -p "$ICONSET"
for entry in "16 16" "16 32" "32 32" "32 64" "128 128" "128 256" "256 256" "256 512" "512 512" "512 1024"; do
	set -- $entry
	size="$1"
	pixels="$2"
	name="icon_${size}x${size}"
	if [ "$pixels" -eq $((size * 2)) ]; then name="${name}@2x"; fi
	sips -s format png -z "$pixels" "$pixels" "$PWD/Resources/CalendarSyncIcon.png" --out "$PWD/$ICONSET/$name.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/CalendarSyncIcon.icns"
[ -s "$CONTENTS/Resources/CalendarSyncIcon.icns" ]
xattr -dr com.apple.quarantine "$APP_DIR"
codesign --force --sign - "$APP_DIR"
printf 'Built %s/%s\n' "$PWD" "$APP_DIR"
