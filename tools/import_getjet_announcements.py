"""Rebuild the bundled catalogue from the user-supplied PAB 6/1 PDF.

Developer-only dependency: PyMuPDF. No rewriting, translation or inferred scripts.
"""
import argparse
import hashlib
import json
import re
from pathlib import Path

GROUPS = {"1.1", "1.3", "1.4", "1.6", "1.7", "1.8", "1.9"}
DEMO_TYPES = {"1.3.1": "A320", "1.3.2": "A321", "1.3.3": "B738"}


def category(section):
    if section in {"1.1.2", "1.8.7", "1.8.8", "1.8.9"}: return "Fueling"
    if section.startswith("1.3."): return "Safety demonstration"
    if section.startswith("2."): return "Emergency"
    if section.startswith("1.9."): return "Transit"
    if section.startswith("1.6."): return "Service"
    if section.startswith("1.7."): return "Disruptions"
    if section.startswith("1.5") or section in {"1.4.4", "1.4.5"}: return "Arrival"
    if section.startswith("1.4."): return "In-flight"
    if section.startswith("1.1.") or section in {"1.2", "1.8.3", "1.8.17", "1.8.18"}: return "Boarding"
    return "Other situations"


def extract_lines(path):
    import fitz
    document = fitz.open(path)
    assert len(document) == 45, "Unexpected PAB export; review extraction before updating"
    output, printed = [], ""
    for index, page in enumerate(document):
        if index < 8: continue  # Cover, preface and table of contents.
        lines = []
        for block in page.get_text("dict")["blocks"]:
            for line in block.get("lines", []):
                if line["dir"] != (1.0, 0.0): continue  # Vertical export watermark.
                text = "".join(span["text"] for span in line["spans"]).strip()
                if text:
                    lines.append(dict(x=line["bbox"][0], y=line["bbox"][1], text=text, pdfPage=index + 1))
        headers = [line for line in lines if line["text"] == "Page:"]
        for header in headers:
            header["printedPage"] = next(line["text"] for line in lines
                if abs(line["y"] - header["y"]) < 2 and line["x"] > 490)
        grouped = []
        for line in sorted(lines, key=lambda line: (round(line["y"], 0), line["x"])):
            if line["text"] == "Page:": printed = line["printedPage"]
            if any(header["y"] - 8 <= line["y"] <= header["y"] + 40 for header in headers): continue
            if "UNCONTROLLED" in line["text"] or line["text"].startswith("©") or "END OF CHAPTER" in line["text"] or line["text"] == "END OF DOCUMENT" or line["text"].startswith("CHAPTER "): continue
            line["printedPage"] = printed
            if grouped and abs(grouped[-1]["y"] - line["y"]) < 2:
                grouped[-1]["text"] += " " + line["text"]
            else:
                grouped.append(line)
        output.extend(grouped)
    return output


def catalogue(path):
    assert hashlib.sha256(path.read_bytes()).hexdigest() == "f02652cad675001445d5ea6f29205bb20c4dc8ae25d712dfea27a4a2c8006f1e", "Different source revision: review metadata and extraction before importing"
    entries, current, language, aircraft, previous = [], None, None, [], None
    for line in extract_lines(path):
        text = line["text"]
        heading = re.match(r"^([12]\.\d+(?:\.\d+)?)\s+(.+)", text)
        if heading:
            section, title = heading.groups()
            current, language, aircraft, previous = None, None, [], None
            if section in GROUPS: continue
            title = title.split("/")[0].strip().capitalize()
            title = {"1.3.1": "Airbus A320 safety demonstration", "1.3.2": "Airbus A321 safety demonstration",
                     "1.3.3": "Boeing 737-800 safety demonstration", "1.5.1": "Controlled disembarkation",
                     "2.1": "Emergency landing on ground", "2.2": "Ditching"}.get(section, title)
            current = dict(id="gjt.pab." + section, section=section, title=title,
                           category=category(section), aircraft=[DEMO_TYPES[section]] if section in DEMO_TYPES else [],
                           sourcePage=line["printedPage"], segments=[])
            entries.append(current)
            if section == "1.5.1": language = "en"  # Source has English only, with no EN label.
            continue
        if current is None: continue
        marker = re.match(r"^(EN|LT)(?::\s*|$)(.*)", text)
        if marker:
            language, text = marker.group(1).lower(), marker.group(2).strip()
            aircraft, previous = [], None
            if not text: continue
        if language is None: continue  # Wrapped section title before the first language marker.
        kind, segment_language = "text", language
        variant = re.sub(r"\s|[-–]", "", text)
        if current["section"].startswith("2.") and variant in {"A320", "A321", "B737800", "B737800/A320"}:
            aircraft = {"A320": ["A320"], "A321": ["A321"], "B737800": ["B738"], "B737800/A320": ["B738", "A320"]}[variant]
            kind = "heading"
        elif aircraft and line["x"] < 90:
            aircraft = []
        if text.isupper() and len(text) < 100:
            kind = "heading"
            if current["section"] in DEMO_TYPES: segment_language = "both"
        segments = current["segments"]
        # Preserve paragraph boundaries and source order. Join physical line wraps only.
        same_paragraph = (previous is not None and segments and kind == "text" and
                          segments[-1]["kind"] == kind and segments[-1]["language"] == segment_language and
                          segments[-1]["aircraft"] == aircraft and
                          (line["pdfPage"] != previous["pdfPage"] or line["y"] - previous["y"] < 15))
        if same_paragraph:
            segments[-1]["text"] += " " + text
            if line["pdfPage"] not in segments[-1]["pdfPages"]: segments[-1]["pdfPages"].append(line["pdfPage"])
        else:
            segments.append(dict(id=str(len(segments)), language=segment_language, kind=kind,
                                 aircraft=aircraft[:], text=text, pdfPages=[line["pdfPage"]]))
        previous = line
    assert len(entries) == 54, f"Expected 54 announcements, got {len(entries)}"
    assert len({entry["id"] for entry in entries}) == 54
    for entry in entries:
        expected = {"en"} if entry["section"] == "1.5.1" else {"en", "lt"}
        assert {segment["language"] for segment in entry["segments"]} >= expected, entry["id"]
        entry["requiresAircraft"] = bool(entry["aircraft"] or any(segment["aircraft"] for segment in entry["segments"]))
    return dict(schemaVersion=1, airline="getjet", title="Public Announcements Book", issue="6", revision="1",
                revisionDate="2026-02-01", uncontrolledExport=True, sourceSHA256=hashlib.sha256(path.read_bytes()).hexdigest(),
                copyright="© GetJet Airlines, JSC", announcements=entries)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pdf", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    result = catalogue(args.pdf)
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(f"Extracted {len(result['announcements'])} source announcements; source languages preserved")
