from __future__ import annotations

import argparse
import asyncio
import logging
import os
import secrets

from .settings import Settings


def initialize(settings):
    from .runtime import Runtime

    runtime = Runtime(settings)
    runtime.db.migrate()
    runtime.queue.migrate(runtime.db)
    settings.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not settings.access_key_file.exists():
        fd = os.open(settings.access_key_file, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(fd, "w") as stream:
            stream.write(secrets.token_urlsafe(32) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
    return runtime


def main():
    parser = argparse.ArgumentParser(description="Paper NAS v2 API and durable workers")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("init", help="Create schema, queue and private access-key file")
    commands.add_parser("api", help="Run the REST API")
    worker = commands.add_parser("worker", help="Run task workers with recovery and scheduling")
    worker.add_argument("--queues", default="io,parse,model")
    worker.add_argument("--concurrency", type=int, default=2)
    worker.add_argument("--drain", action="store_true", help="Exit when currently runnable jobs finish")
    commands.add_parser("maintain", help="Recover stalled jobs and run due discovery once")
    commands.add_parser("show-access-key", help="Print the private connection key for the server owner")
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")
    settings = Settings.environment()
    runtime = initialize(settings)
    if args.command == "init":
        print(f"Initialized Paper NAS v2. Access key file: {settings.access_key_file}")
    elif args.command == "show-access-key":
        print(settings.access_key_file.read_text().strip())
    elif args.command == "api":
        import uvicorn

        from .api import create_app

        uvicorn.run(create_app(settings), host=settings.host, port=settings.port)
    elif args.command == "maintain":
        from .maintenance import tick

        print({"recovered": tick(runtime)})
    else:
        from .maintenance import loop
        from .queue import DurableQueue

        async def run():
            queue = DurableQueue(settings, asynchronous=True)
            if args.drain:
                await queue.run(queues=args.queues.split(","), concurrency=args.concurrency, wait=False)
            else:
                maintenance = asyncio.create_task(loop(settings))
                try:
                    await queue.run(queues=args.queues.split(","), concurrency=args.concurrency)
                finally:
                    maintenance.cancel()
                    await asyncio.gather(maintenance, return_exceptions=True)

        asyncio.run(run())


if __name__ == "__main__":
    main()
