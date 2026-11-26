#!/usr/bin/env python3
"""Verify that public OAuth configuration matches the reviewed source exactly."""
import os
from pathlib import Path
import plistlib
import re


def configure(path, client_id=None):
    info = plistlib.loads(path.read_bytes())
    value = info.get('XOAuthClientID', '')
    if not isinstance(value, str) or (value and not re.fullmatch(r'[A-Za-z0-9_.~-]{1,256}', value)):
        raise ValueError('X_OAUTH_CLIENT_ID must be a public OAuth client identifier without whitespace')
    # A workflow variable is a consistency assertion, never an unreviewed edit
    # to the binary built under a source-only release receipt.
    if client_id is not None and client_id != value:
        raise ValueError('X OAuth configuration differs from the reviewed source; update it through code review')
    return bool(value)


if __name__ == '__main__':
    path = Path(__file__).resolve().parents[2] / 'apps/ios/Roomwave/Info.plist'
    enabled = configure(path, os.environ.get('X_OAUTH_CLIENT_ID') or None)
    print('X OAuth client: configured' if enabled else 'X OAuth client: not configured; guest play remains available')
