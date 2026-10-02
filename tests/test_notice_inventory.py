"""Exercise the real notice check before any build directory exists."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class NoticeInventoryTests(unittest.TestCase):
    def test_fresh_inventory_passes_but_required_missing_bundle_fails(self):
        with tempfile.TemporaryDirectory(prefix="ballpad notices ") as folder:
            root = Path(folder)
            for name in ("notices", "scripts/native"):
                shutil.copytree(ROOT / name, root / name)
            for name in ("ATTRIBUTION.md", "THIRD_PARTY_NOTICES.md",
                         "docs/native-strikers-dependency-manifest.json"):
                (root / name).parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(ROOT / name, root / name)
            command = ["/bin/bash", str(root / "scripts/native/verify-notices.sh"), "--final"]
            inventory = subprocess.run(command + ["--inventory-only"],
                                       capture_output=True, text=True, timeout=15)
            self.assertEqual(inventory.returncode, 0, inventory.stdout + inventory.stderr)
            required = subprocess.run(command + ["--require-bundle"],
                                      capture_output=True, text=True, timeout=15)
            self.assertNotEqual(required.returncode, 0)
            self.assertIn("expected bundle", required.stderr)
            self.assertFalse((root / "build").exists())
