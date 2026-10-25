import asyncio
import hashlib
import json
from concurrent.futures import ThreadPoolExecutor

import httpx
import pytest

from paper_nas.app import Settings, create_app
from paper_nas.store import Store

PAPER = 'a' * 20
SHA = hashlib.sha256(b'PDF fixture').hexdigest()


class Bytes(httpx.AsyncByteStream):
    async def __aiter__(self):
        yield b'PDF '
        yield b'fixture'


class EngineFixture:
    def __init__(self):
        self.calls = []
        self.jobs = []
        self.failure = False
        self.closed = False

    async def close(self):
        self.closed = True

    async def request(self, method, path, **kwargs):
        self.calls.append((method, path, kwargs))
        if self.failure:
            raise httpx.ReadTimeout('sensitive-internal-host-and-key')
        if method == 'POST' and path == 'jobs':
            await asyncio.sleep(0.03)
            job = {'id': 'b' * 20, 'status': 'running', **kwargs['body']}
            self.jobs.append(job)
            return httpx.Response(202, json={'job': job})
        if path == f'papers/{PAPER}/pdf/info':
            return httpx.Response(200, json={'available': True, 'sha256': SHA, 'page_count': 4})
        if path == f'papers/{PAPER}/pdf':
            return httpx.Response(206, stream=Bytes(), headers={
                'Content-Type': 'application/pdf', 'Content-Length': '11',
                'Content-Range': 'bytes 0-10/40', 'Accept-Ranges': 'bytes',
                'Set-Cookie': 'internal-secret=value'})
        if path.startswith('papers/') and path != f'papers/{PAPER}':
            return httpx.Response(404, json={'error': 'Paper not found'})
        return httpx.Response(200, json={'key': PAPER, 'revision': 3})


@pytest.fixture
async def api(tmp_path):
    token = tmp_path / 'key'
    token.write_text('fixture-private-key')
    settings = Settings(tmp_path, tmp_path / 'native', token, watch=False)
    engine = EngineFixture()
    app = create_app(settings, engine)
    async with app.router.lifespan_context(app):
        async with httpx.AsyncClient(transport=httpx.ASGITransport(app=app), base_url='http://test') as client:
            response = await client.post('/api/v1/auth/devices', json={
                'access_key': 'fixture-private-key', 'device_name': 'Test Mac'})
            credentials = response.json()
            client.headers['Authorization'] = 'Bearer ' + credentials['device']['token']
            yield client, app, engine, settings, credentials


async def test_authentication_storage_and_revocation(api):
    client, app, engine, settings, credentials = api
    devices = (await client.get('/api/v1/devices')).json()['devices']
    assert len(devices) == 1
    assert 'token' not in devices[0] and 'token_hash' not in devices[0]
    with app.state.store.db() as db:
        stored = dict(db.execute('SELECT * FROM devices').fetchone())
    assert stored['token_hash'] != credentials['device']['token']
    assert len(stored['token_hash']) == 64
    assert (settings.state_dir / 'native.sqlite3').stat().st_mode & 0o777 == 0o600
    assert (await client.get('/api/v1/overview', headers={'Authorization': ''})).status_code == 401
    assert (await client.delete('/api/v1/devices/' + credentials['device']['id'])).status_code == 200
    assert (await client.get('/api/v1/overview')).status_code == 401


async def test_login_failures_and_rate_limit(api):
    client, *_ = api
    for _ in range(9):
        r = await client.post('/api/v1/auth/devices', json={'access_key': 'incorrect', 'device_name': 'Mac'})
        assert r.status_code == 401
    r = await client.post('/api/v1/auth/devices', json={'access_key': 'incorrect', 'device_name': 'Mac'})
    assert r.status_code == 429


async def test_api_allowlist_and_mutation_requirements(api):
    client, app, engine, *_ = api
    for path in ['session', 'files/private', '../config', 'admin', 'papers/not-a-key']:
        assert (await client.get('/api/v1/' + path)).status_code == 404
    r = await client.post('/api/v1/jobs', json={'action': 'daily'}, headers={'Origin': 'https://evil.example'})
    assert r.status_code == 403
    assert (await client.post('/api/v1/jobs', json={'action': 'daily'})).status_code == 400
    assert (await client.post('/api/v1/jobs', json={'action': 'shell'})).status_code == 422
    validation = await client.post('/api/v1/auth/devices', json={'access_key': 'fixture-private-key', 'device_name': '', 'unexpected_secret': 'never-echo'})
    assert validation.status_code == 422
    assert 'fixture-private-key' not in validation.text and 'never-echo' not in validation.text
    r = await client.patch('/api/v1/papers/' + PAPER, json={'collection': 'library'}, headers={'Idempotency-Key': 'x' * 20})
    assert r.status_code == 400
    r = await client.post('/api/v1/groups', content=b'{}', headers={'Content-Length': 'invalid'})
    assert r.status_code == 400
    r = await client.post('/api/v1/groups', content=b'{}', headers={'Content-Length': str(3 * 1024 * 1024)})
    assert r.status_code == 413
    assert not any(c[0] in {'POST', 'PUT', 'PATCH'} for c in engine.calls)


async def test_duplicate_jobs_never_execute_twice_and_survive_restart(api):
    client, app, engine, settings, credentials = api
    headers = {'Idempotency-Key': 'same-operation-12345'}
    first, second = await asyncio.gather(*[
        client.post('/api/v1/jobs', json={'action': 'daily'}, headers=headers) for _ in range(2)])
    assert sorted([first.status_code, second.status_code]) == [202, 409]
    assert len(engine.jobs) == 1
    replay = await client.post('/api/v1/jobs', json={'action': 'daily'}, headers=headers)
    assert replay.status_code == 202 and replay.headers['Idempotency-Replayed'] == 'true'
    conflict = await client.post('/api/v1/jobs', json={'action': 'collect'}, headers=headers)
    assert conflict.status_code == 409
    restarted = create_app(settings, engine)
    async with httpx.AsyncClient(transport=httpx.ASGITransport(app=restarted), base_url='http://test', headers=client.headers) as c:
        assert (await c.get('/api/v1/capabilities')).json()['server_id'] == credentials['server_id']
        assert (await c.post('/api/v1/jobs', json={'action': 'daily'}, headers=headers)).status_code == 202
    assert len(engine.jobs) == 1 and engine.jobs[0]['status'] == 'running'


async def test_uncertain_submission_is_not_blindly_retried(api):
    client, app, engine, *_ = api
    engine.failure = True
    headers = {'Idempotency-Key': 'uncertain-operation-12345'}
    r = await client.post('/api/v1/jobs', json={'action': 'daily'}, headers=headers)
    assert r.status_code == 503
    assert 'sensitive' not in r.text and 'fixture-private-key' not in r.text
    engine.failure = False
    assert (await client.post('/api/v1/jobs', json={'action': 'daily'}, headers=headers)).status_code == 409
    assert not engine.jobs


async def test_shared_reading_position_conflicts_and_pdf_versions(api):
    client, app, engine, settings, credentials = api
    path = f'/api/v1/papers/{PAPER}/reading-state'
    assert (await client.get(path)).json()['reading']['revision'] == 0
    payload = {'page': 3, 'section': 'pdf', 'pdf_sha256': SHA, 'revision': 0}
    result = await client.put(path, json=payload)
    assert result.status_code == 200
    assert result.json()['reading']['revision'] == 1
    other = app.state.store.register('Second Mac')
    headers = {'Authorization': 'Bearer ' + other['token']}
    assert (await client.get(path, headers=headers)).json()['reading']['page'] == 3
    assert (await client.put(path, json=payload, headers=headers)).status_code == 409
    assert (await client.put(path, json={**payload, 'revision': 1, 'page': 5})).status_code == 400
    assert (await client.put(path, json={**payload, 'revision': 1, 'pdf_sha256': 'f' * 64})).status_code == 409
    assert Store(settings.state_dir / 'native.sqlite3').reading(PAPER)['page'] == 3
    events = app.state.store.events(0)
    assert events[-1]['kind'] == 'reading.changed'


async def test_authenticated_pdf_stream_forwards_range_not_cookies(api):
    client, app, engine, *_ = api
    r = await client.get(f'/api/v1/papers/{PAPER}/pdf', headers={'Range': 'bytes=0-10'})
    assert r.status_code == 206 and r.content == b'PDF fixture'
    assert r.headers['Content-Range'] == 'bytes 0-10/40'
    assert 'Set-Cookie' not in r.headers
    assert engine.calls[-1][2]['headers']['Range'] == 'bytes=0-10'
    assert r.headers['Cache-Control'] == 'no-store'


def test_durable_event_gap_and_atomic_claim(tmp_path):
    store = Store(tmp_path / 'state.sqlite3')
    with ThreadPoolExecutor(max_workers=5) as pool:
        states = list(pool.map(lambda _: store.claim('device', 'same-key', 'same-body')[0], range(5)))
    assert states.count('new') == 1 and states.count('pending') == 4
    with store.db() as db:
        db.executemany('INSERT INTO events(kind,payload,created) VALUES(?,?,?)', [('change', '{}', 1)] * 10002)
    latest = store.event('final')
    assert store.events(0) == [{'id': latest, 'kind': 'reset', 'payload': {}}]
    assert store.events(latest - 1)[0]['kind'] == 'final'
