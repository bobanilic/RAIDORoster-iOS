"""V2.20.5: make announcement scripts continuous and visually distinct from roster content."""
from pathlib import Path

ROOT = Path(__file__).resolve().parent

# Merge genuine PDF line-wrap fragments while preserving headings and explicit // alternatives.
models = ROOT / "RAIDORoster/AnnouncementModels.swift"
m = models.read_text()
old = '''    func readingSegments(language: AnnouncementLanguage, aircraft: AnnouncementAircraft) -> [AnnouncementSegment] {
        guard applies(to: aircraft), hasLanguage(language) else { return [] }
        return segments.filter { $0.applies(language: language, aircraft: aircraft) }
    }
'''
new = '''    func readingSegments(language: AnnouncementLanguage, aircraft: AnnouncementAircraft) -> [AnnouncementSegment] {
        guard applies(to: aircraft), hasLanguage(language) else { return [] }
        let filtered = segments.filter { $0.applies(language: language, aircraft: aircraft) }
        var output: [AnnouncementSegment] = []

        func endsSentence(_ text: String) -> Bool {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let last = value.last else { return true }
            return #".?!:;”\"'»."#.contains(last)
        }

        for segment in filtered {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isAlternative = text.hasPrefix("//")
            if segment.kind == "text", !isAlternative,
               let previous = output.last,
               previous.kind == "text",
               !previous.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//"),
               previous.language == segment.language,
               previous.aircraft == segment.aircraft,
               !endsSentence(previous.text) {
                let mergedPages = Array(Set(previous.pdfPages + segment.pdfPages)).sorted()
                output[output.count - 1] = AnnouncementSegment(
                    id: previous.id + "+" + segment.id,
                    language: previous.language,
                    kind: previous.kind,
                    aircraft: previous.aircraft,
                    text: previous.text.trimmingCharacters(in: .whitespacesAndNewlines) + " " + text,
                    pdfPages: mergedPages
                )
            } else {
                output.append(segment)
            }
        }
        return output
    }
'''
if old not in m:
    raise RuntimeError("Announcement readingSegments anchor not found")
models.write_text(m.replace(old, new, 1))

view = ROOT / "RAIDORoster/AnnouncementsView.swift"
v = view.read_text()
old_header = '''                VStack(alignment: .leading, spacing: 8) {
                    Text(announcement.title).font(.title2.bold())
                    Text("\\(airline.label) · \\(aircraft == .unspecified ? \"Common announcement\" : aircraft.label)")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    if !announcement.hasLanguage(.lt) {
                        Text("This announcement is English-only in the supplied book.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if language == .lt && announcement.section == "2.1" {
                        Text("The source’s Lithuanian version includes English exit instructions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Source wording retained. Fill the bracketed fields and choose the applicable alternatives before reading.")
                        .font(.caption).foregroundStyle(.secondary)
                }.id("header")
                ForEach(segments) { segment in
                    if segment.kind == "heading" {
                        Text(segment.text).font(.headline).foregroundStyle(.secondary).id(segment.id)
                    } else {
                        Text(segment.text)
                            .font(.system(size: min(34, max(18, textSize))))
                            .lineSpacing(6)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .id(segment.id)
                    }
                }
'''
new_header = '''                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "megaphone.fill")
                            .font(.title3)
                            .foregroundStyle(.tint)
                            .frame(width: 34, height: 34)
                            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(announcement.title).font(.title2.bold())
                            Text("\\(announcement.category) · § \\(announcement.section)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("\\(airline.label) · \\(aircraft == .unspecified ? \"Common announcement\" : aircraft.label)")
                        .font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                    if !announcement.hasLanguage(.lt) {
                        Text("This announcement is English-only in the supplied book.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if language == .lt && announcement.section == "2.1" {
                        Text("The source’s Lithuanian version includes English exit instructions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Label("Read the script below. Bracketed fields and // lines require the applicable choice.", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .id("header")

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(segments) { segment in
                        if segment.kind == "heading" {
                            Text(segment.text)
                                .font(.headline)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                                .id(segment.id)
                        } else if segment.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//") {
                            HStack(alignment: .top, spacing: 10) {
                                Capsule()
                                    .fill(.tint)
                                    .frame(width: 3)
                                Text(segment.text)
                                    .font(.system(size: min(31, max(18, textSize - 1)), weight: .medium, design: .rounded))
                                    .lineSpacing(5)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .id(segment.id)
                        } else {
                            Text(segment.text)
                                .font(.system(size: min(34, max(18, textSize)), weight: .regular, design: .rounded))
                                .lineSpacing(8)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(segment.id)
                        }
                    }
                }
                .padding(18)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(.tint)
                        .frame(width: 4)
                        .padding(.vertical, 14)
                }
'''
if old_header not in v:
    raise RuntimeError("AnnouncementReader body anchor not found")
v = v.replace(old_header, new_header, 1)
# Slightly tighter top-level spacing now that the body has its own paragraph rhythm.
v = v.replace('LazyVStack(alignment: .leading, spacing: 18)', 'LazyVStack(alignment: .leading, spacing: 14)', 1)
view.write_text(v)

# Version bump in generated app after V2.20.3 BLH patch.
content = ROOT / "RAIDORoster/ContentView.swift"
c = content.read_text()
if '"2.20.3"' not in c:
    raise RuntimeError("Content version 2.20.3 anchor not found")
c = c.replace('"2.20.3"', '"2.20.5"').replace('RAIDORoster/2.20.3', 'RAIDORoster/2.20.5')
content.write_text(c)

pbx = ROOT / "RAIDORoster.xcodeproj/project.pbxproj"
p = pbx.read_text()
if 'MARKETING_VERSION = 2.20.3;' not in p:
    raise RuntimeError("Project version 2.20.3 anchor not found")
pbx.write_text(p.replace('MARKETING_VERSION = 2.20.3;', 'MARKETING_VERSION = 2.20.5;'))

print("V2.20.5 announcement reader readability polish applied")
