import contextlib
import hashlib
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path

script = Path(__file__).resolve().parents[2] / "desktop/host/remote_scripts/application_rollback.py"
spec = importlib.util.spec_from_file_location("release_artifact", script)
release_artifact = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release_artifact)


class ReleaseArtifactTest(unittest.TestCase):
    def test_replay_after_helper_cleanup(self):
        old, current, new = "a" * 24, "b" * 24, "c" * 24
        app = "11111111-1111-4111-8111-111111111111"
        installation = "22222222-2222-4222-8222-222222222222"

        def write(path, value):
            path.write_text(json.dumps(value))

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            history = root / ".desktop-deployments"
            app_root = root / "apps/slot"
            app_root.mkdir(parents=True)
            active = dict(deployment_id=current, app_id=app, component="slot", id=installation)
            write(app_root / ".vhttpd-installation.json", active)
            (history / new).mkdir(parents=True)

            for ident, parent in ((old, ""), (current, json.dumps(dict(id=old)))):
                path = history / ident
                path.mkdir()
                write(path / "status.json", dict(id=ident, config_path=str(root / "vhttpd.toml"),
                                                 phase="completed"))
                write(path / "plan.json", dict(previous_manifest=parent))
                write(path / "preview.json", dict(installation=active))
                payload = path / "payload.json"
                write(payload, dict(id=ident, component_id="slot", files=[dict(path=ident)]))
                release_artifact.retain(path, hashlib.sha256(payload.read_bytes()).hexdigest())
                # This is what the existing runtime helper removes on exit.
                payload.unlink()
                (path / "plan.json").unlink()

            destination = history / new
            with contextlib.redirect_stdout(io.StringIO()):
                release_artifact.stage(root, "slot", current, app, destination)
            staged = destination / "payload.json"
            payload = json.loads(staged.read_text())
            self.assertEqual(payload["id"], new)
            self.assertEqual(payload["target_installation_id"], installation)
            self.assertEqual(payload["files"], [dict(path=old)])
            staged.unlink()

            with self.assertRaises(ValueError):
                release_artifact.stage(root, "slot", old, app, destination)
            with self.assertRaises(ValueError):
                release_artifact.stage(root, "slot", current, "wrong-app", destination)
            (history / old / "release-payload.json").write_text("{}")
            with self.assertRaises(ValueError):
                release_artifact.stage(root, "slot", current, app, destination)
            self.assertFalse(staged.exists())


if __name__ == "__main__":
    unittest.main()
