#!/bin/bash
# Run only an official CEF sample obtained from the CEF project.
# This does not install or copy CDMs, change signing, or disable sandboxing.
set -euo pipefail
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo "Run this on an Apple Silicon Mac using a native terminal." >&2
  exit 1
fi
if [[ $# != 1 ]]; then
  echo "Usage: bash experiments/chromium/check-cef.sh /path/to/cefclient.app" >&2
  exit 2
fi
app="$1"
if [[ ! -d "$app/Contents" ]]; then
  echo "Expected the extracted official cefclient.app bundle." >&2
  exit 2
fi
exe=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app/Contents/Info.plist")
binary="$app/Contents/MacOS/$exe"
[[ -x "$binary" ]] || { echo "Missing client executable." >&2; exit 1; }
echo "System: $(sw_vers -productVersion) ($(uname -m))"
echo "Client version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo unknown)"
echo "Client architecture:"
/usr/bin/file "$binary"
archs=$(/usr/bin/lipo -archs "$binary")
case " $archs " in
  *" arm64 "*) ;;
  *) echo "This executable does not contain arm64." >&2; exit 1 ;;
esac
echo "Framework and helpers:"
find "$app/Contents/Frameworks" -maxdepth 3 -name '*.app' -print 2>/dev/null || true
echo "Code signature verification (informational):"
if /usr/bin/codesign --verify --deep --strict "$app" 2>/dev/null; then
  echo "Signature verification passed; this is not a notarization or trust guarantee."
else
  echo "Signature verification failed. Do not bypass macOS security checks."
fi
echo "Check the official download checksum and publisher before launching."
echo "If macOS permits normal launch, use:"
printf 'open %q --args --url=https://open.spotify.com/\n' "$app"
