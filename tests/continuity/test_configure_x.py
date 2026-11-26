"""The public OAuth build input cannot change reviewed source bytes."""
import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[2] / 'scripts/release/configure-x.py'
spec = importlib.util.spec_from_file_location('configure_public_x', SOURCE)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ConfigurePublicXTests(unittest.TestCase):
    def test_matching_or_absent_assertion_preserves_exact_reviewed_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            original = plistlib.dumps({'XOAuthClientID': 'synthetic-public-client', 'Keep': 'unchanged'})
            path.write_bytes(original)
            for supplied in [None, 'synthetic-public-client']:
                self.assertTrue(module.configure(path, supplied))
                self.assertEqual(path.read_bytes(), original)

    def test_different_or_invalid_input_is_rejected_without_mutation_or_value_leakage(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            original = plistlib.dumps({'XOAuthClientID': 'synthetic-reviewed-client'})
            path.write_bytes(original)
            for supplied in ['synthetic-unreviewed-client', '', 'invalid whitespace', 123]:
                with self.subTest(supplied=supplied), self.assertRaises(ValueError) as failure:
                    module.configure(path, supplied)
                self.assertNotIn('synthetic-reviewed-client', str(failure.exception))
                self.assertNotIn('synthetic-unreviewed-client', str(failure.exception))
                self.assertEqual(path.read_bytes(), original)

    def test_missing_configuration_preserves_guest_only_source(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            for info in [{}, {'XOAuthClientID': ''}]:
                original = plistlib.dumps(info)
                path.write_bytes(original)
                self.assertFalse(module.configure(path))
                self.assertEqual(path.read_bytes(), original)
                with self.assertRaises(ValueError):
                    module.configure(path, 'synthetic-unreviewed-client')

    def test_invalid_committed_value_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'Info.plist'
            for value in ['invalid whitespace', 123, 'x' * 257]:
                path.write_bytes(plistlib.dumps({'XOAuthClientID': value}))
                with self.subTest(value=value), self.assertRaises(ValueError):
                    module.configure(path)


if __name__ == '__main__':
    unittest.main()
