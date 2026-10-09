"""V2.20.6: compact announcement reader, smoother scrolling, direct +/- text controls."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent
view = ROOT / "RAIDORoster/AnnouncementsView.swift"
v = view.read_text()

# Avoid lazy cell recycling/layout churn for these short/medium PA scripts.
v = v.replace('LazyVStack(alignment: .leading, spacing: 14)', 'VStack(alignment: .leading, spacing: 12)', 1)

# Compact the header card.
v = v.replace('.padding(16)\n                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))',
              '.padding(12)\n                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14, style: .continuous))', 1)

# Tighten script rhythm and remove the oversized outer card / blue rail.
v = v.replace('VStack(alignment: .leading, spacing: 12) {\n                    ForEach(segments)',
              'VStack(alignment: .leading, spacing: 9) {\n                    ForEach(segments)', 1)
v = v.replace('.font(.system(size: min(31, max(18, textSize - 1)), weight: .medium, design: .rounded))\n                                    .lineSpacing(5)',
              '.font(.system(size: min(29, max(16, textSize - 2)), weight: .medium))\n                                    .lineSpacing(3)', 1)
v = v.replace('.padding(12)\n                            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))',
              '.padding(.horizontal, 10)\n                            .padding(.vertical, 8)\n                            .background(.tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))', 1)
v = v.replace('.font(.system(size: min(34, max(18, textSize)), weight: .regular, design: .rounded))\n                                .lineSpacing(8)',
              '.font(.system(size: min(30, max(16, textSize)), weight: .regular))\n                                .lineSpacing(4)', 1)
old_outer = '''                .padding(18)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.tint)
                        .frame(width: 4)
                        .padding(.vertical, 14)
                }
'''
new_outer = '''                .padding(.horizontal, 2)
                .padding(.vertical, 4)
'''
if old_outer not in v:
    raise RuntimeError("V2.20.5 script card anchor not found")
v = v.replace(old_outer, new_outer, 1)

# Make zoom immediately accessible with direct minus/plus buttons; keep language and jump controls in menu.
old_toolbar = '''                Menu {
                    Picker("Language", selection: $language) {
                        ForEach(AnnouncementLanguage.allCases.filter { announcement.hasLanguage($0) }) {
                            Text($0.label).tag($0)
                        }
                    }
                    Button("Larger text", systemImage: "textformat.size.larger") { textSize = min(34, textSize + 2) }
                    Button("Smaller text", systemImage: "textformat.size.smaller") { textSize = max(18, textSize - 2) }
                    Button("Back to beginning", systemImage: "arrow.up.to.line") { scrollID = "header" }
                } label: {
                    Image(systemName: "textformat.size")
                }.accessibilityLabel("Reading options")
'''
new_toolbar = '''                Button {
                    textSize = max(16, textSize - 1)
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityLabel("Smaller text")
                .disabled(textSize <= 16)

                Button {
                    textSize = min(30, textSize + 1)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Larger text")
                .disabled(textSize >= 30)

                Menu {
                    Picker("Language", selection: $language) {
                        ForEach(AnnouncementLanguage.allCases.filter { announcement.hasLanguage($0) }) {
                            Text($0.label).tag($0)
                        }
                    }
                    Button("Back to beginning", systemImage: "arrow.up.to.line") { scrollID = "header" }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Reading options")
'''
if old_toolbar not in v:
    raise RuntimeError("Reading options toolbar anchor not found")
v = v.replace(old_toolbar, new_toolbar, 1)

# Slightly smaller page margins for more usable line length.
v = v.replace('.scrollTargetLayout()\n            .padding(20)', '.scrollTargetLayout()\n            .padding(.horizontal, 16)\n            .padding(.vertical, 14)', 1)

view.write_text(v)

content = ROOT / "RAIDORoster/ContentView.swift"
c = content.read_text()
if '"2.20.5"' not in c:
    raise RuntimeError("Content version 2.20.5 anchor not found")
c = c.replace('"2.20.5"', '"2.20.6"').replace('RAIDORoster/2.20.5', 'RAIDORoster/2.20.6')
content.write_text(c)

pbx = ROOT / "RAIDORoster.xcodeproj/project.pbxproj"
p = pbx.read_text()
if 'MARKETING_VERSION = 2.20.5;' not in p:
    raise RuntimeError("Project version 2.20.5 anchor not found")
pbx.write_text(p.replace('MARKETING_VERSION = 2.20.5;', 'MARKETING_VERSION = 2.20.6;'))

print("V2.20.6 compact smooth announcement reader applied")
