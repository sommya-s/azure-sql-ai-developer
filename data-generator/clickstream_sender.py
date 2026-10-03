#!/usr/bin/env python3
"""Replay the generated clickstream into a Fabric Eventstream (custom endpoint source).

In Fabric: Eventstream -> Add source -> Custom endpoint -> "Event Hub" protocol tab ->
copy the *connection string - primary key* (it contains EntityPath=...).

    pip install azure-eventhub
    export EVENTSTREAM_CONNECTION_STRING="Endpoint=sb://...;EntityPath=es_..."
    python clickstream_sender.py --file output/stream/clickstream_replay.jsonl --speed 60

Timestamps are shifted so the first event is "now"; --speed 60 replays one hour of
recorded traffic per minute. Use --inject-late to send ~3% of events 2-10 minutes late
(useful for the watermark / late-data exercises in DP-700 lab 6).
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import random
import time

from azure.eventhub import EventData, EventHubProducerClient


def parse_ts(s: str) -> dt.datetime:
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00"))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file", default="output/stream/clickstream_replay.jsonl")
    ap.add_argument("--speed", type=float, default=60.0, help="replay speed multiplier")
    ap.add_argument("--max-events", type=int, default=20000)
    ap.add_argument("--inject-late", action="store_true")
    args = ap.parse_args()

    conn = os.environ["EVENTSTREAM_CONNECTION_STRING"]
    producer = EventHubProducerClient.from_connection_string(conn)
    rng = random.Random(7)

    with open(args.file, encoding="utf-8") as f:
        events = [json.loads(line) for _, line in zip(range(args.max_events), f)]
    t0_recorded = parse_ts(events[0]["event_time"])
    t0_wall = dt.datetime.now(dt.timezone.utc)
    held_back: list[tuple[float, dict]] = []
    sent = 0

    with producer:
        batch = producer.create_batch()
        for e in events:
            offset = (parse_ts(e["event_time"]) - t0_recorded).total_seconds() / args.speed
            due = t0_wall + dt.timedelta(seconds=offset)
            sleep = (due - dt.datetime.now(dt.timezone.utc)).total_seconds()
            if sleep > 0:
                if len(batch) > 0:
                    producer.send_batch(batch)
                    batch = producer.create_batch()
                time.sleep(min(sleep, 5))
            e["event_time"] = due.isoformat(timespec="seconds").replace("+00:00", "Z")
            e["sent_at"] = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
            if args.inject_late and rng.random() < 0.03:
                held_back.append((time.time() + rng.uniform(120, 600), e))
                continue
            # release late events whose delay has passed
            ready = [x for x in held_back if x[0] <= time.time()]
            held_back = [x for x in held_back if x[0] > time.time()]
            for _, late in ready + [(0, e)]:
                try:
                    batch.add(EventData(json.dumps(late)))
                except ValueError:  # batch full
                    producer.send_batch(batch)
                    batch = producer.create_batch()
                    batch.add(EventData(json.dumps(late)))
                sent += 1
            if sent % 500 == 0:
                print(f"sent {sent} events, last event_time={e['event_time']}")
        for _, late in held_back:
            try:
                batch.add(EventData(json.dumps(late)))
            except ValueError:
                producer.send_batch(batch)
                batch = producer.create_batch()
                batch.add(EventData(json.dumps(late)))
        if len(batch) > 0:
            producer.send_batch(batch)
    print(f"done: {sent + len(held_back)} events")


if __name__ == "__main__":
    main()
