# Deployment

The supported application consists of PostgreSQL, the v2 API/browser server, an IO/model worker, a parsing worker, and a private state directory. Do not start the legacy adapter for a new deployment.

## Existing Linux server

1. Install PostgreSQL 18 and create a dedicated database/user. Keep the database on loopback or an isolated internal network.
2. Place the public source at `~/papernas`, create `backend/.venv`, and install `./backend` (plus `[layout]` if wanted).
3. Run `python3 scripts/package-source.py` to include the corresponding source download.
4. Copy `deploy/server.env.example` to `~/.config/papernas/server.env`, fill in the private values, and set mode 0600. The state directory should be mode 0700 and writable by the service user.
5. Copy `deploy/systemd/*.service` to `~/.config/systemd/user/`, run `systemctl --user daemon-reload`, then enable/start `papernas-api`, `papernas-worker`, and `papernas-parser`. The services assume the checkout path above; adjust them together for another path.
6. If services must run without an interactive login, arrange user lingering with your system administrator. PostgreSQL lifecycle is managed separately.

The CLI initializes schema and access-key files on startup. The API and workers share the exact database URL and state directory. `papernas-v2 show-access-key` prints the registration key in the operator's terminal. Do not put it in logs, screenshots, URLs, issue reports, or Git.

## Containers

`compose.yaml` runs the same topology. The application is a non-root user. Its build context is an allowlist that excludes private runtime data. Use a fresh random hex database password in `.env`; hex avoids URI escaping errors in the generated connection string.

```sh
cp .env.example .env
# Replace the password placeholder before starting.
docker compose config --quiet
docker compose up --build -d
docker compose exec api papernas-v2 show-access-key
docker compose logs --tail=50 api worker parser
```

The default image omits the heavy layout parser and uses embedded text. To enable Docling, set `PAPERNAS_INSTALL_LAYOUT=1` and `PAPERNAS_V2_DOCLING=1`, rebuild, and ensure enough RAM/disk and outbound access for model downloads. Model licenses and caches are separate from application source. Container layout dependencies resolve for the target architecture; the historical CPU constraint snapshot is not used as a universal lock.

The PostgreSQL 18 volume is mounted at `/var/lib/postgresql`, following the official image's versioned data layout. Application data and model cache use separate named volumes. Do not run `docker compose down -v` unless you intend to delete the entire installation's data.

## Network access

Both clients use the same server URL. Serve browser and API on the same HTTPS origin, forwarding `/app/`, `/api/`, `/health`, and `/source` to the API. Set an appropriate upload limit (80 MiB by default) and proxy timeouts. A private VPN can provide transport isolation, but ordinary public HTTP must not carry credentials or papers.

The default Compose port binds only to loopback. Set `PAPERNAS_BIND` to an intentionally selected private address if using a VPN; do not blindly bind to every interface. PostgreSQL is not exposed. Browser access does not require enabling cross-origin requests.

Mac source builds allow HTTP loopback only by default. For a deliberately trusted private HTTP host, use `PAPERNAS_HTTP_HOST` during the app build. HTTPS needs no host exception.

## Backup and restore

Back up PostgreSQL and the **entire application state**, including immutable objects and access/model keys, at one consistent point. A PDF-only copy or a database-only dump is incomplete. Keep `.env` or service configuration separately with restricted permissions.

For Compose, stop all application writers, keep PostgreSQL running, and preserve their previous running state for restart:

```sh
docker compose stop api worker parser
umask 077
mkdir -p backup
docker compose exec -T postgres pg_dump -U papernas -d papernas -Fc > backup/database.dump
docker compose run --rm --no-deps -T api tar -C /var/lib/papernas -cf - . > backup/state.tar
docker compose start api worker parser
```

If any backup command fails, restart the services you stopped and investigate before relying on the files. Encrypt backups and retain the matching application version. The model cache can be downloaded again, but offline installations may want to preserve it too.

Restore into a new empty database and independent state volume using `pg_restore`, copy the full state, and check each database asset hash against its object bytes before starting application writers. Preserve file ownership and private modes. Unknown provider calls remain unknown after recovery until reconciled. Test restoration independently before replacing a live installation.

For bare-metal/systemd deployments use the same sequence: stop writers, `pg_dump -Fc`, archive the full state, restart prior services. `backend/scripts/backup_nas.sh` documents an older custom NAS layout and should only be used when that exact layout exists.

## Updates and source availability

Back up first. Install the new application in a separate release directory, regenerate the corresponding source archive, and restart all application processes on the same version. New migrations are automatic; old migrations must not be edited. Rollback across schema changes may require restoring the matched backup.

Release packages provide corresponding source at `/source`, linked from the browser's About page. If you change the software, regenerate this archive from the actual modified source before sharing the service. AGPL source availability is part of the deployment, not merely a link to an unrelated upstream version.
