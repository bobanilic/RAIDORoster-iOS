from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
JS = ROOT / "RAIDORoster" / "RosterEnhancements.js"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

# -----------------------------------------------------------------------------
# V2.17.9 — RAIDO duty segmentation.
# A calendar day is not a duty. Split same-day activities into independent duty
# envelopes so an early-morning release and an evening check-in remain 2 + 2
# sectors instead of becoming one artificial four-sector/day record.
# -----------------------------------------------------------------------------
js = JS.read_text()
start = js.find('  function groupDays(activities) {')
end = js.find('\n  function build() {', start)
if start < 0 or end < 0:
    raise RuntimeError('V2.17.9 groupDays boundaries not found')

new_grouping = r'''  function activityEpoch(meta) {
    if (!meta) return NaN;
    const iso = meta.utcTime && meta.utcDateISO
      ? `${meta.utcDateISO}T${meta.utcTime}:00Z`
      : `${meta.dateISO}T${meta.localTime}:00Z`;
    const value = Date.parse(iso);
    return Number.isFinite(value) ? value : NaN;
  }

  function activityStartEpoch(a) {
    return activityEpoch(a.checkIn) || activityEpoch(a.start) || NaN;
  }

  function activityEndEpoch(a) {
    return activityEpoch(a.checkOut) || activityEpoch(a.end) || activityStartEpoch(a);
  }

  function isDutyCore(a) {
    return ['FLIGHT', 'POSITIONING', 'TRAINING', 'RESERVE', 'STANDBY'].includes(a.category);
  }

  function dutyGapStartsNew(previous, current, groupStart, groupEnd) {
    const prevEnd = activityEndEpoch(previous);
    const currentStart = activityStartEpoch(current);
    const currentCI = activityEpoch(current.checkIn);
    const previousCO = activityEpoch(previous.checkOut);

    // Explicit release followed by a later explicit check-in is authoritative.
    if (Number.isFinite(previousCO) && Number.isFinite(currentCI) && currentCI > previousCO + 30 * 60 * 1000) {
      return true;
    }

    // If RAIDO repeats duty CI/CO only on the first/last logical activity,
    // a large real gap between core activities still marks a new duty.
    if (Number.isFinite(prevEnd) && Number.isFinite(currentStart) && currentStart - prevEnd >= 4 * 60 * 60 * 1000) {
      return true;
    }

    // A new explicit CI many hours after this group's CI is also a new duty,
    // even if a non-flight administrative activity has a broad time span.
    if (Number.isFinite(currentCI) && Number.isFinite(groupStart) && currentCI - groupStart >= 4 * 60 * 60 * 1000) {
      if (!Number.isFinite(groupEnd) || currentCI > groupEnd + 30 * 60 * 1000) return true;
    }

    return false;
  }

  function dutyGroupsForDate(items) {
    const sorted = [...items].sort((a, b) => {
      const aa = activityStartEpoch(a);
      const bb = activityStartEpoch(b);
      if (Number.isFinite(aa) && Number.isFinite(bb) && aa !== bb) return aa - bb;
      return a.start.localTime.localeCompare(b.start.localTime) || a.sourceIndex - b.sourceIndex;
    });

    const core = sorted.filter(isDutyCore);
    const passive = sorted.filter(a => !isDutyCore(a) && !isAuxiliary(a.category));

    // OFF/REST/etc. dates naturally remain one day record.
    if (!core.length) return [sorted];

    const groups = [];
    let current = [];
    let groupStart = NaN;
    let groupEnd = NaN;

    for (const a of core) {
      if (current.length && dutyGapStartsNew(current[current.length - 1], a, groupStart, groupEnd)) {
        groups.push(current);
        current = [];
        groupStart = NaN;
        groupEnd = NaN;
      }
      current.push(a);
      const s = activityStartEpoch(a);
      const e = activityEndEpoch(a);
      if (Number.isFinite(s)) groupStart = Number.isFinite(groupStart) ? Math.min(groupStart, s) : s;
      if (Number.isFinite(e)) groupEnd = Number.isFinite(groupEnd) ? Math.max(groupEnd, e) : e;
    }
    if (current.length) groups.push(current);

    // Administrative entries such as delayed reporting are attached to the
    // nearest duty envelope, but never allowed to bridge two flight duties.
    for (const a of passive) {
      const t = activityStartEpoch(a);
      let bestIndex = 0;
      let bestDistance = Number.POSITIVE_INFINITY;
      groups.forEach((g, index) => {
        const starts = g.map(activityStartEpoch).filter(Number.isFinite);
        const ends = g.map(activityEndEpoch).filter(Number.isFinite);
        const lo = starts.length ? Math.min(...starts) : NaN;
        const hi = ends.length ? Math.max(...ends) : lo;
        let distance = 0;
        if (Number.isFinite(t) && Number.isFinite(lo)) {
          if (t < lo) distance = lo - t;
          else if (Number.isFinite(hi) && t > hi) distance = t - hi;
        }
        if (distance < bestDistance) {
          bestDistance = distance;
          bestIndex = index;
        }
      });
      groups[bestIndex].push(a);
    }

    return groups.map(g => g.sort((a, b) => {
      const aa = activityStartEpoch(a);
      const bb = activityStartEpoch(b);
      if (Number.isFinite(aa) && Number.isFinite(bb) && aa !== bb) return aa - bb;
      return a.start.localTime.localeCompare(b.start.localTime);
    }));
  }

  function groupDays(activities) {
    const byDate = new Map();
    for (const a of activities) {
      if (!byDate.has(a.dateISO)) byDate.set(a.dateISO, []);
      byDate.get(a.dateISO).push(a);
    }

    const rows = [];
    let rowIndex = 0;

    for (const [dateISO, dayItems] of Array.from(byDate.entries()).sort((a, b) => a[0].localeCompare(b[0]))) {
      const groups = dutyGroupsForDate(dayItems);

      groups.forEach((items, dutyIndex) => {
        const primary = [...items].sort((a, b) => priority(b.category) - priority(a.category))[0];
        const meaningful = items.filter(i => !isAuxiliary(i.category));
        const displayItems = meaningful.length ? meaningful : items;
        const names = Array.from(new Set(displayItems.map(i => i.title).filter(Boolean)));

        const first = displayItems[0] || items[0];
        const last = displayItems[displayItems.length - 1] || items[items.length - 1];
        const ci = displayItems.map(i => i.checkIn?.localTime).find(Boolean) || '';
        const span = first?.start?.localTime
          ? `${first.start.localTime}${last?.end?.localTime ? `–${last.end.localTime}` : ''}`
          : '';

        const activeHotels = activities.filter(a =>
          a.category === 'HOTEL' &&
          a.start?.dateISO <= dateISO &&
          (a.end?.dateISO || a.start.dateISO) >= dateISO
        );

        rows.push({
          id: `d-${dateISO}-${dutyIndex + 1}`,
          index: rowIndex++,
          dateISO,
          dateText: first.dateText,
          category: primary.category,
          title: names.slice(0, 5).join(' + ') || primary.title,
          route: combineRoute(displayItems),
          timeText: `${ci ? `CI ${ci}  •  ` : ''}${span}`,
          rawText: items.map(i => i.rawText).join('\n'),
          cells: items.flatMap((i, n) => [`ACTIVITY ${n + 1}: ${i.title}`, ...i.cells]),
          activities: items.map(publicActivity),
          activeHotels: activeHotels.map(publicActivity)
        });
      });
    }

    return rows.sort((a, b) => a.dateISO.localeCompare(b.dateISO) || a.index - b.index);
  }
'''
js = js[:start] + new_grouping + js[end:]

# Coverage must count calendar dates, not duty rows.
js = js.replace(
    "    const monthDays = monthPrefix ? b.days.filter(d => d.dateISO.startsWith(monthPrefix)).length : b.days.length;",
    "    const monthDates = new Set(b.days.filter(d => !monthPrefix || d.dateISO.startsWith(monthPrefix)).map(d => d.dateISO));\n    const monthDays = monthDates.size;",
    1,
)
js = js.replace("parser: 'raido-logical-activity-2.4'", "parser: 'raido-duty-envelope-2.17.9'", 1)
JS.write_text(js)

# -----------------------------------------------------------------------------
# Native model: allow >1 RosterItem on the same date and choose the correct
# current/upcoming duty by timestamps instead of simply `.first` for the day.
# -----------------------------------------------------------------------------
content = CONTENT.read_text()

# Remove the legacy one-row-per-date deduplication in ingest().
content = re.sub(r'\n\s*var seenDates = Set<String>\(\)\n', '\n', content, count=1)
content = re.sub(
    r',\s*!seenDates\.contains\(dateISO\) else \{ return nil \}\s*\n\s*seenDates\.insert\(dateISO\)',
    ' else { return nil }',
    content,
    count=1,
)

# Timestamp-aware primary duty for Today/Fleet/Crew Control.
store_start = content.find('final class RosterStore: ObservableObject {')
store_end = content.find('\n@MainActor\nfinal class AppState:', store_start)
if store_start < 0 or store_end < 0:
    raise RuntimeError('V2.17.9 RosterStore boundaries not found')
store = content[store_start:store_end]
if 'var todayPrimaryItem: RosterItem?' not in store:
    marker = '''    var todayItems: [RosterItem] {\n'''
    idx = store.find(marker)
    if idx < 0:
        raise RuntimeError('V2.17.9 todayItems marker not found')
    # Insert after the todayItems computed-property block.
    brace = store.find('{', idx)
    depth = 0
    end_prop = -1
    for i in range(brace, len(store)):
        if store[i] == '{': depth += 1
        elif store[i] == '}':
            depth -= 1
            if depth == 0:
                end_prop = i + 1
                break
    if end_prop < 0:
        raise RuntimeError('V2.17.9 todayItems end not found')
    helper = r'''

    var todayPrimaryItem: RosterItem? {
        let now = Date()
        let today = todayItems
        if let active = today.first(where: { item in
            guard let start = item.dutyStartUTCDate, let end = item.dutyEndUTCDate else { return false }
            return now >= start && now < end
        }) { return active }

        let future = today.compactMap { item -> (RosterItem, Date)? in
            guard item.isOperationalDuty, let start = item.dutyStartUTCDate, start > now else { return nil }
            return (item, start)
        }.sorted { $0.1 < $1.1 }
        if let next = future.first { return next.0 }

        let completed = today.compactMap { item -> (RosterItem, Date)? in
            guard item.isOperationalDuty, let end = item.dutyEndUTCDate, end <= now else { return nil }
            return (item, end)
        }.sorted { $0.1 > $1.1 }
        return completed.first?.0 ?? today.first
    }
'''
    store = store[:end_prop] + helper + store[end_prop:]
content = content[:store_start] + store + content[store_end:]

# Any Today/toolbar context that used the arbitrary first same-day row should
# use the timestamp-aware duty selection instead.
content = content.replace('store.todayItems.first', 'store.todayPrimaryItem')

# Calendar must tolerate multiple duty rows for one date. Show the most useful
# operational row; full details remain in List/Today.
content = content.replace(
    '''    private var itemsByDate: [String: RosterItem] {\n        Dictionary(uniqueKeysWithValues: items.compactMap { item in\n            guard let iso = item.dateISO else { return nil }\n            return (iso, item)\n        })\n    }\n''',
    '''    private var itemsByDate: [String: RosterItem] {\n        let grouped = Dictionary(grouping: items.compactMap { item -> RosterItem? in\n            item.dateISO == nil ? nil : item\n        }, by: { $0.dateISO ?? "" })\n        return grouped.compactMapValues { rows in\n            rows.first(where: { $0.isOperationalDuty }) ?? rows.first\n        }\n    }\n''',
    1,
)

# Detailed change detection must not use Dictionary(uniqueKeysWithValues:) on
# duplicate dates. Collapse each date to a deterministic combined fingerprint.
content = content.replace(
    '''        let oldMap = Dictionary(uniqueKeysWithValues: old.compactMap { item in item.dateISO.map { ($0, item) } })\n        let newMap = Dictionary(uniqueKeysWithValues: new.compactMap { item in item.dateISO.map { ($0, item) } })\n''',
    '''        let oldGroups = Dictionary(grouping: old.compactMap { item -> RosterItem? in item.dateISO == nil ? nil : item }, by: { $0.dateISO ?? "" })\n        let newGroups = Dictionary(grouping: new.compactMap { item -> RosterItem? in item.dateISO == nil ? nil : item }, by: { $0.dateISO ?? "" })\n        let oldMap = oldGroups.compactMapValues { $0.sorted { $0.index < $1.index }.first }\n        let newMap = newGroups.compactMapValues { $0.sorted { $0.index < $1.index }.first }\n''',
    1,
)

# Other old/new day maps written manually should concatenate all same-date duty
# fingerprints rather than silently overwriting the first/last duty.
content = content.replace(
    'if let date = item.dateISO { oldMap[date] = normalizedItem(item) }',
    'if let date = item.dateISO { oldMap[date] = [oldMap[date], normalizedItem(item)].compactMap { $0 }.joined(separator: "~~") }'
)
content = content.replace(
    'if let date = item.dateISO { newMap[date] = normalizedItem(item) }',
    'if let date = item.dateISO { newMap[date] = [newMap[date], normalizedItem(item)].compactMap { $0 }.joined(separator: "~~") }'
)

# -----------------------------------------------------------------------------
# Fleet state engine: retain ICAO identity and ADS-B position quality instead of
# treating every returned lat/lon as equally trustworthy.
# -----------------------------------------------------------------------------
if 'let icaoHex: String?' not in content:
    marker = '''    let sourceSeenSeconds: Double\n    let fetchedAt: Date\n'''
    replacement = '''    let sourceSeenSeconds: Double\n    let fetchedAt: Date\n    let icaoHex: String?\n    let seenPositionSeconds: Double?\n    let nacP: Int?\n    let nic: Int?\n    let radiusContainmentMeters: Double?\n'''
    if marker not in content:
        raise RuntimeError('V2.17.9 FleetLiveSnapshot fields marker not found')
    content = content.replace(marker, replacement, 1)

# New properties are optional, but existing memberwise initializers must now
# explicitly carry them when cloning snapshots.
content = content.replace(
    '''                    sourceSeenSeconds: old.sourceSeenSeconds,\n                    fetchedAt: old.fetchedAt\n''',
    '''                    sourceSeenSeconds: old.sourceSeenSeconds,\n                    fetchedAt: old.fetchedAt,\n                    icaoHex: old.icaoHex,\n                    seenPositionSeconds: old.seenPositionSeconds,\n                    nacP: old.nacP,\n                    nic: old.nic,\n                    radiusContainmentMeters: old.radiusContainmentMeters\n''',
    1,
)

# Enrich ADSB.lol decoder with surveillance identity and quality fields.
adsb_start = content.find('private struct ADSBLOLAircraft: Decodable {')
adsb_end = content.find('\nprivate struct ADSBLOLRouteRequest', adsb_start)
if adsb_start < 0 or adsb_end < 0:
    raise RuntimeError('V2.17.9 ADSBLOLAircraft boundaries not found')
new_adsb = r'''private struct ADSBLOLAircraft: Decodable {
    let hex: String?
    let flight: String?
    let lat: Double?
    let lon: Double?
    let gs: Double?
    let track: Double?
    let seen: Double
    let seenPos: Double?
    let nacP: Int?
    let nic: Int?
    let rc: Double?
    let altitudeFeet: Double?
    let onGround: Bool

    enum CodingKeys: String, CodingKey {
        case hex, flight, lat, lon, gs, track, seen, nic, rc
        case seenPos = "seen_pos"
        case nacP = "nac_p"
        case altBaro = "alt_baro"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hex = try? container.decodeIfPresent(String.self, forKey: .hex)
        flight = try container.decodeIfPresent(String.self, forKey: .flight)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lat = try container.decodeIfPresent(Double.self, forKey: .lat)
        lon = try container.decodeIfPresent(Double.self, forKey: .lon)
        gs = try container.decodeIfPresent(Double.self, forKey: .gs)
        track = try container.decodeIfPresent(Double.self, forKey: .track)
        seen = (try? container.decode(Double.self, forKey: .seen)) ?? 0
        seenPos = try? container.decodeIfPresent(Double.self, forKey: .seenPos)
        nacP = try? container.decodeIfPresent(Int.self, forKey: .nacP)
        nic = try? container.decodeIfPresent(Int.self, forKey: .nic)
        rc = try? container.decodeIfPresent(Double.self, forKey: .rc)

        if let numeric = try? container.decode(Double.self, forKey: .altBaro) {
            altitudeFeet = numeric
            onGround = false
        } else if let value = try? container.decode(String.self, forKey: .altBaro) {
            altitudeFeet = nil
            onGround = value.lowercased() == "ground"
        } else {
            altitudeFeet = nil
            onGround = false
        }
    }
}
'''
content = content[:adsb_start] + new_adsb + content[adsb_end:]

# Populate enriched snapshot fields.
fetch_marker = '''            sourceSeenSeconds: aircraft.seen,\n            fetchedAt: Date()\n'''
fetch_replacement = '''            sourceSeenSeconds: aircraft.seen,\n            fetchedAt: Date(),\n            icaoHex: aircraft.hex?.uppercased(),\n            seenPositionSeconds: aircraft.seenPos,\n            nacP: aircraft.nacP,\n            nic: aircraft.nic,\n            radiusContainmentMeters: aircraft.rc\n'''
if fetch_marker not in content:
    raise RuntimeError('V2.17.9 Fleet snapshot creation marker not found')
content = content.replace(fetch_marker, fetch_replacement, 1)

# Position freshness should follow seen_pos when available; the transponder can
# be freshly heard while its last coordinate is old.
if 'var effectivePositionAge:' not in content:
    marker = '''    var observationAge: TimeInterval {\n        max(0, Date().timeIntervalSince(fetchedAt) + sourceSeenSeconds)\n    }\n'''
    support = '''    var observationAge: TimeInterval {\n        max(0, Date().timeIntervalSince(fetchedAt) + sourceSeenSeconds)\n    }\n\n    var effectivePositionAge: TimeInterval {\n        max(observationAge, seenPositionSeconds ?? sourceSeenSeconds)\n    }\n\n    var positionQualityText: String {\n        if let rc = radiusContainmentMeters, rc > 0 {\n            return rc < 1000 ? "±\\(Int(rc.rounded())) m" : "±\\(String(format: \"%.1f\", rc / 1000)) km"\n        }\n        if let nacP {\n            switch nacP {\n            case 11: return "< 3 m"\n            case 10: return "< 10 m"\n            case 9: return "< 30 m"\n            case 8: return "< 92 m"\n            case 7: return "< 185 m"\n            case 6: return "< 556 m"\n            case 5: return "< 0.93 km"\n            default: break\n            }\n        }\n        return "Unknown accuracy"\n    }\n'''
    if marker not in content:
        raise RuntimeError('V2.17.9 observationAge marker not found')
    content = content.replace(marker, support, 1)

content = content.replace('var isFresh: Bool { observationAge <= 120 }', 'var isFresh: Bool { effectivePositionAge <= 120 }')
content = content.replace('var isRecent: Bool { observationAge <= 900 }', 'var isRecent: Bool { effectivePositionAge <= 900 }')
content = content.replace('var isStale: Bool { observationAge > 900 }', 'var isStale: Bool { effectivePositionAge > 900 }')

# In Fleet detail expose ICAO and ADS-B position integrity when present.
anchor = '''                            Text("Observation \\(fleetCompactAge(snapshot.observationAge)) • public ADS-B")\n                                .font(.caption)\n                                .foregroundStyle(.secondary)\n'''
if anchor in content:
    content = content.replace(anchor, anchor + '''                            HStack(spacing: 8) {\n                                Text("Position \\(snapshot.positionQualityText)")\n                                if let hex = snapshot.icaoHex { Text("ICAO \\(hex)") }\n                            }\n                            .font(.caption2.monospacedDigit())\n                            .foregroundStyle(.secondary)\n''', 1)

# Version bump.
content = content.replace('LabeledContent("RAIDO Roster", value: "2.17.8")', 'LabeledContent("RAIDO Roster", value: "2.17.9")', 1)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace('MARKETING_VERSION = 2.17.8;', 'MARKETING_VERSION = 2.17.9;')
PBX.write_text(pbx)

print('V2.17.9 duty-envelope segmentation + ADS-B identity/quality state engine applied')
