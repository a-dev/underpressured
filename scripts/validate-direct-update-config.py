#!/usr/bin/env python3
"""Validate Sparkle settings supplied to the direct-distribution Xcode target.

Xcode Run Script usage: pass the generated plist output path followed by the
base Info.plist path. The script reads
CONFIGURATION, SPARKLE_FEED_URL, SPARKLE_PUBLIC_ED_KEY, and SPARKLE_TEST_FEED
from the build environment. Debug builds must leave feed and key empty unless
SPARKLE_TEST_FEED=YES, in which case they must provide a loopback fixture feed
and a valid base64-encoded 32-byte Ed25519 public key. Release builds require
an HTTPS feed URL and the same public-key format. This script never generates
or stores private keys and performs no network access.
"""

import base64
import binascii
import os
import ipaddress
import plistlib
import socket
import sys
from pathlib import Path
from urllib.parse import urlsplit


def fail(message: str) -> None:
    raise ValueError(message)


def validate_key(value: str) -> None:
    if not value:
        fail("SPARKLE_PUBLIC_ED_KEY is required")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (binascii.Error, ValueError):
        fail("SPARKLE_PUBLIC_ED_KEY must be valid base64")
    if len(decoded) != 32:
        fail("SPARKLE_PUBLIC_ED_KEY must decode to exactly 32 bytes")


def parse_feed(value: str):
    if not value:
        fail("SPARKLE_FEED_URL is required")
    if any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in value):
        fail("SPARKLE_FEED_URL must not contain whitespace or control characters")
    try:
        parsed = urlsplit(value)
        # Accessing port also validates malformed port syntax.
        _ = parsed.port
    except ValueError:
        fail("SPARKLE_FEED_URL is malformed")
    if parsed.scheme.lower() not in ("http", "https") or not parsed.hostname:
        fail("SPARKLE_FEED_URL must be an absolute HTTP or HTTPS URL with a host")
    if parsed.username is not None or parsed.password is not None:
        fail("SPARKLE_FEED_URL must not contain credentials")
    if "?" in value or "#" in value:
        fail("SPARKLE_FEED_URL must not contain a query or fragment")
    return parsed


def is_loopback_host(host: str) -> bool:
    return host.lower() in {"localhost", "127.0.0.1", "::1"}


def validate(configuration: str, feed: str, key: str, test_feed: str) -> None:
    if configuration == "Debug":
        if test_feed == "YES":
            parsed = parse_feed(feed)
            if not is_loopback_host(parsed.hostname):
                fail("SPARKLE_TEST_FEED=YES requires a loopback host (localhost, 127.0.0.1, or ::1)")
            validate_key(key)
            return
        if test_feed not in ("", "NO"):
            fail("SPARKLE_TEST_FEED must be YES or NO")
        if feed or key:
            fail("Debug builds must leave SPARKLE_FEED_URL and SPARKLE_PUBLIC_ED_KEY empty; set SPARKLE_TEST_FEED=YES only for loopback fixtures")
        return

    if configuration == "Release":
        if test_feed not in ("", "NO"):
            fail("SPARKLE_TEST_FEED must be empty or NO in Release builds")
        parsed = parse_feed(feed)
        if parsed.scheme.lower() != "https":
            fail("Release SPARKLE_FEED_URL must use HTTPS")
        host = parsed.hostname.lower().rstrip(".")
        try:
            address = ipaddress.ip_address(host)
            loopback = address.is_loopback or (isinstance(address, ipaddress.IPv6Address) and address.ipv4_mapped is not None and address.ipv4_mapped.is_loopback)
        except ValueError:
            loopback = host == "localhost" or host.endswith(".localhost")
            try:
                # inet_aton parses legacy numeric IPv4 locally, without DNS or I/O.
                loopback = loopback or ipaddress.IPv4Address(socket.inet_aton(host)).is_loopback
            except OSError:
                pass
        if loopback:
            fail("Release SPARKLE_FEED_URL must not use a loopback host")
        validate_key(key)
        return

    fail(f"Unsupported CONFIGURATION '{configuration}'; expected Debug or Release")


def write_target_plist(output_path: str, base_path: str, configuration: str, feed: str, key: str, test_feed: str) -> None:
    with Path(base_path).open("rb") as source:
        info = plistlib.load(source)
    for name in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUAllowsAutomaticUpdates", "UPUpdateMode"):
        info.pop(name, None)

    info["SUAllowsAutomaticUpdates"] = False
    if configuration == "Release":
        info["SUFeedURL"] = feed
        info["SUPublicEDKey"] = key
        info["UPUpdateMode"] = "release"
    elif test_feed == "YES":
        info["SUFeedURL"] = feed
        info["SUPublicEDKey"] = key
        info["SUEnableAutomaticChecks"] = False
        info["UPUpdateMode"] = "fixture"
    else:
        info["SUEnableAutomaticChecks"] = False
        info["UPUpdateMode"] = "disabled"

    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with destination.open("wb") as output:
        plistlib.dump(info, output, fmt=plistlib.FMT_XML, sort_keys=False)


def main() -> int:
    try:
        validate(
            os.environ.get("CONFIGURATION", ""),
            os.environ.get("SPARKLE_FEED_URL", ""),
            os.environ.get("SPARKLE_PUBLIC_ED_KEY", ""),
            os.environ.get("SPARKLE_TEST_FEED", ""),
        )
        if len(sys.argv) == 3:
            write_target_plist(
                sys.argv[1], sys.argv[2], os.environ["CONFIGURATION"],
                os.environ.get("SPARKLE_FEED_URL", ""),
                os.environ.get("SPARKLE_PUBLIC_ED_KEY", ""),
                os.environ.get("SPARKLE_TEST_FEED", ""),
            )
        elif len(sys.argv) != 1:
            raise ValueError("usage: validate-direct-update-config.py [OUTPUT_PLIST BASE_INFO_PLIST]")
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
