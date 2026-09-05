import csv
import importlib.util
import tempfile
import unittest
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
from urllib.error import HTTPError

SPEC = importlib.util.spec_from_file_location("benchmark", Path(__file__).parents[1] / "tools/fleet_benchmark.py")
b = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(b)
T = b.date("2026-09-05T10:00:00Z")


def observation(provider="adsblol", reg="LY-NOW", sample="one"):
    row = b.empty_row(sample, provider, reg, T, "observation")
    row.update(status="airborne", status_observed_at=b.stamp(T),
               position_observed_at=b.stamp(T), latitude=32, longitude=34)
    return row


class BenchmarkTests(unittest.TestCase):
    def test_no_signal_remains_in_denominator(self):
        rows = [observation(), observation("fr24_manual"),
                b.empty_row("one", "adsblol", "9H-GTS", T, "no_observation"),
                observation("fr24_manual", "9H-GTS")]
        result = b.summarize(rows)
        self.assertEqual(result["expected_pairs"], 2)
        self.assertEqual(result["sources"]["adsblol"]["fresh_position_rows"], 1)
        self.assertEqual(result["comparable_status_pairs"], 1)

    def test_missing_reference_not_counted_as_agreement(self):
        result = b.summarize([observation()])
        self.assertEqual(result["sources"]["fr24_manual"]["missing_rows"], 1)
        self.assertEqual(result["comparable_status_pairs"], 0)

    def test_old_position_new_message(self):
        payload = {"now": T.timestamp() * 1000,
                   "ac": [{"r": "LY-NOW", "lat": 32, "lon": 34, "alt_baro": 35000,
                           "seen": 1, "seen_pos": 300}]}
        row = b.normalize_adsblol(payload, "one", "LY-NOW", T)
        self.assertTrue(b.fresh(row))
        self.assertFalse(b.fresh(row, True))
        self.assertEqual(b.age(row, "position_observed_at"), 300)

    def test_missing_source_clock_stays_unknown_age(self):
        row = b.normalize_adsblol({"ac": [{"r": "9H-GTS", "alt_baro": "ground", "seen": 0}]}, "one", "9H-GTS", T)
        self.assertEqual(row["status"], "on_ground")
        self.assertFalse(b.fresh(row))

    def test_missing_altitude_is_not_airborne(self):
        row = b.normalize_adsblol({"now": T.timestamp(), "ac": [{"r": "LY-NOW", "seen": 0}]}, "one", "LY-NOW", T)
        self.assertEqual(row["status"], "unknown")

    def test_wrong_aircraft_rejected(self):
        row = b.normalize_adsblol({"ac": [{"r": "LY-UNO"}]}, "one", "LY-NOW", T)
        self.assertEqual(row["outcome"], "identity_mismatch")

    def test_capture_skew_excludes_comparison(self):
        ref = observation("fr24_manual")
        ref["captured_at"] = b.stamp(T + timedelta(seconds=60))
        result = b.summarize([observation(), ref])
        self.assertEqual(result["matched_capture_pairs"], 0)

    def test_position_source_time_skew(self):
        ref = observation("fr24_manual")
        ref["position_observed_at"] = b.stamp(T - timedelta(seconds=10))
        result = b.summarize([observation(), ref])
        self.assertEqual(result["comparable_position_pairs"], 0)
        self.assertEqual(result["comparable_status_pairs"], 1)

    def test_estimates_and_unknown_times_do_not_inflate_agreement(self):
        ref = observation("fr24_manual")
        ref["estimated"] = "true"
        self.assertEqual(b.summarize([observation(), ref])["comparable_status_pairs"], 0)
        ref["estimated"] = "false"
        ref["status_observed_at"] = ""
        self.assertEqual(b.summarize([observation(), ref])["comparable_status_pairs"], 0)

    def test_distance_and_status_disagreement(self):
        ref = observation("fr24_manual")
        ref.update(status="on_ground", latitude=32.001)
        result = b.summarize([observation(), ref])
        self.assertEqual(result["status_agreements"], 0)
        self.assertAlmostEqual(result["position_separation_m"][0], 111.195, places=2)

    def test_duplicate_rows_rejected_including_hyphen_alias(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.csv"
            b.write_rows(path, [observation(), observation(reg="LYNOW")])
            with self.assertRaisesRegex(ValueError, "Duplicate"):
                b.read_rows([path])

    def test_naive_timestamps_and_invalid_coordinates_rejected(self):
        with self.assertRaisesRegex(ValueError, "timezone"):
            b.date("2026-09-05T10:00:00")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.csv"
            row = observation()
            row["latitude"] = "NaN"
            b.write_rows(path, [row])
            with self.assertRaisesRegex(ValueError, "Coordinates"):
                b.read_rows([path])

    def test_rate_limit_stops_requests_and_keeps_cohort(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture.csv"
            args = SimpleNamespace(registrations="LY-NOW,9H-GTS", sample_id="one", output=str(path))
            error = HTTPError("https://api.adsb.lol", 429, "Too many requests", {"Retry-After": "300"}, None)
            with patch.object(b, "urlopen", side_effect=error) as fetch:
                b.collect(args)
            self.assertEqual(fetch.call_count, 1)
            rows = b.read_rows([path])
            self.assertEqual(len(rows), 2)
            self.assertEqual(rows[1]["outcome"], "skipped_rate_limit")

    def test_report_end_to_end_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            source, report = Path(directory) / "input.csv", Path(directory) / "report.md"
            b.write_rows(source, [observation(), observation("fr24_manual"),
                                  b.empty_row("one", "adsblol", "9H-GTS", T, "no_observation")])
            args = SimpleNamespace(inputs=[source], reference="fr24_manual", candidate="adsblol", output=report)
            b.report(args)
            content = report.read_text()
            self.assertIn("not ground-truth accuracy", content)
            self.assertIn("Expected aircraft/sample pairs: 2", content)
            self.assertIn("| 9HGTS | 1 | 0 | 0 |", content)
            with self.assertRaises(FileExistsError):
                b.report(args)


if __name__ == "__main__":
    unittest.main()
