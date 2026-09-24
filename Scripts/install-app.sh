#!/usr/bin/env bash
#
# Installiert die gebaute App nach /Applications.
#
# Abweichung von den Schwester-Apps (die laufen produktiv aus ~/Git/<repo>/dist/):
# HAScreenTime lief frueher in einem eigenen Sammel-Benutzer, der das Home des
# Entwicklers nicht betreten konnte; /Applications ist fuer alle lesbar und fuer
# Admins ohne sudo beschreibbar. Der Selbst-Update-Mechanismus setzt darauf auf.
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
# Damit die App sich auch als Standardbenutzer selbst aktualisieren kann (ohne
# Umzug an einen anderen Pfad, der erteilte Berechtigungen kosten wuerde),
# ist genau dieses Bundle fuer alle beschreibbar.
chmod -R a+w "$DST"

echo "==> Fertig."
cat <<'EOF'

Nächste Schritte (in der Sitzung, in der die App laufen soll):

  1. /Applications/HAScreenTime.app starten.
  2. Beim ersten Start fragt macOS nach den Bedienungshilfen: Systemeinstellungen
     -> Datenschutz & Sicherheit -> Bedienungshilfen -> HAScreenTime einschalten.
     Die App liest die Werte aus Familie -> Bildschirmzeit.
  3. In den Einstellungen der App: Home-Assistant-URL + Token, Name des Kindes
     (wie unter Familie aufgefuehrt), Mail-Empfaenger.
  4. "Bei der Anmeldung starten" aktivieren.
EOF
