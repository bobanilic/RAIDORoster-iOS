"""V2.20.7: restrained reader layout, preserving eager scrolling and source text."""
from pathlib import Path
ROOT = Path(__file__).resolve().parent
p = ROOT / 'RAIDORoster/AnnouncementsView.swift'
s = p.read_text()
reader = s.index('private struct AnnouncementReader: View {')
start = s.index('    var body: some View {', reader)
end = s.index('    private func keepAwake()', start)
s = s[:start] + r'''    var body: some View {
        ScrollView {
            // Keep the eager layout from 2.20.6. Each paragraph is a direct scroll target.
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(airline.label) · \(aircraft == .unspecified ? "Common" : aircraft.label)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(announcement.title)
                        .font(.system(.title, design: .default, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if !announcement.hasLanguage(.lt) {
                        Text("English only in the supplied book")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if language == .lt && announcement.section == "2.1" {
                        Text("The source includes English exit instructions.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 8)
                .id("header")

                ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                    VStack(alignment: .leading, spacing: 10) {
                        if segment.kind == "heading" {
                            Text(segment.text)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 12)
                        } else if isAlternative(segment) {
                            if index == 0 || !isAlternative(segments[index - 1]) {
                                Text("Choose the applicable version")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)
                            }
                            Text(segment.text)
                                .font(.system(size: min(30, max(16, textSize))))
                                .lineSpacing(5)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 14)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 1)
                                        .fill(Color.accentColor.opacity(0.4))
                                        .frame(width: 2)
                                }
                        } else {
                            Text(segment.text)
                                .font(.system(size: min(30, max(16, textSize))))
                                .lineSpacing(6)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .id(segment.id)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Divider()
                    Text("PAB \(catalogue.issue)/\(catalogue.revision) · § \(announcement.section) · \(catalogue.revisionDate)")
                    Text("Uncontrolled export · Check the current revision in Web Manuals.")
                    Text(catalogue.copyright)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 12)
                .id("source")
            }
            .scrollTargetLayout()
            .padding(.horizontal, 24)
            .padding(.vertical, 12)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemBackground))
        .scrollPosition(id: $scrollID, anchor: .top)
        .navigationTitle("Announcement")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Button("Script details", systemImage: "info.circle") { showSourceDetails = true }
                    Button("Back to beginning", systemImage: "arrow.up.to.line") { scrollID = "header" }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel("Announcement options")
                Button { store.toggle(key) } label: {
                    Image(systemName: store.favorites.contains(key) ? "star.fill" : "star")
                        .frame(minWidth: 32, minHeight: 44)
                }.accessibilityLabel(store.favorites.contains(key) ? "Remove favorite" : "Add favorite")
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 16) {
                Menu {
                    Picker("Language", selection: $language) {
                        ForEach(AnnouncementLanguage.allCases.filter { announcement.hasLanguage($0) }) {
                            Text($0.label).tag($0)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(language.label).font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                    }.foregroundStyle(.primary).frame(minHeight: 44)
                }.accessibilityLabel("Announcement language: " + language.label)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Button { textSize = max(16, min(30, textSize) - 1) } label: {
                        Text("A−").font(.system(size: 16, weight: .medium)).frame(width: 44, height: 44)
                    }.disabled(textSize <= 16).accessibilityLabel("Smaller text")
                    Text("\(Int(min(30, max(16, textSize))))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 22)
                        .accessibilityLabel("Text size \(Int(min(30, max(16, textSize)))) points")
                    Button { textSize = min(30, max(16, textSize) + 1) } label: {
                        Text("A+").font(.system(size: 20, weight: .medium)).frame(width: 44, height: 44)
                    }.disabled(textSize >= 30).accessibilityLabel("Larger text")
                }
                .buttonStyle(.plain)
                .background(Color.primary.opacity(0.05), in: Capsule())
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 8)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .sheet(isPresented: $showSourceDetails) {
            NavigationStack {
                List {
                    Section {
                        LabeledContent("Book", value: "GetJet Public Announcements Book")
                        LabeledContent("Issue / revision", value: "\(catalogue.issue) / \(catalogue.revision)")
                        LabeledContent("Date", value: catalogue.revisionDate)
                        LabeledContent("Section", value: "\(announcement.section) · \(announcement.sourcePage)")
                    }
                    Section {
                        Text("Source wording is retained. Fill bracketed fields and choose the applicable // alternatives before reading.")
                        Text("This export is marked uncontrolled. Check the current revision in Web Manuals.")
                    }
                }
                .navigationTitle("Script details")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showSourceDetails = false } } }
            }
            .presentationDetents([.medium, .large])
        }
        .onAppear {
            textSize = min(30, max(16, textSize))
            scrollID = store.preferences.position(for: positionKey)
            if scenePhase == .active { keepAwake() }
        }
        .onDisappear { restoreIdleTimer() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { keepAwake() } else { restoreIdleTimer() }
        }
        .onChange(of: scrollID) { _, value in
            if let value { store.preferences.savePosition(value, for: positionKey) }
        }
        .onChange(of: language) { _, _ in
            scrollID = store.preferences.position(for: positionKey) ?? "header"
        }
    }

    private func isAlternative(_ segment: AnnouncementSegment) -> Bool {
        segment.text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("//")
    }

''' + s[end:]
anchor = '    @State private var ownsIdleTimer = false'
if s.count(anchor) != 1: raise RuntimeError('Reader state anchor changed')
s = s.replace(anchor, anchor + '\n    @State private var showSourceDetails = false')
p.write_text(s)
for relative, old, new in [('RAIDORoster/ContentView.swift', '"2.20.6"', '"2.20.7"'),
                           ('RAIDORoster.xcodeproj/project.pbxproj', 'MARKETING_VERSION = 2.20.6;', 'MARKETING_VERSION = 2.20.7;')]:
    p = ROOT / relative
    text = p.read_text()
    if old not in text: raise RuntimeError('Reader version anchor changed: ' + relative)
    p.write_text(text.replace(old, new).replace('RAIDORoster/2.20.6', 'RAIDORoster/2.20.7'))
print('V2.20.7 Clean announcement reader layout applied')
