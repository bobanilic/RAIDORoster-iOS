from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_in_range(text: str, start_marker: str, end_marker: str, old: str, new: str, label: str) -> str:
    start = text.find(start_marker)
    end = text.find(end_marker, start + len(start_marker))
    if start < 0 or end < 0:
        raise RuntimeError(f"V2.12.1 patch range not found: {label}")
    block = text[start:end]
    if new in block:
        return text
    if old not in block:
        raise RuntimeError(f"V2.12.1 marker not found: {label}")
    block = block.replace(old, new, 1)
    return text[:start] + block + text[end:]


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# Calendar refinement: the month itself is already one premium surface, so
# individual unselected days should not look like cards inside that card.
# Only the selected day gets a filled surface + outline.
# -----------------------------------------------------------------------------
content = replace_in_range(
    content,
    "struct RosterCalendarDayCell: View {",
    "struct RosterCalendarAgendaCard: View {",
    '''                    isSelected
                        ? DPlusTheme.accent(colorScheme)
                        : (isToday ? DPlusTheme.accent(colorScheme).opacity(0.55) : DPlusTheme.border(colorScheme)),
''',
    '''                    isSelected ? DPlusTheme.accent(colorScheme) : Color.clear,
''',
    "flat calendar cell stroke",
)

content = replace_in_range(
    content,
    "struct RosterCalendarDayCell: View {",
    "struct RosterCalendarAgendaCard: View {",
    '''    private var cellBackground: Color {
        if isSelected {
            return DPlusTheme.accent(colorScheme).opacity(colorScheme == .dark ? 0.19 : 0.10)
        }
        return DPlusTheme.calendarCell(colorScheme)
    }
''',
    '''    private var cellBackground: Color {
        if isSelected {
            return DPlusTheme.accent(colorScheme).opacity(colorScheme == .dark ? 0.19 : 0.10)
        }
        return Color.clear
    }
''',
    "flat calendar cell background",
)

# -----------------------------------------------------------------------------
# Navigation headers: force a solid, theme-aware background instead of iOS's
# translucent scroll-edge/material treatment. Roster and Today are the two D+
# redesigned primary screens and should read as one matte surface.
# -----------------------------------------------------------------------------
content = replace_in_range(
    content,
    "struct RosterHomeView: View {",
    "struct RosterMonthCalendarView: View {",
    '''            .background(DPlusTheme.canvas(colorScheme).ignoresSafeArea())
            .navigationTitle("")
''',
    '''            .background(DPlusTheme.canvas(colorScheme).ignoresSafeArea())
            .toolbarBackground(DPlusTheme.canvas(colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("")
''',
    "solid Roster navigation header",
)

content = replace_in_range(
    content,
    "struct TodayView: View {",
    "struct TodayPersonalNoteDisclosure: View {",
    '''            .background(DPlusTheme.canvas(colorScheme).ignoresSafeArea())
            .navigationTitle("Today")
''',
    '''            .background(DPlusTheme.canvas(colorScheme).ignoresSafeArea())
            .toolbarBackground(DPlusTheme.canvas(colorScheme), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .navigationTitle("Today")
''',
    "solid Today navigation header",
)

# Version only. Parser/extraction version remains 2.4.0.
content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.12")',
    'LabeledContent("RAIDO Roster", value: "2.12.1")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 27;", "CURRENT_PROJECT_VERSION = 28;")
pbx = pbx.replace("MARKETING_VERSION = 2.12;", "MARKETING_VERSION = 2.12.1;")
PBX.write_text(pbx)

print("V2.12.1 calendar flattening + solid navigation headers applied")
