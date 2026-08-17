from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

old = '''                                Button {
                                    openCrewWhatsApp(phone)
                                } label: {
                                    Label("WhatsApp", systemImage: "message.fill")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
'''
new = '''                                Button {
                                    openCrewWhatsApp(phone)
                                } label: {
                                    Label("WA", systemImage: "message.fill")
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
'''

if new not in content:
    if old not in content:
        raise RuntimeError("V2.10.2 crew WA button marker not found")
    content = content.replace(old, new, 1)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.10.1")',
    'LabeledContent("RAIDO Roster", value: "2.10.2")',
    1
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 11;", "CURRENT_PROJECT_VERSION = 12;")
pbx = pbx.replace("MARKETING_VERSION = 2.10.1;", "MARKETING_VERSION = 2.10.2;")
PBX.write_text(pbx)

print("V2.10.2 compact crew WA button applied")
