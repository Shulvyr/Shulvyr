"""Check source validation across Git's platform text checkout formats."""

import hashlib
import contextlib
import io
import sys
import tempfile
import unittest
from pathlib import Path

from build_probe import ROOT, run, verify_header, visual_studio_generator


class HeaderValidation(unittest.TestCase):
    source = b"int rtcExample(void);\n#define EXAMPLE 1\n"
    digest = hashlib.sha256(source).hexdigest()

    def test_git_lf_and_windows_crlf_checkouts(self):
        verify_header(self.source, self.digest)
        verify_header(self.source.replace(b"\n", b"\r\n"), self.digest)

    def test_changed_declaration_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "checksum mismatch"):
            verify_header(self.source.replace(b"int", b"void"), self.digest)

    def test_trailing_bytes_are_not_trimmed(self):
        for changed in [self.source + b"\n", self.source.rstrip(b"\n"), self.source + b"\0"]:
            with self.subTest(changed=changed), self.assertRaises(ValueError):
                verify_header(changed, self.digest)

    def test_bare_carriage_returns_are_not_normalized(self):
        with self.assertRaises(ValueError):
            verify_header(self.source.replace(b"\n", b"\r"), self.digest)


class WindowsCompilerSelection(unittest.TestCase):
    def test_local_2022_and_hosted_2026_generators(self):
        self.assertEqual(visual_studio_generator("17.14.36218.1"), "Visual Studio 17 2022")
        self.assertEqual(visual_studio_generator("18.0.11205.1"), "Visual Studio 18 2026")

    def test_missing_or_unreviewed_compiler_is_rejected(self):
        for installed in ["", "16.11", "19.0", "garbage"]:
            with self.subTest(installed=installed), self.assertRaises(ValueError):
                visual_studio_generator(installed)


class PrivateDiagnostics(unittest.TestCase):
    def test_probe_errors_and_leak_counts_keep_private_text_redacted(self):
        work = ROOT / "work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=work) as folder:
            log = Path(folder) / "probe.log"
            output = io.StringIO()
            program = "\n".join([
                "print('native probe leaked 1 Zig allocations')",
                "print('native probe failed: OutOfMemory')",
                "print('native probe failed: a=ice-pwd:synthetic')",
                "print('native probe leaked 2 Zig allocations a=ice-pwd:synthetic')",
                "raise SystemExit(1)",
            ])
            with contextlib.redirect_stdout(output), self.assertRaises(RuntimeError):
                run([sys.executable, "-c", program], log=log, private=True)
            self.assertEqual(output.getvalue(), "native probe leaked 1 Zig allocations\nnative probe failed: OutOfMemory\n")
            self.assertIn("a=ice-pwd:synthetic", log.read_text(encoding="utf-8"))

    def test_failed_native_test_keeps_raw_sdp_out_of_output(self):
        work = ROOT / "work"
        work.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=work) as folder:
            log = Path(folder) / "native.log"
            output = io.StringIO()
            command = [sys.executable, "-c", "print('a=ice-pwd:synthetic'); print('transport cycle 1 failed: ProbeTimeout'); raise SystemExit(1)"]
            with contextlib.redirect_stdout(output), self.assertRaises(RuntimeError):
                run(command, log=log, private=True)
            self.assertEqual(output.getvalue(), "transport cycle 1 failed: ProbeTimeout\n")
            self.assertIn("a=ice-pwd:synthetic", log.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
