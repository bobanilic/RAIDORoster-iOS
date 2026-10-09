from pathlib import Path
import re

root = Path(__file__).resolve().parent
path = root / "RAIDORoster" / "ContentView.swift"
text = path.read_text()


def block_bounds(source: str, anchor: str) -> tuple[int, int]:
    start = source.find(anchor)
    if start < 0:
        raise RuntimeError(f"Crew dedup patch: anchor missing: {anchor}")
    opening = source.find("{", start)
    if opening < 0:
        raise RuntimeError("Crew dedup patch: opening brace missing")
    depth = 0
    for index in range(opening, len(source)):
        char = source[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return start, index + 1
    raise RuntimeError("Crew dedup patch: unterminated block")


crew_struct_start, crew_struct_end = block_bounds(text, "struct CrewMember:")
crew_struct = text[crew_struct_start:crew_struct_end]
stored_fields = re.findall(r"^\s*let\s+([A-Za-z_][A-Za-z0-9_]*)\s*:", crew_struct, re.MULTILINE)
if "name" not in stored_fields or "code" not in stored_fields:
    raise RuntimeError(f"Crew dedup patch: unexpected CrewMember fields: {stored_fields}")

property_start, property_end = block_bounds(text, "    var crewMembers: [CrewMember] {")
current = text[property_start:property_end]

# The patch is intentionally semantic rather than tied to one historical source
# snapshot. Earlier patches have expanded CrewMember over time, so exact string
# replacement makes the build chain unnecessarily fragile. If the generated
# property already contains the stable code/name identity logic, leave it alone.
markers = (
    "let normalizedCode = member.code",
    'let identity = normalizedCode.isEmpty ? "NAME|',
    "unique.append(CrewMember(",
)
if all(marker in current for marker in markers):
    print("V2.21.0 crew de-duplication already integrated")
    raise SystemExit(0)

initializer_lines = []
for field in stored_fields:
    value = "cleanName.isEmpty ? member.name : cleanName" if field == "name" else f"member.{field}"
    initializer_lines.append(f"                {field}: {value}")
initializer = ",\n".join(initializer_lines)

new = f'''    var crewMembers: [CrewMember] {{
        var seen = Set<String>()
        var unique: [CrewMember] = []

        for member in flightActivities.flatMap(\\.crew) {{
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

            guard !identity.hasSuffix("|"), !seen.contains(identity) else {{ continue }}
            seen.insert(identity)
            unique.append(CrewMember(
{initializer}
            ))
        }}
        return unique
    }}'''

text = text[:property_start] + new + text[property_end:]
path.write_text(text)
print(f"V2.21.0 crew de-duplication integrated for fields: {', '.join(stored_fields)}")
