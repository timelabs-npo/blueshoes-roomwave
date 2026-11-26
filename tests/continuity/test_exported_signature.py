"""Offline signature-policy regressions; Apple command calls are simulated."""
from copy import deepcopy
from contextlib import redirect_stderr
from datetime import datetime, timedelta, timezone
import importlib.util
import io
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
                     'CFBundleVersion': '1003.1', 'CFBundleExecutable': 'Roomwave'}
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
        for key in ['CFBundleIdentifier', 'CFBundleShortVersionString', 'CFBundleVersion']:
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

    def test_default_keychain_group_is_authorized_by_exact_or_apple_team_wildcard(self):
        entitlements = {**self.entitlements, 'keychain-access-groups': [module.APP_IDENTIFIER],
                        'beta-reports-active': True}
        for groups in [[module.APP_IDENTIFIER], [module.TEAM + '.*'],
                       [module.TEAM + '.*', 'com.apple.token']]:
            profile = {**self.profile, 'Entitlements': {**self.profile['Entitlements'],
                       'keychain-access-groups': groups}}
            with self.subTest(groups=groups):
                self.assertTrue(self.verify(entitlements=entitlements, profile=profile)['signature_verified'])

    def test_rejects_unreviewed_capabilities_claimed_by_app(self):
        for field, value in [('aps-environment', 'production'),
                             ('com.apple.developer.associated-domains', ['applinks:example.invalid']),
                             ('com.apple.security.application-groups', ['group.other']),
                             ('beta-reports-active', False)]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(entitlements={**self.entitlements, field: value})

    def test_profile_may_authorize_unused_capabilities_and_shared_keychain_groups(self):
        unused = {'aps-environment': 'production',
                  'com.apple.security.application-groups': ['group.other']}
        profile = {**self.profile, 'Entitlements': {**self.profile['Entitlements'], **unused,
                   'keychain-access-groups': [module.TEAM + '.other', module.TEAM + '.*', 'com.apple.token']}}
        entitlements = {**self.entitlements, 'keychain-access-groups': [module.APP_IDENTIFIER]}
        self.assertTrue(self.verify(entitlements=entitlements, profile=profile)['signature_verified'])
        for field, value in unused.items():
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.verify(entitlements={**entitlements, field: value}, profile=profile)
        with self.assertRaises(ValueError):
            self.verify(entitlements={**entitlements, 'keychain-access-groups': [module.TEAM + '.other']},
                        profile=profile)

    def test_rejects_wrong_or_unauthorized_keychain_groups_without_generic_globbing(self):
        for groups in [[module.TEAM + '.*'], ['OTHERTEAM.other'], [module.APP_IDENTIFIER, 'com.apple.token'],
                       [], module.APP_IDENTIFIER, None]:
            with self.subTest(app_groups=groups), self.assertRaises(ValueError):
                self.verify(entitlements={**self.entitlements, 'keychain-access-groups': groups})
        for groups in [None, [], ['com.apple.token'], ['*'], [module.TEAM + '.other'],
                       [123], module.TEAM + '.*']:
            profile = {**self.profile, 'Entitlements': {**self.profile['Entitlements'],
                       'keychain-access-groups': groups}}
            with self.subTest(profile_groups=groups), self.assertRaises(ValueError):
                self.verify(entitlements={**self.entitlements, 'keychain-access-groups': [module.APP_IDENTIFIER]},
                            profile=profile)

    def test_uuid_reader_requires_actual_unique_arm_architecture_uuid_pairs(self):
        uuid = '01234567-89AB-CDEF-0123-456789ABCDEF'
        line = 'UUID: ' + uuid + ' (arm64) /synthetic/Roomwave\n'
        with patch.object(module, 'run_command', return_value=subprocess.CompletedProcess([], 0, line.encode())):
            self.assertEqual(module.macho_uuids(Path('/synthetic/Roomwave')), {'arm64': uuid})
        for output in ['', 'not a UUID\n', line + line, line.replace('(arm64)', '(x86_64)'),
                       line.replace(uuid, 'bad-uuid')]:
            with self.subTest(output=output), patch.object(module, 'run_command',
                    return_value=subprocess.CompletedProcess([], 0, output.encode())), self.assertRaises(ValueError):
                module.macho_uuids(Path('/synthetic/Roomwave'))

    def test_rejects_unsafe_or_ambiguous_archive_before_running_tools(self):
        for names in [['../escape'], ['Payload/One.app/Info.plist', 'Payload/Two.app/Info.plist']]:
            with self.subTest(names=names), tempfile.TemporaryDirectory() as folder:
                path = Path(folder) / 'app.ipa'
                with zipfile.ZipFile(path, 'w') as archive:
                    for name in names:
                        archive.writestr(name, b'synthetic')
                with patch.object(module, 'run_command') as command, self.assertRaises(ValueError):
                    module.verify_ipa(path, '0.3.0', '1003.1', Path(folder) / 'unused-symbols.zip')
                command.assert_not_called()

    def test_actual_export_orchestration_requires_codesign_and_binds_ipa_digest(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'app.ipa'
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr('Payload/Roomwave.app/Info.plist', plistlib.dumps(self.info))
            symbols_archive = Path(folder) / 'symbols.zip'
            with zipfile.ZipFile(symbols_archive, 'w') as archive:
                archive.writestr(module.DSYM_MEMBER, b'synthetic DWARF bytes')
            app_uuid = '01234567-89AB-CDEF-0123-456789ABCDEF'
            symbols_uuid = app_uuid
            mutate_symbols = False
            calls = []
            def command(*args, **kwargs):
                calls.append(args)
                output, error = b'', b''
                if args[0] == 'ditto':
                    if args[3] == str(path):
                        app = Path(args[-1]) / 'Payload/Roomwave.app'
                        app.mkdir(parents=True)
                        (app / 'Info.plist').write_bytes(plistlib.dumps(self.info))
                        (app / 'embedded.mobileprovision').write_bytes(b'synthetic CMS')
                        (app / 'Roomwave').write_bytes(b'synthetic Mach-O bytes')
                    else:
                        symbols = Path(args[-1]) / module.DSYM_MEMBER
                        symbols.parent.mkdir(parents=True)
                        symbols.write_bytes(b'synthetic DWARF bytes')
                elif '--entitlements' in args:
                    output = plistlib.dumps(self.entitlements)
                elif '-dvv' in args:
                    error = ('TeamIdentifier=' + module.TEAM + '\n').encode()
                elif args[0] == 'security':
                    profile = {**self.profile, 'ExpirationDate': self.profile['ExpirationDate'].replace(tzinfo=None)}
                    output = plistlib.dumps(profile)
                elif any(arg.startswith('--extract-certificates') for arg in args):
                    # Optional long-option values must be joined with '='.
                    # A separated prefix is another codesign object path.
                    self.assertEqual(len(args), 4)
                    self.assertEqual(args[0:2], ('codesign', '-d'))
                    self.assertTrue(args[2].startswith('--extract-certificates='))
                    prefix = args[2].partition('=')[2]
                    self.assertTrue(prefix)
                    self.assertTrue(Path(args[3]).is_dir())
                    Path(prefix + '0').write_bytes(self.certificate)
                elif args[0:3] == ('xcrun', 'dwarfdump', '--uuid'):
                    is_symbols = 'symbols' in Path(args[-1]).parts
                    uuid = symbols_uuid if is_symbols else app_uuid
                    output = ('UUID: ' + uuid + ' (arm64) ' + args[-1] + '\n').encode()
                    if is_symbols and mutate_symbols:
                        with symbols_archive.open('ab') as stream:
                            stream.write(b'changed-after-inspection')
                return subprocess.CompletedProcess(args, 0, output, error)
            with patch.object(module, 'run_command', side_effect=command):
                receipt = module.verify_ipa(path, '0.3.0', '1003.1', symbols_archive)
            self.assertEqual(receipt['ipa_sha256'], module.digest(path))
            self.assertEqual(receipt['dsym_sha256'], module.digest(symbols_archive))
            self.assertEqual(receipt['dsym_uuids'], {'arm64': app_uuid})
            self.assertTrue(any(call[0:4] == ('codesign', '--verify', '--deep', '--strict') for call in calls))
            self.assertTrue(any(call[0:5] == ('codesign', '-d', '--entitlements', '-', '--xml') for call in calls))
            symbols_uuid = 'FFFFFFFF-89AB-CDEF-0123-456789ABCDEF'
            with patch.object(module, 'run_command', side_effect=command), self.assertRaises(ValueError):
                module.verify_ipa(path, '0.3.0', '1003.1', symbols_archive)
            symbols_uuid = app_uuid
            mutate_symbols = True
            with patch.object(module, 'run_command', side_effect=command), self.assertRaises(ValueError):
                module.verify_ipa(path, '0.3.0', '1003.1', symbols_archive)
            mutate_symbols = False
            def rejecting_command(*args, **kwargs):
                if args[0:2] == ('codesign', '--verify'):
                    raise ValueError('invalid signature')
                return command(*args, **kwargs)
            with patch.object(module, 'run_command', side_effect=rejecting_command), self.assertRaises(ValueError):
                module.verify_ipa(path, '0.3.0', '1003.1', symbols_archive)

    def test_cli_failure_reports_stage_without_raw_exception_data_or_receipt(self):
        with tempfile.TemporaryDirectory() as folder:
            output = Path(folder) / 'signature.json'
            error_log = io.StringIO()
            def unreadable_export(*args, **kwargs):
                with module.verification_stage('exported-entitlements'):
                    raise ValueError('private-tool-output-sentinel')
            with patch.object(module, 'verify_ipa', side_effect=unreadable_export), redirect_stderr(error_log):
                status = module.main([str(Path(folder) / 'app.ipa'), '--build', '1003.1',
                                      '--dsym-archive', str(Path(folder) / 'symbols.zip'),
                                      '--output', str(output)])
            self.assertEqual(status, 2)
            self.assertIn('exported-entitlements: ValueError', error_log.getvalue())
            self.assertNotIn('private-tool-output-sentinel', error_log.getvalue())
            self.assertFalse(output.exists())

    def test_policy_failure_keeps_fixed_reason_and_stage(self):
        with self.assertRaisesRegex(module.VerificationFailure, 'signer-certificate: codesign verification failed'):
            with module.verification_stage('signer-certificate'):
                module.require(False, 'codesign verification failed')


if __name__ == '__main__':
    unittest.main()
