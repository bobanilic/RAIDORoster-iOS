from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
s = CONTENT.read_text()

start = s.find('private final class TodayLiveFlightLocationManager: NSObject, ObservableObject, CLLocationManagerDelegate {')
end = s.find('\nstruct TodayRouteMapCard: View {', start)
if start < 0 or end < 0:
    raise RuntimeError('V2.22.1 location manager boundaries missing')
manager = s[start:end]

publish_start = manager.find('    private func publishFused(_ value: CLLocation, source: String, estimated: Bool, now: Date) {')
if publish_start < 0:
    raise RuntimeError('V2.22.1 publishFused boundary missing')
publish_end = manager.find('\n    }', publish_start)
while publish_end >= 0:
    # Find the closing brace for publishFused structurally.
    brace = manager.find('{', publish_start)
    depth = 0
    publish_end = -1
    for i in range(brace, len(manager)):
        if manager[i] == '{':
            depth += 1
        elif manager[i] == '}':
            depth -= 1
            if depth == 0:
                publish_end = i + 1
                break
    break
if publish_end < 0:
    raise RuntimeError('V2.22.1 publishFused end missing')

block = manager[publish_start:publish_end]
phase_anchor = '        updatePhase(value, estimated: estimated, now: now)\n'
guard_line = '        guard !estimated else { return } // measured trail only\n'

if guard_line not in block:
    if phase_anchor not in block:
        raise RuntimeError('V2.22.1 phase-update anchor missing')
    block = block.replace(phase_anchor, phase_anchor + '\n' + guard_line, 1)

# Fail closed: persistent green trail must only be reached after the estimated
# guard. This keeps route-model / stale-GNSS propagation visible as the moving
# marker without writing invented points into the saved flown path.
append_idx = block.find('fusedTrail.append(value.coordinate)')
guard_idx = block.find('guard !estimated else { return } // measured trail only')
if append_idx < 0:
    raise RuntimeError('V2.22.1 fused trail append missing')
if guard_idx < 0 or guard_idx > append_idx:
    raise RuntimeError('V2.22.1 measured-trail guard is not before trail append')

manager = manager[:publish_start] + block + manager[publish_end:]
s = s[:start] + manager + s[end:]
CONTENT.write_text(s)
print('Flight Companion measured-only persistent trail applied')
