from pathlib import Path

root = Path(__file__).resolve().parent
path = root / "RAIDORoster" / "ContentView.swift"
text = path.read_text()

old = '''    var crewMembers: [CrewMember] {
        var seen = Set<String>()
        return flightActivities.flatMap(\\.crew).filter { member in
            guard !seen.contains(member.id) else { return false }
            seen.insert(member.id)
            return true
        }
    }
'''

new = '''    var crewMembers: [CrewMember] {
        var seen = Set<String>()
        var unique: [CrewMember] = []

        for member in flightActivities.flatMap(\\.crew) {
            // RAIDO can repeat the same person once per sector and decorate the
            // display name with operational markers such as (x), (y), (p) or
            // combinations of those markers. Employee/crew code is the stable
            // identity when available; otherwise use a normalized clean name.
            let cleanName = member.name
                .replacingOccurrences(
                    of: #"\\s*\\((?i:[xyp](?:\\s+[xyp])*)\\)\\s*"#,
                    with: " ",
                    options: .regularExpression
                )
                .split(whereSeparator: \\.isWhitespace)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let normalizedCode = member.code
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            let normalizedName = cleanName
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .uppercased()
            let identity = normalizedCode.isEmpty ? "NAME|\\(normalizedName)" : "CODE|\\(normalizedCode)"

            guard !identity.hasSuffix("|"), !seen.contains(identity) else { continue }
            seen.insert(identity)
            unique.append(CrewMember(
                role: member.role,
                code: member.code,
                name: cleanName.isEmpty ? member.name : cleanName,
                country: member.country,
                phone: member.phone
            ))
        }
        return unique
    }
'''

if new in text:
    print("V2.21.0 crew de-duplication already integrated")
elif old in text:
    path.write_text(text.replace(old, new, 1))
    print("V2.21.0 crew de-duplication integrated")
else:
    raise SystemExit("crewMembers block not found; refusing an unsafe patch")
