import json
import subprocess
import sys
import unittest
from pathlib import Path


TOOLS = Path(__file__).resolve().parent
SCRIPT = TOOLS / "compare-traces.py"
FIXTURES = TOOLS / "testdata" / "compare-traces"


class CompareTracesTests(unittest.TestCase):
    def run_tool(self, baseline: str, current: str, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(FIXTURES / baseline), str(FIXTURES / current), *arguments],
            capture_output=True,
            text=True,
            check=False,
        )

    @staticmethod
    def json_output(result: subprocess.CompletedProcess[str]) -> dict:
        return json.loads(result.stdout)

    @staticmethod
    def metric(payload: dict, section: str, metric: str, scope: str) -> dict:
        return next(
            row
            for row in payload["metrics"]
            if (row["section"], row["metric"], row["scope"]) == (section, metric, scope)
        )

    def test_self_comparison_has_zero_deltas(self) -> None:
        result = self.run_tool("equal.json", "equal.json", "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        payload = self.json_output(result)
        self.assertTrue(payload["metrics"])
        self.assertTrue(all(row["absolute_delta"] == 0 for row in payload["metrics"] if row["absolute_delta"] is not None))

    def test_positive_and_negative_deltas(self) -> None:
        positive = self.json_output(self.run_tool("equal.json", "positive.json", "--format", "json"))
        negative = self.json_output(self.run_tool("equal.json", "negative.json", "--format", "json"))
        positive_geometry = self.metric(positive, "native_timing", "average", "cpp_geometry")
        negative_geometry = self.metric(negative, "native_timing", "average", "cpp_geometry")
        self.assertGreater(positive_geometry["absolute_delta"], 0)
        self.assertLess(negative_geometry["absolute_delta"], 0)

    def test_swapping_inputs_reverses_delta(self) -> None:
        forward = self.json_output(self.run_tool("equal.json", "positive.json", "--format", "json"))
        reverse = self.json_output(self.run_tool("positive.json", "equal.json", "--format", "json"))
        key = ("native_timing", "average", "cpp_geometry")
        self.assertEqual(
            self.metric(forward, *key)["absolute_delta"],
            -self.metric(reverse, *key)["absolute_delta"],
        )

    def test_zero_baseline_percentage_is_unavailable(self) -> None:
        result = self.run_tool("zero-baseline.json", "positive.json", "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        row = self.metric(self.json_output(result), "native_timing", "average", "cpp_geometry")
        self.assertIsNone(row["percentage_delta"])

    def test_missing_metric_is_reported(self) -> None:
        result = self.run_tool("equal.json", "missing.json", "--format", "json")
        self.assertEqual(result.returncode, 0, result.stderr)
        missing = self.json_output(result)["missing_metrics"]
        self.assertIn(
            {
                "section": "hot_paths",
                "metric": "average",
                "scope": "upstream_extrusion",
                "missing_from": "current",
            },
            missing,
        )

    def test_changed_unit_is_rejected(self) -> None:
        result = self.run_tool("equal.json", "changed-unit.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incompatible unit", result.stderr)

    def test_duplicate_metric_key_is_rejected(self) -> None:
        result = self.run_tool("duplicate.json", "equal.json")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("duplicate metric key", result.stderr)

    def test_geometry_gate_and_serialized_gate_report_all_violations(self) -> None:
        result = self.run_tool(
            "equal.json",
            "positive.json",
            "--max-geometry-regression-ms",
            "0.2",
            "--require-same-serialized-bytes",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("max_geometry_regression_ms", result.stdout)
        self.assertIn("require_same_serialized_bytes", result.stdout)
        self.assertIn("**FAIL**", result.stdout)

    def test_serialized_gate_passes_when_bytes_are_unchanged(self) -> None:
        result = self.run_tool("equal.json", "negative.json", "--require-same-serialized-bytes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("**PASS** `require_same_serialized_bytes`", result.stdout)

    def test_nonnumeric_threshold_is_rejected(self) -> None:
        result = self.run_tool("equal.json", "positive.json", "--max-geometry-regression-ms", "later")
        self.assertEqual(result.returncode, 2)
        self.assertIn("not a number", result.stderr)


if __name__ == "__main__":
    unittest.main()
