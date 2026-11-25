#!/usr/bin/env python3
"""Inject only the public native OAuth client ID; credentials never belong in an IPA."""
import os
from pathlib import Path
import plistlib
import re


def configure(path, client_id=None):
    info = plistlib.loads(path.read_bytes())
    value = info.get('XOAuthClientID', '') if client_id is None else client_id
    if not isinstance(value, str) or (value and not re.fullmatch(r'[A-Za-z0-9_.~-]{1,256}', value)):
        raise ValueError('X_OAUTH_CLIENT_ID must be a public OAuth client identifier without whitespace')
    if info.get('XOAuthClientID') != value:
        info['XOAuthClientID'] = value
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
    return bool(value)


if __name__ == '__main__':
    path = Path(__file__).resolve().parents[2] / 'apps/ios/Roomwave/Info.plist'
    enabled = configure(path, os.environ.get('X_OAUTH_CLIENT_ID') or None)
    print('X OAuth client: configured' if enabled else 'X OAuth client: not configured; guest play remains available')
