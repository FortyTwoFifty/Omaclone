#!/usr/bin/env python3
"""Create an S3 bucket with SigV4. Used by tests/test-s3-roundtrip.sh (MinIO)."""
from __future__ import annotations

import datetime
import hashlib
import hmac
import http.client
import os
import sys


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def _signing_key(secret: str, datestamp: str, region: str, service: str) -> bytes:
    k = _sign(("AWS4" + secret).encode("utf-8"), datestamp)
    k = _sign(k, region)
    k = _sign(k, service)
    return _sign(k, "aws4_request")


def create_bucket(hostport: str, bucket: str, access: str, secret: str, region: str = "us-east-1") -> None:
    if ":" in hostport:
        host, port_s = hostport.rsplit(":", 1)
        port = int(port_s)
    else:
        host, port = hostport, 80
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(b"").hexdigest()
    canonical_uri = f"/{bucket}"
    canonical_headers = (
        f"host:{hostport}\n"
        f"x-amz-content-sha256:{payload_hash}\n"
        f"x-amz-date:{amzdate}\n"
    )
    signed_headers = "host;x-amz-content-sha256;x-amz-date"
    canonical_request = (
        f"PUT\n{canonical_uri}\n\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
    )
    scope = f"{datestamp}/{region}/s3/aws4_request"
    string_to_sign = (
        "AWS4-HMAC-SHA256\n"
        f"{amzdate}\n{scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )
    signature = hmac.new(
        _signing_key(secret, datestamp, region, "s3"),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    auth = (
        f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
        f"SignedHeaders={signed_headers}, Signature={signature}"
    )
    conn = http.client.HTTPConnection(host, port, timeout=10)
    try:
        conn.request(
            "PUT",
            canonical_uri,
            body=b"",
            headers={
                "Host": hostport,
                "x-amz-date": amzdate,
                "x-amz-content-sha256": payload_hash,
                "Authorization": auth,
            },
        )
        resp = conn.getresponse()
        body = resp.read()
        if resp.status not in (200, 409):
            raise SystemExit(
                f"CreateBucket failed: HTTP {resp.status} {body.decode('utf-8', 'replace')}"
            )
    finally:
        conn.close()


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print("usage: s3_create_bucket.py HOST:PORT BUCKET", file=sys.stderr)
        return 2
    access = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    if not access or not secret:
        print("AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY are required", file=sys.stderr)
        return 2
    create_bucket(argv[1], argv[2], access, secret)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
