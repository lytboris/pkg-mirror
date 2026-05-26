#!/usr/bin/env python3
"""
Website mirror script with debug output.

- Mirrors directory structure locally decoding URL/UU-encoded path
- Ignores URLs containing '='
- Tracks downloaded files in unique_files, except for URLs with substring `Latest`
- If URL returns 403:
    store forbidden URL
- After main crawl:
    for each forbidden URL, try downloading every filename from unique_files
    under that forbidden path

Example:
    python3 pymirror.py https://example.com ./mirror
    python3 pymirror.py --debug https://example.com ./mirror
"""

from __future__ import annotations

import argparse
import logging
import re
import posixpath
from collections import deque
from email.utils import parsedate_to_datetime
from pathlib import Path
from typing import Final, Iterable
from urllib.parse import urljoin, urlparse, urldefrag, unquote

import requests
from requests import Response, Session
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


USER_AGENT: Final[str] = "MirrorBot/1.0"
TIMEOUT: Final[int] = 20
MAX_PAGES: Final[int] = 100000

logger = logging.getLogger(__name__)


class Mirror:
    def __init__(self, base_url: str, output_dir: Path, max_pages: int = MAX_PAGES) -> None:
        self.base_url: str = base_url.rstrip("/")
        self.output_dir: Path = output_dir
        self.max_pages: int = max_pages

        parsed = urlparse(self.base_url)
        self.netloc: str = parsed.netloc

        self.session: Session = self._build_session()

        self.visited: set[str] = set()
        self.queued: set[str] = {self.base_url}
        self.queue: deque[str] = deque([self.base_url])

        self.unique_files: set[str] = set()
        self.forbidden_urls: set[str] = set()

    def _build_session(self) -> Session:
        session = requests.Session()

        retry = Retry(
            total=3,
            backoff_factor=0.5,
            status_forcelist=[500, 502, 503, 504],
            allowed_methods=["GET"],
        )
        adapter = HTTPAdapter(
            pool_block=True,
            max_retries=retry,
        )

        session.mount("http://", adapter)
        session.mount("https://", adapter)
        session.headers.update({"User-Agent": USER_AGENT})

        logger.debug("HTTP session created with retry policy")
        return session

    def _is_up_to_date(self, path: Path, response: Response) -> bool:
        """Return True if local file matches remote based on Content-Length and Last-Modified."""
        content_length = response.headers.get("Content-Length")
        if not content_length:
            return False
        try:
            stat = path.stat()
        except FileNotFoundError:
            return False
        if stat.st_size != int(content_length):
            return False
        last_modified = response.headers.get("Last-Modified")
        if last_modified:
            try:
                remote_mtime = parsedate_to_datetime(last_modified).timestamp()
                if remote_mtime > stat.st_mtime:
                    return False
            except Exception:
                pass
        return True

    def run(self) -> None:
        logger.debug("Starting crawl: %s", self.base_url)

        pages_processed = 0

        while self.queue and pages_processed < self.max_pages:
            url = self.queue.popleft()

            if url in self.visited:
                continue

            self.visited.add(url)
            pages_processed += 1

            if pages_processed % 1000 == 0:
                logger.info(
                    "Progress: %d pages processed, %d in queue",
                    pages_processed,
                    len(self.queue),
                )

            logger.debug("Crawling (%d): %s", pages_processed, url)

            if "=" in url:
                logger.info("Skipped URL with '=': %s", url)
                continue

            try:
                response = self.fetch(url)
            except requests.RequestException as exc:
                logger.debug("Request failed: %s (%s)", url, exc)
                continue

            logger.info("Response %d: %s", response.status_code, url)

            if response.status_code == 403:
                self.forbidden_urls.add(url)
                logger.debug("Stored forbidden URL: %s", url)
                response.close()
                continue

            if response.status_code != 200:
                response.close()
                continue

            content_type = response.headers.get("Content-Type", "").lower()

            if "text/html" in content_type:
                self.save_html(url, response)
                self.enqueue_links(url.rstrip("/") + "/", response.text)
            else:
                self.save_binary(url, response)

        self.retry_forbidden_paths()

    def fetch(self, url: str, stream: bool = True) -> Response:
        logger.debug("GET %s", url)
        return self.session.get(
            url,
            timeout=TIMEOUT,
            allow_redirects=True,
            stream=stream,
        )

    def enqueue_links(self, current_url: str, html: str) -> None:
        for link in self.extract_links(html):
            absolute = urljoin(current_url, link)
            absolute, _ = urldefrag(absolute)

            if "=" in absolute:
                continue

            if re.search(r'FreeBSD.*\.pkg', link):
                continue

            if not self.is_same_site(absolute):
                continue

            if absolute not in self.visited and absolute not in self.queued:
                self.queue.append(absolute)
                self.queued.add(absolute)

    def extract_links(self, html: str) -> Iterable[str]:
        pattern = re.compile(
            r"""(?:href|src)\s*=\s*["']([^"'#]+)["']""",
            re.IGNORECASE,
        )
        return pattern.findall(html)

    def is_same_site(self, url: str) -> bool:
        parsed = urlparse(url)
        return parsed.scheme in ("http", "https") and parsed.netloc == self.netloc

    def save_html(self, url: str, response: Response) -> None:
        path = self.url_to_path(url, is_html=True)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(response.content)
        logger.debug("Saved HTML: %s", path)

    def save_binary(self, url: str, response: Response) -> None:
        path = self.url_to_path(url, is_html=False)

        # With stream=True the body is not yet downloaded; check headers before reading.
        # Skip only when size matches AND remote is not newer than our local copy.
        if self._is_up_to_date(path, response):
            response.close()
            logger.debug("Skipped (up to date): %s", path)
            if path.name and "Latest" not in url:
                self.unique_files.add(path.name)
            return

        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("wb") as fh:
            for chunk in response.iter_content(chunk_size=65536):
                fh.write(chunk)
        logger.debug("Saved file: %s", path)

        if path.name and "Latest" not in url:
            self.unique_files.add(path.name)

    def decode_path(self, raw_path: str) -> str:
        """Decode URL-encoded characters (%20 -> space, etc.)"""
        return unquote(raw_path)

    def sanitize_parts(self, path_value: str) -> str:
        parts = []

        for part in path_value.split("/"):
            if not part:
                continue

            clean = part.strip()

            if clean in {".", ".."}:
                continue

            parts.append(clean)

        return "/".join(parts)

    def url_to_path(self, url: str, is_html: bool) -> Path:
        parsed = urlparse(url)

        clean_path = parsed.path or "/"

        clean_path = self.decode_path(clean_path)

        if clean_path.endswith("/"):
            clean_path += "index.html"

        filename = posixpath.basename(clean_path)

        if is_html and "." not in filename:
            clean_path += "/index.html"

        clean_path = self.sanitize_parts(clean_path)

        local_path = self.output_dir / clean_path

        logger.debug("Decoded path: %s -> %s", parsed.path, local_path)

        return local_path

    def retry_forbidden_paths(self) -> None:
        if not self.forbidden_urls:
            return

        files = sorted(self.unique_files)
        logger.info(
            "Retrying %d forbidden URL(s) x %d unique files = %d requests",
            len(self.forbidden_urls),
            len(files),
            len(self.forbidden_urls) * len(files),
        )

        for forbidden_url in sorted(self.forbidden_urls):
            logger.info("Retrying forbidden URL %s", forbidden_url)

            base = forbidden_url.rstrip("/")

            for filename in files:
                url = f"{base}/{filename}"

                try:
                    response = self.fetch(url)
                except requests.RequestException:
                    continue

                logger.debug("Retry %d: %s", response.status_code, url)
                logger.info("Response %d: %s", response.status_code, url)

                if response.status_code == 200:
                    self.visited.add(url)
                    self.save_binary(url, response)
                else:
                    response.close()

    def close(self) -> None:
        self.session.close()
        logger.debug("Session closed")


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Mirror a website's directory structure locally.",
        epilog="Example: python pymirror.py https://pkg.freebsd.org ./mirror",
    )
    parser.add_argument("url", help="Base URL to mirror")
    parser.add_argument("output_dir", help="Local directory to save files")
    parser.add_argument("--debug", action="store_true", help="Enable debug logging")
    parser.add_argument(
        "--max-pages",
        type=int,
        default=MAX_PAGES,
        metavar="N",
        help=f"Stop crawling after N pages (default: {MAX_PAGES})",
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.debug else logging.INFO,
        format="[%(levelname)s] %(message)s",
    )

    mirror = Mirror(args.url, Path(args.output_dir), max_pages=args.max_pages)

    try:
        mirror.run()
    except Exception as exc:
        logger.error("Mirror failed: %s", exc)
        return 1
    finally:
        mirror.close()

    logger.info(
        "Done. Visited URLs: %d, Forbidden URLs: %d",
        len(mirror.visited),
        len(mirror.forbidden_urls),
    )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
