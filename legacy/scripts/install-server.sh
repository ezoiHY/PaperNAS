#!/bin/bash
set -euo pipefail
# Run on the existing processing server after extracting server/ into this directory.
task_source=$(cd "$(dirname "$0")/../server" && pwd)
task_target="$HOME/paper-nas-api"
task_version="0.1.0"
mkdir -p "$task_target/releases" "$HOME/.config/systemd/user" "$HOME/paper-nas-data"
chmod 700 "$HOME/paper-nas-data"
if [ ! -x "$task_target/venv/bin/python" ]; then
  "$HOME/research-digest/.venv/bin/python" -m venv "$task_target/venv"
fi
"$task_target/venv/bin/python" -m pip install -r "$task_source/requirements.lock"
task_release="$task_target/releases/$task_version-$(date +%Y%m%d%H%M%S)"
task_previous=$(readlink "$task_target/current" || true)
mkdir -p "$task_release/paper_nas"
cp "$task_source/paper_nas/"*.py "$task_release/paper_nas/"
cp "$task_source/pyproject.toml" "$task_source/requirements.lock" "$task_release/"
"$task_target/venv/bin/python" -m compileall -q "$task_release/paper_nas"
ln -s "$task_release" "$task_target/current.next"
mv -Tf "$task_target/current.next" "$task_target/current"
cp "$task_source/paper-nas-api.service" "$HOME/.config/systemd/user/"
systemctl --user daemon-reload
systemctl --user enable paper-nas-api
systemctl --user restart paper-nas-api
if ! "$task_target/venv/bin/python" - <<'PY'
import json, os, shlex, subprocess, time, urllib.request
values = subprocess.check_output(['systemctl','--user','show','paper-nas-api','-p','Environment','--value'],text=True)
env = dict(v.split('=',1) for v in shlex.split(values) if '=' in v)
address = 'http://' + env.get('PAPER_NAS_HOST','127.0.0.1') + ':' + env.get('PAPER_NAS_PORT','8787') + '/health'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
for _ in range(20):
    try:
        with opener.open(address,timeout=2) as response:
            assert json.load(response)['service'] == 'paper-nas'
        break
    except Exception:
        time.sleep(0.5)
else:
    raise SystemExit('Native API did not become healthy')
PY
then
  if [ -n "$task_previous" ]; then
    ln -s "$task_previous" "$task_target/current.rollback"
    mv -Tf "$task_target/current.rollback" "$task_target/current"
    systemctl --user restart paper-nas-api
  fi
  exit 1
fi
systemctl --user is-active paper-nas-api
