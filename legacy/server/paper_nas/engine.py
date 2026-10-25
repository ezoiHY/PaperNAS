"""Authenticated adapter to the independently supervised processing engine.

The adapter never starts or terminates jobs on connection lifecycle changes.
Mutating requests are not retried after transport failures.
"""
import asyncio
from pathlib import Path

import httpx


class Engine:
    def __init__(self, base_url: str, token_file: Path):
        self.base_url = base_url.rstrip('/')
        self.token_file = token_file
        self.client = httpx.AsyncClient(base_url=self.base_url, timeout=httpx.Timeout(60, connect=8),
                                        trust_env=False, follow_redirects=False)
        self.lock = asyncio.Lock()
        self.signed_in = False

    async def authenticate(self):
        async with self.lock:
            if self.signed_in:
                return
            token = self.token_file.read_text().strip()
            response = await self.client.post('/api/session', json={'token': token},
                                              headers={'Origin': self.base_url})
            response.raise_for_status()
            self.signed_in = True

    async def request(self, method, path, *, params=None, body=None, headers=None, stream=False):
        await self.authenticate()
        values = {'Origin': self.base_url, **(headers or {})}
        request = self.client.build_request(method, '/api/' + path, params=params,
                                           json=body, headers=values)
        response = await self.client.send(request, stream=stream)
        if response.status_code == 401:
            # An explicit 401 is guaranteed to precede the engine mutation.
            await response.aclose()
            self.signed_in = False
            await self.authenticate()
            request = self.client.build_request(method, '/api/' + path, params=params,
                                               json=body, headers=values)
            response = await self.client.send(request, stream=stream)
        return response

    async def close(self):
        await self.client.aclose()
