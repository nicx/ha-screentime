#!/bin/bash
#
# devices.sh (v3) — JEDES Gerät (alle Plattformen) auf App-Nutzung prüfen.
# In einem Terminal MIT Full Disk Access ausführen:  bash ~/Git/ha-screentime/devices.sh
#
# Ziel: für jedes in sync.db bekannte Gerät die Top-Apps zeigen, damit klar wird,
# ob IRGENDEIN Gerät die Apps des Sohnes trägt (oder nur eigene Geräte).

set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$SCRIPT_DIR/aw-import-screentime"
CLI="$REPO/.venv/bin/aw-import-screentime"
SYNC_DB="$HOME/Library/Biome/sync/sync.db"

[ -x "$CLI" ] || { echo "CLI fehlt: $CLI"; exit 1; }
[ -r "$SYNC_DB" ] || { echo ">> sync.db nicht lesbar — Full Disk Access prüfen!"; exit 1; }
cd "$REPO" || exit 1

echo "############ Gerätetabelle (device_identifier | me | platform | model | last_sync) ############"
sqlite3 -header -column "$SYNC_DB" \
  "SELECT device_identifier, me, platform, model,
          datetime(last_sync_date,'unixepoch','localtime') AS last_sync
   FROM DevicePeer ORDER BY platform;" 2>&1
echo

# Alle Geräte + Plattform durchgehen
sqlite3 "$SYNC_DB" "SELECT device_identifier||'|'||COALESCE(platform,'') FROM DevicePeer;" 2>/dev/null \
| while IFS='|' read -r dev plat; do
    [ -z "$dev" ] && continue
    echo "======================================================================"
    echo "  Gerät: $dev   (platform $plat)"
    json=$("$CLI" events preview --device "$dev" --platform "$plat" --since "14 days ago" --limit 0 2>/dev/null)
    n=$(echo "$json" | jq '[.[].events[]] | length' 2>/dev/null)
    echo "  Events (14 Tage): ${n:-0}"
    if [ "${n:-0}" != "0" ] && [ -n "${n:-}" ]; then
      echo "  Top-Apps (Name):"
      echo "$json" | jq -r '.[].events[].data | (.title // .app // tojson)' 2>/dev/null \
        | sort | uniq -c | sort -rn | head -20 | sed 's/^/     /'
    fi
    echo
done

echo "FERTIG."
echo "-> Kannst du EIN Gerät eindeutig deinem Sohn zuordnen (seine Apps)?"
echo "   JA  -> sein Gerät synct in deinen Account -> Phase 1 möglich."
echo "   NEIN (alles deine Geräte) -> Eltern-Account genügt nicht -> Fallbacks."
