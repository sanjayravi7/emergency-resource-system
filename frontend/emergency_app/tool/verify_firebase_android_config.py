#!/usr/bin/env python3
"""Validate the Firebase Android app and OAuth clients in google-services.json.

The check has two halves:

1. ``android/app/google-services.json`` itself - the file the google-services
   Gradle plugin consumes. It must describe an Android app whose package name
   matches the repository's application ID, carry the ERAS Production project
   number, expose an OAuth **web** client (``client_type`` 3) and an OAuth
   **Android** client (``client_type`` 1) bound to that same package name.
2. The Android string resources the Gradle plugin *generates* from that file
   (``<build>/app/generated/res/google-services/<variant>/values/values.xml``).
   ``google_sign_in`` on Android reads ``default_web_client_id`` from those
   resources, so they are what actually reaches the Google Sign-In SDK. When
   the generated resources are present they are cross-checked against the JSON.

Nothing secret is printed: client IDs, API keys and the project number are
rendered as ``[len=..,fp=..]`` fingerprints, which are enough to compare two
configurations without disclosing a value.
"""

import argparse
import hashlib
import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

DEFAULT_APPLICATION_ID = "io.github.sanjayravi7.eras"
DEFAULT_GENERATED_RES = "build/app/generated/res/google-services"

CLIENT_TYPE_ANDROID = 1
CLIENT_TYPE_WEB = 3


def fail(message: str) -> None:
    print(f"Firebase Android config check failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def mask(value: str | None) -> str:
    """Render an identifier as a non-reversible, stable fingerprint."""
    if not value:
        return "<unset>"
    digest = hashlib.blake2b(value.encode("utf-8"), digest_size=4).hexdigest()
    return f"[len={len(value)},fp={digest}]"


def normalize_sha1(value: str) -> str:
    return value.replace(":", "").replace(" ", "").upper()


def android_clients(config: dict, application_id: str) -> list[dict]:
    """The client entries in the JSON that describe this Android app."""
    clients = config.get("client")
    if not isinstance(clients, list):
        fail("no client array is present")
    return [
        client
        for client in clients
        if ((client.get("client_info") or {}).get("android_client_info") or {}).get(
            "package_name"
        )
        == application_id
    ]


def oauth_clients(app_clients: list[dict], client_type: int) -> list[dict]:
    return [
        oauth
        for client in app_clients
        for oauth in client.get("oauth_client", [])
        if oauth.get("client_type") == client_type
    ]


def read_generated_resources(directory: Path) -> dict[str, dict[str, str]]:
    """Parse every ``values.xml`` the google-services plugin generated.

    Returns ``{variant: {resource_name: value}}``. Missing directories simply
    yield an empty mapping: a clean checkout has not built Android yet.
    """
    resources: dict[str, dict[str, str]] = {}
    if not directory.is_dir():
        return resources

    for values_file in sorted(directory.glob("*/values/values.xml")):
        try:
            root = ET.parse(values_file).getroot()
        except ET.ParseError as error:
            fail(f"{values_file} is not valid XML: {error}")
        resources[values_file.parent.parent.name] = {
            node.get("name"): (node.text or "").strip()
            for node in root.iter("string")
            if node.get("name")
        }
    return resources


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
        "--project-number",
        help="ERAS Production project number; required to match the JSON",
    )
    parser.add_argument(
        "--generated-res",
        default=DEFAULT_GENERATED_RES,
        help=(
            "Directory holding the google-services Gradle plugin's generated "
            "Android string resources"
        ),
    )
    parser.add_argument(
        "--require-generated-res",
        action="store_true",
        help="Fail when no generated Android resources were found",
    )
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

    # -- 1. Project identity -------------------------------------------------
    project = config.get("project_info") or {}
    project_id = project.get("project_id")
    if project_id != args.project_id:
        fail(f"project_id is {project_id!r}, expected {args.project_id!r}")

    project_number = str(project.get("project_number") or "")
    if args.project_number:
        expected = args.project_number.strip()
        if project_number != expected:
            fail(
                "project_number is "
                f"{mask(project_number)}, expected {mask(expected)}; "
                "google-services.json belongs to a different Firebase project"
            )
    elif not project_number:
        fail("project_info.project_number is absent")

    # -- 2. The Android app entry --------------------------------------------
    app_clients = android_clients(config, args.application_id)
    if not app_clients:
        clients = config.get("client") or []
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

    # -- 3. The OAuth web client (client_type 3) ------------------------------
    # google_sign_in reads this on Android as the `default_web_client_id`
    # resource, i.e. as the ID-token audience. Without it no ID token can be
    # requested at all.
    web_clients = oauth_clients(app_clients, CLIENT_TYPE_WEB)
    if not web_clients:
        fail(
            "no OAuth Web client (client_type 3) is present for "
            f"{args.application_id!r}; the generated resources will have no "
            "default_web_client_id and Android Google sign-in cannot request "
            "an ID token"
        )
    matching_web_clients = {oauth.get("client_id") for oauth in web_clients}
    if args.web_client_id not in matching_web_clients:
        fail(
            "the configured OAuth Web client ID "
            f"{mask(args.web_client_id)} is not present as client_type 3; the "
            f"file exposes {[mask(c) for c in sorted(matching_web_clients)]}"
        )

    # -- 4. The OAuth Android client (client_type 1) --------------------------
    # This is the entry that binds the package name to a signing certificate
    # fingerprint. A mismatch here is the classic DEVELOPER_ERROR (10).
    android_oauth = [
        oauth
        for oauth in oauth_clients(app_clients, CLIENT_TYPE_ANDROID)
        if ((oauth.get("android_info") or {}).get("package_name") == args.application_id)
    ]
    if not android_oauth:
        fail(
            "no Android OAuth client is present; add this app's SHA-1 fingerprint "
            "in Firebase project settings and download google-services.json again"
        )

    sha1s = sorted(
        {
            normalize_sha1(str((oauth.get("android_info") or {}).get("certificate_hash", "")))
            for oauth in android_oauth
            if (oauth.get("android_info") or {}).get("certificate_hash")
        }
    )
    if not sha1s:
        fail("Android OAuth clients have no SHA-1 certificate hashes")

    if args.release_sha1:
        release_sha1 = normalize_sha1(args.release_sha1)
        if release_sha1 not in sha1s:
            fail("the release signing SHA-1 is not registered in google-services.json")

    print(f"Firebase project: {project_id}")
    print(f"Firebase project number: {mask(project_number)}")
    print(f"Android application ID: {args.application_id}")
    print(f"OAuth Web client ID (client_type 3): {mask(args.web_client_id)} present")
    print(f"Android OAuth client IDs (client_type 1): {len(android_oauth)}")
    for oauth in android_oauth:
        print(f"  {mask(oauth.get('client_id'))}")
    print(f"Android OAuth SHA-1 certificate hashes in JSON: {len(sha1s)}")
    for sha1 in sha1s:
        print(f"  {sha1}")
    if args.release_sha1:
        print("Release signing SHA-1: registered")

    # -- 5. Cross-check the generated Android resources -----------------------
    generated_dir = Path(args.generated_res)
    generated = read_generated_resources(generated_dir)
    if not generated:
        if args.require_generated_res:
            fail(f"no generated Android resources were found under {generated_dir}")
        print(
            f"Generated Android resources: none found under {generated_dir} "
            "(build the APK to produce them; they are what the Android Google "
            "SDK actually reads)."
        )
    else:
        expected_web_client_id = args.web_client_id
        for variant, resources in generated.items():
            web_resource = resources.get("default_web_client_id")
            sender_resource = resources.get("gcm_defaultSenderId")
            project_resource = resources.get("project_id")
            if not web_resource:
                fail(
                    f"generated resources for {variant!r} have no "
                    "default_web_client_id string"
                )
            if web_resource != expected_web_client_id:
                fail(
                    f"generated default_web_client_id for {variant!r} is "
                    f"{mask(web_resource)}, not the configured "
                    f"{mask(expected_web_client_id)}; rebuild after refreshing "
                    "google-services.json"
                )
            if project_resource and project_resource != project_id:
                fail(
                    f"generated project_id for {variant!r} is "
                    f"{project_resource!r}, expected {project_id!r}"
                )
            if project_number and sender_resource != project_number:
                fail(
                    f"generated gcm_defaultSenderId for {variant!r} is "
                    f"{mask(sender_resource)}, expected the project number "
                    f"{mask(project_number)}"
                )
            print(
                f"Generated Android resources ({variant}): "
                f"default_web_client_id={mask(web_resource)} matches, "
                f"gcm_defaultSenderId={mask(sender_resource)} matches, "
                f"project_id={project_resource!r}, "
                f"google_api_key={mask(resources.get('google_api_key'))}"
            )

    print(
        "Note: google-services.json does not attest the SHA-256 fingerprint or "
        "Google Cloud web origins/redirect URIs; verify those separately in the "
        "Firebase and Google Cloud consoles."
    )


if __name__ == "__main__":
    main()
