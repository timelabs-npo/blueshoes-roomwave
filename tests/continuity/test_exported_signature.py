"""Offline signature-policy regressions; Apple command calls are simulated."""
from copy import deepcopy
from datetime import datetime, timedelta, timezone
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

SOURCE = Path(__file__).resolve().parents[2] / 'scripts/release/verify-exported-signature.py'
spec = importlib.util.spec_from_file_location('exported_signature', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ExportedSignatureTests(unittest.TestCase):
    def setUp(self):
        self.now = datetime.now(timezone.utc)
        self.info = {'CFBundleIdentifier': module.BUNDLE, 'CFBundleShortVersionString': '0.3.0',
                     'CFBundleVersion': '1003.1'}
        self.entitlements = {'application-identifier': module.TEAM + '.' + module.BUNDLE,
                             'com.apple.developer.team-identifier': module.TEAM, 'get-task-allow': False}
        self.certificate = b'synthetic DER certificate for offline policy tests'
        self.profile = {'Entitlements': {**self.entitlements, 'beta-reports-active': True},
                        'TeamIdentifier': [module.TEAM], 'ExpirationDate': self.now + timedelta(days=1),
                        'DeveloperCertificates': [self.certificate]}

    def verify(self, **changes):
        values = {'info': self.info, 'entitlements': self.entitlements, 'profile': self.profile,
                  'signed_team': module.TEAM, 'signer_certificate': self.certificate,
                  'version': '0.3.0', 'build': '1003.1', 'now': self.now}
        return module.verify_metadata(**{**values, **changes})

    def test_exact_distribution_identity_and_actual_signer_membership(self):
        result = self.verify()
        self.assertTrue(result['signature_verified'])
        self.assertTrue(result['distribution_profile_verified'])
        self.assertEqual(result['team_id'], module.TEAM)
        self.assertEqual(len(result['signer_certificate_sha256']), 64)
        without_debug = dict(self.entitlements)
        del without_debug['get-task-allow']
        self.assertTrue(self.verify(entitlements=without_debug)['signature_verified'])

    def test_rejects_wrong_compiled_bundle_version_and_build(self):
        for key in self.info:
            with self.subTest(key=key), self.assertRaises(ValueError):
                self.verify(info={**self.info, key: 'different'})

    def test_rejects_other_signature_team_and_unlisted_signer(self):
        for changes in [{'signed_team': 'OTHERTEAM'}, {'signer_certificate': b'other cert'},
                        {'signer_certificate': b''}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(**changes)

    def test_rejects_debug_wildcard_and_wrong_team_entitlements_in_either_source(self):
        for source in ['signature', 'profile']:
            for field, value in [('get-task-allow', True), ('get-task-allow', 'false'),
                                 ('application-identifier', module.TEAM + '.*'),
                                 ('com.apple.developer.team-identifier', 'OTHERTEAM')]:
                entitlements, profile = deepcopy(self.entitlements), deepcopy(self.profile)
                target = entitlements if source == 'signature' else profile['Entitlements']
                target[field] = value
                with self.subTest(source=source, field=field, value=value), self.assertRaises(ValueError):
                    self.verify(entitlements=entitlements, profile=profile)

    def test_rejects_device_enterprise_expired_or_incomplete_profiles(self):
        for changes in [{'ProvisionedDevices': ['device']}, {'ProvisionedDevices': []},
                        {'ProvisionsAllDevices': True}, {'TeamIdentifier': ['OTHERTEAM']},
                        {'ExpirationDate': self.now - timedelta(seconds=1)}, {'ExpirationDate': None},
                        {'DeveloperCertificates': []}, {'Entitlements': {**self.entitlements}},
                        {'Entitlements': {k: v for k, v in self.profile['Entitlements'].items() if k != 'get-task-allow'}}]:
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                self.verify(profile={**self.profile, **changes})

    def test_accepts_plist_naive_utc_expiration(self):
        self.assertTrue(self.verify(profile={**self.profile,
            'ExpirationDate': (self.now + timedelta(days=1)).replace(tzinfo=None)})['signature_verified'])

    def test_rejects_unsafe_or_ambiguous_archive_before_running_tools(self):
        for names in [['../escape'], ['Payload/One.app/Info.plist', 'Payload/Two.app/Info.plist']]:
            with self.subTest(names=names), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / 'app.ipa'
                with zipfile.ZipFile(path, 'w') as archive:
                    for name in names:
                        archive.writestr(name, b'synthetic')
                with patch.object(module, 'run_command') as command, self.assertRaises(ValueError):
                    module.verify_ipa(path, '0.3.0', '1003.1')
                command.assert_not_called()

    def test_actual_export_orchestration_requires_codesign_and_binds_ipa_digest(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'app.ipa'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('Payload/Roomwave.app/Info.plist', plistlib.dumps(self.info))
            calls = []
            def command(*args, **kwargs):
                calls.append(args)
                output, error = b'', b''
                if args[0] == 'ditto':
                    app = Path(args[-1]) / 'Payload/Roomwave.app'
                    app.mkdir(parents=True)
                    (app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
                    (app / 'embedded.mobileprovision').write_bytes(b'synthetic CMS')
                elif '--entitlements' in args:
                    output = plistlib.dumps(self.entitlements)
                elif '-dvv' in args:
                    error = ('TeamIdentifier=' + module.TEAM + '\n').encode()
                elif args[0] == 'security':
                    profile = {**self.profile, 'ExpirationDate': self.profile['ExpirationDate'].replace(tzinfo=None)}
                    output = plistlib.dumps(profile)
                elif '--extract-certificates' in args:
                    Path(args[3] + '0').write_bytes(self.certificate)
                return subprocess.CompletedProcess(args, 0, output, error)
            with patch.object(module, 'run_command', side_effect=command):
                receipt = module.verify_ipa(path, '0.3.0', '1003.1')
            self.assertEqual(receipt['ipa_sha256'], module.digest(path))
            self.assertTrue(any(call[0:4] == ('codesign', '--verify', '--deep', '--strict') for call in calls))
            def rejecting_command(*args, **kwargs):
                if args[0:2] == ('codesign', '--verify'):
                    raise ValueError('invalid signature')
                return command(*args, **kwargs)
            with patch.object(module, 'run_command', side_effect=rejecting_command), self.assertRaises(ValueError):
                module.verify_ipa(path, '0.3.0', '1003.1')


if __name__ == '__main__':
    unittest.main()
