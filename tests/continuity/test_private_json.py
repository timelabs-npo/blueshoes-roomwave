"""Real-file regressions for the protected JSON reader; no Apple API calls."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
HARNESS = r'''
import fs from 'node:fs';
import { resolve } from 'node:path';
import { syncBuiltinESMExports } from 'node:module';

const input = JSON.parse(fs.readFileSync(0, 'utf8'));
const absolute = resolve(input.path);
const original = { open: fs.openSync, stat: fs.fstatSync, read: fs.readSync };
let descriptor = null;
let changedAfterStat = false;
const reads = [];
fs.openSync = function(path, ...args) {
  const opened = original.open(path, ...args);
  if (path === absolute && descriptor === null) descriptor = opened;
  return opened;
};
fs.fstatSync = function(opened, ...args) {
  const information = original.stat(opened, ...args);
  if (opened === descriptor && !changedAfterStat && input.change) {
    changedAfterStat = true;
    if (input.change === 'replace-path') {
      fs.renameSync(absolute, absolute + '.opened');
      fs.writeFileSync(absolute, JSON.stringify({ source: 'replacement-path' }), { mode: 0o600 });
    } else if (input.change === 'grow') {
      fs.appendFileSync(absolute, 'x'.repeat(30000));
    }
  }
  return information;
};
fs.readSync = function(opened, buffer, offset, length, position) {
  const count = original.read(opened, buffer, offset, length, position);
  if (opened === descriptor) reads.push({ count, bufferSize: buffer.length });
  return count;
};
syncBuiltinESMExports();
globalThis.fetch = async () => { throw new Error('Network is forbidden in this fixture'); };
const { privateJSON } = await import(HELPER_URL);
let result;
try {
  result = { ok: true, value: privateJSON(input.path, input.contact) };
} catch (error) {
  result = { ok: false, code: error.code ?? null, message: error.message };
}
let descriptorClosed = descriptor === null;
if (descriptor !== null) {
  try { original.stat(descriptor); }
  catch (error) { descriptorClosed = error.code === 'EBADF'; }
}
fs.openSync = original.open;
fs.fstatSync = original.stat;
fs.readSync = original.read;
syncBuiltinESMExports();
console.log(JSON.stringify({ ...result, descriptorClosed, reads, changedAfterStat,
  noFollowSupported: typeof fs.constants.O_NOFOLLOW === 'number' && fs.constants.O_NOFOLLOW !== 0 }));
'''.replace('HELPER_URL', json.dumps((ROOT / 'scripts/release/public-beta.mjs').as_uri()))


@unittest.skipUnless(shutil.which('node'), 'Node is required for private JSON reader tests')
class PrivateJSONTests(unittest.TestCase):
    def read(self, path, *, contact=True, change=None):
        result = subprocess.run(
            ['node', '--input-type=module', '-e', HARNESS],
            input=json.dumps({'path': str(path), 'contact': contact, 'change': change}),
            text=True, capture_output=True, timeout=15,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, '')
        parsed = json.loads(result.stdout)
        self.assertTrue(parsed['descriptorClosed'], 'The opened descriptor must close on every outcome')
        return parsed

    def write(self, directory, payload, *, name='contact.json', mode=0o600):
        path = Path(directory) / name
        path.write_bytes(payload)
        path.chmod(mode)
        return path

    def assert_blocked(self, result):
        self.assertFalse(result['ok'])
        self.assertEqual(result['code'], 'BLOCKED_INPUT')

    def test_valid_owner_only_contact_outside_repository(self):
        with tempfile.TemporaryDirectory() as directory:
            expected = {'firstName': 'Fixture', 'email': 'fixture@example.invalid'}
            path = self.write(directory, json.dumps(expected).encode())
            result = self.read(path)
            self.assertTrue(result['ok'])
            self.assertEqual(result['value'], expected)

    @unittest.skipIf(os.name == 'nt', 'Windows keeps the existing non-POSIX permission behavior')
    def test_contact_with_group_or_other_permissions_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            for mode in (0o640, 0o604, 0o644):
                with self.subTest(mode=oct(mode)):
                    path = self.write(directory, b'{"safe":true}', mode=mode)
                    result = self.read(path)
                    self.assert_blocked(result)
                    self.assertEqual(result['reads'], [])

    def test_dotdot_filename_inside_repository_is_not_a_parent_component(self):
        # This first relative path component starts with '..' but is not '..'.
        with tempfile.TemporaryDirectory(prefix='..private-json-', dir=ROOT) as directory:
            path = self.write(directory, b'{"safe":true}')
            result = self.read(path)
            self.assert_blocked(result)
            self.assertEqual(result['reads'], [])
            self.assertIn('outside the repository', result['message'])

    def test_content_file_may_remain_inside_repository_with_ordinary_mode(self):
        with tempfile.TemporaryDirectory(prefix='private-json-content-', dir=ROOT) as directory:
            path = self.write(directory, b'{"reviewNotes":"Reviewed fixture content"}', mode=0o644)
            result = self.read(path, contact=False)
            self.assertTrue(result['ok'])
            self.assertEqual(result['value']['reviewNotes'], 'Reviewed fixture content')
            self.assert_blocked(self.read(path, contact=True))

    def test_exact_size_limit_succeeds_and_larger_file_is_rejected_before_read(self):
        with tempfile.TemporaryDirectory() as directory:
            encoded = b'{"safe":true}'
            path = self.write(directory, encoded + b' ' * (20000 - len(encoded)))
            result = self.read(path)
            self.assertTrue(result['ok'])
            self.assertEqual(result['value'], {'safe': True})
            self.assertEqual(sum(read['count'] for read in result['reads']), 20000)
            path = self.write(directory, encoded + b' ' * (20001 - len(encoded)))
            result = self.read(path)
            self.assert_blocked(result)
            self.assertEqual(result['reads'], [])

    def test_malformed_json_never_exposes_values_or_the_private_path(self):
        with tempfile.TemporaryDirectory() as directory:
            secret = 'PRIVATE_VALUE_SENTINEL_92b47@example.invalid'
            path = self.write(directory, ('{"email":"' + secret + '", invalid}').encode(),
                              name='PRIVATE_PATH_SENTINEL.json')
            result = self.read(path)
            self.assert_blocked(result)
            output = json.dumps(result)
            self.assertNotIn(secret, output)
            self.assertNotIn(str(path), output)
            self.assertNotIn('PRIVATE_PATH_SENTINEL', output)

    def test_directory_is_not_accepted_as_a_regular_file(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.read(Path(directory))
            self.assert_blocked(result)
            self.assertEqual(result['reads'], [])

    @unittest.skipUnless(hasattr(os, 'mkfifo'), 'FIFO creation is a POSIX-only regression')
    def test_fifo_is_rejected_without_waiting_for_a_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'pipe.json'
            os.mkfifo(path, 0o600)
            result = self.read(path)
            self.assert_blocked(result)
            self.assertEqual(result['reads'], [])

    def test_final_symlink_is_rejected_where_no_follow_is_supported(self):
        with tempfile.TemporaryDirectory() as directory:
            target = self.write(directory, b'{"safe":true}')
            link = Path(directory) / 'contact-link.json'
            try:
                link.symlink_to(target.name)
            except (NotImplementedError, OSError) as error:
                self.skipTest(f'Symlink creation unavailable: {type(error).__name__}')
            result = self.read(link)
            if not result['noFollowSupported']:
                self.skipTest('Node does not expose O_NOFOLLOW on this platform')
            self.assert_blocked(result)
            self.assertEqual(result['reads'], [])

    @unittest.skipIf(os.name == 'nt', 'Open-file rename semantics are platform-specific')
    def test_path_replaced_after_fstat_cannot_replace_the_opened_file(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(directory, b'{"source":"opened-file"}')
            result = self.read(path, change='replace-path')
            self.assertTrue(result['changedAfterStat'])
            self.assertTrue(result['ok'])
            self.assertEqual(result['value'], {'source': 'opened-file'})
            self.assertEqual(json.loads(path.read_text()), {'source': 'replacement-path'})

    def test_growth_after_fstat_is_bounded_and_rejected_before_parsing(self):
        with tempfile.TemporaryDirectory() as directory:
            path = self.write(directory, b'{"safe":true}')
            result = self.read(path, change='grow')
            self.assertTrue(result['changedAfterStat'])
            self.assert_blocked(result)
            self.assertIn('size limit', result['message'])
            self.assertEqual(sum(read['count'] for read in result['reads']), 20001)
            self.assertTrue(all(read['bufferSize'] == 20001 for read in result['reads']))


if __name__ == '__main__':
    unittest.main()
