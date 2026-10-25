"""Read-only library checks plus an event/restart check for the new API service.

Connection-file credentials are never printed. The existing processing service is
not restarted, and this probe does not submit model jobs or alter paper content.
"""
import argparse
import asyncio
import json
import subprocess
import time
from pathlib import Path

import httpx


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('connection_file')
    parser.add_argument('--ssh-host', required=True)
    parser.add_argument('--ssh-control', required=True)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    credentials = json.loads(Path(args.connection_file).read_text())
    ssh = ['ssh', '-S', args.ssh_control, args.ssh_host]
    def remote(command):
        return subprocess.check_output(ssh + [command], text=True).strip()
    engine_pid = remote('systemctl --user show research-digest-web -p MainPID --value')
    headers = {'Authorization': 'Bearer ' + credentials['token']}
    async with httpx.AsyncClient(base_url=credentials['serverURL'],headers=headers,trust_env=False,timeout=15) as client:
        cap = (await client.get('/api/v1/capabilities')).json()
        library = (await client.get('/api/v1/papers',params={'collection':'library'})).json()
        candidates = (await client.get('/api/v1/papers',params={'collection':'candidates'})).json()
        before_notes = (await client.get('/api/v1/papers/52af0d1bc83f3a76e0a8/notes')).json()
        async with client.stream('GET','/api/v1/events',params={'after':cap['event_cursor']}) as response:
            response.raise_for_status()
            event_command = "cd ~/paper-nas-api/current && ~/paper-nas-api/venv/bin/python -c \"from paper_nas.store import Store; from pathlib import Path; Store(Path.home()/'paper-nas-data/native.sqlite3').event('verification')\""
            await asyncio.to_thread(remote,event_command)
            event_received = False
            async for line in response.aiter_lines():
                if line == 'event: verification':
                    event_received = True
                    break
        await asyncio.to_thread(remote,'systemctl --user restart paper-nas-api')
        for _ in range(20):
            try:
                health = await client.get('/health')
                if health.status_code == 200:
                    break
            except httpx.HTTPError:
                pass
            await asyncio.sleep(0.5)
        after = await client.get('/api/v1/capabilities')
        after.raise_for_status()
        after_notes = (await client.get('/api/v1/papers/52af0d1bc83f3a76e0a8/notes')).json()
        result = {'library_papers':library['total'],'candidate_papers':candidates['total'],
                  'event_stream':event_received,'device_login_survived_restart':after.status_code == 200,
                  'server_identity_stable':cap['server_id'] == after.json()['server_id'],
                  'existing_notes_unchanged':before_notes == after_notes,
                  'processing_service_uninterrupted':engine_pid == remote('systemctl --user show research-digest-web -p MainPID --value')}
        assert all(result[key] for key in result if key not in {'library_papers','candidate_papers'})
        Path(args.output).write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result,indent=2))


if __name__ == '__main__':
    asyncio.run(main())
