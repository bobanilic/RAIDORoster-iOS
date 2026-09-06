"""Compatibility initializer for older RosterSnapshot construction sites after monthlyBLH was added."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
content = ROOT / "RAIDORoster/ContentView.swift"
s = content.read_text()

marker = "extension RosterSnapshot {\n    init(capturedAt: Date, sourceURL: String, pageTitle: String, items: [RosterItem], validation: RosterValidation?)"
if marker not in s:
    anchor = "struct SummaryMetric: Identifiable {"
    if anchor not in s:
        raise RuntimeError("SummaryMetric anchor not found")
    compatibility = '''extension RosterSnapshot {
    // Compatibility for feed/archive paths created before monthlyBLH existed.
    // Live RAIDO page snapshots use the six-argument initializer and preserve monthlyBLH.
    init(capturedAt: Date, sourceURL: String, pageTitle: String, items: [RosterItem], validation: RosterValidation?) {
        self.init(
            capturedAt: capturedAt,
            sourceURL: sourceURL,
            pageTitle: pageTitle,
            items: items,
            validation: validation,
            monthlyBLH: nil
        )
    }
}

'''
    s = s.replace(anchor, compatibility + anchor, 1)

content.write_text(s)
print("V2.20.4 RosterSnapshot monthlyBLH compatibility initializer applied")
