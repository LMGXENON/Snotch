#!/usr/bin/env python3
"""
Generate printable license keys and hashed records for backend storage.

Usage:
  python3 scripts/generate_license_keys.py --count 50 --prefix SNTCH --out licenses.csv
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import hmac
import secrets
from datetime import datetime, timezone

ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"


def random_chunk(length: int = 4) -> str:
    return "".join(secrets.choice(ALPHABET) for _ in range(length))


def generate_key(prefix: str) -> str:
    chunks = [random_chunk() for _ in range(4)]
    return f"{prefix}-" + "-".join(chunks)


def hash_key(key: str, pepper: str) -> str:
    # Store hash only in DB. Keep pepper in server secret env.
    digest = hmac.new(pepper.encode("utf-8"), key.encode("utf-8"), hashlib.sha256).hexdigest()
    return digest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--prefix", type=str, default="SNTCH")
    parser.add_argument("--out", type=str, default="licenses.csv")
    parser.add_argument(
        "--pepper",
        type=str,
        default="",
        help="Optional pepper. If omitted, script reads LICENSE_PEPPER env fallback behavior by prompting blank hash pepper.",
    )
    args = parser.parse_args()

    pepper = args.pepper.strip()
    if not pepper:
        # For quick local testing only. For production pass --pepper from secure env.
        pepper = "CHANGE_ME_SERVER_SIDE_SECRET"

    rows = []
    now = datetime.now(timezone.utc).isoformat()

    for _ in range(args.count):
        key = generate_key(args.prefix.upper())
        key_hash = hash_key(key, pepper)
        rows.append({
            "license_key": key,
            "license_hash": key_hash,
            "created_at": now,
            "devices_allowed": 2,
            "status": "active",
        })

    with open(args.out, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=["license_key", "license_hash", "created_at", "devices_allowed", "status"],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} licenses to {args.out}")
    print("IMPORTANT: only store/use license_hash in production DB; share license_key with customer.")


if __name__ == "__main__":
    main()
