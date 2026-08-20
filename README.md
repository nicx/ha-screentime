# ha-screentime

Apple-Bildschirmzeit eines Familienmitglieds app-genau als Sensoren in Home Assistant —
als autarke macOS-Menüleisten-App.

## Warum der Umweg über einen zweiten Benutzer

Screen-Time-Daten sind Ende-zu-Ende-verschlüsselt (CloudKit) und existieren nur
entschlüsselt auf einem Gerät, das im **jeweiligen** Apple-Account angemeldet ist.

Empirisch geprüft und verworfen:

- **iCloud-Web / API** — existiert nicht, `pyicloud` & Co. können Screen Time nicht.
- **Eltern-Account (Family Sharing)** — liefert die Daten des Kindes **nicht**. Nach
  vollständigem Setup (iCloud-Login, „Über Geräte synchronisieren“, Full Disk Access)
  tauchten in `~/Library/Biome` ausschließlich eigene und geteilte Haushaltsgeräte auf.
  Die Biome-Synchronisation ist Apple-ID-gebunden.
- **Eigene iOS-App (`DeviceActivity`)** — liefert nur Kategorie-/Gesamtzeiten, **nicht
  app-genau**, kostet 99 €/Jahr (auch zum Testen — ein kostenloser Personal Team kann
  weder App Groups noch das `family-controls`-Entitlement aktivieren) und deckt mehrere
  Geräte nur mit App-Installation pro Gerät ab.
- **Netzwerk (UniFi/NextDNS), MS Family Safety** — kein app-genaues Signal in HA.

Bleibt: ein **separater macOS-Benutzer**, angemeldet in der Apple-ID des Kindes, mit
**ausschließlich** aktivierter Screen-Time-Synchronisation (iCloud Drive, Fotos, Mail,
Schlüsselbund bewusst aus). Dort synchronisiert iCloud die Nutzung **aller** Geräte des
Kindes nach `~/Library/Biome`, wo sie ausgelesen werden kann.

## Architektur

```
Sammel-Benutzer (Apple-ID des Kindes)          Haupt-Benutzer
┌──────────────────────────────────┐          ┌──────────────────┐
│ HAScreenTime.app                 │  REST    │ Home Assistant   │
│  ├─ Timer (Standard 30 min)      │─────────▶│  sensor.         │
│  ├─ Runtime/python  (autark)     │  /api/   │  screentime_*    │
│  ├─ payload/run.py               │  states  │                  │
│  │    ├─ collector.py  ← Biome   │          │  Automation:     │
│  │    └─ exporter.py   → HA      │          │  Totmann-Schalter│
│  └─ Mail bei Problemen (MailRelay)│         └──────────────────┘
└──────────────────────────────────┘
```

Die App ist **autark**: eine relocatable CPython 3.13 samt aller Abhängigkeiten
(`requests`, `python-dotenv`, `aw-import-screentime`, `ccl-segb`) steckt im Bundle unter
`Contents/Resources/Runtime`. Es gibt kein externes venv und keine Abhängigkeit von einer
Python-Installation des Systems.

### Warum der Totmann-Schalter in Home Assistant liegt

Die App kann ihren **eigenen** Ausfall nicht melden: Ist der Sammel-Benutzer nach einem
Neustart nicht angemeldet, läuft die App nicht — und iCloud synchronisiert dann ohnehin
keine neuen Daten. Deshalb wacht HA von außen (Automation
`screen_time_erfassung_ausgefallen`): kommt >12 h kein Sensor-Update, gibt es eine
Meldung. Alles andere (Lauf fehlgeschlagen, Tageslimit, Tagesbericht) meldet die App
selbst per Mail über den lokalen MailRelay.

## Bauen

```bash
git clone https://github.com/ActivityWatch/aw-import-screentime.git   # Biome/SEGB-Parser
bash Scripts/bundle-runtime.sh                                        # Runtime + Deps (~100 MB)
CODESIGN_IDENTITY="nicx Selfsign" bash Scripts/make-app.sh            # dist/HAScreenTime.app
bash Scripts/install-app.sh                                           # -> /Applications
```

Signieren mit einer **stabilen** Identität, nicht ad-hoc: ad-hoc ändert bei jedem Build
den CDHash, wodurch macOS erteilte Berechtigungen (u. a. Festplattenvollzugriff) verwirft.

Die App liegt in `/Applications` statt wie die Schwester-Apps in `~/Git/<repo>/dist/` —
der Sammel-Benutzer kann das Home des Hauptbenutzers (`drwxr-x---`) nicht betreten.

## Einrichten (im Sammel-Benutzer)

Anmeldung **per Bildschirmfreigabe**, nicht über den schnellen Benutzerwechsel: Letzterer
lässt auf diesem Mac reproduzierbar den WindowServer hängen (Watchdog-Kill), was **beide**
Sitzungen abmeldet und alle Dienste des Haupt-Benutzers mitreißt.

1. Apple-ID des Kindes anmelden, Bildschirmzeit + „Über Geräte synchronisieren“ aktivieren,
   alle übrigen iCloud-Dienste aus.
2. `/Applications/HAScreenTime.app` starten.
3. Festplattenvollzugriff für die App erteilen (ohne den kommt sie nicht an `~/Library/Biome`),
   danach App neu starten.
4. In den Einstellungen: HA-URL + Long-Lived-Token, Geräte (`Name:UUID,…`), Mail-Empfänger.
5. „Bei der Anmeldung starten“ aktivieren.

Geräte-IDs ermitteln: `bash devices.sh` (Full Disk Access nötig) listet alle
synchronisierten Geräte samt Top-Apps — daran erkennt man, welches Gerät wem gehört.

## Diagnose

| Skript | Zweck |
|---|---|
| `diagnose.sh` | Prüft iCloud-Login, Biome-Streams, knowledgeC — Grundvoraussetzungen |
| `devices.sh` | Listet alle Geräte je Plattform samt Top-Apps |
| `deploy.sh` | Kopiert die Diagnose-Skripte nach `/Users/Shared/ha-screentime` |

Achtung `aw-import-screentime`: Der Default ist `--platform 2` (iPhone). Ein iPad ist
**platform 1** und liefert ohne den passenden Schalter stillschweigend null Events —
`collector.py` ermittelt die Plattform deshalb selbst aus `sync.db`.

## Sensoren

`sensor.screentime_total`, `sensor.screentime_<gerät>`, `sensor.screentime_top_app`,
`sensor.screentime_by_category`, `sensor.screentime_top_apps` — Minuten des laufenden
Tages, Aufschlüsselung in den Attributen. Über `state_class: measurement` führt HA
Langzeitstatistiken, der Verlauf überlebt also die `purge_keep_days` des Recorders.

Die Werte werden per `/api/states` gesetzt und überleben einen **HA-Neustart nicht** —
beim nächsten Lauf der App sind sie wieder da (max. ein Intervall Lücke).

## Lizenz

MIT (siehe `LICENSE`). Enthält Code aus [nichtlegacy/screentime](https://github.com/nichtlegacy/screentime),
ebenfalls MIT — siehe `LICENSE-upstream-screentime`.
