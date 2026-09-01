from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()

start = content.find('@MainActor\nfinal class CalendarExporter: ObservableObject {')
if start < 0:
    start = content.find('final class CalendarExporter: ObservableObject {')
if start < 0:
    raise RuntimeError('V2.18.2c CalendarExporter start not found')

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
    raise RuntimeError('V2.18.2c CalendarExporter end not found')

cls = content[start:end]

if 'func syncMonthIfAuthorized(' not in cls:
    marker = '    func exportMonth(_ items: [RosterItem], month: String?) {'
    idx = cls.find(marker)
    if idx < 0:
        raise RuntimeError('V2.18.2c exportMonth marker not found')

    method = r'''    func syncMonthIfAuthorized(
        _ items: [RosterItem],
        month: String?,
        completion: @escaping (String) -> Void
    ) {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return }

        do {
            let selected = items.filter { item in
                guard let month, !month.isEmpty else { return true }
                return item.dateISO?.hasPrefix(month) == true
            }

            var created = 0
            var updated = 0
            for item in selected {
                if try upsert(item) { created += 1 } else { updated += 1 }
            }

            try reconcile(items: selected, month: month, removeObsolete: true)
            try eventStore.commit()
            completion("Calendar synced • \(selected.count) duties • \(created) added • \(updated) updated")
        } catch {
            completion("Calendar sync failed: \(error.localizedDescription)")
        }
    }

'''
    cls = cls[:idx] + method + cls[idx:]

content = content[:start] + cls + content[end:]
CONTENT.write_text(content)
print('V2.18.2c automatic Calendar sync API restored')
