#!/usr/bin/env python3
"""Uploads the signed bundle to a Google Play track as a draft release.

    python3 tools/play-upload.py [--track internal] [--aab app/build/outputs/bundle/release/app-release.aab]

"internal" is the internal-testing track ("alpha" is closed testing). Draft releases are rolled out from Play Console.
Auth: the service account key in ~/.config/google-play/play-publisher.json (or
$PLAY_SERVICE_ACCOUNT_JSON); it never lives in the repo.
"""
import argparse
import os
import sys

import google.auth.transport.requests
import requests
from google.oauth2 import service_account

PACKAGE = "com.dautovri.bitecurve"
API = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{PACKAGE}"
UPLOAD = f"https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/{PACKAGE}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--track", default="internal")
    parser.add_argument("--aab", default="app/build/outputs/bundle/release/app-release.aab")
    parser.add_argument("--notes", default="First test build.")
    args = parser.parse_args()

    key = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", os.path.expanduser("~/.config/google-play/play-publisher.json"))
    creds = service_account.Credentials.from_service_account_file(
        key, scopes=["https://www.googleapis.com/auth/androidpublisher"])
    creds.refresh(google.auth.transport.requests.Request())
    s = requests.Session()
    s.headers["Authorization"] = f"Bearer {creds.token}"

    def check(r: requests.Response) -> dict:
        if not r.ok:
            sys.exit(f"{r.request.method} {r.url.split('?')[0]} -> {r.status_code}: {r.text[:800]}")
        return r.json() if r.text else {}

    edit = check(s.post(f"{API}/edits"))["id"]
    with open(args.aab, "rb") as f:
        bundle = check(s.post(f"{UPLOAD}/edits/{edit}/bundles?uploadType=media",
                              data=f, headers={"Content-Type": "application/octet-stream"}, timeout=600))
    code = bundle["versionCode"]
    print(f"uploaded versionCode {code} (sha256 {bundle.get('sha256', '?')[:16]}…)")
    check(s.put(f"{API}/edits/{edit}/tracks/{args.track}", json={
        "track": args.track,
        "releases": [{
            "versionCodes": [str(code)],
            "status": "draft",
            "releaseNotes": [{"language": "en-US", "text": args.notes}],
        }],
    }))
    check(s.post(f"{API}/edits/{edit}:commit"))
    print(f"committed: draft release on track '{args.track}'")
    return 0


if __name__ == "__main__":
    sys.exit(main())
