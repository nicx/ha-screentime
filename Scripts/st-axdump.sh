#!/bin/bash
#
# st-axdump.sh — Machbarkeitstest "Bildschirmzeit-UI auslesen".
#
# 1. Systemeinstellungen -> Bildschirmzeit -> Kind waehlen -> Ansicht mit der
#    App-Nutzung oeffnen (Zeitraum "Heute").
# 2. Im Terminal:  bash ~/Git/ha-screentime/Scripts/st-axdump.sh
#
# Liest nur, klickt nichts. Das Ergebnis enthaelt Nutzungsdaten und landet
# deshalb ausserhalb des (oeffentlichen) Repos.
#
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="$HOME/Library/Caches/HAScreenTime"
mkdir -p "$OUT_DIR"
OUT="$OUT_DIR/ax-dump-$(date +%Y%m%d-%H%M%S).txt"

# Wie in make-app.sh: auf die stabile SDK-Reihe pinnen, falls vorhanden.
SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX26.sdk
[[ -d "$SDK" ]] && export SDKROOT="$SDK"

swift "$DIR/st-axdump.swift" "$OUT" || exit $?
echo "Treffer mit Zeitangaben (Vorschau):"
grep -Ei '[0-9]+ ?(Std|Min|h|m|Sek|s)\b' "$OUT" | head -15
