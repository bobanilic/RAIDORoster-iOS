from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_in_range(text: str, start_marker: str, end_marker: str, old: str, new: str, label: str) -> str:
    start = text.find(start_marker)
    end = text.find(end_marker, start + len(start_marker))
    if start < 0 or end < 0:
        raise RuntimeError(f"V2.12.2 patch range not found: {label}")
    block = text[start:end]
    if new in block:
        return text
    if old not in block:
        raise RuntimeError(f"V2.12.2 marker not found: {label}")
    block = block.replace(old, new, 1)
    return text[:start] + block + text[end:]


content = CONTENT.read_text()

# The month calendar is already one premium rounded surface. The selected-day
# agenda must therefore be integrated into that surface instead of rendering as
# another rounded card inside it. Keep its blue accent line / chevron / content,
# but remove its own background, border and shadow treatment.
content = replace_in_range(
    content,
    "struct RosterCalendarAgendaCard: View {",
    "private func calendarPrimaryLabel",
    "        .dPlusCard(radius: 16, elevated: false)\n",
    "        .padding(.vertical, 2)\n",
    "flatten selected-day agenda",
)

# Version only. Parser/extraction version remains 2.4.0.
content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.12.1")',
    'LabeledContent("RAIDO Roster", value: "2.12.2")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 28;", "CURRENT_PROJECT_VERSION = 29;")
pbx = pbx.replace("MARKETING_VERSION = 2.12.1;", "MARKETING_VERSION = 2.12.2;")
PBX.write_text(pbx)

print("V2.12.2 integrated selected-day agenda applied")
