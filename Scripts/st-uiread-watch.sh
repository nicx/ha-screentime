#!/bin/bash
#
# st-uiread-watch.sh — Messreihe: liest die Bildschirmzeit in festem Takt aus
# und protokolliert je Lauf eine Zeile. Beantwortet zwei Fragen:
#   1. Wie oft aendern sich Apples Zahlen tatsaechlich (Aktualisierungstakt)?
#   2. Funktioniert das Auslesen auch bei gesperrtem Bildschirm?
#
#   bash ~/Git/ha-screentime/Scripts/st-uiread-watch.sh [Abstand_s] [Anzahl] [Kind]
#   Standard: alle 180 s, 20 Laeufe (= 1 Stunde), Kind "Max"
#
# Laeuft im Hintergrund weiter, solange das Terminal offen bleibt.
#
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
INTERVAL="${1:-180}"; COUNT="${2:-20}"; CHILD="${3:-Max}"
OUT_DIR="$HOME/Library/Caches/HAScreenTime"; mkdir -p "$OUT_DIR"
LOG="$OUT_DIR/watch-$(date +%Y%m%d-%H%M%S).tsv"
BIN="$OUT_DIR/st-uiread"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
[[ -d "$SDK" ]] && export SDKROOT="$SDK"

# Einmal uebersetzen statt bei jedem Lauf -- spart je Lauf einige Sekunden.
swiftc -O -o "$BIN" "$DIR/st-uiread.swift" || exit 1

printf "zeit\texit\tsekunden_lauf\taktualisiert\tgesamt_s\tapps\ttop_app\ttop_app_s\n" > "$LOG"
echo "Protokoll: $LOG  ($COUNT Laeufe, alle $INTERVAL s)"

for ((i = 1; i <= COUNT; i++)); do
  t0=$(date +%s)
  json=$("$BIN" "$CHILD" 2>>"$LOG.stderr"); rc=$?
  line=$(printf '%s' "$json" | /usr/bin/python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    top = max(d["apps"], key=lambda a: a["seconds"] or 0) if d["apps"] else {"name": "-", "seconds": 0}
    print("\t".join(map(str, [d["updated"], d["total_seconds"], len(d["apps"]), top["name"], top["seconds"]])))
except Exception:
    print("-\t-\t-\t-\t-")
')
  printf "%s\t%s\t%s\t%s\n" "$(date +%H:%M:%S)" "$rc" "$(( $(date +%s) - t0 ))" "$line" >> "$LOG"
  (( i < COUNT )) && sleep "$INTERVAL"
done
echo "Fertig: $LOG"
