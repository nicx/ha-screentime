#!/usr/bin/env bash
#
# Baut HAScreenTime.app: kompiliert das Swift-Binary (release) und setzt das
# Bundle inklusive eingebetteter Python-Runtime und der Python-Skripte zusammen.
#
# Voraussetzung: Scripts/bundle-runtime.sh wurde ausgeführt (./Runtime existiert).
#
# Env-Overrides:
#   CODESIGN_IDENTITY   Signatur-Identität. Default ad-hoc ("-"). Für den
#                       produktiven Einsatz die stabile selbstsignierte
#                       Identität "nicx Selfsign" verwenden — ad-hoc ändert bei
#                       jedem Build den CDHash, wodurch macOS erteilte
#                       Berechtigungen (u.a. Festplattenvollzugriff!) verwirft.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME="$ROOT/Runtime"
APP="$ROOT/dist/HAScreenTime.app"
IDENTITY="${CODESIGN_IDENTITY:--}"
ENTITLEMENTS="$ROOT/Resources/HAScreenTime.entitlements"

# Läuft die App aus genau diesem dist/, würde der Build ihr das Bundle unter den
# Füßen weglöschen: der Prozess liefe mit ALTEM Code aus einem gelöschten Bundle
# weiter, macOS graut ihn aus, Beenden ginge nur noch per `kill`.
RUNNING="$(pgrep -f "$APP/Contents/MacOS/HAScreenTime" || true)"
if [[ -n "$RUNNING" ]]; then
  echo "ABBRUCH: HAScreenTime läuft gerade aus $ROOT/dist (PID: ${RUNNING//$'\n'/ })." >&2
  echo "         Der Build würde das laufende Bundle löschen." >&2
  echo "         Erst die App beenden (Menüleiste -> Beenden), dann erneut bauen." >&2
  exit 1
fi

if [[ ! -x "$RUNTIME/python/bin/python3" ]]; then
  echo "error: $RUNTIME/python fehlt — zuerst Scripts/bundle-runtime.sh ausführen." >&2
  exit 1
fi

# SDK explizit auf die stabile macOS-26-Reihe pinnen. Am 2026-09-10 hat sich
# ein macOS-27-Beta-SDK als Default eingenistet (Symlink MacOSX.sdk ->
# MacOSX27.0.sdk); dessen SwiftUI-Makro-Plugin fehlt, `swift build` bricht
# dann mit "SwiftUIMacros.StateMacro could not be found" ab. Der Rechner laeuft
# auf macOS 26.6 -- gegen ein 27er-Beta-SDK zu bauen waere ohnehin falsch.
CLT_SDKS="/Library/Developer/CommandLineTools/SDKs"
if [[ -d "$CLT_SDKS/MacOSX26.sdk" ]]; then
  export SDKROOT="$CLT_SDKS/MacOSX26.sdk"
  echo "==> SDKROOT gepinnt: $(readlink -f "$SDKROOT" 2>/dev/null || echo "$SDKROOT")"
fi

echo "==> Baue Release-Binary"
swift build -c release
BIN="$(swift build -c release --show-bin-path)/HAScreenTime"

echo "==> Setze App-Bundle zusammen"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN" "$APP/Contents/MacOS/HAScreenTime"
cp -R "$RUNTIME" "$APP/Contents/Resources/Runtime"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/"

# Build-Kennung: daran erkennt die laufende App, dass eine neuere Version
# bereitliegt (siehe Updater.swift / Scripts/stage-update.sh).
date +%Y%m%d-%H%M%S > "$APP/Contents/Resources/BUILD-ID"

# Python-Nutzlast: run.py + src/. aw-import-screentime steckt bereits als
# pip-Installation in der Runtime und wird nicht separat mitkopiert.
PAYLOAD="$APP/Contents/Resources/payload"
mkdir -p "$PAYLOAD"
cp "$ROOT/run.py" "$PAYLOAD/"
cp -R "$ROOT/src" "$PAYLOAD/src"
find "$PAYLOAD" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true

echo "==> Signiere (Identität: $IDENTITY)"
# Inside-out: erst jede Mach-O-Datei der eingebetteten Runtime, dann der
# Interpreter, dann das App-Binary, dann das Bundle. Ohne die Entitlements an
# jeder .so verweigert die Hardened Runtime das Laden der pip-Extensions.
RUNTIME_IN_APP="$APP/Contents/Resources/Runtime/python"

sign() {
  codesign --force --options runtime --timestamp=none \
    --entitlements "$ENTITLEMENTS" -s "$IDENTITY" "$1"
}

echo "    Mach-O-Dateien in der Runtime…"
while IFS= read -r -d '' f; do
  if file -b "$f" | grep -q 'Mach-O'; then
    sign "$f"
  fi
done < <(find "$RUNTIME_IN_APP" -type f \( -name '*.so' -o -name '*.dylib' -o -perm -u+x \) -print0)

sign "$RUNTIME_IN_APP/bin/python3"

echo "    App-Binary…"
sign "$APP/Contents/MacOS/HAScreenTime"

echo "    Bundle…"
sign "$APP"

echo "==> Prüfe Signatur"
codesign --verify --strict --verbose=2 "$APP" || true

echo "==> Fertig: $APP"
echo "    Installieren für den Sammel-Benutzer: bash Scripts/install-app.sh"
