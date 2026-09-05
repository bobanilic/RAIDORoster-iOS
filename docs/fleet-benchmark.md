# GetJet and Airhub: free prototype comparison

The goal is to measure where the existing free feed agrees with or misses information visible in Flightradar24. FR24 is a comparison source, not ground truth. This developer tool does not add FR24 data to the production iOS UI and does not scrape its website.

No subscription, Python package installation or service deployment is needed to run the tool. Python 3.11 or later is sufficient. Automated capture currently supports the existing ADSB.lol feed only; FR24 input is manually recorded or obtained under an agreement permitting the intended comparison. A private, unpublished prototype does not create a website-scraping exception in [FR24's terms, section 2.3](https://www.flightradar24.com/terms-of-service). The API's combination and retention restrictions still require review for an authorized data import.

## Scope and current implementation

- Include both **GetJet and Airhub**. Choose registrations explicitly; the tool does not assume a GJT callsign, Lithuanian registration or fixed fleet size. Wet-lease customer callsigns must not exclude an aircraft.
- A capture writes one row for every requested tail, even on no reception, identity mismatch, server failure or rate limiting. Never construct the test cohort only from aircraft already visible on FR24.
- The collector probes the same public upstream feed used by the app. Its result measures upstream availability, not the installed application's UI, refresh interval, parsing or display latency. The optional `raido_export` source supports future app instrumentation; an app exporter is not implemented in this change.
- The CSV reference template is empty on purpose. No live FR24 observations or measured coverage result are included in the repository.

## Run a paired sample

Start with a small cohort so a person can record FR24 observations close to the collection time. For example, these two registrations cover both operators already represented in the app; they are not a claim that both aircraft are currently flying:

```bash
python3 tools/fleet_benchmark.py collect \
  --registrations LY-NOW,9H-GTS \
  --sample-id session-001 \
  --output benchmark-data/session-001-adsblol.csv
```

During the capture, inspect each registration's current FR24 display in a normal browser. Copy `docs/fleet-reference-template.csv` to `benchmark-data/session-001-fr24.csv` and enter one row per aircraft using the same `sample_id`. Keep the exact UTC capture time for each row; a 19-aircraft sequential sweep does not produce 19 simultaneous observations.

| Field | Entry rule |
|---|---|
| `sample_id` | Same explicit comparison session ID in both sources |
| `provider` | `fr24_manual`, or `fr24_authorized` for data obtained with appropriate permission |
| `registration` | Exact tail, such as `LY-NOW` or `9H-GTS` |
| `captured_at` | When the reference was inspected; ISO 8601 with timezone, preferably UTC `Z` |
| `status` | `airborne`, `on_ground`, or `unknown`; use current aircraft evidence |
| `status_observed_at` | Timestamp supporting that state, if actually available; otherwise blank |
| `position_observed_at` | Position's source timestamp, if available; otherwise blank |
| `latitude`, `longitude` | Both numeric coordinates, or both blank |
| `estimated` | `true` if the displayed data is estimated; otherwise `false` |
| `outcome` | `observation`, `no_observation`, `unavailable`, or another explicit failure outcome |
| `detail` | Optional provenance, unavailable-field explanation, or source reference |

A historical flight labelled “landed” does not establish that the aircraft is currently on the ground. If the website provides only a last-flight record, enter current state as `unknown`. Never use inspection time to invent a source timestamp. Missing source timestamps make a row ineligible for freshness-based agreement; this limitation is reported rather than silently ignored. Do not estimate coordinates by eyeballing the map.

ADSB.lol's `seen` is a message timestamp proxy, not a separately verified last-change timestamp for every status field. The collector preserves `seen_pos` separately. A recent message cannot rejuvenate an old position. This benchmark does not establish true takeoff, landing, AOG, maintenance or dispatchability.

The collector makes a single sweep, spaces requests, uses an eight-second request timeout and stops further requests on HTTP 429. It records `Retry-After` where supplied; respect that delay before starting another sweep. There is no automatic background loop, retry storm or FR24 network request.

## Produce a comparison

```bash
python3 tools/fleet_benchmark.py report \
  benchmark-data/session-001-adsblol.csv \
  benchmark-data/session-001-fr24.csv \
  --output benchmark-data/session-001-report.md
```

Pass multiple capture/reference CSV paths to summarize multiple sessions. Sample IDs must distinguish separate sampling times. Duplicate source/tail/sample rows are rejected, including registration aliases with a missing hyphen. Output files are created exclusively; choose a new filename rather than overwriting the evidence from an earlier run.

The report shows source availability, missing rows, fresh-position and fresh-status counts, position age p50/p95, comparable status agreement, median position separation and per-aircraft sample coverage. Keep the collection cohort representative of both operators and the actual operating routes; include inactive-looking and hard-to-track aircraft.

Comparison rules:

1. The denominator is the union of requested aircraft/sample pairs present in either source. Missing or failed rows never count as agreement. A session absent from both input files cannot be detected; keep a separate planned-sample log for a continuous trial.
2. Capture times must be within 30 seconds to form a comparison pair.
3. A fresh observation requires a known source timestamp no more than 120 seconds old, valid applicable fields, outcome `observation`, and `estimated=false`.
4. State timestamps must be within 30 seconds for status agreement. Position timestamps must be within five seconds for position comparison. Even five seconds can explain substantial separation at cruise speed; reported distance is disagreement, not absolute positioning error.
5. Estimated observations, missing ages and unknown states are excluded from agreement metrics. Their missing contribution remains visible in coverage counts.

**Do not call a high agreement percentage “accuracy.”** Both feeds can repeat the same bad onboard position. A 100% result from two matched observations says very little if most aircraft have missing data. Sample coverage also differs from continuous airborne-minute coverage; the latter needs a planned observation schedule and an independently obtained flight/movement denominator.

## Validation and next gate

```bash
python3 -m unittest discover -s tests -p 'test_fleet_benchmark.py' -v
```

The tests use synthetic fixtures and mocked network responses. They exercise coverage denominators, missing data, timestamp skew, estimates, stale positions, identity mismatch, rate limits, duplicate captures and report generation. They do not measure either provider's live coverage.

The next practical gate is several real paired samples, followed by the representative multi-day trial in [the research report](getjet-fleet-research.md). Those observations have not yet been collected. Keep real captures under `benchmark-data/`, which excludes them from Git history, and apply the relevant source's retention requirements. Do not commit provider credentials or crew personal data.
