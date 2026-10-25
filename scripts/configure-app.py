#!/usr/bin/env python3
"""Add one explicit trusted HTTP host to a built app, never to source defaults."""

import ipaddress
import plistlib
import re
import sys
from pathlib import Path

path, host = Path(sys.argv[1]), sys.argv[2].lower()
try:
    ipaddress.ip_address(host)
except ValueError:
    if not re.fullmatch(r"[a-z0-9](?:[a-z0-9.-]{0,251}[a-z0-9])?", host) or ".." in host:
        raise SystemExit("PAPERNAS_HTTP_HOST must be one hostname or IP address, without a scheme, port or path.")
with path.open("rb") as stream:
    content = plistlib.load(stream)
content.setdefault("NSAppTransportSecurity", {}).setdefault("NSExceptionDomains", {})[host] = {
    "NSExceptionAllowsInsecureHTTPLoads": True
}
with path.open("wb") as stream:
    plistlib.dump(content, stream, sort_keys=False)
