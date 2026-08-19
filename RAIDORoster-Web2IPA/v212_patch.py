from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.12 patch marker not found: {label}")
    return text.replace(old, new, 1)


def range_text(text: str, start_marker: str, end_marker: str, label: str):
    start = text.find(start_marker)
    end = text.find(end_marker, start + len(start_marker))
    if start < 0 or end < 0:
        raise RuntimeError(f"V2.12 patch range not found: {label}")
    return start, end, text[start:end]


def replace_in_range(text: str, start_marker: str, end_marker: str, old: str, new: str, label: str) -> str:
    start, end, block = range_text(text, start_marker, end_marker, label)
    if new in block:
        return text
    if old not in block:
        raise RuntimeError(f"V2.12 range marker not found: {label}")
    block = block.replace(old, new, 1)
    return text[:start] + block + text[end:]


content = CONTENT.read_text()

# -----------------------------------------------------------------------------
# D+ visual system. This is presentation-only: no roster/parser/cache behavior
# changes. Light mode uses the approved premium neutral/emerald direction;
# dark mode uses OLED black/charcoal with a restrained aviation-blue accent.
# -----------------------------------------------------------------------------
theme = r'''
private enum DPlusTheme {
    static let lightAccent = Color(red: 0.02, green: 0.40, blue: 0.25)
    static let darkAccent = Color(red: 0.14, green: 0.49, blue: 1.00)

    static func accent(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? darkAccent : lightAccent
    }

    static func canvas(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black : Color(uiColor: .systemGroupedBackground)
    }

    static func surface(_ scheme: ColorScheme, elevated: Bool = false) -> Color {
        if scheme == .dark {
            return elevated
                ? Color(red: 0.075, green: 0.082, blue: 0.092)
                : Color(red: 0.052, green: 0.058, blue: 0.066)
        }
        return elevated ? Color.white : Color(uiColor: .secondarySystemGroupedBackground)
    }

    static func calendarCell(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.045, green: 0.050, blue: 0.057)
            : Color.white.opacity(0.92)
    }

    static func border(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color.white.opacity(0.09) : Color.black.opacity(0.055)
    }

    static func shadow(_ scheme: ColorScheme, elevated: Bool) -> Color {
        guard scheme == .light else { return .clear }
        return Color.black.opacity(elevated ? 0.075 : 0.035)
    }
}

private struct DPlusCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let radius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(DPlusTheme.surface(colorScheme, elevated: elevated), in: shape)
            .overlay {
                shape.stroke(DPlusTheme.border(colorScheme), lineWidth: 1)
            }
            .shadow(
                color: DPlusTheme.shadow(colorScheme, elevated: elevated),
                radius: elevated ? 10 : 4,
                x: 0,
                y: elevated ? 4 : 2
            )
    }
}

private extension View {
    func dPlusCard(radius: CGFloat = 18, elevated: Bool = false) -> some View {
        modifier(DPlusCardModifier(radius: radius, elevated: elevated))
    }
}

'''
if "private enum DPlusTheme" not in content:
    content = replace_once(
        content,
        "enum MainTab: Hashable { case roster, today, portal, settings }\n",
        theme + "enum MainTab: Hashable { case roster, today, portal, settings }\n",
        "D+ theme helpers",
    )

# -----------------------------------------------------------------------------
# App-wide tint and tab-bar treatment. Appearance System / Light / Dark remains
# the source of truth; this simply gives each scheme its approved accent.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''struct ContentView: View {
    @StateObject private var appState = AppState()
''',
    '''struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var appState = AppState()
''',
    "ContentView color scheme",
)

cv_start, cv_end, cv = range_text(content, "struct ContentView: View {", "struct RosterHeaderPrincipal: View {", "ContentView")
if ".tint(DPlusTheme.accent(colorScheme))" not in cv:
    cv = cv.replace(
        '''        }
    }
}

''',
        '''        }
        .tint(DPlusTheme.accent(colorScheme))
        .toolbarBackground(DPlusTheme.surface(colorScheme), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

''',
        1,
    )
content = content[:cv_start] + cv + content[cv_end:]

# -----------------------------------------------------------------------------
# Roster header: keep the compact hierarchy the user approved, but give the
# brand premium typography and scheme-aware accent separation.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''struct RosterHeaderPrincipal: View {
    @ObservedObject var store: RosterStore
''',
    '''struct RosterHeaderPrincipal: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: RosterStore
''',
    "Roster header color scheme",
)

content = replace_in_range(
    content,
    "struct RosterHeaderPrincipal: View {",
    "struct RosterHomeView: View {",
    '''                Text("GetJet / AirHub Roster")
                    .font(.system(size: 22, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .accessibilityAddTraits(.isHeader)
''',
    '''                HStack(spacing: 4) {
                    Text("GetJet")
                        .foregroundStyle(.primary)
                    Text("/")
                        .foregroundStyle(DPlusTheme.accent(colorScheme))
                    Text("AirHub Roster")
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .accessibilityAddTraits(.isHeader)
''',
    "Roster brand title",
)

# -----------------------------------------------------------------------------
# Roster and Today canvas backgrounds. Navigation structure and toolbars are
# preserved exactly; only visual surface treatment changes.
# -----------------------------------------------------------------------------
content = replace_once(
    content,
    '''struct RosterHomeView: View {
    @ObservedObject var store: RosterStore
''',
    '''struct RosterHomeView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: RosterStore
''',
    "RosterHomeView color scheme",
)
content = replace_in_range(
    content,
    "struct RosterHomeView: View {",
    "struct RosterMonthCalendarView: View {",
    '''            .navigationTitle("")
''',
    '''            .background(DPlusTheme.canvas(colorScheme).ignoresSafeArea())
            .navigationTitle("")
''',
    "Roster canvas",
)

content = replace_once(
    content,
    '''struct TodayView: View {
    @ObservedObject var store: RosterStore
''',
    '''struct TodayView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var store: RosterStore
''',
    "TodayView color scheme",
)
content = replace_in_range(
    content,
    "struct TodayView: View {",
    "struct TodayPersonalNoteDisclosure: View {",
    '''                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title2.bold())
''',
    '''                    Text(Date().formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.title2.bold())
                        .foregroundStyle(DPlusTheme.accent(colorScheme))
''',
    "Today date accent",
)
content = replace_in_range(
    content,
    "struct TodayView: View {",
    "struct TodayPersonalNoteDisclosure: View {",
    '''            .navigationTitle("Today")
''',
    '''            .background(DPlusTheme.canvas(colorScheme).ignoresSafeArea())
            .navigationTitle("Today")
''',
    "Today canvas",
)

# -----------------------------------------------------------------------------
# Calendar-first premium redesign: neutral cells, colored duty typography,
# stronger selected-day state, subtle borders, and a real card surface.
# -----------------------------------------------------------------------------
content = replace_in_range(
    content,
    "struct RosterMonthCalendarView: View {",
    "struct RosterCalendarDayCell: View {",
    '.font(.title3.bold())',
    '.font(.title2.bold())',
    "calendar month hierarchy",
)
content = replace_in_range(
    content,
    "struct RosterMonthCalendarView: View {",
    "struct RosterCalendarDayCell: View {",
    '''        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
''',
    '''        .dPlusCard(radius: 22, elevated: false)
''',
    "calendar card surface",
)

content = replace_once(
    content,
    '''struct RosterCalendarDayCell: View {
    let item: RosterItem?
''',
    '''struct RosterCalendarDayCell: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: RosterItem?
''',
    "calendar cell color scheme",
)
content = replace_in_range(
    content,
    "struct RosterCalendarDayCell: View {",
    "struct RosterCalendarAgendaCard: View {",
    '.foregroundStyle(isSelected ? Color.accentColor : Color.primary)',
    '.foregroundStyle(isSelected ? DPlusTheme.accent(colorScheme) : Color.primary)',
    "calendar selected date color",
)
content = replace_in_range(
    content,
    "struct RosterCalendarDayCell: View {",
    "struct RosterCalendarAgendaCard: View {",
    '''                    isSelected ? Color.accentColor : (isToday ? Color.accentColor.opacity(0.55) : Color.clear),
''',
    '''                    isSelected
                        ? DPlusTheme.accent(colorScheme)
                        : (isToday ? DPlusTheme.accent(colorScheme).opacity(0.55) : DPlusTheme.border(colorScheme)),
''',
    "calendar cell stroke",
)

cell_start, cell_end, cell_block = range_text(content, "struct RosterCalendarDayCell: View {", "struct RosterCalendarAgendaCard: View {", "calendar cell")
old_cell_background = '''    private var cellBackground: Color {
        guard let item else { return Color.secondary.opacity(0.025) }
        let base = categoryColor(item.category)
        return base.opacity(isSelected ? 0.13 : 0.075)
    }
'''
new_cell_background = '''    private var cellBackground: Color {
        if isSelected {
            return DPlusTheme.accent(colorScheme).opacity(colorScheme == .dark ? 0.19 : 0.10)
        }
        return DPlusTheme.calendarCell(colorScheme)
    }
'''
if new_cell_background not in cell_block:
    if old_cell_background not in cell_block:
        raise RuntimeError("V2.12 calendar background marker not found")
    cell_block = cell_block.replace(old_cell_background, new_cell_background, 1)
content = content[:cell_start] + cell_block + content[cell_end:]

content = replace_in_range(
    content,
    "struct RosterCalendarAgendaCard: View {",
    "private func calendarPrimaryLabel",
    '''        .background(Color.secondary.opacity(0.065), in: RoundedRectangle(cornerRadius: 14))
''',
    '''        .dPlusCard(radius: 16, elevated: false)
''',
    "calendar agenda card",
)

# -----------------------------------------------------------------------------
# Premium duty surfaces. These preserve the same data and component order while
# applying the approved rounded-card, high-contrast D+ hierarchy.
# -----------------------------------------------------------------------------
content = replace_in_range(
    content,
    "struct DutyHeroCard: View {",
    "struct RosterRowCard: View {",
    'Text(item.displayTitle).font(.title2.bold()).foregroundStyle(.primary)',
    'Text(item.displayTitle).font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.primary)',
    "Duty hero title",
)
content = replace_in_range(
    content,
    "struct DutyHeroCard: View {",
    "struct RosterRowCard: View {",
    '''        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
''',
    '''        .dPlusCard(radius: 22, elevated: true)
''',
    "Duty hero surface",
)
content = replace_in_range(
    content,
    "struct RosterRowCard: View {",
    "struct RosterDetailView: View {",
    '''        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
''',
    '''        .dPlusCard(radius: 16, elevated: false)
''',
    "Roster row surface",
)

# Live status and operational timeline.
content = replace_once(
    content,
    '''struct DutyLiveStatusCard: View {
    let item: RosterItem
''',
    '''struct DutyLiveStatusCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: RosterItem
''',
    "DutyLiveStatus color scheme",
)
content = replace_in_range(
    content,
    "struct DutyLiveStatusCard: View {",
    "private struct TodayTimelineEntry",
    '''                .background(Color.accentColor.opacity(0.075), in: RoundedRectangle(cornerRadius: 17))
''',
    '''                .background(DPlusTheme.accent(colorScheme).opacity(colorScheme == .dark ? 0.10 : 0.065), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DPlusTheme.accent(colorScheme).opacity(colorScheme == .dark ? 0.20 : 0.10), lineWidth: 1)
                }
''',
    "Live status premium surface",
)
content = replace_in_range(
    content,
    "struct TodayOperationalTimelineCard: View {",
    "private struct TodayTimelineRow: View {",
    '''        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 17))
''',
    '''        .dPlusCard(radius: 18, elevated: false)
''',
    "Today timeline surface",
)

# Primary timing mini-cards introduced in V2.11.9.
content = replace_in_range(
    content,
    "struct TodayPrimaryTimingRow: View {",
    "struct DutyBriefingView: View {",
    '''                .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
''',
    '''                .dPlusCard(radius: 14, elevated: false)
''',
    "Today primary timing cards",
)

# Personal note disclosure remains compact, but receives a small accent signal.
content = replace_once(
    content,
    '''struct TodayPersonalNoteDisclosure: View {
    let item: RosterItem
''',
    '''struct TodayPersonalNoteDisclosure: View {
    @Environment(\.colorScheme) private var colorScheme
    let item: RosterItem
''',
    "Today note color scheme",
)
content = replace_in_range(
    content,
    "struct TodayPersonalNoteDisclosure: View {",
    "struct DutyBriefingView: View {",
    '''                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
''',
    '''                .foregroundStyle(isExpanded ? DPlusTheme.accent(colorScheme) : .secondary)
                .padding(.horizontal, 4)
''',
    "Today note disclosure accent",
)

# Supporting cards: presentation-only replacements.
for start_marker, end_marker, label in [
    ("struct DutyTimelineCard: View {", "struct TimelinePoint: View {", "Duty timeline card"),
    ("struct LogisticsCard: View {", "struct NotesCard: View {", "Logistics card"),
    ("struct NotesCard: View {", "struct NoteBlock: View {", "Notes card"),
    ("struct AircraftCard: View {", "struct CrewCard: View {", "Aircraft card"),
    ("struct CrewCard: View {", "struct InfoRow: View {", "Crew card"),
]:
    start, end, block = range_text(content, start_marker, end_marker, label)
    replacements = [
        ('        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))\n', '        .dPlusCard(radius: 18, elevated: false)\n'),
        ('        .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))\n', '        .dPlusCard(radius: 18, elevated: false)\n'),
    ]
    changed = False
    for old, new in replacements:
        if old in block:
            block = block.replace(old, new, 1)
            changed = True
            break
    if changed:
        content = content[:start] + block + content[end:]

# Briefing section headers are calmer, more premium, and slightly tighter.
content = replace_once(
    content,
    '    var body: some View { Text(text).font(.headline).padding(.top, 2) }',
    '    var body: some View { Text(text).font(.headline.weight(.semibold)).padding(.top, 1) }',
    "briefing section hierarchy",
)

# Version only. Parser/extraction version remains 2.4.0.
content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.13")',
    'LabeledContent("RAIDO Roster", value: "2.12")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 26;", "CURRENT_PROJECT_VERSION = 27;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.13;", "MARKETING_VERSION = 2.12;")
PBX.write_text(pbx)

print("V2.12 D+ premium theme system applied")
