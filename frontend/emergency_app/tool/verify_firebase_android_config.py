#!/usr/bin/env python3
"""Validate the Firebase Android app and OAuth clients in google-services.json."""

import argparse
import json
import sys
from pathlib import Path

DEFAULT_APPLICATION_ID = "io.github.sanjayravi7.eras"


def fail(message: str) -> None:
    print(f"Firebase Android config check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--file",
        default="android/app/google-services.json",
        help="Path to the Firebase Android google-services.json",
    )
    parser.add_argument("--project-id", required=True)
    parser.add_argument("--web-client-id", required=True)
    parser.add_argument("--application-id", default=DEFAULT_APPLICATION_ID)
    parser.add_argument(
        "--release-sha1",
        help="Optional SHA-1 of the release certificate to require in the JSON",
    )
    args = parser.parse_args()

    path = Path(args.file)
    if not path.is_file():
        fail(f"{path} is missing; download it for the configured Firebase Android app")

    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        fail(f"{path} is not readable valid JSON")

    project = config.get("project_info") or {}
    project_id = project.get("project_id")
    if project_id != args.project_id:
        fail(f"project_id is {project_id!r}, expected {args.project_id!r}")

    clients = config.get("client")
    if not isinstance(clients, list):
        fail("no client array is present")

    app_clients = [
        client
        for client in clients
        if ((client.get("client_info") or {}).get("android_client_info") or {}).get(
            "package_name"
        )
        == args.application_id
    ]
    if not app_clients:
        packages = sorted(
            {
                info.get("package_name")
                for client in clients
                if (info := (client.get("client_info") or {}).get("android_client_info"))
                and info.get("package_name")
            }
        )
        fail(
            f"application ID {args.application_id!r} is absent; file contains {packages!r}"
        )

    matching_web_clients = {
        oauth.get("client_id")
        for client in app_clients
        for oauth in client.get("oauth_client", [])
        if oauth.get("client_type") == 3
    }
    if args.web_client_id not in matching_web_clients:
        fail("the configured OAuth Web client ID is not present as client_type 3")

    android_clients = [
        oauth
        for client in app_clients
        for oauth in client.get("oauth_client", [])
        if oauth.get("client_type") == 1
        and ((oauth.get("android_info") or {}).get("package_name") == args.application_id)
    ]
    if not android_clients:
        fail(
            "no Android OAuth client is present; add this app's SHA-1 fingerprint "
            "in Firebase project settings and download google-services.json again"
        )

    sha1s = sorted(
        {
            str((oauth.get("android_info") or {}).get("certificate_hash", ""))
            .replace(":", "")
            .upper()
            for oauth in android_clients
            if (oauth.get("android_info") or {}).get("certificate_hash")
        }
    )
    if not sha1s:
        fail("Android OAuth clients have no SHA-1 certificate hashes")

    if args.release_sha1:
        release_sha1 = args.release_sha1.replace(":", "").replace(" ", "").upper()
        if release_sha1 not in sha1s:
            fail("the release signing SHA-1 is not registered in google-services.json")

    print(f"Firebase project: {project_id}")
    print(f"Android application ID: {args.application_id}")
    print(f"OAuth Web client ID: {args.web_client_id}")
    print("Android OAuth client IDs:")
    for oauth in android_clients:
        print(f"  {oauth.get('client_id')}")
    print("Android OAuth SHA-1 certificate hashes in JSON:")
    for sha1 in sha1s:
        print(f"  {sha1}")
    if args.release_sha1:
        print("Release signing SHA-1: registered")
    print(
        "Note: google-services.json does not attest the SHA-256 fingerprint or "
        "Google Cloud web origins/redirect URIs; verify those separately in the "
        "Firebase and Google Cloud consoles."
    )


if __name__ == "__main__":
    main()
