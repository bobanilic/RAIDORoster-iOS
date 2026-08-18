from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise RuntimeError(f"V2.11.5 patch marker not found: {label}")
    return text.replace(old, new, 1)


content = CONTENT.read_text()

# Calendar is the primary planning surface. Keep List one tap away and preserve
# the user's explicit selection after they switch modes.
content = replace_once(
    content,
    '@AppStorage("RAIDORoster.RosterDisplayMode") private var rosterDisplayMode = "list"',
    '@AppStorage("RAIDORoster.RosterDisplayMode") private var rosterDisplayMode = "calendar"',
    "Calendar default",
)

content = replace_once(
    content,
    '''                    Picker("Roster view", selection: $rosterDisplayMode) {
                        Label("List", systemImage: "list.bullet").tag("list")
                        Label("Calendar", systemImage: "calendar").tag("calendar")
                    }
''',
    '''                    Picker("Roster view", selection: $rosterDisplayMode) {
                        Label("Calendar", systemImage: "calendar").tag("calendar")
                        Label("List", systemImage: "list.bullet").tag("list")
                    }
''',
    "Calendar first picker",
)

# Use the available width more efficiently without increasing information
# density. Day height stays compact so the selected-day agenda remains close.
start = content.find("struct RosterMonthCalendarView: View {")
end = content.find("private func calendarPrimaryLabel", start)
if start < 0 or end < 0:
    raise RuntimeError("V2.11.5 calendar view range not found")
calendar = content[start:end]

calendar = calendar.replace(
    'private let columns = Array(repeating: GridItem(.flexible(), spacing: 5), count: 7)',
    'private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 7)',
    1,
)
calendar = calendar.replace('LazyVGrid(columns: columns, spacing: 5)', 'LazyVGrid(columns: columns, spacing: 4)')
calendar = calendar.replace(
    '''        .padding(12)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
''',
    '''        .padding(.horizontal, 5)
        .padding(.vertical, 12)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18))
''',
    1,
)
calendar = calendar.replace(
    '.font(.caption.weight(isToday || isSelected ? .bold : .semibold))',
    '.font(.subheadline.weight(isToday || isSelected ? .bold : .semibold))',
    1,
)
calendar = calendar.replace(
    '''                Text(calendarPrimaryLabel(item))
                    .font(.caption2.bold())
                    .foregroundStyle(categoryColor(item.category))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
''',
    '''                Text(calendarPrimaryLabel(item))
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(categoryColor(item.category))
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    .allowsTightening(true)
                    .frame(maxWidth: .infinity, alignment: .leading)
''',
    1,
)
calendar = calendar.replace(
    '''        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
''',
    '''        .padding(.horizontal, 5)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
''',
    1,
)

content = content[:start] + calendar + content[end:]

# Avoid repeating the same hotel title in Logistics while preserving every
# distinct assignment range. This is presentation-only; the underlying RAIDO
# activities remain untouched.
hotel_helper = r'''
private struct HotelDisplayRow: Identifiable {
    let id: String
    let title: String
    let value: String
}

private func groupedHotelDisplayRows(_ hotels: [RosterActivity]) -> [HotelDisplayRow] {
    var order: [String] = []
    var titles: [String: String] = [:]
    var ranges: [String: [String]] = [:]

    for hotel in hotels {
        let title = (hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let key = title.lowercased()
        guard !key.isEmpty else { continue }

        if titles[key] == nil {
            order.append(key)
            titles[key] = title
            ranges[key] = []
        }

        let range = hotelRange(hotel)
        if !range.isEmpty, !(ranges[key] ?? []).contains(range) {
            ranges[key, default: []].append(range)
        }
    }

    return order.map { key in
        HotelDisplayRow(
            id: key,
            title: titles[key] ?? "Hotel",
            value: (ranges[key] ?? []).joined(separator: "\n")
        )
    }
}

'''
if "private struct HotelDisplayRow: Identifiable" not in content:
    content = replace_once(
        content,
        "struct LogisticsCard: View {\n",
        hotel_helper + "struct LogisticsCard: View {\n",
        "hotel presentation helper",
    )

content = replace_once(
    content,
    '''            ForEach(item.hotelAssignments) { hotel in
                InfoRow(
                    icon: "bed.double.fill",
                    title: hotel.hotelName.isEmpty ? hotel.title : hotel.hotelName,
                    value: hotelRange(hotel)
                )
            }
''',
    '''            ForEach(groupedHotelDisplayRows(item.hotelAssignments)) { hotel in
                InfoRow(
                    icon: "bed.double.fill",
                    title: hotel.title,
                    value: hotel.value
                )
            }
''',
    "deduplicated hotel presentation",
)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.4")',
    'LabeledContent("RAIDO Roster", value: "2.11.5")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 17;", "CURRENT_PROJECT_VERSION = 18;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.4;", "MARKETING_VERSION = 2.11.5;")
PBX.write_text(pbx)

print("V2.11.5 calendar-first polish applied")
