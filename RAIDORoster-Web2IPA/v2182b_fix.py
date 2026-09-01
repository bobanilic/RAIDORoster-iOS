from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

# V2.18.2b: make Calendar reconciliation Swift-6/Xcode-26 friendly.
# Avoid optional-binding/eventIdentifier assumptions and actor-sensitive method
# references while retaining stable calendar IDs and RAIDO-only cleanup.
start = content.find('@MainActor\nfinal class CalendarExporter: ObservableObject {')
if start < 0:
    start = content.find('final class CalendarExporter: ObservableObject {')
if start < 0:
    raise RuntimeError('V2.18.2b CalendarExporter start not found')

brace = content.find('{', start)
depth = 0
end = -1
for i in range(brace, len(content)):
    if content[i] == '{':
        depth += 1
    elif content[i] == '}':
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end < 0:
    raise RuntimeError('V2.18.2b CalendarExporter end not found')

cls = content[start:end]

# Replace filter(methodReference) with explicit closures.
cls = cls.replace('.filter(isRAIDOOwned)', '.filter { self.isRAIDOOwned($0) }')

# EventKit eventIdentifier is imported differently across SDK/compiler versions.
# Do not optional-bind it; compare the identifier strings directly and use the
# stable calendar key as the logical keep-set instead.
cls = cls.replace(
'''        var keepIDs = Set<String>()
        for expectedDuty in expected {''',
'''        var keepKeys = Set<String>()
        for expectedDuty in expected {''', 1)

cls = cls.replace(
'''            if let id = canonical.eventIdentifier { keepIDs.insert(id) }
''',
'''            keepKeys.insert(expectedDuty.key)
''', 1)

cls = cls.replace(
'''        for event in owned {
            if let id = event.eventIdentifier, keepIDs.contains(id) { continue }
            let belongs = expected.contains { duty in
                event.notes?.contains(marker(prefix: stableMarkerPrefix, value: duty.key)) == true ||
                semanticMatch(event, item: duty.item, span: duty.span)
            }
            if !belongs {
                try eventStore.remove(event, span: .thisEvent, commit: false)
            }
        }''',
'''        for event in owned {
            let belongs = expected.contains { duty in
                event.notes?.contains(marker(prefix: stableMarkerPrefix, value: duty.key)) == true ||
                semanticMatch(event, item: duty.item, span: duty.span)
            }
            if !belongs {
                try eventStore.remove(event, span: .thisEvent, commit: false)
            }
        }''', 1)

# Avoid eventIdentifier optionality entirely for duplicate identity comparison.
# Calendar item identifiers are stable enough within this reconciliation pass;
# compare object identity first and fall back to calendarItemIdentifier.
cls = cls.replace(
'''        for duplicate in candidates where duplicate.eventIdentifier != event.eventIdentifier {
            if duplicate.notes?.contains(stableMarker) == true || semanticMatch(duplicate, item: item, span: span) {
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
            }
        }''',
'''        for duplicate in candidates {
            if duplicate === event { continue }
            if duplicate.calendarItemIdentifier == event.calendarItemIdentifier { continue }
            if duplicate.notes?.contains(stableMarker) == true || semanticMatch(duplicate, item: item, span: span) {
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
            }
        }''', 1)

cls = cls.replace(
'''            for duplicate in matches where duplicate.eventIdentifier != canonical.eventIdentifier {
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
            }''',
'''            for duplicate in matches {
                if duplicate === canonical { continue }
                if duplicate.calendarItemIdentifier == canonical.calendarItemIdentifier { continue }
                try eventStore.remove(duplicate, span: .thisEvent, commit: false)
            }''', 1)

# Remove unused keepKeys if compiler treats it as warning-only, but keep the
# expected stable keys semantically represented by `belongs`; no state needed.
cls = cls.replace('        var keepKeys = Set<String>()\n', '')
cls = cls.replace('            keepKeys.insert(expectedDuty.key)\n', '')

content = content[:start] + cls + content[end:]
content = content.replace('LabeledContent("RAIDO Roster", value: "2.18.2")',
                          'LabeledContent("RAIDO Roster", value: "2.18.2b")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.18.2;', 'MARKETING_VERSION = 2.18.2;')
PBX.write_text(pbx)

print('V2.18.2b Calendar compile-compatibility fix applied')
