"""Exercise the app selector used by CI without contacting Modal."""

import json
from pathlib import Path
import subprocess
import sys
import textwrap
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/deploy-cloud-code-editor.yml"


class DeploymentAppSelectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        workflow = WORKFLOW.read_text()
        cls.selector = textwrap.dedent(
            workflow.split("modal app list --env main --json | python -c '\n", 1)[1]
            .split("\n          '", 1)[0]
        )

    def select(self, apps):
        return subprocess.run(
            [sys.executable, "-c", self.selector],
            input=json.dumps(apps),
            text=True,
            capture_output=True,
        )

    def app(self, state, name="cloud-code-editor"):
        return {"description": name, "state": state}

    def test_deployed_app_with_historical_and_ephemeral_namesakes(self):
        for state in ("stopped", "ephemeral", "detached", "initializing"):
            for states in ((state, "deployed"), ("deployed", state)):
                with self.subTest(states=states):
                    result = self.select([self.app(value) for value in states])
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), "deployed")

    def test_single_deployed_app(self):
        result = self.select([self.app("deployed")])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "deployed")

    def test_no_deployed_match_remains_pending(self):
        for apps in (
            [],
            [self.app("stopped")],
            [self.app("initializing"), self.app("stopped")],
            [self.app("deployed", "another-app")],
            [{"description": "cloud-code-editor"}],
        ):
            with self.subTest(apps=apps):
                result = self.select(apps)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), "pending")

    def test_multiple_deployed_matches_fail(self):
        result = self.select([self.app("deployed"), self.app("deployed")])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("found 2", result.stderr)

    def test_invalid_json_fails(self):
        result = subprocess.run(
            [sys.executable, "-c", self.selector],
            input="not JSON",
            text=True,
            capture_output=True,
        )
        self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
