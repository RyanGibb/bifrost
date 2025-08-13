#!/usr/bin/env python3
import sys
import redis
import json
import time

def send_event(hub_id: str, event_type: str):
    r = redis.Redis()
    event = {
        "type": event_type,
        "timestamp": time.time(),
    }
    channel = f"iot:events:{hub_id}"
    r.publish(channel, json.dumps(event))
    print(f"Sent {event_type} to {channel}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} HUB_ID EVENT_TYPE")
        print("Example: hub_client.py room42 USER_ENTERED_ROOM")
        sys.exit(1)
    send_event(sys.argv[1], sys.argv[2])
