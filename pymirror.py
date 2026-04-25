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
    python pymirror.py https://example.com ./mirror
"""

from __future__ import annotations

import re
import sys
import posixpath
from pathlib import Path
from typing import Final, Iterable
from urllib.parse import urljoin, urlparse, urldefrag, unquote

import requests
from requests import Response, Session
from requests.adapters import HTTPAdapter


USER_AGENT: Final[str] = "MirrorBot/1.0"
TIMEOUT: Final[int] = 20
MAX_PAGES: Final[int] = 100000
DEBUG: Final[bool] = False


class Mirror:
    def __init__(self, base_url: str, output_dir: Path) -> None:
        self.base_url: str = base_url.rstrip("/")
        self.output_dir: Path = output_dir

        parsed = urlparse(self.base_url)
        self.netloc: str = parsed.netloc

        self.session: Session = self._build_session()

        self.visited: set[str] = set()
        self.queue: list[str] = [self.base_url]

        self.unique_files: set[str] = set()
        self.forbidden_urls: set[str] = set()

    def debug(self, message: str) -> None:
        if DEBUG:
            print(f"[DEBUG] {message}", flush=True)

    def info(self, message: str) -> None:
        print(f"[INFO] {message}", flush=True)

    def _build_session(self) -> Session:
        session = requests.Session()

        adapter = HTTPAdapter(
            pool_connections=1,
            pool_maxsize=1,
            pool_block=True,
        )

        session.mount("http://", adapter)
        session.mount("https://", adapter)
        session.headers.update({"User-Agent": USER_AGENT})

        self.debug("HTTP session created with single connection pool")
        return session

    def run(self) -> None:
        self.debug(f"Starting crawl: {self.base_url}")

        pages_processed = 0

        while self.queue and pages_processed < MAX_PAGES:
            url = self.queue.pop(0)

            if url in self.visited:
                continue

            self.visited.add(url)
            pages_processed += 1

            self.debug(f"Crawling ({pages_processed}): {url}")

            if "=" in url:
                self.info(f"Skipped URL with '=': {url}")
                continue

            try:
                response = self.fetch(url)
            except requests.RequestException as exc:
                self.debug(f"Request failed: {url} ({exc})")
                continue

            self.info(f"Response {response.status_code}: {url}")

            if response.status_code == 403:
                self.forbidden_urls.add(url)
                self.debug(f"Stored forbidden URL: {url}")
                continue

            if response.status_code != 200:
                continue

            content_type = response.headers.get("Content-Type", "").lower()

            if "text/html" in content_type:
                self.save_html(url, response)
                self.enqueue_links(url + '/', response.text)
            else:
                self.save_binary(url, response)

        self.retry_forbidden_paths()

    def fetch(self, url: str) -> Response:
        self.debug(f"GET {url}")
        return self.session.get(
            url,
            timeout=TIMEOUT,
            allow_redirects=True,
            stream=False,
        )

    def enqueue_links(self, current_url: str, html: str) -> None:
        for link in self.extract_links(html):
            absolute = urljoin(current_url, link)
            absolute, _ = urldefrag(absolute)

            if "=" in absolute:
                continue

            if re.match('^FreeBSD.*\.pkg', link):
                continue

            if not self.is_same_site(absolute):
                continue

            if absolute not in self.visited:
                self.queue.append(absolute)

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
        self.debug(f"Saved HTML: {path}")

    def save_binary(self, url: str, response: Response) -> None:
        path = self.url_to_path(url, is_html=False)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(response.content)
        self.debug(f"Saved file: {path}")

        if path.name and "Latest" not in url:
            self.unique_files.add(path.name)

    def decode_path(self, raw_path: str) -> str:
        """
        Decode URL-encoded characters:
        %20 -> space
        %5B -> [
        etc.
        """
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

        self.debug(f"Decoded path: {parsed.path} -> {local_path}")

        return local_path

    def retry_forbidden_paths(self) -> None:
        for forbidden_url in sorted(self.forbidden_urls):

            self.info(f"Retrying forbidden URL {forbidden_url}")

            base = forbidden_url.rstrip("/")

            for filename in sorted(self.unique_files):
                url = f"{base}/{filename}"

                try:
                    response = self.fetch(url)
                except requests.RequestException:
                    continue

                self.debug(f"Retry {response.status_code}: {url}")

                self.info(f"Response {response.status_code}: {url}")

                if response.status_code == 200:
                    self.visited.add(url)
                    self.save_binary(url, response)

    def close(self) -> None:
        self.session.close()
        self.debug("Session closed")


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: python mirror.py <url> <output_dir>")
        return 1

    mirror = Mirror(sys.argv[1], Path(sys.argv[2]))

    try:
        mirror.run()
    finally:
        mirror.close()

    print("Done.")
    print(f"Visited URLs: {len(mirror.visited)}")
    print(f"Forbidden URLs: {len(mirror.forbidden_urls)}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
