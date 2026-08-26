#!/usr/bin/env bash
#
# Installiert die gebaute App nach /Applications.
#
# Abweichung von den Schwester-Apps: die laufen produktiv aus ~/Git/<repo>/dist/.
# Das geht hier NICHT — die App läuft im Sammel-Benutzer (Apple-ID des Kindes),
# und Home-Verzeichnisse sind drwxr-x---, für ihn also nicht betretbar. /Applications ist
# für beide Benutzer lesbar und für Admins ohne sudo beschreibbar.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/dist/HAScreenTime.app"
DST="/Applications/HAScreenTime.app"

if [[ ! -d "$SRC" ]]; then
  echo "error: $SRC fehlt — zuerst Scripts/make-app.sh ausführen." >&2
  exit 1
fi

RUNNING="$(pgrep -f "$DST/Contents/MacOS/HAScreenTime" || true)"
if [[ -n "$RUNNING" ]]; then
  echo "ABBRUCH: HAScreenTime läuft gerade aus /Applications (PID: ${RUNNING//$'\n'/ })." >&2
  echo "         Erst beenden (Menüleiste -> Beenden), dann erneut installieren." >&2
  echo "         Achtung: läuft die App im anderen Benutzer, dort beenden." >&2
  exit 1
fi

echo "==> Installiere nach $DST"
rm -rf "$DST"
cp -R "$SRC" "$DST"
chmod -R a+rX "$DST"
# Der Sammel-Benutzer ist Standardbenutzer und darf /Applications nicht
# beschreiben. Damit die App sich selbst aktualisieren kann (ohne Umzug an einen
# anderen Pfad, der den Festplattenvollzugriff kosten wuerde), bekommt er
# Schreibrecht auf genau dieses Bundle.
chmod -R a+w "$DST"

echo "==> Fertig."
cat <<'EOF'

Nächste Schritte im Sammel-Benutzer (per Bildschirmfreigabe anmelden,
NICHT über den schnellen Benutzerwechsel):

  1. /Applications/HAScreenTime.app starten
  2. Systemeinstellungen -> Datenschutz & Sicherheit -> Festplattenvollzugriff
     -> HAScreenTime.app hinzufügen und aktivieren, danach App neu starten.
     (Ohne Festplattenvollzugriff kommt die App nicht an ~/Library/Biome.)
  3. In den Einstellungen der App: Home-Assistant-URL + Token, Geräte,
     Mail-Empfänger eintragen.
  4. "Bei der Anmeldung starten" aktivieren.
EOF
