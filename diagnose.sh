#!/bin/bash
#
# diagnose.sh  —  READ-ONLY Feasibility-Test (Phase 0)
#
# Zweck: Nach iCloud-Login mit dem ELTERN-Account prüfen, ob die Screen-Time-
# Nutzungsdaten des SOHN-iPhones lokal auf diesem Mac ankommen (Biome / knowledgeC).
# Das Skript schreibt NICHTS und ändert NICHTS — es liest nur und gibt einen Report aus.
#
# Voraussetzungen (manuell, vorher erledigen):
#   1. Mac mini in die eigene (Organizer-)Apple-ID eingeloggt
#   2. Bildschirmzeit an: "App- & Website-Aktivität" + "Über Geräte synchronisieren"
#      auf dem Mac UND auf dem eigenen iPhone
#   3. Full Disk Access für das ausführende Terminal (bzw. sshd-keygen-wrapper bei SSH)
#   4. ein paar Minuten iCloud syncen lassen
#
# Aufruf:  bash ~/Git/ha-screentime/diagnose.sh

set -uo pipefail
BIOME="$HOME/Library/Biome/streams/restricted/App.InFocus"
KNOW="$HOME/Library/Application Support/Knowledge/knowledgeC.db"
RMADMIN="$HOME/Library/Application Support/com.apple.remotemanagementd/RMAdminStore-Cloud.sqlite"

hr(){ printf '\n=== %s ===\n' "$1"; }

hr "1) iCloud-Account eingeloggt?"
if defaults read MobileMeAccounts Accounts 2>/dev/null | grep -qi AccountID; then
  defaults read MobileMeAccounts Accounts 2>/dev/null \
    | grep -iE 'AccountID|DisplayName' | sed 's/^/   /'
else
  echo "   (KEIN iCloud-Account gefunden — bitte zuerst einloggen)"
fi

hr "2) Biome App.InFocus-Streams (Quelle der iOS-Nutzungsdaten)"
if [ -d "$BIOME" ]; then
  for sub in remote local; do
    echo "   --- $sub/ ---"
    if [ -d "$BIOME/$sub" ]; then
      ls -1 "$BIOME/$sub" 2>/dev/null | sed 's/^/     /' \
        || echo "     (leer)"
      cnt=$(ls -1 "$BIOME/$sub" 2>/dev/null | wc -l | tr -d ' ')
      echo "     -> $cnt Einträge"
    else
      echo "     (nicht vorhanden)"
    fi
  done
else
  echo "   (App.InFocus existiert nicht — noch keine iOS-Sync-Daten oder kein Zugriff)"
fi

hr "3) knowledgeC.db — welche Geräte liefern App-Nutzung?"
if [ -r "$KNOW" ] && command -v sqlite3 >/dev/null 2>&1; then
  echo "   Distinct Geräte-Quellen (ZSOURCE / ZDEVICEID) mit /app/usage:"
  sqlite3 "$KNOW" "
    SELECT DISTINCT
      COALESCE(ZSOURCE.ZDEVICEID,'(lokal/dieser Mac)') AS device
    FROM ZOBJECT
    LEFT JOIN ZSOURCE ON ZOBJECT.ZSOURCE = ZSOURCE.Z_PK
    WHERE ZOBJECT.ZSTREAMNAME = '/app/usage';" 2>/dev/null | sed 's/^/     /' \
    || echo "     (Query fehlgeschlagen — evtl. fehlt Full Disk Access)"
  echo "   Anzahl /app/usage-Events je Gerät (letzte 30 Tage):"
  sqlite3 "$KNOW" "
    SELECT COALESCE(ZSOURCE.ZDEVICEID,'(lokal)') AS device, COUNT(*) AS n
    FROM ZOBJECT
    LEFT JOIN ZSOURCE ON ZOBJECT.ZSOURCE = ZSOURCE.Z_PK
    WHERE ZOBJECT.ZSTREAMNAME = '/app/usage'
      AND ZOBJECT.ZSTARTDATE > (strftime('%s','now','-30 days') - 978307200)
    GROUP BY device ORDER BY n DESC;" 2>/dev/null | sed 's/^/     /' \
    || echo "     (Query fehlgeschlagen)"
else
  echo "   (knowledgeC.db nicht lesbar oder sqlite3 fehlt — Full Disk Access prüfen)"
fi

hr "4) Verwaltete Geräte laut RMAdminStore (nur Settings, zur Kontrolle)"
if [ -r "$RMADMIN" ] && command -v sqlite3 >/dev/null 2>&1; then
  echo "   Tabellen:"
  sqlite3 "$RMADMIN" ".tables" 2>/dev/null | sed 's/^/     /' \
    || echo "     (kein Zugriff)"
else
  echo "   (RMAdminStore-Cloud.sqlite nicht vorhanden/lesbar — normal, wenn keine Verwaltung aktiv)"
fi

hr "FAZIT"
cat <<'EOF'
   -> Erscheint unter (2) oder (3) eine Geräte-ID, die dem iPhone des SOHNES
      entspricht (bzw. Nutzungs-Events, die NICHT von deinen eigenen Geräten
      stammen), dann liefert der Eltern-Account seine Daten -> Phase 1 möglich.
   -> Erscheinen NUR deine eigenen Geräte (dein iPhone + dieser Mac), dann
      bestätigt sich die Recherche: Eltern-Account genügt nicht -> Fallbacks.
   Zur Geräte-Identifikation: bash ~/Git/ha-screentime/devices.sh
EOF
