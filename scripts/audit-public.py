#!/usr/bin/env python3
"""Audit the selected public tree, reporting paths and categories, not values."""

import argparse
import sys

from public_source import audit, source_files

parser = argparse.ArgumentParser()
parser.add_argument("--from-checkout", action="store_true", help="Use the public allowlist without Git metadata")
args = parser.parse_args()
paths = source_files(from_checkout=args.from_checkout)
findings = audit(paths)
for path, reason in findings:
    print(f"FAIL {path}: {reason}")
if not paths:
    print("FAIL: no public files selected; stage the intended source first")
    sys.exit(1)
if findings:
    sys.exit(1)
print(f"Public-source checks passed for {len(paths)} files. Review any new binary assets separately.")
