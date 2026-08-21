#!/usr/bin/env python3
"""
Ergänzt die Ansicht "Bildschirmzeit" im Standard-Dashboard um Karten für
Kategorien, beobachtete Apps und den Tagesverlauf.

Geht bewusst über die WebSocket-API (lovelace/config/save) statt direkt in
.storage zu schreiben: HA hält die Dashboard-Konfiguration im Speicher, eine
Dateiänderung würde beim nächsten Speichern aus der Oberfläche verlorengehen.

Aufruf:  python add_cards.py <token> [--dry-run]
"""

import asyncio
import json
import sys

import aiohttp

URL = "ws://localhost:8123/api/websocket"
VIEW_TITLE = "Bildschirmzeit"

CATEGORY_SENSORS = [
    ("sensor.screentime_cat_games", "Spiele"),
    ("sensor.screentime_cat_social", "Social"),
    ("sensor.screentime_cat_media", "Medien"),
    ("sensor.screentime_cat_ai", "KI"),
    ("sensor.screentime_cat_communication", "Kommunikation"),
    ("sensor.screentime_cat_browser", "Browser"),
    ("sensor.screentime_cat_school", "Schule"),
]

WATCHED_SENSORS = [
    ("sensor.screentime_app_brawl_stars", "Brawl Stars"),
    ("sensor.screentime_app_splash", "Splash"),
    ("sensor.screentime_app_youtube", "YouTube"),
    ("sensor.screentime_app_whatsapp", "WhatsApp"),
    ("sensor.screentime_app_instagram", "Instagram"),
]

# Die Attribut-Schlüssel, die keine App bzw. Kategorie sind.
SKIP = "['friendly_name','icon','unit_of_measurement','state_class','last_updated','device_class']"

# Robust gegen fehlende Entities: die Sensoren werden per /api/states gesetzt
# und sind nach einem HA-Neustart kurzzeitig weg -- ohne Guard wirft die Karte
# dann im Minutentakt Template-Fehler ins Log.
MARKDOWN = """## Heute: {{ states('sensor.screentime_total') }} min

{% set apps = state_attr('sensor.screentime_top_apps', 'friendly_name') %}
{%- if apps is none %}
_Noch keine Daten -- der nächste Lauf füllt die Werte._
{%- else %}
**Top-Apps**
{%- set a = states.sensor.screentime_top_apps.attributes %}
{%- set skip = ['friendly_name','icon','unit_of_measurement','state_class','last_updated','device_class','minutes'] %}
{%- for item in (a.items() | rejectattr('0','in', skip) | list | sort(attribute='1', reverse=true)) %}
- {{ item[0] }}: {{ item[1] }} min
{%- endfor %}

**Kategorien**
{%- set c = states.sensor.screentime_by_category.attributes %}
{%- for item in (c.items() | selectattr('0','match','category_') | list | sort(attribute='1', reverse=true)) %}
{%- if item[1] > 0 %}
- {{ item[0] | replace('category_', '') }}: {{ item[1] }} min
{%- endif %}
{%- endfor %}
{%- endif %}
"""

NEW_CARDS = [
    {
        "type": "markdown",
        "title": "Was steckt dahinter?",
        "content": MARKDOWN,
    },
    {
        "type": "entities",
        "title": "Kategorien heute",
        "entities": [{"entity": e, "name": n} for e, n in CATEGORY_SENSORS],
    },
    {
        "type": "entities",
        "title": "Apps im Blick",
        "entities": [{"entity": e, "name": n} for e, n in WATCHED_SENSORS],
    },
    {
        "type": "statistics-graph",
        "title": "Bildschirmzeit je Tag",
        "chart_type": "bar",
        "period": "day",
        "days_to_show": 30,
        "stat_types": ["sum"],
        "entities": ["sensor.screentime_total"],
    },
]

# Karten, die dieses Skript erzeugt hat — an den Titeln wiedererkennbar,
# damit ein erneuter Lauf sie ersetzt statt zu duplizieren.
OWNED_TITLES = {c["title"] for c in NEW_CARDS}


async def main() -> int:
    token = sys.argv[1]
    dry = "--dry-run" in sys.argv

    async with aiohttp.ClientSession() as session:
        async with session.ws_connect(URL) as ws:
            msg_id = 0

            async def send(payload: dict) -> dict:
                nonlocal msg_id
                msg_id += 1
                payload["id"] = msg_id
                await ws.send_json(payload)
                while True:
                    data = json.loads(await ws.receive_str())
                    if data.get("id") == msg_id:
                        return data

            # Auth
            hello = json.loads(await ws.receive_str())
            if hello.get("type") != "auth_required":
                print("unerwartete Begrüßung:", hello)
                return 1
            await ws.send_json({"type": "auth", "access_token": token})
            auth = json.loads(await ws.receive_str())
            if auth.get("type") != "auth_ok":
                print("Auth fehlgeschlagen:", auth)
                return 1

            got = await send({"type": "lovelace/config", "url_path": None})
            if not got.get("success"):
                print("config lesen fehlgeschlagen:", got.get("error"))
                return 1
            config = got["result"]

            views = config.get("views", [])
            target = next((v for v in views if v.get("title") == VIEW_TITLE), None)
            if target is None:
                print(f"Ansicht '{VIEW_TITLE}' nicht gefunden.")
                return 1

            cards = target.get("cards", []) or []
            before = len(cards)
            # eigene Karten aus früheren Läufen entfernen, fremde unangetastet lassen
            cards = [c for c in cards if c.get("title") not in OWNED_TITLES]
            removed = before - len(cards)
            cards.extend(NEW_CARDS)
            target["cards"] = cards

            print(f"Ansicht '{VIEW_TITLE}': {before} Karten vorher, "
                  f"{removed} eigene ersetzt, {len(cards)} nachher")
            for c in cards:
                print(f"   - {c.get('title', c.get('type'))}")

            if dry:
                print("(dry-run, nichts gespeichert)")
                return 0

            saved = await send({"type": "lovelace/config/save",
                                "url_path": None, "config": config})
            if not saved.get("success"):
                print("Speichern fehlgeschlagen:", saved.get("error"))
                return 1
            print("gespeichert ✓")
            return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
