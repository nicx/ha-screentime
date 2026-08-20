#!/bin/bash
#
# deploy.sh — kopiert die Diagnose-Skripte an einen Ort, den auch der
# Sammel-Benutzer (der mit der Apple-ID des Kindes angemeldete Account) lesen
# und ausführen kann.
#
# Hintergrund: Home-Verzeichnisse sind unter macOS drwxr-x---, der Sammel-Benutzer
# kommt also nicht in das Home des Hauptbenutzers, in dem entwickelt wird.
# /Users/Shared ist für alle lesbar.
#
# Für den produktiven Betrieb wird das hier NICHT gebraucht — den übernimmt
# HAScreenTime.app (siehe Scripts/install-app.sh). Dieses Skript ist nur für
# die Diagnose-Skripte diagnose.sh und devices.sh gedacht.
#
# venvs werden nicht kopiert (enthalten absolute Pfade), sondern am Ziel gebaut.
#
# Aufruf (als Hauptbenutzer):  bash ~/Git/ha-screentime/deploy.sh

set -euo pipefail
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DST="/Users/Shared/ha-screentime"

echo ">> Deploy $SRC -> $DST"
mkdir -p "$DST"

rsync -a --delete \
  --exclude '.git' \
  --exclude '.venv' \
  --exclude 'aw-import-screentime/.venv' \
  --exclude 'data' \
  --exclude '__pycache__' \
  --exclude '.build' \
  --exclude 'dist' \
  --exclude 'Runtime' \
  "$SRC"/ "$DST"/

echo ">> venv (Hauptprojekt) am Ziel bauen"
cd "$DST"
[ -d .venv ] || uv venv .venv >/dev/null
uv pip install --quiet --python .venv/bin/python requests python-dotenv

echo ">> venv (aw-import-screentime) am Ziel sicherstellen"
cd "$DST/aw-import-screentime"
[ -x .venv/bin/aw-import-screentime ] || uv sync >/dev/null

echo ">> Rechte setzen"
# Datenverzeichnis muss für den Sammel-Benutzer beschreibbar sein.
mkdir -p "$DST/data"
chmod 1777 "$DST/data"
chmod -R a+rX "$DST"
chmod a+x "$DST"/*.sh 2>/dev/null || true

echo ">> Fertig. In der Sitzung des Sammel-Benutzers ausführen:"
echo "   bash $DST/devices.sh"
