from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"


def block_end(text: str, start: int) -> int:
    brace = text.find('{', start)
    if brace < 0:
        return -1
    depth = 0
    for i in range(brace, len(text)):
        if text[i] == '{':
            depth += 1
        elif text[i] == '}':
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


content = CONTENT.read_text()
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.19.5 RosterStore boundaries not found')
store = content[store_start:store_end]

start = store.find('    func adjacentRosterMonthKey(previous: Bool) -> String? {')
if start < 0:
    raise RuntimeError('V2.19.5 adjacentRosterMonthKey not found')
end = block_end(store, start)
if end < 0:
    raise RuntimeError('V2.19.5 adjacentRosterMonthKey end not found')

# YYYY-MM is an identifier, not an instant in time. Do pure integer month
# arithmetic so device timezone / DST can never roll a month at midnight.
replacement = r'''    func adjacentRosterMonthKey(previous: Bool) -> String? {
        guard let key = selectedRosterMonth, key.count == 7 else { return nil }
        let parts = key.split(separator: "-")
        guard parts.count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              (1...12).contains(month) else { return nil }

        let delta = previous ? -1 : 1
        let zeroBased = (year * 12) + (month - 1) + delta
        guard zeroBased >= 0 else { return nil }
        let targetYear = zeroBased / 12
        let targetMonth = (zeroBased % 12) + 1
        return String(format: "%04d-%02d", targetYear, targetMonth)
    }'''
store = store[:start] + replacement + store[end:]
content = content[:store_start] + store + content[store_end:]

content = content.replace('LabeledContent("RAIDO Roster", value: "2.19.4")',
                          'LabeledContent("RAIDO Roster", value: "2.19.5")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.19.4;', 'MARKETING_VERSION = 2.19.5;')
PBX.write_text(pbx)

print('V2.19.5 timezone-independent YYYY-MM month arithmetic applied')
