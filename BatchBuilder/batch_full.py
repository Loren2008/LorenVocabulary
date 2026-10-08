#!/usr/bin/env python3
"""Deprecated compatibility entry point for the guarded expansion pipeline.

The original script embedded a bearer key and wrote model output directly into the
live database without a schema gate.  Keep the familiar command name, but delegate
all work to ``expand_words.py`` so secrets, resumability, staging, backups, and
quality checks follow the same production path.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path


PIPELINE = Path(__file__).with_name("expand_words.py")


def main() -> None:
    os.execv(
        sys.executable,
        [sys.executable, str(PIPELINE), *sys.argv[1:]],
    )


if __name__ == "__main__":
    main()
