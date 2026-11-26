#!/usr/bin/env python3
"""Verify the actual exported IPA before it may become an upload intent.

The receipt is operator evidence tied to the IPA digest, not a standalone
cryptographic attestation. Apple signing tools are required for live execution.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import tempfile
from pathlib import Path, PurePosixPath
import zipfile

APP = '6837899703'
BUNDLE = 'org.timelabs.moleculefoundry'
TEAM = '398XACWZ7G'
APP_IDENTIFIER = TEAM + '.' + BUNDLE
EXPECTED_ENTITLEMENTS = frozenset({
    'application-identifier', 'com.apple.developer.team-identifier',
    'get-task-allow', 'beta-reports-active', 'keychain-access-groups',
})
UUID_PATTERN = r'[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
DSYM_MEMBER = 'dSYMs/Roomwave.app.dSYM/Contents/Resources/DWARF/Roomwave'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def verify_metadata(info, entitlements, profile, signed_team, signer_certificate, version, build, now=None):
    require(isinstance(info, dict) and isinstance(entitlements, dict) and isinstance(profile, dict),
            'Exported signing metadata must contain plist dictionaries')
    for key, expected in {'CFBundleIdentifier': BUNDLE, 'CFBundleShortVersionString': version,
                          'CFBundleVersion': build}.items():
        require(info.get(key) == expected, 'Exported app identity differs: ' + key)
    require(signed_team == TEAM, 'Exported code signature belongs to another team')
    for label, values in [('signature', entitlements), ('profile', profile.get('Entitlements'))]:
        require(isinstance(values, dict), 'Missing exported ' + label + ' entitlements')
        if label == 'signature':
            require(set(values) <= EXPECTED_ENTITLEMENTS,
                    'Exported app claims an unreviewed capability')
        require(values.get('application-identifier') == APP_IDENTIFIER,
                'Exported ' + label + ' application identifier differs')
        require(values.get('com.apple.developer.team-identifier') == TEAM,
                'Exported ' + label + ' team entitlement differs')
        # An absent code-signature entitlement grants no debugging privilege.
        # App Store profiles must explicitly deny it.
        debug = values.get('get-task-allow', False) if label == 'signature' else values.get('get-task-allow')
        require(debug is False, 'Exported ' + label + ' permits debugging or has an invalid debugging declaration')
        if 'beta-reports-active' in values:
            require(values['beta-reports-active'] is True, 'Invalid beta distribution entitlement')
    # Profiles may authorize more capabilities and groups than the app claims.
    # This app claims only its own group, authorized by an exact match or the
    # one known Apple team wildcard; no general-purpose wildcard matching.
    profile_groups = profile['Entitlements'].get('keychain-access-groups')
    if 'keychain-access-groups' in profile['Entitlements']:
        require(isinstance(profile_groups, list)
                and all(isinstance(group, str) and bool(group) for group in profile_groups),
                'Embedded profile contains malformed keychain authorizations')
    if 'keychain-access-groups' in entitlements:
        require(entitlements['keychain-access-groups'] == [APP_IDENTIFIER],
                'Exported app must use only its own keychain access group')
        require(profile_groups is not None and
                (APP_IDENTIFIER in profile_groups or TEAM + '.*' in profile_groups),
                'Embedded profile does not authorize the app keychain access group')
    require(profile.get('TeamIdentifier') == [TEAM], 'Embedded distribution profile belongs to another team')
    require('ProvisionedDevices' not in profile and profile.get('ProvisionsAllDevices', False) is False,
            'Embedded profile must be for App Store distribution')
    require(profile['Entitlements'].get('beta-reports-active') is True,
            'Embedded profile is not enabled for App Store beta distribution')
    expiration = profile.get('ExpirationDate')
    require(isinstance(expiration, datetime), 'Embedded profile has no valid expiration date')
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    require(expiration > (now or datetime.now(timezone.utc)), 'Embedded distribution profile has expired')
    certificates = profile.get('DeveloperCertificates')
    require(isinstance(certificates, list) and isinstance(signer_certificate, bytes) and bool(signer_certificate)
            and signer_certificate in certificates,
            'Exported signer certificate is not permitted by the embedded profile')
    return {'app_id': APP, 'bundle_identifier': BUNDLE, 'version': version, 'build': build,
            'team_id': TEAM, 'signature_verified': True, 'distribution_profile_verified': True,
            'signer_certificate_sha256': hashlib.sha256(signer_certificate).hexdigest()}


def run_command(*arguments, seconds=60):
    result = subprocess.run(arguments, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            timeout=seconds, check=False)
    require(result.returncode == 0, arguments[0] + ' verification failed')
    return result


def macho_uuids(path):
    """Read actual Mach-O UUIDs, rejecting missing, duplicate or malformed slices."""
    result = {}
    output = run_command('xcrun', 'dwarfdump', '--uuid', str(path)).stdout.decode('utf-8')
    for line in output.splitlines():
        match = re.fullmatch(r'UUID: (' + UUID_PATTERN + r') \((arm64|arm64e)\) .+', line.strip())
        require(match is not None and match[2] not in result, 'Invalid or duplicate Mach-O UUID evidence')
        result[match[2]] = match[1].upper()
    require(bool(result), 'Mach-O UUID evidence is missing')
    return result


def verify_ipa(ipa, version, build, dsym_archive):
    require(ipa.is_file() and not ipa.is_symlink(), 'A regular exported IPA is required')
    checksum = digest(ipa)
    with zipfile.ZipFile(ipa) as archive:
        for name in archive.namelist():
            path = PurePosixPath(name)
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in name,
                    'IPA contains an unsafe archive path')
        roots = [name for name in archive.namelist() if name.startswith('Payload/')
                 and name.count('/') == 2 and name.endswith('.app/Info.plist')]
        require(len(roots) == 1, 'IPA must contain exactly one primary app')
    require(dsym_archive.is_file() and not dsym_archive.is_symlink(), 'A regular dSYM archive is required')
    symbols_checksum = digest(dsym_archive)
    with zipfile.ZipFile(dsym_archive) as archive:
        for name in archive.namelist():
            path = PurePosixPath(name)
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in name,
                    'dSYM archive contains an unsafe path')
        require(archive.namelist().count(DSYM_MEMBER) == 1, 'Expected application symbols are missing or ambiguous')
    with tempfile.TemporaryDirectory(prefix='roomwave-export-check-') as folder:
        root = Path(folder)
        run_command('ditto', '-x', '-k', str(ipa), str(root), seconds=120)
        apps = list((root / 'Payload').glob('*.app'))
        require(len(apps) == 1 and apps[0].is_dir() and not apps[0].is_symlink(),
                'IPA must extract to exactly one regular primary app')
        app = apps[0]
        run_command('codesign', '--verify', '--deep', '--strict', str(app))
        entitlements = plistlib.loads(run_command('codesign', '-d', '--entitlements', '-', '--xml', str(app)).stdout)
        detail = run_command('codesign', '-dvv', str(app))
        team = re.search(rb'^TeamIdentifier=(\S+)\s*$', detail.stderr, re.MULTILINE)
        require(team is not None, 'Exported code signature has no team identifier')
        embedded = app / 'embedded.mobileprovision'
        require(embedded.is_file() and not embedded.is_symlink(), 'Embedded distribution profile is missing')
        profile = plistlib.loads(run_command('security', 'cms', '-D', '-i', str(embedded)).stdout)
        certificate_prefix = root / 'signer-'
        run_command('codesign', '-d', '--extract-certificates', str(certificate_prefix), str(app))
        signer = Path(str(certificate_prefix) + '0').read_bytes()
        info = plistlib.loads((app / 'Info.plist').read_bytes())
        receipt = verify_metadata(info, entitlements, profile, team[1].decode('ascii'), signer, version, build)
        require(info.get('CFBundleExecutable') == 'Roomwave', 'Unexpected exported executable')
        executable = app / 'Roomwave'
        require(executable.is_file() and not executable.is_symlink(), 'Exported executable is missing')
        symbols_root = root / 'symbols'
        run_command('ditto', '-x', '-k', str(dsym_archive), str(symbols_root), seconds=120)
        symbols = symbols_root / DSYM_MEMBER
        require(symbols.is_file() and not symbols.is_symlink(), 'Application symbols are missing')
        uuids = macho_uuids(executable)
        require(uuids == macho_uuids(symbols), 'Application symbols do not match the exported executable UUIDs')
    require(digest(ipa) == checksum, 'Exported IPA changed during signature verification')
    require(digest(dsym_archive) == symbols_checksum, 'dSYM archive changed during verification')
    return {**receipt, 'ipa_sha256': checksum, 'dsym_verified': True,
            'dsym_sha256': symbols_checksum, 'dsym_uuids': uuids}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('ipa', type=Path)
    parser.add_argument('--build', required=True)
    parser.add_argument('--version', default=(Path(__file__).resolve().parents[2] / 'VERSION').read_text().strip())
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--dsym-archive', type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        require(re.fullmatch(r'\d+\.\d+\.\d+', args.version), 'Invalid release version')
        require(re.fullmatch(r'\d+(?:\.\d+){0,2}', args.build), 'Invalid release build')
        receipt = verify_ipa(args.ipa, args.version, args.build, args.dsym_archive)
        with args.output.open('x', encoding='utf-8') as stream:
            json.dump(receipt, stream, indent=2, sort_keys=True)
            stream.write('\n')
        print(json.dumps(receipt, sort_keys=True))
        return 0
    except (OSError, ValueError, zipfile.BadZipFile, plistlib.InvalidFileException,
            subprocess.SubprocessError, UnicodeError):
        # Private tool stderr, profile fields and local paths stay out of logs.
        print('Exported IPA signature verification failed; no release receipt or upload intent is authorized',
              file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
