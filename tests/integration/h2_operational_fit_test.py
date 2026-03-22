import importlib.util
import pathlib
import unittest


REPO = pathlib.Path(__file__).resolve().parents[2]
MODULE_PATH = REPO / "tests/integration/h2_operational_fit.py"

spec = importlib.util.spec_from_file_location("h2_operational_fit", MODULE_PATH)
assert spec is not None and spec.loader is not None
h2_operational_fit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(h2_operational_fit)


class H2OperationalFitReportTests(unittest.TestCase):
    def test_summarize_report_error_uses_first_line(self) -> None:
        error_text = "AssertionError('bad mixed load')\nfull traceback line 1\nfull traceback line 2"
        self.assertEqual(
            h2_operational_fit.summarize_report_error(error_text),
            "AssertionError('bad mixed load')",
        )

    def test_summarize_recommendation_requires_clean_mixed_load(self) -> None:
        proxy_results = [
            {"name": "direct", "mode": "control", "transportSpec": "h2://127.0.0.1:1/rpc"},
            {"name": "caddy", "mode": "reverse-proxy-h2c", "transportSpec": "h2://127.0.0.1:2/rpc"},
        ]
        comparison_results = [
            {
                "profile": {"name": "baseline"},
                "http": {
                    "mixedLoad": {
                        "mode": "buffered-pane-capture",
                        "ping": {"p95Ms": 90},
                    }
                },
                "h2": {
                    "mixedLoad": {
                        "error": "AssertionError('probe mixed-load failed')\ntraceback..."
                    }
                },
            }
        ]

        self.assertEqual(
            h2_operational_fit.summarize_recommendation(proxy_results, comparison_results),
            "needs-human-call",
        )


if __name__ == "__main__":
    unittest.main()
