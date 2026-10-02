#!/bin/sh
set -eu

cd "$(dirname "$0")/.."
DEVELOPER_PATH="$(xcode-select -p)"
FRAMEWORKS="$DEVELOPER_PATH/Library/Developer/Frameworks"

# Newer Command Line Tools ship Swift Testing as a framework rather than in
# SwiftPM's default library search path. XCTest is not needed by these suites.
if [ -d "$FRAMEWORKS/Testing.framework" ]; then
    set -- "$@" --disable-xctest \
        -Xswiftc -F -Xswiftc "$FRAMEWORKS" \
        -Xswiftc -plugin-path -Xswiftc "$DEVELOPER_PATH/usr/lib/swift/host/plugins/testing" \
        -Xlinker -rpath -Xlinker "$FRAMEWORKS"
fi

swift test "$@"
