#!/usr/bin/env python3
"""Register a local preview device without printing credentials or changing Keychain."""

import json
import os
from pathlib import Path

import httpx

root = Path(__file__).resolve().parents[1]
config = json.loads((root / ".runtime" / "connection.json").read_text())
with httpx.Client(base_url="http://127.0.0.1:8788", timeout=15) as client:
    response = client.post(
        "/api/v2/auth/devices",
        json={
            "access_key": (Path(config["state_dir"]) / "access-key").read_text().strip(),
            "device_name": "Mac v2 local preview",
        },
    )
    response.raise_for_status()
    auth = response.json()
destination = root / ".runtime" / "preview-connection.json"
fd = os.open(destination, os.O_CREAT | os.O_WRONLY | os.O_TRUNC, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, "w") as output:
    json.dump(
        {
            "serverURL": "http://127.0.0.1:8788",
            "token": auth["device"]["token"],
            "deviceID": auth["device"]["id"],
            "serverID": auth["server_id"],
            "apiVersion": 2,
        },
        output,
    )
print(f"Preview connection saved to {destination}. Run bash scripts/preview-v2.sh from the project root.")
