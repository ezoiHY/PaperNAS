"""Exercise the unchanged processing engine through actual loopback HTTP.

Set PAPER_NAS_ENGINE_SOURCE to the existing research-digest source checkout.
The fixture uses a temporary database/PDF and cannot touch the user's library.
"""
import asyncio
import os
import sys
import threading
import uuid
from pathlib import Path

import httpx
import pytest

from paper_nas.app import Settings, create_app

ENGINE_SOURCE = os.environ.get('PAPER_NAS_ENGINE_SOURCE')
pytestmark = pytest.mark.skipif(not ENGINE_SOURCE, reason='Set PAPER_NAS_ENGINE_SOURCE for the engine contract test')


async def test_real_engine_notes_groups_config_and_pdf(tmp_path, monkeypatch):
    sys.path.insert(0, str(Path(ENGINE_SOURCE) / 'src'))
    import yaml
    from pypdf import PdfWriter
    from research_digest import web
    from research_digest.models import Config, Paper
    from research_digest.pdfs import ensure_pdf
    from research_digest.pdf_queue import PDFDownloadManager
    from research_digest.semantic import LocalIndex
    from research_digest.storage import Store, paper_key

    for key in ['RESEARCH_LLM_API_KEY', 'RESEARCH_LLM_MODEL', 'RESEARCH_LLM_BASE_URL']:
        monkeypatch.delenv(key, raising=False)
    monkeypatch.setattr(PDFDownloadManager, 'start', lambda self: None)
    monkeypatch.setattr(LocalIndex, 'start', lambda self: None)
    configuration = tmp_path / 'config.local.yaml'
    root = tmp_path / 'output'
    configuration.write_text(yaml.safe_dump({'output_dir': str(root), 'sources': [], 'daily': {'enabled': False}}))
    engine = web.create_server(configuration, host='127.0.0.1', port=0)
    worker = threading.Thread(target=engine.serve_forever, daemon=True)
    worker.start()
    origin = f'http://127.0.0.1:{engine.server_address[1]}'
    p = Paper(source='local', source_id='native-contract', title='Synthetic API test fixture',
              url='https://example.test/fixture', authors=['Test Fixture'])
    store = Store(root)
    store.upsert(p)
    store.set_collection(p.identity, 'library')
    store.close()
    key = paper_key(p)
    source_pdf = tmp_path / 'fixture.pdf'
    writer = PdfWriter()
    writer.add_blank_page(width=612, height=792)
    with source_pdf.open('wb') as f:
        writer.write(f)
    info = ensure_pdf(p, Config(), root / 'papers' / key, local_path=source_pdf)
    native = create_app(Settings(tmp_path, tmp_path / 'native', tmp_path / '.web-access-token', origin, watch=False))
    try:
        async with native.router.lifespan_context(native):
            async with httpx.AsyncClient(transport=httpx.ASGITransport(app=native), base_url='http://native') as client:
                login = await client.post('/api/v1/auth/devices', json={'access_key': engine.state.access_token, 'device_name': 'Contract Mac'})
                assert login.status_code == 200, login.text
                client.headers['Authorization'] = 'Bearer ' + login.json()['device']['token']
                async def mutate(method, path, payload):
                    return await client.request(method, '/api/v1/' + path, json=payload, headers={'Idempotency-Key': uuid.uuid4().hex})
                papers = await client.get('/api/v1/papers', params={'collection': 'library', 'sort': 'published_desc', 'mode': 'keyword'})
                assert papers.json()['papers'][0]['key'] == key
                group = (await mutate('POST', 'groups', {'name': 'Contract group'})).json()['group']
                detail = (await client.get('/api/v1/papers/' + key)).json()
                changed = await mutate('PATCH', 'papers/' + key, {'revision': detail['revision'], 'group_ids': [group['id']]})
                assert changed.status_code == 200, changed.text
                grouped = await client.get('/api/v1/papers', params={'group': group['id']})
                assert grouped.json()['total'] == 1
                note_payload = {'selected_text': 'Synthetic selection', 'page': 1,
                    'rects': [{'x': 0.2, 'y': 0.3, 'width': 0.4, 'height': 0.02}],
                    'pdf_sha256': info['sha256'], 'prefix': '', 'suffix': '', 'body': 'Native contract note'}
                added = await mutate('POST', f'papers/{key}/notes', note_payload)
                assert added.status_code == 201, added.text
                note = added.json()['note']
                assert note['pdf_current'] and note['revision'] == 1
                updated = await mutate('PATCH', f'papers/{key}/notes/{note["id"]}', {'revision': 1, 'body': 'Updated on Mac'})
                assert updated.status_code == 200 and updated.json()['note']['revision'] == 2
                assert (await mutate('PATCH', f'papers/{key}/notes/{note["id"]}', {'revision': 1, 'body': 'Stale'})).status_code == 409
                async with httpx.AsyncClient(base_url=origin) as browser:
                    assert (await browser.post('/api/session', json={'token': engine.state.access_token}, headers={'Origin': origin})).status_code == 200
                    web_notes = (await browser.get(f'/api/papers/{key}/notes')).json()['notes']
                    assert web_notes[0]['body'] == 'Updated on Mac'
                pdf = await client.get(f'/api/v1/papers/{key}/pdf', headers={'Range': 'bytes=0-19'})
                assert pdf.status_code == 206 and len(pdf.content) == 20 and pdf.content.startswith(b'%PDF')
                config = (await client.get('/api/v1/config')).json()
                config['config']['interests'] = 'Fixture-only research interests'
                saved = await mutate('PUT', 'config', {'config': config['config'], 'revision': config['revision']})
                assert saved.status_code == 200 and saved.json()['revision'] != config['revision']
                assert (await mutate('PUT', 'config', {'config': config['config'], 'revision': config['revision']})).status_code == 409
                removed = await mutate('DELETE', f'papers/{key}/notes/{note["id"]}', {'revision': 2})
                assert removed.status_code == 200
                assert (await mutate('DELETE', 'groups/' + group['id'], {})).status_code == 200
                assert (await client.get('/api/v1/papers')).json()['total'] == 1
    finally:
        engine.shutdown()
        engine.server_close()
        worker.join(timeout=3)
