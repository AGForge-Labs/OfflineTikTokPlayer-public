"""Synthetic build-product identity and transport controls; no SDK or network."""
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/native-profile-products.py"

class NativeProfileProductsTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location("profile_products", SCRIPT)
        self.module = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.module)
        temp = tempfile.TemporaryDirectory(); self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.products = self.root / "build/Products"
        self.products.mkdir(parents=True)
        app = self.products / "Debug-iphonesimulator/Player.app/Player"
        app.parent.mkdir(parents=True); app.write_bytes(b"synthetic executable"); app.chmod(0o755)
        (self.products / "Player.xctestrun").write_text("synthetic xctestrun")
        self.context = dict(source="a" * 40, xcode="Xcode synthetic", sdk="26.6", architecture="arm64", profile="b" * 64, optimization="-O", debugHooks=True)
        self.archive = self.root / "products.tar.gz"
        self.target = self.root / "test/Products"

    def packed(self):
        self.module.pack(self.products, self.archive, self.context)

    def rewrite(self, alter):
        with tarfile.open(self.archive) as tar:
            entries = [(m, tar.extractfile(m).read() if m.isfile() else None) for m in tar]
        entries = alter(entries)
        with tarfile.open(self.archive, "w:gz") as tar:
            for member, data in entries:
                if data is not None: member.size = len(data)
                tar.addfile(member, io.BytesIO(data) if data is not None else None)

    def test_round_trip_preserves_bytes_permissions_and_relative_symlinks(self):
        (self.products / "alias").symlink_to("Player.xctestrun")
        self.packed(); self.module.unpack(self.archive, self.target, self.context)
        app = self.target / "Debug-iphonesimulator/Player.app/Player"
        self.assertEqual(app.read_bytes(), b"synthetic executable")
        self.assertEqual(app.stat().st_mode & 0o777, 0o755)
        self.assertTrue((self.target / "alias").is_symlink())
        self.assertEqual((self.target / "alias").read_text(), "synthetic xctestrun")

    def test_changed_source_toolchain_or_profile_fails_before_extraction(self):
        self.packed()
        for field in ("source", "xcode", "sdk", "architecture", "profile", "optimization", "debugHooks"):
            with self.subTest(field=field):
                changed = dict(self.context); changed[field] = "changed"
                with self.assertRaises(ValueError): self.module.unpack(self.archive, self.target, changed)
                self.assertFalse(self.target.exists())

    def test_changed_binary_fails_before_extraction(self):
        self.packed()
        self.rewrite(lambda entries: [(m, b"changed" if m.name.endswith("Player.app/Player") else data) for m, data in entries])
        with self.assertRaises(ValueError): self.module.unpack(self.archive, self.target, self.context)
        self.assertFalse(self.target.exists())

    def test_missing_binary_fails_before_extraction(self):
        self.packed()
        self.rewrite(lambda entries: [(m, data) for m, data in entries if not m.name.endswith("Player.app/Player")])
        with self.assertRaises(ValueError): self.module.unpack(self.archive, self.target, self.context)
        self.assertFalse(self.target.exists())

    def test_extra_binary_and_parent_path_are_rejected(self):
        for name in ("Products/extra", "Products/../../outside"):
            with self.subTest(name=name):
                self.packed()
                member = tarfile.TarInfo(name); member.size = 4
                self.rewrite(lambda entries: entries + [(member, b"more")])
                with self.assertRaises(ValueError): self.module.unpack(self.archive, self.target, self.context)
                self.assertFalse(self.target.exists()); self.assertFalse((self.root / "outside").exists())

    def test_external_symlink_is_rejected(self):
        (self.products / "outside").symlink_to("../../outside")
        with self.assertRaises(ValueError): self.packed()

    def test_existing_products_are_never_overwritten(self):
        self.packed(); self.target.mkdir(parents=True)
        marker = self.target / "keep"; marker.write_bytes(b"keep")
        with self.assertRaises(ValueError): self.module.unpack(self.archive, self.target, self.context)
        self.assertEqual(marker.read_bytes(), b"keep")
