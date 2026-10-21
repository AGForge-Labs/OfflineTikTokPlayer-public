"""Exact production-declaration projection; no Apple command is invoked."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "apple_buffer_projection", ROOT / "scripts" / "generate-apple-buffer-resources.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
FIRST = b'''    @MainActor final class PreparedVideoResource {
        // UTF8: \xcf\x80 \xe4\xb8\xad\xe6\x96\x87 } and a fake class VideoResourcePreparation {
        let text = "not code: { class PreparedVideoResource {} }"
        /* outer { /* nested } */ still a comment } */
        func retire() { if true { } }
    }'''
SECOND = b'''    @MainActor final class VideoResourcePreparation {
        let raw = #"literal { }"#
        #if DEBUG
        var debugOnly: ContinuousPictureInPicture?
        #else
        func install() { if true { } }
        #endif
    }'''
SOURCE = b"import Foundation\n@MainActor\nfinal class ContinuousPictureInPicture: NSObject {\n" + FIRST + b"\n" + SECOND + b"\n}\n"


class AppleBufferProjectionTests(unittest.TestCase):
    def test_exact_blocks_and_debug_body_are_copied_not_reimplemented(self):
        output, provenance = MODULE.project_resources(SOURCE)
        self.assertEqual(output.count(FIRST), 1)
        self.assertEqual(output.count(SECOND), 1)
        self.assertIn(b"#if DEBUG\n#error(", output)
        self.assertIn(b"import Foundation\nimport AVFoundation\nimport CoreVideo\n", output)
        self.assertIn(b"@MainActor\nfinal class ContinuousPictureInPicture: NSObject {\n", output)
        self.assertEqual(provenance["blocks"], 2)
        self.assertTrue(provenance["nonDEBUGOnly"])
        self.assertEqual(provenance["sourceSHA256"], hashlib.sha256(SOURCE).hexdigest())
        self.assertEqual(provenance["outputSHA256"], hashlib.sha256(output).hexdigest())

    def test_crlf_and_utf8_body_bytes_offsets_and_hashes_are_exact(self):
        raw = b"// \xcf\x80 before class\r\n" + SOURCE.replace(b"\n", b"\r\n")
        output, provenance = MODULE.project_resources(raw)
        for label, expected in [("prepared", FIRST), ("preparation", SECOND)]:
            expected = expected.replace(b"\n", b"\r\n")
            start, count = provenance[label + "OffsetBytes"], provenance[label + "LengthBytes"]
            self.assertEqual(raw[start:start + count], expected)
            self.assertIn(expected, output)
            self.assertEqual(provenance[label + "SHA256"], hashlib.sha256(expected).hexdigest())

    def test_real_production_source_ranges_and_hashes_match_generated_bytes(self):
        raw = (ROOT / MODULE.SOURCE).read_bytes()
        output, provenance = MODULE.project_resources(raw)
        for label, name in [("prepared", b"PreparedVideoResource"),
                            ("preparation", b"VideoResourcePreparation")]:
            start, count = provenance[label + "OffsetBytes"], provenance[label + "LengthBytes"]
            block = raw[start:start + count]
            self.assertTrue(block.lstrip().startswith(b"@MainActor final class " + name + b" {"))
            self.assertTrue(block.endswith(b"}"))
            self.assertEqual(output.count(block), 1)
            self.assertEqual(hashlib.sha256(block).hexdigest(), provenance[label + "SHA256"])

    def test_missing_and_duplicate_named_declarations_fail_closed(self):
        for source in [SOURCE.replace(FIRST, b""), SOURCE.replace(SECOND, b""),
                       SOURCE.replace(FIRST, FIRST + b"\n" + FIRST),
                       SOURCE.replace(SECOND, SECOND + b"\n" + SECOND),
                       SOURCE + b"\nstruct PreparedVideoResource {}\n"]:
            with self.subTest(source=source[:40]):
                with self.assertRaises(MODULE.ProjectionError):
                    MODULE.project_resources(source)

    def test_exact_unique_top_level_outer_namespace_is_required(self):
        for source in [SOURCE.replace(b"class ContinuousPictureInPicture", b"class Other"),
                       SOURCE.replace(b": NSObject", b": Other"),
                       SOURCE + b"\n@MainActor final class ContinuousPictureInPicture: NSObject {}\n",
                       b"final class Wrapper {\n" + SOURCE + b"}\n"]:
            with self.assertRaises(MODULE.ProjectionError):
                MODULE.project_resources(source)

    def test_both_resources_must_be_immediate_members_of_that_outer_class(self):
        outside = SOURCE.replace(SECOND, b"") + SECOND + b"\n"
        nested = SOURCE.replace(SECOND, b"    final class Wrapper {\n" + SECOND + b"\n    }")
        for source in [outside, nested]:
            with self.assertRaises(MODULE.ProjectionError):
                MODULE.project_resources(source)

    def test_conditional_declarations_are_rejected_but_body_conditionals_survive(self):
        for source in [b"#if DEBUG\n" + SOURCE + b"#endif\n",
                       SOURCE.replace(SECOND, b"    #if DEBUG\n" + SECOND + b"\n    #endif")]:
            with self.assertRaises(MODULE.ProjectionError):
                MODULE.project_resources(source)
        output, _ = MODULE.project_resources(SOURCE)
        self.assertIn(SECOND, output)

    def test_unbalanced_braces_and_unterminated_swift_lexemes_are_rejected(self):
        for source in [SOURCE[:-2], SOURCE + b"}\n", SOURCE + b"/* unterminated",
                       SOURCE + b'\n"unterminated', SOURCE.replace(b"        #endif\n", b"")]:
            with self.assertRaises(MODULE.ProjectionError):
                MODULE.project_resources(source)

    def test_raw_byte_limit_and_utf8_validation_are_enforced(self):
        exactly = SOURCE + b" " * (MODULE.MAX_SOURCE_BYTES - len(SOURCE))
        _, provenance = MODULE.project_resources(exactly)
        self.assertEqual(provenance["sourceBytes"], MODULE.MAX_SOURCE_BYTES)
        for source in [exactly + b" ", SOURCE + b"\xff"]:
            with self.assertRaises(MODULE.ProjectionError):
                MODULE.project_resources(source)

    def test_generation_uses_only_fixed_outputs_and_failure_removes_stale_projection(self):
        temporary_parent = ROOT / "artifacts"
        temporary_parent.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=temporary_parent) as directory:
            root = Path(directory)
            source = root / MODULE.SOURCE
            source.parent.mkdir(parents=True)
            source.write_bytes(SOURCE)
            provenance = MODULE.generate(root)
            output, manifest = root / MODULE.OUTPUT, root / MODULE.PROVENANCE
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), provenance["outputSHA256"])
            self.assertEqual(json.loads(manifest.read_bytes()), provenance)
            self.assertEqual(set(output.parent.iterdir()), {output, manifest})
            source.write_bytes(b"broken source")
            with self.assertRaises(MODULE.ProjectionError):
                MODULE.generate(root)
            self.assertFalse(output.exists())
            self.assertFalse(manifest.exists())


if __name__ == "__main__":
    unittest.main()
