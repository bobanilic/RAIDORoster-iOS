from pathlib import Path

ROOT = Path(__file__).resolve().parent
CONTENT = ROOT / "RAIDORoster" / "ContentView.swift"
PBX = ROOT / "RAIDORoster.xcodeproj" / "project.pbxproj"

content = CONTENT.read_text()

old = '''                .padding()
            }
            .navigationTitle("GetJet / AirHub Roster")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
'''
new = '''                .padding(.horizontal)
                .padding(.bottom)
                .padding(.top, 0)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("GetJet / AirHub Roster")
                        .font(.system(size: 24, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .accessibilityAddTraits(.isHeader)
                }

                ToolbarItem(placement: .topBarTrailing) {
'''

if new not in content:
    if old not in content:
        raise RuntimeError("V2.11.8 compact header spacing marker not found")
    content = content.replace(old, new, 1)

content = content.replace(
    'LabeledContent("RAIDO Roster", value: "2.11.7")',
    'LabeledContent("RAIDO Roster", value: "2.11.8")',
    1,
)
CONTENT.write_text(content)

pbx = PBX.read_text()
pbx = pbx.replace("CURRENT_PROJECT_VERSION = 20;", "CURRENT_PROJECT_VERSION = 21;")
pbx = pbx.replace("MARKETING_VERSION = 2.11.7;", "MARKETING_VERSION = 2.11.8;")
PBX.write_text(pbx)

print("V2.11.8 roster header hierarchy and spacing applied")
