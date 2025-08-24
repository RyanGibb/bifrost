import sys
import redis
import json
import time

def send_event(hub_id: str, event_type: str, event_data: dict | None = None):
    r = redis.Redis()
    event = {
    "type": event_type,
    "timestamp": time.time(),
    "data": event_data or {}}
    channel = f"iot:events:{hub_id}"
    r.publish(channel, json.dumps(event))
    print(f"Sent {event_type} to {channel}")
    if event_data:
        print(f"Event data: {json.dumps(event_data, indent=2)}")

if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} HUB_ID EVENT_TYPE [JSON_DATA]")
        print("\nSimple events:")
        print(" python hub_client.py room42 USER_ENTERED_ROOM")
        print("\nComplex events with data:")
        print(" python hub_client.py exec MULTIPLE_USERS_ENTERED '{\"users\": [\"john.smith@company.com\", \"jane.doe@company.com\"]}'")
        print(" python hub_client.py exec SCHEDULED_MEETING_STARTED '{\"meeting_id\": \"proj_alpha_review\"}'")
        print("\nHub IDs: room42, exec, alpha, beta, open, server")
        sys.exit(1)

    hub_id = sys.argv[1]
    event_type = sys.argv[2]
    event_data = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None

    send_event(hub_id, event_type, event_data)