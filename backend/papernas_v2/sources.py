from __future__ import annotations

import ipaddress
import re
import socket
from urllib.parse import quote, urlencode, urljoin, urlsplit

import httpx
from bs4 import BeautifulSoup
from defusedxml import ElementTree
from psycopg.types.json import Jsonb

from .core import NeedsInput, Problem, Retryable, new_id

ARXIV_ID = re.compile(r"(?:\d{4}\.\d{4,5}|[a-z-]+(?:\.[A-Z]{2})?/\d{7})(?:v\d+)?")


def validate_url(url, settings):
    parsed = urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname or parsed.username or parsed.password:
        raise Problem("invalid_url", "仅支持不含用户名和密码的 HTTP(S) 地址")
    if parsed.hostname in settings.allow_private_hosts:
        return
    try:
        addresses = socket.getaddrinfo(
            parsed.hostname, parsed.port or (443 if parsed.scheme == "https" else 80)
        )
    except socket.gaierror as error:
        raise Retryable("无法解析来源地址", code="source_dns") from error
    if any(not ipaddress.ip_address(row[4][0]).is_global for row in addresses):
        raise Problem("private_source", "来源地址不能指向本机或内网")


class Fetcher:
    def __init__(self, settings, db):
        self.settings, self.db = settings, db

    def reserve_origin(self, url):
        host = urlsplit(url).hostname
        interval = 3.1 if host in {"arxiv.org", "export.arxiv.org"} else 0.15
        provider = "arxiv" if host in {"arxiv.org", "export.arxiv.org"} else host
        with self.db.connect() as conn:
            conn.execute(
                "INSERT INTO provider_limits(provider) VALUES(%s) ON CONFLICT DO NOTHING", (provider,)
            )
            row = conn.execute(
                "SELECT extract(epoch FROM next_allowed_at-now()) AS delay FROM provider_limits WHERE provider=%s FOR UPDATE",
                (provider,),
            ).fetchone()
            if row["delay"] > 0:
                return float(row["delay"])
            conn.execute(
                "UPDATE provider_limits SET next_allowed_at=now()+(%s * interval '1 second') WHERE provider=%s",
                (interval, provider),
            )
        return 0

    def get(self, url, *, limit=None):
        # Each hop is validated independently; credentials are never sent on source requests.
        # This service is single-user. Untrusted multi-tenant deployment also needs egress filtering.
        import time

        limit = limit or self.settings.max_download_bytes
        deadline = time.monotonic() + self.settings.network_timeout

        def check_deadline():
            if time.monotonic() > deadline:
                raise Retryable("获取来源超过总时间限制", code="source_timeout")

        with httpx.Client(
            timeout=self.settings.network_timeout,
            follow_redirects=False,
            trust_env=False,
            headers={"User-Agent": "PaperNAS/0.4 (personal research library)", "Accept": "*/*"},
        ) as client:
            for _ in range(6):
                check_deadline()
                validate_url(url, self.settings)
                while delay := self.reserve_origin(url):
                    check_deadline()
                    time.sleep(min(delay + 0.01, 4))
                try:
                    with client.stream("GET", url) as response:
                        if response.status_code in {301, 302, 303, 307, 308}:
                            url = urljoin(url, response.headers["location"])
                            continue
                        if response.status_code in {408, 429, 500, 502, 503, 504}:
                            retry = response.headers.get("retry-after", "15")
                            raise Retryable(
                                f"来源暂时不可用（HTTP {response.status_code}）",
                                delay=min(float(retry) if retry.isdigit() else 15, 600),
                                code="source_unavailable",
                            )
                        if response.status_code >= 400:
                            raise NeedsInput(
                                f"来源返回 HTTP {response.status_code}，可补充本地 PDF", code="source_missing"
                            )
                        body = bytearray()
                        for chunk in response.iter_bytes():
                            check_deadline()
                            body.extend(chunk)
                            if len(body) > limit:
                                raise NeedsInput("来源文件超出大小限制", code="source_too_large")
                        return (
                            bytes(body),
                            response.headers.get("content-type", "application/octet-stream").split(";")[0],
                            url,
                        )
                except (httpx.TimeoutException, httpx.NetworkError) as error:
                    raise Retryable("获取来源时网络中断", code="source_network") from error
        raise NeedsInput("来源重定向次数过多", code="source_redirects")


def parse_arxiv(body):
    root = ElementTree.fromstring(body)
    ns = {"a": "http://www.w3.org/2005/Atom", "x": "http://arxiv.org/schemas/atom"}
    entries = []
    for item in root.findall("a:entry", ns):
        identifier = item.findtext("a:id", "", ns).split("/abs/")[-1]
        if not ARXIV_ID.fullmatch(identifier):
            continue
        base = re.sub(r"v\d+$", "", identifier)
        entries.append(
            {
                "source": "arxiv",
                "identifier": base,
                "version": identifier[len(base) :] or "v1",
                "title": " ".join(item.findtext("a:title", "", ns).split()),
                "abstract": " ".join(item.findtext("a:summary", "", ns).split()),
                "authors": [a.text for a in item.findall("a:author/a:name", ns)],
                "published_at": item.findtext("a:published", "", ns),
                "doi": item.findtext("x:doi", "", ns),
                "url": f"https://arxiv.org/abs/{identifier}",
                "pdf_url": f"https://arxiv.org/pdf/{identifier}",
                "html_url": f"https://arxiv.org/html/{identifier}",
            }
        )
    return entries


def crossref_work(item):
    date = item.get("published", {}).get("date-parts", [[]])[0]
    links = item.get("link", [])
    return {
        "source": "crossref",
        "identifier": item["DOI"].lower(),
        "doi": item["DOI"].lower(),
        "version": "published",
        "title": next(iter(item.get("title", [])), item["DOI"]),
        "authors": [
            " ".join(filter(None, [a.get("given"), a.get("family")])) for a in item.get("author", [])
        ],
        "abstract": BeautifulSoup(item.get("abstract", ""), "html.parser").get_text(" ", strip=True),
        "published_at": "-".join(f"{d:02}" if n else str(d) for n, d in enumerate(date)),
        "venue": next(iter(item.get("container-title", [])), ""),
        "url": item.get("URL", "https://doi.org/" + item["DOI"]),
        "pdf_url": next((x["URL"] for x in links if x.get("content-type") == "application/pdf"), ""),
    }


def resolve_reference(fetcher, reference):
    import json

    value = reference.strip()
    arxiv = re.sub(r"^https?://(?:export\.)?arxiv\.org/(?:abs|pdf|html)/", "", value).removesuffix(".pdf")
    if ARXIV_ID.fullmatch(arxiv):
        body, _, _ = fetcher.get(
            "https://export.arxiv.org/api/query?" + urlencode({"id_list": arxiv}), limit=4_000_000
        )
        entries = parse_arxiv(body)
        if not entries:
            raise NeedsInput("未找到此 arXiv 论文", code="metadata_missing")
        return entries[0]
    doi = re.sub(r"^(?:https?://(?:dx\.)?doi\.org/|doi:\s*)", "", value, flags=re.I)
    if re.fullmatch(r"10\.\d{4,9}/\S+", doi, flags=re.I):
        body, _, _ = fetcher.get("https://api.crossref.org/works/" + quote(doi, safe=""), limit=4_000_000)
        return crossref_work(json.loads(body)["message"])
    validate_url(value, fetcher.settings)
    return {
        "source": "url",
        "identifier": value,
        "version": "imported",
        "title": "Imported paper",
        "authors": [],
        "url": value,
        "pdf_url": value,
    }


def upsert_work(conn, metadata, *, collection="library"):
    from .db import Database

    source, identifier = metadata["source"], metadata["identifier"]
    # The external identity is locked before either row is inserted.
    conn.execute("SELECT pg_advisory_xact_lock(hashtextextended(%s,0))", (source + ":" + identifier,))
    row = conn.execute(
        "SELECT work_id FROM external_ids WHERE source=%s AND identifier=%s", (source, identifier)
    ).fetchone()
    work_id = row["work_id"] if row else new_id()
    if not row:
        conn.execute(
            """INSERT INTO works(id,title,authors,abstract,source,source_url,published_at,venue,collection)
            VALUES(%s,%s,%s,%s,%s,%s,%s,%s,%s)""",
            (
                work_id,
                metadata["title"],
                Jsonb(metadata.get("authors", [])),
                metadata.get("abstract", ""),
                source,
                metadata.get("url", ""),
                metadata.get("published_at", ""),
                metadata.get("venue", ""),
                collection,
            ),
        )
        conn.execute("INSERT INTO external_ids VALUES(%s,%s,%s)", (source, identifier, work_id))
    version = conn.execute(
        """INSERT INTO work_versions(id,work_id,label,source_url,metadata) VALUES(%s,%s,%s,%s,%s)
        ON CONFLICT(work_id,label) DO UPDATE SET metadata=work_versions.metadata || excluded.metadata RETURNING id""",
        (new_id(), work_id, metadata.get("version", "imported"), metadata.get("url", ""), Jsonb(metadata)),
    ).fetchone()["id"]
    # Importing an older version must not silently switch the current PDF and annotations.
    conn.execute(
        "UPDATE works SET current_version_id=coalesce(current_version_id,%s),revision=revision+1,updated_at=now() WHERE id=%s",
        (version, work_id),
    )
    Database.emit(conn, "work.changed", work_id)
    return work_id, version
