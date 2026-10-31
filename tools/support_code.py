#!/usr/bin/env python3
"""Print today's Support Code, which opens a DriverCentral build's Lua window for
an hour. It is computed as src/lib/support-code.lua computes it, from the build
secret SUPPORT_CODE_SECRET, read the way a build reads it.
"""

from __future__ import annotations

import hashlib
import hmac
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from preprocess import build_secret, parse_env_file  # noqa: E402

NAME = "SUPPORT_CODE_SECRET"
MIN_SECRET_LENGTH = 32
ALPHABET = "0123456789ABCDEFGHJKMNPQRSTVWXYZ"


def code_for(secret: str, day: str) -> str:
    """The code for a UTC day (`YYYY-MM-DD`), as XXXXX-XXXXX."""
    digest = hmac.new(
        secret.encode("utf-8"), f"Support Code {day}".encode("utf-8"), hashlib.sha256
    ).hexdigest()
    n = int(digest[:13], 16)
    code = ""
    for _ in range(10):
        code = ALPHABET[n % 32] + code
        n //= 32
    return f"{code[:5]}-{code[5:]}"


def main() -> None:
    repo_root = Path(__file__).parent.parent
    secret = build_secret(NAME, parse_env_file(repo_root / ".env"))
    if len(secret) < MIN_SECRET_LENGTH:
        raise SystemExit(
            f"{NAME} is not set, or shorter than {MIN_SECRET_LENGTH} characters. "
            "See CONTRIBUTING.md, The Support Code."
        )
    day = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    print(
        f"{code_for(secret, day)}  (for {day} UTC, taken until 01:00 UTC the day after)"
    )


if __name__ == "__main__":
    main()
