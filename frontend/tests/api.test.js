import test from 'node:test';
import assert from 'node:assert/strict';
import { API, APIError, localPath, safeExternalURL, requestID, fileName } from '../src/api.js';

test('authenticated resources cannot leave the API origin or namespace', () => {
  for (const bad of ['https://example.com/api/v2/assets/1', '//example.com/api/v2/', '/api/v2/../../private', '/api/v2/../../../etc/passwd', '/api/v2/\\example.com', '/api/v2/a#secret']) {
    assert.throws(() => localPath(bad));
  }
  assert.equal(localPath('/api/v2/works?q=space%20robotics'), '/api/v2/works?q=space%20robotics');
});

test('explicit retry after a connection failure uses the same idempotency key', async () => {
  const calls = [];
  const api = new API(async (path, init) => {
    calls.push(init);
    if (calls.length === 1) throw new TypeError('lost response');
    return new Response(JSON.stringify({ operation: { id: 'operation-1' } }), { status: 202 });
  });
  api.token = 'synthetic-device-token';
  await assert.rejects(api.call('/operations', { method: 'POST', body: { kind: 'analyze', work_ids: ['paper-1'] } }), APIError);
  assert.equal(calls.length, 1, 'no automatic repeat of a potentially charged action');
  await api.call('/operations', { method: 'POST', body: { kind: 'analyze', work_ids: ['paper-1'] } });
  assert.equal(calls[0].headers['Idempotency-Key'], calls[1].headers['Idempotency-Key']);
  assert.equal(calls[0].headers.Authorization, 'Bearer synthetic-device-token');
  assert.equal(calls[0].redirect, 'error');
  assert.equal(calls[0].credentials, 'omit');
  assert.equal(api.pending.size, 0);
});

test('conflicts preserve a useful error and do not resend the mutation', async () => {
  let calls = 0;
  const api = new API(async () => { calls++; return new Response(JSON.stringify({ type: 'urn:papernas:error:revision_conflict', error: 'conflict' }), { status: 409 }); });
  await assert.rejects(api.call('/works/paper-1', { method: 'PATCH', body: { revision: 1, title: 'New title' } }), e => e.status === 409 && e.message.includes('preserved'));
  assert.equal(calls, 1);
});

test('retrying an upload preserves identity for the selected file without reading its contents', async () => {
  const keys = [];
  const api = new API(async (_path, init) => {
    keys.push(init.headers['Idempotency-Key']);
    if (keys.length === 1) throw new TypeError('lost upload response');
    return new Response('{}', { status: 202 });
  });
  const selectedFile = new File(['synthetic PDF bytes'], 'demo.pdf', { type: 'application/pdf' });
  const upload = () => {
    const form = new FormData(); form.append('file', selectedFile);
    return api.call('/imports/pdf', { method: 'POST', form });
  };
  await assert.rejects(upload(), APIError);
  await upload();
  assert.equal(keys[0], keys[1]);
  assert.equal(api.pending.size, 0);
  await upload();
  assert.notEqual(keys[1], keys[2], 'a confirmed upload does not block a later intentional upload');
});

test('secret values are not retained in mutation retry storage', async () => {
  const api = new API(async () => { throw new TypeError('offline'); });
  await assert.rejects(api.call('/settings/model/key', { method: 'PUT', body: { api_key: 'synthetic-key' } }));
  assert.equal(api.pending.size, 0);
});

test('external source links permit only ordinary HTTP(S) URLs', () => {
  for (const value of ['javascript:alert(1)', 'data:text/html,hello', 'file:///etc/passwd', 'https://user:secret@example.com']) assert.equal(safeExternalURL(value), null);
  assert.equal(safeExternalURL('https://arxiv.org/abs/1706.03762'), 'https://arxiv.org/abs/1706.03762');
});

test('download filenames and request identities are safe', () => {
  assert.equal(fileName('../paper:one', 'pdf'), '..-paper-one.pdf');
  assert.match(requestID(), /^[0-9a-f]{48}$/);
  assert.notEqual(requestID(), requestID());
});
