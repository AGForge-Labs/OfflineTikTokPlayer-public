import importlib.util
from pathlib import Path


def test_xcode_project_identities_match_across_windows_and_posix(monkeypatch):
    path = Path(__file__).resolve().parents[2] / "scripts" / "generate-ios-project.py"
    spec = importlib.util.spec_from_file_location("native_project", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    original = module.generate()
    identity = module.identity
    monkeypatch.setattr(module, "identity", lambda text: identity(text.replace("\\", "/")))
    assert module.generate() == original, "The checked-in project must be identical when generated on Windows or macOS"


def test_debug_app_and_test_targets_match_the_active_swift_package_architecture(monkeypatch):
    path = Path(__file__).resolve().parents[2] / "scripts" / "generate-ios-project.py"
    spec = importlib.util.spec_from_file_location("native_architecture_project", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    captured = {}
    encode = module.encode
    def capture(value, depth=0):
        if isinstance(value, dict) and "objects" in value:
            captured.update(value["objects"])
        return encode(value, depth)
    monkeypatch.setattr(module, "encode", capture)
    module.generate()
    for name in ("project", module.APP, module.APP + "Tests", module.APP + "UITests"):
        debug = captured[module.identity("config:" + name + "Debug")]["buildSettings"]
        release = captured[module.identity("config:" + name + "Release")]["buildSettings"]
        assert debug.get("ONLY_ACTIVE_ARCH") == "YES", "Debug must match the package's single active simulator architecture"
        assert release.get("ONLY_ACTIVE_ARCH") == "NO", "Release archives must retain their normal supported architectures"
