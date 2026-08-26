#!/usr/bin/env bash
#
# Legt die gebaute App unter /Users/Shared/HAScreenTime-Update ab. Die laufende
# Instanz im Sammel-Benutzer erkennt beim naechsten Lauf an der BUILD-ID, dass
# eine andere Version bereitliegt, spiegelt sie ueber ihr eigenes Bundle und
# startet sich neu (siehe Sources/HAScreenTime/Updater.swift).
#
# Das ersetzt fuer Folge-Updates das manuelle Beenden/Starten durch den
# Benutzer: macOS erlaubt es nicht, in der Sitzung eines anderen Benutzers
# Prozesse zu beenden oder zu starten -- die App muss das selbst tun.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/HAScreenTime.app"
STAGE="/Users/Shared/HAScreenTime-Update"

if [[ ! -d "$SRC" ]]; then
  echo "error: $SRC fehlt — zuerst Scripts/make-app.sh ausfuehren." >&2
  exit 1
fi

BUILD_ID="$(cat "$SRC/Contents/Resources/BUILD-ID" 2>/dev/null || true)"
if [[ -z "$BUILD_ID" ]]; then
  echo "error: $SRC hat keine BUILD-ID — mit aktuellem make-app.sh neu bauen." >&2
  exit 1
fi

# Nur eine gueltig signierte Version bereitstellen: die App spielt sonst nichts
# ein, und ein kaputtes Bundle startet macOS gar nicht erst.
if ! codesign --verify --strict "$SRC" 2>/dev/null; then
  echo "error: Signatur von $SRC ist ungueltig." >&2
  exit 1
fi

echo "==> Lege Version $BUILD_ID unter $STAGE ab"
mkdir -p "$STAGE"
rsync -a --delete "$SRC/" "$STAGE/HAScreenTime.app/"
chmod -R a+rX "$STAGE"

echo "==> Fertig. Die laufende App zieht sich das beim naechsten Lauf"
echo "    (spaetestens nach dem eingestellten Intervall) selbst."
