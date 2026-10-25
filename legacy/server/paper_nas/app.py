"""Native-client API for the existing, server-owned research library."""
from __future__ import annotations

import asyncio
import contextlib
import hashlib
import hmac
import json
import os
import re
import time
from collections import defaultdict, deque
from contextlib import asynccontextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Literal

import httpx
from fastapi import Depends, FastAPI, HTTPException, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, ConfigDict, Field
from starlette.background import BackgroundTask

from . import __version__
from .engine import Engine
from .store import Store, digest

KEY = r'[a-f0-9]{20}'
ALLOWED = [
    (r'papers', {'GET'}),
    (rf'papers/{KEY}', {'GET', 'PATCH', 'DELETE'}),
    (rf'papers/{KEY}/pdf', {'GET', 'HEAD', 'POST'}),
    (rf'papers/{KEY}/pdf/info', {'GET'}),
    (rf'papers/{KEY}/download', {'GET'}),
    (rf'papers/{KEY}/figures/[A-Za-z0-9_.-]+', {'GET'}),
    (rf'papers/{KEY}/notes', {'GET', 'POST'}),
    (rf'papers/{KEY}/notes/{KEY}', {'PATCH', 'DELETE'}),
    (r'groups', {'GET', 'POST'}), (rf'groups/{KEY}', {'PATCH', 'DELETE'}),
    (r'jobs', {'GET', 'POST'}), (rf'jobs/{KEY}/(?:cancel|pause|resume|retry)', {'POST'}),
    (rf'jobs/{KEY}/log', {'GET'}),
    (r'overview|skills|models', {'GET'}), (r'config', {'GET', 'PUT'}),
    (r'key', {'PUT', 'DELETE'}), (r'local-index', {'GET', 'POST'}),
    (r'downloads', {'GET'}), (rf'downloads/{KEY}/(?:pause|resume|retry)', {'POST'}),
]


@dataclass
class Settings:
    root: Path
    state_dir: Path
    token_file: Path
    upstream: str = 'http://127.0.0.1:8765'
    watch: bool = True

    @classmethod
    def environment(cls):
        root = Path(os.environ.get('PAPER_NAS_ROOT', '~/research-digest')).expanduser()
        return cls(root, Path(os.environ.get('PAPER_NAS_STATE', '~/paper-nas-data')).expanduser(),
                   Path(os.environ.get('PAPER_NAS_TOKEN_FILE', str(root / '.web-access-token'))).expanduser(),
                   os.environ.get('PAPER_NAS_UPSTREAM', 'http://127.0.0.1:8765'))


class Login(BaseModel):
    model_config = ConfigDict(extra='forbid')
    access_key: str = Field(min_length=6, max_length=512)
    device_name: str = Field(min_length=1, max_length=120)


class Reading(BaseModel):
    model_config = ConfigDict(extra='forbid')
    page: int = Field(ge=1, le=100000)
    section: Literal['report', 'pdf', 'source', 'figures'] = 'report'
    pdf_sha256: str | None = Field(default=None, pattern=r'^[a-f0-9]{64}$')
    revision: int = Field(ge=0)


class JobRequest(BaseModel):
    model_config = ConfigDict(extra='forbid')
    action: Literal['collect', 'extract', 'analyze', 'run', 'inspect', 'add_candidate',
                    'extract_paper', 'analyze_paper', 'brief_paper', 'summarize_paper',
                    'extract_selected', 'analyze_selected', 'daily', 'test_api', 'check_sources', 'reindex']
    key: str | None = Field(default=None, pattern=r'^[a-f0-9]{20}$')
    keys: list[str] | None = None
    arxiv_id: str | None = Field(default=None, max_length=100)
    extract_only: bool | None = None
    resume_run: int | None = Field(default=None, ge=1)


def create_app(settings: Settings | None = None, engine=None):
    settings = settings or Settings.environment()
    store = Store(settings.state_dir / 'native.sqlite3')
    engine = engine or Engine(settings.upstream, settings.token_file)
    attempts = defaultdict(deque)

    async def watcher():
        previous = None
        while True:
            try:
                paths = [settings.root / 'output' / 'state.sqlite3',
                         settings.root / 'output' / 'state.sqlite3-wal',
                         settings.root / 'config.local.yaml']
                paths += list((settings.root / 'output' / 'web-jobs').glob('*.json'))
                paths += list((settings.root / 'output' / 'pdf-downloads').glob('*/state.json'))
                value = tuple(sorted((str(p), p.stat().st_mtime_ns, p.stat().st_size)
                                     for p in paths if p.is_file()))
                if previous is not None and value != previous:
                    store.event('library.changed')
                previous = value
            except OSError:
                pass
            await asyncio.sleep(2)

    @asynccontextmanager
    async def lifespan(_app):
        task = asyncio.create_task(watcher()) if settings.watch else None
        try:
            yield
        finally:
            if task:
                task.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await task
            await engine.close()

    app = FastAPI(title='Paper NAS', version=__version__, lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.store, app.state.engine = store, engine

    @app.middleware('http')
    async def guard(request, call_next):
        # This is a native Bearer API, not a browser-CORS bypass. Browser UI keeps
        # its own same-origin session on the processing service.
        if request.method not in {'GET', 'HEAD', 'OPTIONS'} and request.headers.get('Origin'):
            return JSONResponse({'error': 'Native API does not accept browser mutations'}, status_code=403)
        try:
            length = int(request.headers.get('content-length', '0') or '0')
        except ValueError:
            return JSONResponse({'error': 'Invalid content length'}, status_code=400)
        if length < 0:
            return JSONResponse({'error': 'Invalid content length'}, status_code=400)
        if length > 2 * 1024 * 1024:
            return JSONResponse({'error': 'Request exceeds the JSON limit'}, status_code=413)
        response = await call_next(request)
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Cache-Control'] = 'no-store'
        return response

    @app.exception_handler(HTTPException)
    async def error(_request, exception):
        return JSONResponse({'error': exception.detail}, status_code=exception.status_code)

    @app.exception_handler(RequestValidationError)
    async def validation_error(_request, exception):
        # Pydantic's default error contains the submitted value, including login keys.
        return JSONResponse({'error': '请求字段格式不正确', 'fields': [
            {'field': '.'.join(map(str, item['loc'])), 'message': item['msg']}
            for item in exception.errors()]}, status_code=422)

    @app.exception_handler(httpx.HTTPError)
    async def engine_error(_request, _exception):
        return JSONResponse({'error': '服务器处理服务暂时不可用，请稍后刷新；已提交任务不会因客户端断开而停止。'},
                            status_code=503)

    def device(request: Request):
        authorization = request.headers.get('authorization', '')
        if not authorization.startswith('Bearer ') or len(authorization) > 300:
            raise HTTPException(401, '请连接服务器')
        value = store.authenticate(authorization[7:])
        if not value:
            raise HTTPException(401, '此设备的登录已过期或撤销，请重新连接')
        return value

    @app.get('/health')
    async def health():
        return {'service': 'paper-nas', 'version': __version__, 'api_version': 1}

    @app.post('/api/v1/auth/devices')
    async def login(payload: Login, request: Request):
        ip = request.client.host if request.client else 'local'
        queue, now = attempts[ip], time.monotonic()
        while queue and queue[0] < now - 60:
            queue.popleft()
        if len(queue) >= 10:
            raise HTTPException(429, '连接尝试过多，请一分钟后重试')
        queue.append(now)
        if not hmac.compare_digest(payload.access_key.encode(), settings.token_file.read_text().strip().encode()):
            raise HTTPException(401, '访问密钥不正确')
        response = await engine.request('GET', 'overview')
        if response.status_code != 200:
            raise HTTPException(503, '处理服务暂时不可用')
        value = store.register(payload.device_name.strip())
        return {'device': value, 'server_id': store.server_id(), 'api_version': 1,
                'version': __version__, 'event_cursor': store.cursor()}

    @app.get('/api/v1/capabilities')
    async def capabilities(_device=Depends(device)):
        return {'api_version': 1, 'version': __version__, 'server_id': store.server_id(),
                'features': ['library', 'server_jobs', 'notes', 'pdf', 'reading_state',
                             'events', 'idempotency', 'semantic_search', 'device_sessions'],
                'event_cursor': store.cursor(), 'note_coordinates': 'page-top-left-normalized-v1'}

    @app.get('/api/v1/openapi.json')
    async def schema(_device=Depends(device)):
        return app.openapi()

    @app.get('/api/v1/devices')
    async def devices(_device=Depends(device)):
        return {'devices': store.devices()}

    @app.delete('/api/v1/devices/{identifier}')
    async def revoke(identifier: str, _device=Depends(device)):
        store.revoke(identifier)
        return {'revoked': True}

    @app.get('/api/v1/events')
    async def events(request: Request, after: int = 0, current=Depends(device)):
        try:
            cursor = max(0, int(request.headers.get('last-event-id', after)))
        except (ValueError, TypeError):
            raise HTTPException(400, 'Invalid event cursor') from None

        async def stream():
            nonlocal cursor
            heartbeat = time.monotonic()
            while not await request.is_disconnected():
                # An existing event connection must also observe revocation.
                try:
                    device(request)
                except HTTPException:
                    return
                for entry in store.events(cursor):
                    yield f"id: {entry['id']}\nevent: {entry['kind']}\ndata: {json.dumps(entry['payload'])}\n\n"
                    cursor = entry['id']
                if time.monotonic() - heartbeat >= 15:
                    yield ': heartbeat\n\n'
                    heartbeat = time.monotonic()
                await asyncio.sleep(1)
        return StreamingResponse(stream(), media_type='text/event-stream',
                                 headers={'X-Accel-Buffering': 'no'})

    async def paper_exists(key):
        if not re.fullmatch(KEY, key):
            raise HTTPException(404, 'Paper not found')
        response = await engine.request('GET', f'papers/{key}')
        if response.status_code != 200:
            raise HTTPException(response.status_code, 'Paper not found')
        return response.json()

    @app.get('/api/v1/papers/{key}/reading-state')
    async def reading(key: str, _device=Depends(device)):
        await paper_exists(key)
        return {'reading': store.reading(key)}

    @app.put('/api/v1/papers/{key}/reading-state')
    async def save_reading(key: str, payload: Reading, current=Depends(device)):
        await paper_exists(key)
        if payload.pdf_sha256:
            info = await engine.request('GET', f'papers/{key}/pdf/info')
            value = info.json()
            if info.status_code != 200 or value.get('sha256') != payload.pdf_sha256:
                raise HTTPException(409, 'PDF 版本已变化，请重新打开原文')
            if payload.page > value.get('page_count', payload.page):
                raise HTTPException(400, 'PDF page is outside the document')
        saved = store.save_reading(key, payload.model_dump(), current['id'])
        if saved is None:
            return JSONResponse({'error': '其他设备已更新阅读位置', 'reading': store.reading(key)}, status_code=409)
        store.event('reading.changed', {'key': key, 'device': current['id']})
        return {'reading': saved}

    async def forward(path, request, current, explicit=None):
        method = request.method
        if not any(re.fullmatch(pattern, path) and method in verbs for pattern, verbs in ALLOWED):
            raise HTTPException(404, 'API route not found')
        if '..' in path:
            raise HTTPException(400, 'Invalid resource path')
        mutating = method not in {'GET', 'HEAD'}
        body = explicit
        if mutating and body is None:
            raw = await request.body()
            if len(raw) > 2 * 1024 * 1024:
                raise HTTPException(413, 'Request is too large')
            try:
                body = json.loads(raw) if raw else {}
            except ValueError:
                raise HTTPException(400, 'Invalid JSON') from None
            if not isinstance(body, dict):
                raise HTTPException(400, 'Expected a JSON object')
        if method == 'PATCH' and (re.fullmatch(rf'papers/{KEY}', path) or re.fullmatch(rf'groups/{KEY}', path)):
            if type(body.get('revision')) is not int:
                raise HTTPException(400, 'A revision is required')
        request_id = request.headers.get('idempotency-key', '')
        if mutating:
            if not re.fullmatch(r'[A-Za-z0-9_-]{16,128}', request_id):
                raise HTTPException(400, 'Provide a unique Idempotency-Key')
            fingerprint = digest(json.dumps([method, path, sorted(request.query_params.multi_items()), body], sort_keys=True))
            status, result = store.claim(current['id'], request_id, fingerprint)
            if status == 'conflict':
                raise HTTPException(409, 'Request identifier belongs to another operation')
            if status == 'pending':
                raise HTTPException(409, '此操作已提交但尚未确认，请先刷新任务或数据，避免重复操作')
            if status == 'replay':
                return JSONResponse(result[1], status_code=result[0], headers={'Idempotency-Replayed': 'true'})
        headers = {}
        if value := request.headers.get('range'):
            headers['Range'] = value
        response = await engine.request(method, path, params=request.query_params.multi_items(),
                                        body=body, headers=headers, stream=not mutating)
        content_type = response.headers.get('content-type', '')
        if 'application/json' in content_type:
            await response.aread()
            value = response.json()
            await response.aclose()
            if mutating:
                store.finish(current['id'], request_id, response.status_code, value)
                if response.status_code < 400:
                    store.event('library.changed', {'resource': path, 'device': current['id']})
            return JSONResponse(value, status_code=response.status_code)
        allowed_headers = {'content-type', 'content-length', 'content-range', 'accept-ranges', 'content-disposition'}
        headers = {k: v for k, v in response.headers.items() if k.lower() in allowed_headers}
        return StreamingResponse(response.aiter_raw(), status_code=response.status_code,
                                 headers=headers, background=BackgroundTask(response.aclose))

    @app.post('/api/v1/jobs', status_code=202)
    async def submit_job(payload: JobRequest, request: Request, current=Depends(device)):
        return await forward('jobs', request, current, payload.model_dump(exclude_none=True))

    @app.api_route('/api/v1/{path:path}', methods=['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'])
    async def resource(path: str, request: Request, current=Depends(device)):
        return await forward(path, request, current)

    return app


def main():
    import uvicorn
    os.umask(0o077)
    uvicorn.run(create_app(), host=os.environ.get('PAPER_NAS_HOST', '127.0.0.1'),
                port=int(os.environ.get('PAPER_NAS_PORT', '8787')), access_log=False,
                proxy_headers=False)


if __name__ == '__main__':
    main()
