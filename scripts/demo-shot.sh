#!/bin/zsh
# Construit, installe et lance l'app avec une démo scriptée, puis prend une capture.
# Usage : scripts/demo-shot.sh <simulateur> <masque> <geste> <partial|finish> <sortie.png> [délai_s] [dossier_derived_data]
# Exemple : scripts/demo-shot.sh "iPhone 18 Pro" snow scratch partial /tmp/neige.png 3.5
set -euo pipefail
SIM="$1"; MASK="$2"; GESTURE="$3"; DEMO="$4"; OUT="$5"; DELAY="${6:-3.5}"
ROOT="${0:A:h}/.."
DERIVED="${7:-$ROOT/build/demo-${SIM// /-}}"
UDID=$(xcrun simctl list devices available | grep -F "$SIM (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')
[[ -n "$UDID" ]] || { echo "simulateur introuvable : $SIM"; exit 1; }
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcodebuild build -project "$ROOT/RevelioNoel.xcodeproj" -scheme RevelioNoel \
  -destination "platform=iOS Simulator,id=$UDID" -derivedDataPath "$DERIVED" -quiet
xcrun simctl install "$UDID" "$DERIVED/Build/Products/Debug-iphonesimulator/RevelioNoel.app"
xcrun simctl terminate "$UDID" com.pictarine.proto.RevelioNoel 2>/dev/null || true
xcrun simctl launch "$UDID" com.pictarine.proto.RevelioNoel -RNMask "$MASK" -RNGesture "$GESTURE" -RNDemo "$DEMO" >/dev/null
sleep "$DELAY"
xcrun simctl io "$UDID" screenshot "$OUT" >/dev/null 2>&1
echo "capture : $OUT"
