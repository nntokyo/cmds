#!/usr/bin/env python3
"""Checks the website and the update feed before they are deployed (docs/internals/ci.md).

    python3 -I scripts/ci/site_check.py                         # offline checks
    python3 -I scripts/ci/site_check.py --release               # also download the release DMG and check it
    python3 -I scripts/ci/site_check.py --release --write-download-files site/public/download
    python3 -I scripts/ci/site_check.py --dmg build/release/cmds-X.Y.Z.dmg --write-download-files site/public/download

Offline:
- every page in site/public is well-formed HTML (tags balanced);
- site/public/download/appcast.xml carries a valid feed signature (SUPublicEDKey from project.yml), one item whose
  enclosure is https://github.com/nntokyo/cmds/releases/download/vX.Y.Z/cmds-X.Y.Z.dmg;
- every download and release link on the pages points at that version, and the byte counts shown are the
  enclosure's length.

--release (network): downloads the DMG from the GitHub release and checks its length and Sparkle signature, and that
the SHA-256 shown on the pages is the DMG's. --write-download-files DIR then writes latest.json and SHA256SUMS
(they are not committed; a deploy needs them). --dmg FILE does the same with a local copy of the release DMG and
needs no network (for when GitHub is unavailable); the date in latest.json then comes from the existing latest.json
of the same version, else today. Exit status 0 when every check passes, 1 otherwise.
"""
import argparse
import base64
import datetime
import hashlib
import html.parser
import json
import os
import re
import sys
import tempfile
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ed25519  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
SITE = ROOT / "site" / "public"
APPCAST = SITE / "download" / "appcast.xml"
REPO = "nntokyo/cmds"
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"}

failures = []


def fail(message):
    failures.append(message)
    print(f"FAIL {message}")


class Balance(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.stack = []
        self.errors = []

    def handle_starttag(self, tag, attrs):
        if tag not in VOID:
            self.stack.append((tag, self.getpos()[0]))

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if not self.stack or self.stack[-1][0] != tag:
            open_tag = self.stack[-1] if self.stack else None
            self.errors.append(f"line {self.getpos()[0]}: </{tag}> closes {open_tag}")
            return
        self.stack.pop()


def check_html(pages):
    for page in pages:
        parser = Balance()
        parser.feed(page.read_text(encoding="utf-8"))
        parser.close()
        for error in parser.errors[:3]:
            fail(f"{page.relative_to(ROOT)}: {error}")
        for tag, line in parser.stack[:3]:
            fail(f"{page.relative_to(ROOT)}: <{tag}> on line {line} is never closed")


def public_key():
    match = re.search(r"SUPublicEDKey:\s*(\S+)", (ROOT / "project.yml").read_text(encoding="utf-8"))
    if not match:
        sys.exit("SUPublicEDKey not found in project.yml")
    return base64.b64decode(match.group(1))


def read_appcast(key):
    raw = APPCAST.read_bytes()
    match = re.search(rb"<!-- sparkle-signatures:\nedSignature: (\S+)\nlength: (\d+)\n-->\s*$", raw)
    if not match:
        fail("appcast.xml has no feed signature (write it with scripts/release/make-appcast.sh)")
    else:
        length = int(match.group(2))
        if length != match.start() or not ed25519.verify(key, raw[:length], base64.b64decode(match.group(1))):
            fail("appcast.xml: the feed signature does not match (edited after signing? use make-appcast.sh)")
    text = raw.decode("utf-8")
    items = re.findall(r"<item>", text)
    if len(items) != 1:
        fail(f"appcast.xml has {len(items)} items, expected 1")
    enclosure = re.search(r'<enclosure url="([^"]+)" length="(\d+)"[^>]*sparkle:edSignature="([^"]+)"', text)
    version = re.search(r"<sparkle:shortVersionString>([^<]+)<", text)
    build = re.search(r"<sparkle:version>(\d+)<", text)
    minimum = re.search(r"<sparkle:minimumSystemVersion>([^<]+)<", text)
    if not (enclosure and version and build and minimum):
        fail("appcast.xml: enclosure, version, build or minimum system version missing")
        return None
    item = {
        "version": version.group(1),
        "build": build.group(1),
        "minimum": minimum.group(1),
        "url": enclosure.group(1),
        "length": int(enclosure.group(2)),
        "signature": enclosure.group(3),
    }
    expected = f"https://github.com/{REPO}/releases/download/v{item['version']}/cmds-{item['version']}.dmg"
    if item["url"] != expected:
        fail(f"appcast.xml: enclosure {item['url']}, expected {expected}")
    return item


def check_pages(pages, item):
    version = item["version"]
    shown_length = f"{item['length']:,}"
    for page in pages:
        text = page.read_text(encoding="utf-8")
        name = page.relative_to(ROOT)
        for v, f in re.findall(r"releases/download/v([0-9][^/\"]*)/cmds-([0-9][^\"]*?)\.dmg", text):
            if v != version or f != version:
                fail(f"{name}: download link for {v} / cmds-{f}.dmg, the appcast has {version}")
        for v in re.findall(r"releases/tag/v([0-9][0-9.]*[0-9])", text):
            if v != version:
                fail(f"{name}: release link for {v}, the appcast has {version}")
        for f, count in re.findall(r"<code>cmds-([0-9.]+)\.dmg</code>\s*[（(]([0-9,]+)", text):
            if f != version or count != shown_length:
                fail(f"{name}: shows cmds-{f}.dmg with {count} bytes, the appcast has {version} with {shown_length}")


def page_hashes(pages):
    found = set()
    for page in pages:
        found.update(re.findall(r"SHA-256</dt><dd><code>([0-9a-f]{64})</code>", page.read_text(encoding="utf-8")))
    return found


def fetch(url, dest):
    request = urllib.request.Request(url, headers={"User-Agent": "cmds-site-check"})
    with urllib.request.urlopen(request, timeout=120) as response, open(dest, "wb") as out:
        while chunk := response.read(1 << 20):
            out.write(chunk)


def release_date(version, offline):
    existing = SITE / "download" / "latest.json"
    if offline:
        try:
            data = json.loads(existing.read_text(encoding="utf-8"))
            if data.get("version") == version:
                return data["date"]
        except (OSError, ValueError, KeyError):
            pass
        return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d")
    headers = {"User-Agent": "cmds-site-check", "Accept": "application/vnd.github+json"}
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    url = f"https://api.github.com/repos/{REPO}/releases/tags/v{version}"
    with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60) as response:
        return json.load(response)["published_at"][:10]


def check_release(pages, item, key, write_dir, local_dmg=None):
    if local_dmg:
        data = Path(local_dmg).read_bytes()
    else:
        with tempfile.TemporaryDirectory() as tmp:
            dmg = Path(tmp) / "cmds.dmg"
            fetch(item["url"], dmg)
            data = dmg.read_bytes()
    if len(data) != item["length"]:
        fail(f"release DMG is {len(data)} bytes, the appcast says {item['length']}")
    if not ed25519.verify(key, data, base64.b64decode(item["signature"])):
        fail("release DMG: the appcast's Sparkle signature does not match it")
    sha = hashlib.sha256(data).hexdigest()
    hashes = page_hashes(pages)
    if hashes != {sha}:
        fail(f"pages show SHA-256 {sorted(hashes)}, the release DMG has {sha}")
    print(f"release DMG {local_dmg or item['url']}: {len(data)} bytes, sha256 {sha}")
    if write_dir and not failures:
        out = Path(write_dir)
        out.mkdir(parents=True, exist_ok=True)
        name = f"cmds-{item['version']}.dmg"
        (out / "SHA256SUMS").write_text(f"{sha}  {name}\n", encoding="utf-8")
        latest = (
            "{\n"
            f'  "version": "{item["version"]}",\n'
            f'  "build": "{item["build"]}",\n'
            f'  "file": "{item["url"]}",\n'
            f'  "size": {len(data)},\n'
            f'  "sha256": "{sha}",\n'
            f'  "minimumSystemVersion": "{item["minimum"]}",\n'
            '  "architectures": ["arm64"],\n'
            '  "notarized": true,\n'
            f'  "date": "{release_date(item["version"], bool(local_dmg))}"\n'
            "}\n"
        )
        (out / "latest.json").write_text(latest, encoding="utf-8")
        print(f"wrote {out / 'latest.json'} and {out / 'SHA256SUMS'}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--release", action="store_true", help="download and check the release DMG")
    parser.add_argument("--dmg", metavar="FILE", help="check this local copy of the release DMG (no network)")
    parser.add_argument("--write-download-files", metavar="DIR", help="with --release or --dmg: write latest.json, SHA256SUMS")
    args = parser.parse_args()
    if args.write_download_files and not (args.release or args.dmg):
        parser.error("--write-download-files needs --release or --dmg")

    pages = sorted(p for p in SITE.rglob("*.html"))
    key = public_key()
    check_html(pages)
    item = read_appcast(key)
    if item:
        check_pages(pages, item)
        if (args.release or args.dmg) and not failures:
            check_release(pages, item, key, args.write_download_files, args.dmg)
    if failures:
        print(f"{len(failures)} problem(s)")
        return 1
    print(f"site OK: {len(pages)} pages, appcast {item['version']} ({item['build']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
