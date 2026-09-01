#!/usr/bin/env python3
"""Discover an AWS bucket's region from x-amz-bucket-region (unsigned HEAD)."""
from __future__ import annotations

import sys
import urllib.error
import urllib.request


def probe(bucket: str) -> str:
    bucket = (bucket or "").strip()
    if not bucket or "/" in bucket or ".." in bucket or " " in bucket:
        return ""
    urls = (
        f"https://{bucket}.s3.amazonaws.com/",
        f"https://s3.amazonaws.com/{bucket}",
    )
    for url in urls:
        req = urllib.request.Request(url, method="HEAD")
        region = ""
        try:
            with urllib.request.urlopen(req, timeout=8) as resp:
                region = resp.headers.get("x-amz-bucket-region", "") or ""
        except urllib.error.HTTPError as e:
            if e.headers:
                region = e.headers.get("x-amz-bucket-region", "") or ""
        except (urllib.error.URLError, TimeoutError, ValueError, OSError):
            region = ""
        region = region.strip()
        if region:
            return region
    return ""


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: s3_probe.py BUCKET", file=sys.stderr)
        return 2
    print(probe(argv[1]))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
