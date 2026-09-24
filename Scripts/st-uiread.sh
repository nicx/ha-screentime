#!/bin/bash
#
# st-uiread.sh — Prototyp: Bildschirmzeit eines Kindes aus den
# Systemeinstellungen (Familie) auslesen, inklusive Navigation.
#
#   bash ~/Git/ha-screentime/Scripts/st-uiread.sh <Kindname>
#
# Braucht die Bedienungshilfen-Berechtigung fuer das ausfuehrende Terminal.
# Das Ergebnis enthaelt Nutzungsdaten und landet ausserhalb des Repos. Schlaegt
# die Navigation fehl, wird zur Fehlersuche der aktuelle Fensterinhalt gesichert.
#
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$HOME/Library/Caches/HAScreenTime"
mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$OUT_DIR/uiread-$STAMP.json"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
[[ -d "$SDK" ]] && export SDKROOT="$SDK"

if swift "$DIR/st-uiread.swift" "${1:-${SCREENTIME_CHILD:-}}" > "$OUT"; then
  echo "==> Ergebnis: $OUT"
  /usr/bin/python3 - "$OUT" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
print(f"{d['date_label']} | Geraet: {d['device']} | {d['updated']} | Dauer {d['elapsed_seconds']} s")
print(f"Gesamt: {d['total_text']} ({d['total_seconds']} s) | Apps: {len(d['apps'])} | Websites: {len(d['web'])}")
for a in d['apps'][:8]:
    print(f"   {a['seconds']:>6} s  {a['name']}  ({a['bundle_id']})")
EOF
else
  rc=$?
  echo "==> Fehlgeschlagen (Code $rc). Sichere Fensterinhalt zur Fehlersuche ..."
  bash "$DIR/st-axdump.sh" >/dev/null 2>&1 && ls -t "$OUT_DIR"/ax-dump-*.txt | head -1
  exit $rc
fi
