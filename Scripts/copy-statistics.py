#!/usr/bin/env python3
"""
Kopiert importierte Tagesstatistiken (hascreentime:*) unter neue IDs -- etwa
beim Umstieg auf ein Kind-Kuerzel ("total" -> "kind_total"). Die komplette
Historie wandert mit, samt kumulativer Summen; die alten Reihen bleiben stehen.

Muss laufen, BEVOR die App die neuen Reihen zum ersten Mal schreibt: sie setzt
dort an der letzten vorhandenen Summe an.

  HA_URL=... HA_TOKEN=... python3 Scripts/copy-statistics.py <neues_praefix> <suffix> [<suffix> ...]
  z. B.:  ... copy-statistics.py kind_ total app_youtube app_brawl_stars

Mit --dry-run wird nur gezeigt, was kopiert wuerde.
"""

import asyncio
import json
import os
import sys
from datetime import datetime, timedelta, timezone

import websockets

SOURCE = "hascreentime"


async def main(prefix: str, suffixes: list[str], dry_run: bool) -> int:
    url = os.environ["HA_URL"].rstrip("/")
    ws_url = ("wss://" + url[8:] if url.startswith("https://") else "ws://" + url[7:]) + "/api/websocket"
    async with websockets.connect(ws_url, max_size=None) as ws:
        await ws.recv()
        await ws.send(json.dumps({"type": "auth", "access_token": os.environ["HA_TOKEN"]}))
        if json.loads(await ws.recv()).get("type") != "auth_ok":
            print("Anmeldung fehlgeschlagen")
            return 1
        msg_id = 0

        async def call(msg: dict) -> dict:
            nonlocal msg_id
            msg_id += 1
            msg["id"] = msg_id
            await ws.send(json.dumps(msg))
            while True:
                resp = json.loads(await ws.recv())
                if resp.get("id") == msg_id:
                    return resp

        ids = [f"{SOURCE}:{s}" for s in suffixes]
        meta = {m["statistic_id"]: m for m in
                (await call({"type": "recorder/get_statistics_metadata", "statistic_ids": ids}))["result"]}
        start = (datetime.now(timezone.utc) - timedelta(days=3650)).isoformat()
        ok = True
        for suffix in suffixes:
            old_id, new_id = f"{SOURCE}:{suffix}", f"{SOURCE}:{prefix}{suffix}"
            if old_id not in meta:
                print(f"{old_id}: nicht vorhanden -- uebersprungen")
                continue
            points = (await call({"type": "recorder/statistics_during_period", "start_time": start,
                                  "statistic_ids": [old_id], "period": "hour",
                                  "types": ["state", "sum"]}))["result"].get(old_id, [])
            stats = [{"start": datetime.fromtimestamp(p["start"] / 1000, timezone.utc).isoformat(),
                      "state": p.get("state"), "sum": p.get("sum")}
                     for p in points if p.get("sum") is not None]
            if not stats:
                print(f"{old_id}: keine Werte -- uebersprungen")
                continue
            old = meta[old_id]
            print(f"{old_id} -> {new_id}: {len(stats)} Punkte, {stats[0]['start'][:10]} bis "
                  f"{stats[-1]['start'][:10]}, Summe {stats[-1]['sum']}")
            if dry_run:
                continue
            resp = await call({"type": "recorder/import_statistics", "stats": stats, "metadata": {
                "has_mean": False, "has_sum": True, "mean_type": 0, "unit_class": "duration",
                "name": old.get("name"), "source": SOURCE, "statistic_id": new_id,
                "unit_of_measurement": old.get("statistics_unit_of_measurement") or "min"}})
            if not resp.get("success"):
                print(f"   FEHLER: {resp.get('error')}")
                ok = False
        return 0 if ok else 1


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    if len(args) < 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(asyncio.run(main(args[0], args[1:], "--dry-run" in sys.argv)))
