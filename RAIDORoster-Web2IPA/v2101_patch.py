from pathlib import Path

ROOT = Path(__file__).resolve().parent
SRC = ROOT / "RAIDORoster"
JS = SRC / "RosterEnhancements.js"
CONTENT = SRC / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.10.1 patch marker not found: {label}")
    return text.replace(old, new, 1)


# -----------------------------------------------------------------------------
# RAIDO can render the current duty with detailed rows collapsed/hidden. The
# old extractor preferred innerText, which intentionally omits display:none
# content, so Crew On Board / CheckIn / transfer details could disappear even
# while they were still present in the table DOM. Parse both representations
# and let the existing signature + richness dedupe keep the richer activity.
# -----------------------------------------------------------------------------
js = JS.read_text()
old_extract = '''    activityTables().forEach((table, sourceIndex) => {
      const text = compact(table.innerText || table.textContent);
      splitLogicalActivities(text).forEach((logical, logicalIndex) => {
        const activity = parseLogicalActivity(logical.code, logical.segment, sourceIndex, logicalIndex);
        if (!activity) return;
        const existing = bySignature.get(activity.sig);
        if (!existing || richness(activity) > richness(existing)) {
          bySignature.set(activity.sig, activity);
        }
      });
    });
'''
new_extract = '''    activityTables().forEach((table, sourceIndex) => {
      const representations = Array.from(new Set([
        compact(table.innerText || ''),
        compact(table.textContent || '')
      ].filter(Boolean)));

      representations.forEach((text, representationIndex) => {
        splitLogicalActivities(text).forEach((logical, logicalIndex) => {
          const activity = parseLogicalActivity(
            logical.code,
            logical.segment,
            sourceIndex,
            logicalIndex + (representationIndex * 1000)
          );
          if (!activity) return;
          const existing = bySignature.get(activity.sig);
          if (!existing || richness(activity) > richness(existing)) {
            bySignature.set(activity.sig, activity);
          }
        });
      });
    });
'''
js = replace_once(js, old_extract, new_extract, "dual visible/full DOM extraction")
JS.write_text(js)

# Small hotfix version bump only. No model/schema changes.
content = CONTENT.read_text()
content = content.replace('LabeledContent("RAIDO Roster", value: "2.10")', 'LabeledContent("RAIDO Roster", value: "2.10.1")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 10;", "CURRENT_PROJECT_VERSION = 11;")
pbx = pbx.replace("MARKETING_VERSION = 2.10;", "MARKETING_VERSION = 2.10.1;")
PBX.write_text(pbx)

print("V2.10.1 hidden RAIDO detail recovery applied")
