from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"

content = CONTENT.read_text()
marker = "struct CrewControlSheet: View {"
end_marker = "struct SettingsView: View {"

if marker not in content or end_marker not in content:
    raise RuntimeError("V2.9 Crew Control fix markers not found")

prefix, tail = content.split(marker, 1)
crew, suffix = tail.split(end_marker, 1)

# v29b used a raw Python patch string and escaped Swift interpolation/newline
# sequences one level too far. Limit the correction strictly to CrewControlSheet.
crew = crew.replace(r"\\(", r"\(")
crew = crew.replace(r"\\n", r"\n")

content = prefix + marker + crew + end_marker + suffix
CONTENT.write_text(content)
print("V2.9 Crew Control interpolation fix applied")
