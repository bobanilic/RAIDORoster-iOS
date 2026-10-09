#!/usr/bin/env python3
"""Developer comparison tool. Standard library only; no FR24 website scraper."""
import argparse
import csv
import json
import math
import re
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import quote
from urllib.request import Request, urlopen

FIELDS = ["sample_id", "provider", "registration", "captured_at", "status",
          "status_observed_at", "position_observed_at", "latitude", "longitude",
          "estimated", "outcome", "detail"]
PROVIDERS = {"adsblol", "fr24_manual", "fr24_authorized", "raido_export"}
STATUSES = {"airborne", "on_ground", "unknown"}


def utc_now():
    return datetime.now(timezone.utc)


def stamp(value):
    return value.isoformat().replace("+00:00", "Z")


def date(value):
    if not value:
        return None
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("Timestamps require an explicit timezone")
    return parsed.astimezone(timezone.utc)


def number(value):
    if value is None or value == "" or isinstance(value, bool):
        return None
    try:
        result = float(value)
        return result if math.isfinite(result) else None
    except (TypeError, ValueError):
        return None


def registration(value):
    value = value.strip().upper()
    if not re.fullmatch(r"[A-Z0-9]{1,3}-?[A-Z0-9]{2,5}", value):
        raise ValueError(f"Invalid aircraft registration: {value!r}")
    return value


def key_registration(value):
    return registration(value).replace("-", "")


def source_time(epoch, age, captured):
    epoch, age = number(epoch), number(age)
    if epoch is None or age is None or age < 0:
        return ""
    seconds = epoch / 1000 if epoch > 100_000_000_000 else epoch
    if seconds < 946_684_800 or seconds > captured.timestamp() + 30:
        return ""
    observed = seconds - age
    if observed < 946_684_800:
        return ""
    return stamp(datetime.fromtimestamp(observed, timezone.utc))


def empty_row(sample, provider, reg, captured, outcome):
    row = dict.fromkeys(FIELDS, "")
    row.update(sample_id=sample, provider=provider, registration=registration(reg),
               captured_at=stamp(captured), status="unknown", estimated="false",
               outcome=outcome)
    return row


def normalize_adsblol(payload, sample, reg, captured):
    row = empty_row(sample, "adsblol", reg, captured, "no_observation")
    aircraft = payload.get("ac")
    if not isinstance(aircraft, list):
        raise ValueError("Missing aircraft response array")
    matches = []
    for item in aircraft:
        if not isinstance(item, dict) or not isinstance(item.get("r"), str):
            continue
        try:
            if key_registration(item["r"]) == key_registration(reg):
                matches.append(item)
        except ValueError:
            continue
    if len(matches) != 1:
        row["outcome"] = "identity_mismatch" if aircraft else "no_observation"
        return row
    item = matches[0]
    row["outcome"] = "observation"
    row["status_observed_at"] = source_time(payload.get("now"), item.get("seen"), captured)
    row["position_observed_at"] = source_time(payload.get("now"), item.get("seen_pos"), captured)
    altitude = item.get("alt_baro")
    if isinstance(altitude, str) and altitude.lower() == "ground":
        row["status"] = "on_ground"
    elif number(altitude) is not None:
        row["status"] = "airborne"
    lat, lon = number(item.get("lat")), number(item.get("lon"))
    if lat is not None and lon is not None and -90 <= lat <= 90 and -180 <= lon <= 180:
        row.update(latitude=lat, longitude=lon)
    row["detail"] = "type=" + str(item.get("type", "unknown"))
    return row


def write_rows(path, rows):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # A capture is immutable; an accidental rerun must not erase evidence.
    with path.open("x", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerows(rows)


def collect(args):
    regs = [registration(value) for value in args.registrations.split(",")]
    if len({key_registration(value) for value in regs}) != len(regs):
        raise ValueError("Duplicate registration in the capture cohort")
    if not 1 <= len(regs) <= 100:
        raise ValueError("Capture between 1 and 100 registrations")
    if Path(args.output).exists():
        raise ValueError("Output already exists; use a new capture filename")
    rows, rate_limited = [], False
    for index, reg in enumerate(regs):
        if rate_limited:
            rows.append(empty_row(args.sample_id, "adsblol", reg, utc_now(), "skipped_rate_limit"))
            continue
        if index:
            time.sleep(2)
        request = Request("https://api.adsb.lol/v2/reg/" + quote(reg, safe=""),
                          headers={"User-Agent": "RAIDO-Fleet-Benchmark/1.0"})
        try:
            with urlopen(request, timeout=8) as response:
                payload = json.load(response)
            rows.append(normalize_adsblol(payload, args.sample_id, reg, utc_now()))
        except HTTPError as error:
            rate_limited = error.code == 429
            row = empty_row(args.sample_id, "adsblol", reg, utc_now(), "http_error")
            row["detail"] = f"HTTP {error.code}"
            if rate_limited:
                row["detail"] += "; Retry-After=" + (error.headers.get("Retry-After") or "unspecified")
            rows.append(row)
        except (URLError, TimeoutError, ValueError, TypeError, AttributeError, OSError):
            rows.append(empty_row(args.sample_id, "adsblol", reg, utc_now(), "fetch_or_decode_error"))
    write_rows(args.output, rows)
    print(f"Captured {len(rows)} cohort rows in {args.output}; no FR24 request was made")


def read_rows(paths):
    output, seen = [], set()
    for path in paths:
        with Path(path).open(newline="") as handle:
            reader = csv.DictReader(handle)
            if not set(FIELDS) <= set(reader.fieldnames or []):
                raise ValueError(f"Missing CSV columns in {path}")
            for row in reader:
                if row["provider"] not in PROVIDERS or row["status"] not in STATUSES:
                    raise ValueError("Unrecognized provider/status; 'landed' is not a current ground observation")
                if not row["sample_id"] or not row["outcome"] or date(row["captured_at"]) is None:
                    raise ValueError("Each row requires sample_id, outcome, and captured_at")
                registration(row["registration"])
                if row["estimated"] not in {"true", "false"}:
                    raise ValueError("estimated must be true or false")
                for field in ["status_observed_at", "position_observed_at"]:
                    date(row[field])
                lat, lon = number(row["latitude"]), number(row["longitude"])
                if row["latitude"] or row["longitude"]:
                    if lat is None or lon is None or not -90 <= lat <= 90 or not -180 <= lon <= 180:
                        raise ValueError("Coordinates require a valid latitude/longitude pair")
                key = (row["sample_id"], key_registration(row["registration"]), row["provider"])
                if key in seen:
                    raise ValueError(f"Duplicate comparison row: {key}")
                seen.add(key)
                output.append(row)
    return output


def age(row, field):
    observed = date(row[field])
    if observed is None:
        return None
    seconds = (date(row["captured_at"]) - observed).total_seconds()
    return max(0, seconds) if seconds >= -30 else None


def fresh(row, position=False):
    field = "position_observed_at" if position else "status_observed_at"
    value = age(row, field)
    if row["outcome"] != "observation" or row["estimated"] != "false" or value is None or value > 120:
        return False
    if position:
        return number(row["latitude"]) is not None and number(row["longitude"]) is not None
    return row["status"] != "unknown"


def distance(a, b):
    lat1, lon1, lat2, lon2 = [math.radians(float(value)) for value in
                             [a["latitude"], a["longitude"], b["latitude"], b["longitude"]]]
    h = math.sin((lat2 - lat1) / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2
    return 6_371_000 * 2 * math.asin(math.sqrt(min(1, max(0, h))))


def percentile(values, fraction):
    if not values:
        return None
    values = sorted(values)
    index = (len(values) - 1) * fraction
    low, high = math.floor(index), math.ceil(index)
    return values[low] + (values[high] - values[low]) * (index - low)


def summarize(rows, reference="fr24_manual", candidate="adsblol"):
    if candidate == reference:
        raise ValueError("Candidate and reference must be different sources")
    selected = [row for row in rows if row["provider"] in {candidate, reference}]
    pairs = {}
    for row in selected:
        key = (row["sample_id"], key_registration(row["registration"]))
        pairs.setdefault(key, {})[row["provider"]] = row
    result = {"expected_pairs": len(pairs), "sources": {}, "matched_capture_pairs": 0,
              "comparable_status_pairs": 0, "status_agreements": 0,
              "comparable_position_pairs": 0, "position_separation_m": []}
    for provider in [candidate, reference]:
        group = [row for row in selected if row["provider"] == provider]
        ages = [value for row in group if row["outcome"] == "observation"
                for value in [age(row, "position_observed_at")] if value is not None]
        result["sources"][provider] = {
            "recorded_rows": len(group), "fresh_status_rows": sum(fresh(row) for row in group),
            "fresh_position_rows": sum(fresh(row, True) for row in group),
            "position_age_p50": percentile(ages, .5), "position_age_p95": percentile(ages, .95),
            "missing_rows": len(pairs) - len(group),
        }
    for pair in pairs.values():
        a, b = pair.get(candidate), pair.get(reference)
        if a is None or b is None or abs((date(a["captured_at"]) - date(b["captured_at"])).total_seconds()) > 30:
            continue
        result["matched_capture_pairs"] += 1
        if fresh(a) and fresh(b) and abs((date(a["status_observed_at"]) - date(b["status_observed_at"])).total_seconds()) <= 30:
            result["comparable_status_pairs"] += 1
            result["status_agreements"] += a["status"] == b["status"]
        if fresh(a, True) and fresh(b, True) and abs((date(a["position_observed_at"]) - date(b["position_observed_at"])).total_seconds()) <= 5:
            result["comparable_position_pairs"] += 1
            result["position_separation_m"].append(distance(a, b))
    return result


def display(value):
    return "N/A" if value is None else f"{value:.1f}"


def report(args):
    rows = read_rows(args.inputs)
    stats = summarize(rows, args.reference, args.candidate)
    if not stats["expected_pairs"]:
        raise ValueError("No rows for the selected sources")
    lines = ["# Fleet observation comparison", "",
             "Agreement is not ground-truth accuracy. This is a sampled comparison, not continuous airborne coverage.",
             "The adsblol collector probes RAIDO's upstream feed; it does not measure the installed app's display latency.", "",
             f"Expected aircraft/sample pairs: {stats['expected_pairs']}. Capture pairs within 30 seconds: {stats['matched_capture_pairs']}.", "",
             "| Source | Recorded rows | Missing rows | Fresh status | Fresh position | Position age p50 / p95 (s) |",
             "|---|---:|---:|---:|---:|---|" ]
    for provider, value in stats["sources"].items():
        lines.append(f"| {provider} | {value['recorded_rows']} | {value['missing_rows']} | {value['fresh_status_rows']}/{stats['expected_pairs']} | {value['fresh_position_rows']}/{stats['expected_pairs']} | {display(value['position_age_p50'])} / {display(value['position_age_p95'])} |")
    denominator = stats["comparable_status_pairs"]
    agreement = display(100 * stats["status_agreements"] / denominator) + "%" if denominator else "N/A"
    lines.extend(["", f"Fresh status agreement: {agreement} ({stats['status_agreements']}/{denominator} comparable pairs).",
                  f"Comparable position pairs: {stats['comparable_position_pairs']}; median separation: {display(percentile(stats['position_separation_m'], .5))} m.", "",
                  "Fresh means a known source timestamp no more than 120 seconds old and a non-estimated observation. Position pairs require source times within five seconds.", "",
                  "## Per-aircraft sample coverage", "",
                  "| Registration | Expected pairs | Candidate fresh positions | Reference fresh positions |",
                  "|---|---:|---:|---:|"])
    for reg in sorted({key_registration(row["registration"]) for row in rows if row["provider"] in {args.candidate, args.reference}}):
        item = summarize([row for row in rows if key_registration(row["registration"]) == reg], args.reference, args.candidate)
        lines.append(f"| {reg} | {item['expected_pairs']} | {item['sources'][args.candidate]['fresh_position_rows']} | {item['sources'][args.reference]['fresh_position_rows']} |")
    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x") as handle:
        handle.write("\n".join(lines) + "\n")
    print(f"Wrote {args.output}; no parity or ground-truth accuracy claim is made")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    capture = commands.add_parser("collect", help="One ADSB.lol sweep; every requested tail gets a row")
    capture.add_argument("--registrations", required=True)
    capture.add_argument("--sample-id", required=True)
    capture.add_argument("--output", required=True)
    capture.set_defaults(run=collect)
    comparison = commands.add_parser("report", help="Compare CSV captures and manually entered or authorized reference data")
    comparison.add_argument("inputs", nargs="+")
    comparison.add_argument("--candidate", choices=sorted(PROVIDERS), default="adsblol")
    comparison.add_argument("--reference", choices=sorted(PROVIDERS), default="fr24_manual")
    comparison.add_argument("--output", required=True)
    comparison.set_defaults(run=report)
    args = parser.parse_args()
    try:
        args.run(args)
    except (ValueError, OSError) as error:
        parser.exit(2, f"Error: {error}\n")


if __name__ == "__main__":
    main()
