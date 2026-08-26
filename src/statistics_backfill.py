#!/usr/bin/env python3
"""
Spielt Tagessummen als Langzeitstatistik nach Home Assistant ein.

Warum das nötig ist: Der Exporter setzt immer nur den Wert des *heutigen*
Tages. Kommen Ereignisse verspätet an — etwa weil die iCloud-Synchronisation
tagelang stand und die Daten anschließend nachgeliefert werden — landen sie
zwar in der CSV, aber die Tagesbalken vergangener Tage in HA bleiben auf dem
falschen Wert stehen. Es gibt keinen Weg, einen Sensor rückwirkend zu setzen.

Deshalb wird der Tagesverlauf als eigene, importierte Statistik geführt
(`hascreentime:...`). Die wird bei jedem Lauf komplett aus der CSV neu
berechnet und überschrieben — sie heilt sich also selbst, sobald fehlende
Daten eintreffen, und ist unabhängig davon, ob der Sensor zum richtigen
Zeitpunkt gepusht wurde oder ob HA zwischendurch neu gestartet ist.

`recorder/import_statistics` gibt es nur über die WebSocket-Schnittstelle,
nicht per REST.
"""

import asyncio
import json
import os
from collections import defaultdict
from datetime import datetime, timedelta

import websockets

from exporter import CATEGORY_LABELS, load_data, slugify, watched_apps

HA_URL = os.getenv("HA_URL", "http://localhost:8123")
HA_TOKEN = os.getenv("HA_TOKEN", "")

# Wie weit zurück Tagessummen gepflegt werden. 35 Tage decken die 28 Tage ab,
# die der Collector aus Biome holt, mit etwas Reserve.
DAYS_BACK = 35

SOURCE = "hascreentime"


def websocket_url() -> str:
    url = HA_URL.rstrip("/")
    if url.startswith("https://"):
        return "wss://" + url[len("https://"):] + "/api/websocket"
    return "ws://" + url[len("http://"):] + "/api/websocket"


def daily_totals(rows: list[dict]) -> dict:
    """
    Tagessummen je Reihe: gesamt, je Gerät, je Kategorie, je beobachteter App.

    Returns: {statistic_suffix: {date: minuten}}
    """
    out: dict[str, dict] = defaultdict(lambda: defaultdict(float))
    cutoff = (datetime.now().astimezone() - timedelta(days=DAYS_BACK)).date()
    watched = set(watched_apps())

    for r in rows:
        day = r["dt"].astimezone().date()
        if day < cutoff:
            continue
        minutes = r["duration"] / 60.0
        out["total"][day] += minutes
        out[f"device_{slugify(r.get('source') or 'unknown')}"][day] += minutes
        out[f"cat_{slugify(r.get('category') or 'Other')}"][day] += minutes
        if r["title"] in watched:
            out[f"app_{slugify(r['title'])}"][day] += minutes
    return out


def build_series(day_values: dict, label: str) -> tuple[dict, list]:
    """
    Baut Metadaten und Punkte für eine importierte Statistik.

    HA erwartet bei Summenstatistiken einen *kumulativen* Wert; die Balken im
    Diagramm sind die Differenz zweier Tage. Lücken werden bewusst mit 0
    gefüllt, damit die Summe nicht springt und der fehlende Tag als leerer
    Balken erscheint statt zu verschwinden.
    """
    if not day_values:
        return {}, []

    start_day = min(day_values)
    end_day = max(day_values)
    stats = []
    running = 0.0
    day = start_day
    while day <= end_day:
        running += round(day_values.get(day, 0.0), 2)
        stats.append({
            "start": datetime.combine(day, datetime.min.time())
                        .astimezone().isoformat(),
            "state": round(day_values.get(day, 0.0), 1),
            "sum": round(running, 1),
        })
        day += timedelta(days=1)

    meta = {
        "has_mean": False,
        "has_sum": True,
        "name": label,
        "source": SOURCE,
        "statistic_id": None,      # wird vom Aufrufer gesetzt
        "unit_of_measurement": "min",
    }
    return meta, stats


async def push(series: list[tuple[str, str, dict]]) -> bool:
    if not HA_TOKEN:
        print("[Statistik] HA_TOKEN nicht gesetzt - übersprungen")
        return False

    try:
        async with websockets.connect(websocket_url(), max_size=None) as ws:
            hello = json.loads(await ws.recv())
            if hello.get("type") != "auth_required":
                print(f"[Statistik] unerwartete Begrüßung: {hello.get('type')}")
                return False
            await ws.send(json.dumps({"type": "auth", "access_token": HA_TOKEN}))
            auth = json.loads(await ws.recv())
            if auth.get("type") != "auth_ok":
                print("[Statistik] Anmeldung fehlgeschlagen")
                return False

            msg_id = 0
            ok = True
            for suffix, label, day_values in series:
                meta, stats = build_series(day_values, label)
                if not stats:
                    continue
                meta["statistic_id"] = f"{SOURCE}:{suffix}"
                msg_id += 1
                await ws.send(json.dumps({
                    "id": msg_id,
                    "type": "recorder/import_statistics",
                    "metadata": meta,
                    "stats": stats,
                }))
                while True:
                    resp = json.loads(await ws.recv())
                    if resp.get("id") == msg_id:
                        break
                if not resp.get("success"):
                    print(f"[Statistik] {meta['statistic_id']}: {resp.get('error')}")
                    ok = False
            print(f"[Statistik] {msg_id} Reihen à {len(stats)} Tage eingespielt")
            return ok
    except Exception as e:
        print(f"[Statistik] Fehler: {e}")
        return False


def main() -> int:
    rows = load_data(0)
    if not rows:
        print("[Statistik] keine Daten")
        return 0

    totals = daily_totals(rows)
    series = []
    for suffix, day_values in sorted(totals.items()):
        if suffix == "total":
            label = "Bildschirmzeit gesamt (täglich)"
        elif suffix.startswith("device_"):
            label = f"Bildschirmzeit {suffix[len('device_'):]} (täglich)"
        elif suffix.startswith("cat_"):
            raw = suffix[len("cat_"):]
            pretty = next((v for k, v in CATEGORY_LABELS.items()
                           if slugify(k) == raw), raw)
            label = f"Bildschirmzeit {pretty} (täglich)"
        else:
            label = f"Bildschirmzeit {suffix[len('app_'):]} (täglich)"
        series.append((suffix, label, day_values))

    return 0 if asyncio.run(push(series)) else 1


if __name__ == "__main__":
    raise SystemExit(main())
