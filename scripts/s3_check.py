#!/usr/bin/env python3
"""Signed ListObjects probe for S3-compatible buckets.

Prints one JSON object:
  ok, http, code, region, hint

Used by backends/transport/s3 after keys are stored so restic init is not
the first time we learn Access Denied.
"""
from __future__ import annotations

import datetime
import hashlib
import hmac
import json
import os
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

HINTS = {
    "InvalidAccessKeyId": "Access key id is not recognized. Paste the key id (AKIA… / ASIA…), not an IAM role ARN.",
    "SignatureDoesNotMatch": "Secret access key does not match this access key id.",
    "NoSuchBucket": "No bucket with that name exists for these credentials.",
    "AccessDenied": "These keys cannot list the bucket. The IAM policy needs s3:ListBucket on the bucket ARN and s3:GetObject/PutObject/DeleteObject on the object ARN (bucket/*). AWS also returns Access Denied for a missing bucket.",
    "InvalidToken": "Temporary credentials need a session token (AWS_SESSION_TOKEN).",
    "ExpiredToken": "The session token has expired. Create new temporary keys or use a long-lived AKIA key.",
    "AuthorizationHeaderMalformed": "Region does not match the bucket. Use the region AWS reports.",
    "PermanentRedirect": "Bucket lives in another region. Use that region’s S3 endpoint.",
}


def _sign(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def signing_key(secret: str, datestamp: str, region: str) -> bytes:
    k = _sign(("AWS4" + secret).encode("utf-8"), datestamp)
    k = _sign(k, region)
    k = _sign(k, "s3")
    return _sign(k, "aws4_request")


def _host_port(endpoint: str, tls: bool) -> tuple[str, str]:
    endpoint = endpoint.strip()
    endpoint = endpoint.removeprefix("https://").removeprefix("http://")
    endpoint = endpoint.rstrip("/")
    host = endpoint
    port = ""
    if ":" in endpoint and not endpoint.endswith("]"):
        host, port_s = endpoint.rsplit(":", 1)
        if port_s.isdigit():
            port = port_s
    if not port:
        port = "443" if tls else "80"
    return host, port


def is_amazon(host: str) -> bool:
    h = host.lower()
    return h == "s3.amazonaws.com" or h.endswith(".amazonaws.com") or h.endswith(".amazonaws.com.cn")


def list_url(endpoint: str, bucket: str, region: str, tls: bool) -> tuple[str, str, str]:
    """Return (url, canonical_uri, host_header). Amazon uses virtual-hosted style."""
    host, port = _host_port(endpoint, tls)
    scheme = "https" if tls else "http"
    query = "list-type=2&max-keys=1"
    if is_amazon(host):
        vhost = f"{bucket}.{host}"
        host_header = vhost if port in ("443", "80") else f"{vhost}:{port}"
        url = f"{scheme}://{host_header}/?{query}"
        return url, "/", host_header
    host_header = host if port in ("443", "80") else f"{host}:{port}"
    path = "/" + urllib.parse.quote(bucket, safe="-_.~")
    url = f"{scheme}://{host_header}{path}?{query}"
    return url, path, host_header


def signed_headers(
    method: str,
    canonical_uri: str,
    canonical_query: str,
    host_header: str,
    access: str,
    secret: str,
    region: str,
    token: str = "",
    extra_headers: dict[str, str] | None = None,
) -> dict[str, str]:
    now = datetime.datetime.now(datetime.timezone.utc)
    amzdate = now.strftime("%Y%m%dT%H%M%SZ")
    datestamp = now.strftime("%Y%m%d")
    payload_hash = hashlib.sha256(b"").hexdigest()
    headers = {
        "host": host_header,
        "x-amz-content-sha256": payload_hash,
        "x-amz-date": amzdate,
    }
    if token:
        headers["x-amz-security-token"] = token
    if extra_headers:
        headers.update({k.lower(): v for k, v in extra_headers.items()})
    signed = ";".join(sorted(headers))
    canonical_headers = "".join(f"{k}:{headers[k]}\n" for k in sorted(headers))
    canonical_request = (
        f"{method}\n{canonical_uri}\n{canonical_query}\n"
        f"{canonical_headers}\n{signed}\n{payload_hash}"
    )
    scope = f"{datestamp}/{region}/s3/aws4_request"
    string_to_sign = (
        "AWS4-HMAC-SHA256\n"
        f"{amzdate}\n{scope}\n"
        f"{hashlib.sha256(canonical_request.encode()).hexdigest()}"
    )
    signature = hmac.new(
        signing_key(secret, datestamp, region),
        string_to_sign.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    headers["authorization"] = (
        f"AWS4-HMAC-SHA256 Credential={access}/{scope}, "
        f"SignedHeaders={signed}, Signature={signature}"
    )
    return headers


def _xml_code(body: bytes) -> str:
    text = body.decode("utf-8", "replace")
    start = text.find("<Code>")
    end = text.find("</Code>")
    if start >= 0 and end > start:
        return text[start + 6 : end].strip()
    return ""


def check_access(
    endpoint: str,
    bucket: str,
    region: str,
    access: str,
    secret: str,
    tls: bool = True,
    token: str = "",
    timeout: float = 12,
) -> dict:
    region = (region or "us-east-1").strip() or "us-east-1"
    bucket = bucket.strip()
    out = {"ok": False, "http": 0, "code": "", "region": region, "hint": ""}
    if not endpoint or not bucket or not access or not secret:
        out["code"] = "MissingInput"
        out["hint"] = "endpoint, bucket, access key, and secret key are required"
        return out
    url, canonical_uri, host_header = list_url(endpoint, bucket, region, tls)
    hdrs = signed_headers(
        "GET",
        canonical_uri,
        "list-type=2&max-keys=1",
        host_header,
        access,
        secret,
        region,
        token=token,
    )
    req_headers = {
        "Host": host_header,
        "x-amz-content-sha256": hdrs["x-amz-content-sha256"],
        "x-amz-date": hdrs["x-amz-date"],
        "Authorization": hdrs["authorization"],
    }
    if token:
        req_headers["x-amz-security-token"] = token
    req = urllib.request.Request(url, method="GET", headers=req_headers)
    ctx = ssl.create_default_context()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            body = resp.read()
            out["http"] = resp.status
            out["ok"] = 200 <= resp.status < 300
            header_region = resp.headers.get("x-amz-bucket-region", "") or ""
            if header_region:
                out["region"] = header_region.strip()
            if not out["ok"]:
                out["code"] = _xml_code(body) or f"HTTP{resp.status}"
    except urllib.error.HTTPError as e:
        body = e.read() if e.fp else b""
        out["http"] = e.code
        out["code"] = _xml_code(body) or (e.reason or f"HTTP{e.code}")
        header_region = ""
        if e.headers:
            header_region = e.headers.get("x-amz-bucket-region", "") or ""
        if header_region:
            out["region"] = header_region.strip()
        if e.code in (200, 204):
            out["ok"] = True
        if e.code in (301, 307) and header_region and header_region != region:
            out["code"] = "PermanentRedirect"
    except (urllib.error.URLError, TimeoutError, ValueError, OSError) as e:
        out["code"] = "NetworkError"
        out["hint"] = f"Could not reach {endpoint}: {e}"
        return out

    if out["ok"]:
        out["hint"] = ""
        return out
    if out["region"] and out["region"] != region and out["code"] in (
        "PermanentRedirect",
        "AuthorizationHeaderMalformed",
        "AccessDenied",
        "",
    ):
        out["hint"] = (
            f"Bucket region looks like {out['region']}, not {region}. "
            "Re-run setup with that region."
        )
        return out
    out["hint"] = HINTS.get(out["code"], out["code"] or f"HTTP {out['http']}")
    return out


def main(argv: list[str]) -> int:
    if len(argv) < 5 or argv[1] != "access":
        print(
            "usage: s3_check.py access ENDPOINT BUCKET REGION TLS",
            file=sys.stderr,
        )
        return 2
    endpoint, bucket, region, tls_s = argv[2], argv[3], argv[4], argv[5] if len(argv) > 5 else "1"
    access = os.environ.get("AWS_ACCESS_KEY_ID", "")
    secret = os.environ.get("AWS_SECRET_ACCESS_KEY", "")
    token = os.environ.get("AWS_SESSION_TOKEN", "")
    result = check_access(
        endpoint,
        bucket,
        region,
        access,
        secret,
        tls=tls_s != "0",
        token=token,
    )
    print(json.dumps(result, separators=(",", ":")))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
