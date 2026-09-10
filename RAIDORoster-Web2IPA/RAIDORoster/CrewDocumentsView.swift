import SwiftUI
import PhotosUI
import VisionKit
import PDFKit
import UniformTypeIdentifiers
import CoreTransferable
import UserNotifications
import AVFoundation

struct CrewDocumentsView: View {
    @ObservedObject private var store = CrewDocumentStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var category: CrewDocumentCategory?
    @State private var query = ""
    @State private var importSession: UUID?
    @State private var importFile = false
    @State private var importPhoto = false
    @State private var photo: PhotosPickerItem?
    @State private var destination: Destination?
    @State private var photoLoading = false
    private enum Destination: Identifiable {
        case document(CrewDocument), scan
        var id: String {
            switch self { case .document(let item): return item.id.uuidString; case .scan: return "scan" }
        }
    }
    private var visible: [CrewDocument] {
        store.documents.filter { item in
            (category == nil || item.category == category) &&
            (query.isEmpty || item.title.localizedCaseInsensitiveContains(query))
        }.sorted { a, b in
            if a.pinned != b.pinned { return a.pinned }
            return a.created > b.created
        }
    }
    var body: some View {
        NavigationStack {
            Group {
                if store.unlocked { documentList }
                else { lockedView }
            }
            .midnightCanvas()
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { store.lock(); dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if store.unlocked {
                        Button { store.lock() } label: { Image(systemName: "lock") }
                            .accessibilityLabel("Lock Documents")
                        Menu {
                            Button("Import PDF or image", systemImage: "folder") { importSession = store.sessionID; importFile = true }
                            Button("Choose photo", systemImage: "photo") { importPhoto = true }
                            if VNDocumentCameraViewController.isSupported {
                                Button("Scan document", systemImage: "doc.viewfinder") { Task { await beginScan() } }
                            }
                        } label: { Image(systemName: "plus").frame(minWidth: 32, minHeight: 44) }
                        .accessibilityLabel("Add document")
                        .disabled(store.busy || photoLoading)
                    }
                }
            }
            .overlay { if store.busy || photoLoading { ProgressView().padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
            .fileImporter(isPresented: $importFile, allowedContentTypes: [.pdf, .jpeg, .png, .heic, .heif], allowsMultipleSelection: false) { result in
                guard importSession == store.sessionID, store.unlocked else { return }
                switch result {
                case .success(let urls):
                    if let url = urls.first { Task { await store.importURL(url, category: category ?? .other) } }
                case .failure:
                    store.message = "The file could not be imported. Please try again."
                }
            }
            .photosPicker(isPresented: $importPhoto, selection: $photo, matching: .images)
            .onChange(of: photo) { _, selected in
                guard let selected else { return }
                photoLoading = true
                let token = store.sessionID
                Task {
                    defer { photo = nil; photoLoading = false }
                    do {
                        guard let data = try await selected.loadTransferable(type: Data.self) else { throw CrewDocumentError.invalidFile }
                        guard store.sessionID == token, store.unlocked else { return }
                        await store.importData(data, title: "Photo " + Date().formatted(date: .abbreviated, time: .omitted), category: category ?? .other)
                    } catch { store.message = "The photo could not be imported. Choose a local image and try again." }
                }
            }
            .sheet(item: $destination) { value in
                switch value {
                case .document(let item): CrewDocumentDetail(documentID: item.id)
                case .scan:
                    let token = store.sessionID
                    CrewDocumentScanner { result in
                        guard token == store.sessionID, store.unlocked else { return }
                        destination = nil
                        switch result {
                        case .success(let data):
                            if let data { Task { await store.importData(data, title: "Scan " + Date().formatted(date: .abbreviated, time: .omitted), category: category ?? .other) } }
                        case .failure(let error): store.message = error.localizedDescription
                        }
                    }
                }
            }
            .alert("Documents", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK") { store.message = nil }
            } message: { Text(store.message ?? "") }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            CrewDocumentPrivacyShield.shared.cover()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            CrewDocumentPrivacyShield.shared.uncover()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            store.lock(); destination = nil; photo = nil; query = ""
        }
        .onDisappear {
            store.lock(); CrewDocumentPrivacyShield.shared.uncover()
        }
    }
    private var lockedView: some View {
        VStack(spacing: 18) {
            Image(systemName: "lock.doc").font(.system(size: 44, weight: .light)).foregroundStyle(MidnightTheme.accent)
            Text("Your crew documents").font(.title2.weight(.semibold))
            Text("Passports, visas, certificates, medical records and vaccinations, available offline.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Unlock Documents") { Task { await store.unlock() } }
                .buttonStyle(.borderedProminent).disabled(store.busy)
            Text("Protected by Face ID, Touch ID or your device passcode.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Text("Saved only on this device. Keep your originals: deleting the app or removing the device passcode can make these copies unavailable.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var documentList: some View {
        List {
            Section {
                Picker("Category", selection: $category) {
                    Text("All documents").tag(Optional<CrewDocumentCategory>.none)
                    ForEach(CrewDocumentCategory.allCases) { Text($0.label).tag(Optional($0)) }
                }
            }.listRowBackground(MidnightTheme.surface)
            if let notice = store.reminderNotice {
                Section { Text(notice).font(.caption).foregroundStyle(.orange) }.listRowBackground(MidnightTheme.surface)
            }
            if visible.isEmpty {
                Section {
                    ContentUnavailableView(store.documents.isEmpty ? "No documents yet" : "No matching documents",
                        systemImage: "doc.badge.plus", description: Text("Use + to add a PDF, photo or scan. Choose a category before importing, or change it later."))
                }.listRowBackground(MidnightTheme.surface)
            } else {
                Section {
                    ForEach(visible) { item in
                        Button { destination = .document(item) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: item.category.icon).font(.title2).foregroundStyle(MidnightTheme.accent).frame(width: 32)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(item.title).font(.headline).foregroundStyle(.primary)
                                    Text(item.category.label).font(.caption).foregroundStyle(.secondary)
                                    if let day = item.expiryDay { CrewDocumentExpiry(day: day) }
                                }
                                Spacer(minLength: 0)
                                if item.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(MidnightTheme.accent) }
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(store.busy || photoLoading)
                    }
                }.listRowBackground(MidnightTheme.surface)
            }
            Section {
                Label("Encrypted · Stored on this device", systemImage: "lock.shield")
                Text("PDF, JPEG, PNG and HEIC · Up to 25 MB per file. Photos and scans are saved as PDFs. Use Share to export a copy when needed.")
            }.font(.caption).foregroundStyle(.secondary).listRowBackground(MidnightTheme.surface)
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "Find a document")
    }
    private func beginScan() async {
        let authorized = AVCaptureDevice.authorizationStatus(for: .video)
        var allowed = authorized == .authorized
        if authorized == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        guard allowed else { store.message = "Enable camera access for RAIDO in iPhone Settings to scan documents."; return }
        guard store.unlocked else { return }
        destination = .scan
    }
}

private struct CrewDocumentExpiry: View {
    let day: String
    var body: some View {
        let remaining = CrewDocumentDates.daysRemaining(day)
        Text(remaining.map { $0 < 0 ? "Expired · " + day : $0 == 0 ? "Expires today" : "Expiry / renewal · " + day } ?? day)
            .font(.caption).foregroundStyle((remaining ?? 999) <= 30 ? Color.orange : Color.secondary)
    }
}

private struct CrewDocumentDetail: View {
    let documentID: UUID
    @ObservedObject private var store = CrewDocumentStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    private var document: CrewDocument? { store.documents.first { $0.id == documentID } }
    var body: some View {
        NavigationStack {
            Group {
                if store.unlocked, let data = store.preview { CrewDocumentPDF(data: data) }
                else if store.busy { ProgressView("Opening document") }
                else { ContentUnavailableView("Document unavailable", systemImage: "lock.doc", description: Text("Close this screen and unlock Documents to try again.")) }
            }
            .midnightCanvas().navigationTitle(document?.title ?? "Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let data = store.preview, store.unlocked {
                        ShareLink(item: CrewDocumentExport(data: data), preview: SharePreview("Crew document")) {
                            Image(systemName: "square.and.arrow.up")
                        }.accessibilityLabel("Share a PDF copy")
                    }
                    Button("Edit") { editing = true }.disabled(document == nil || store.busy)
                }
            }
            .sheet(isPresented: $editing) {
                if let document { CrewDocumentEditor(document: document) }
            }
            .alert("Documents", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
                Button("OK") { store.message = nil }
            } message: { Text(store.message ?? "") }
        }
        .task { await store.open(documentID) }
        .onDisappear { store.clearPreview() }
        .onChange(of: store.unlocked) { _, unlocked in if !unlocked { dismiss() } }
        .onChange(of: document == nil) { _, missing in if missing { dismiss() } }
    }
}

private struct CrewDocumentEditor: View {
    @State var document: CrewDocument
    @ObservedObject private var store = CrewDocumentStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var hasExpiry = false
    @State private var expiry = Date()
    @State private var confirmDelete = false
    @State private var saving = false
    @State private var initialized = false
    @State private var notice: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Document name", text: $document.title).textInputAutocapitalization(.words)
                    Picker("Category", selection: $document.category) {
                        ForEach(CrewDocumentCategory.allCases) { Text($0.label).tag($0) }
                    }
                    Toggle("Pin to top", isOn: $document.pinned)
                }.listRowBackground(MidnightTheme.surface)
                Section {
                    Toggle("Expiry or renewal date", isOn: $hasExpiry)
                    if hasExpiry {
                        DatePicker("Date", selection: $expiry, displayedComponents: .date)
                        Toggle("Expiry reminders", isOn: $document.reminders)
                    }
                } footer: {
                    Text("Optional reminders at 09:00, 30, 7 and 1 day before the date. Notifications do not show the document name. Set a date only when it applies to the document.")
                }.listRowBackground(MidnightTheme.surface)
                if let notice { Section { Text(notice).foregroundStyle(.orange) }.listRowBackground(MidnightTheme.surface) }
                Section {
                    Button("Delete document", role: .destructive) { confirmDelete = true }
                }.listRowBackground(MidnightTheme.surface)
            }
            .disabled(saving || !store.unlocked)
            .midnightCanvas().navigationTitle("Edit document").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(saving || store.busy || document.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.unlocked)
                }
            }
            .confirmationDialog("Delete this saved copy?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete document", role: .destructive) {
                    Task {
                        saving = true; await store.remove(document.id); saving = false
                        if store.message == nil { dismiss() } else { notice = store.message; store.message = nil }
                    }
                }
            } message: { Text("The imported original is not changed.") }
        }
        .onAppear {
            guard !initialized else { return }; initialized = true
            hasExpiry = document.expiryDay != nil
            expiry = document.expiryDay.flatMap { CrewDocumentDates.date($0) } ?? Date()
        }
        .onChange(of: store.unlocked) { _, unlocked in if !unlocked { dismiss() } }
    }
    private func save() async {
        saving = true
        defer { saving = false }
        document.expiryDay = hasExpiry ? CrewDocumentDates.day(expiry) : nil
        document.reminders = hasExpiry && document.reminders
        var keepOpen = false
        if document.reminders {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if !allowed {
                    document.reminders = false
                    notice = "Notifications are disabled. The date was saved without reminders; enable notifications in iPhone Settings to turn reminders on later."
                    keepOpen = true
                }
            } catch {
                document.reminders = false
                notice = "Notification permission could not be checked. The date was saved without reminders; you can enable reminders later."
                keepOpen = true
            }
        }
        await store.update(document)
        if let message = store.message {
            notice = message
            store.message = nil
        } else if !keepOpen {
            dismiss()
        }
    }
}

private struct CrewDocumentPDF: UIViewRepresentable {
    let data: Data
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = MidnightTheme.backgroundUI
        view.document = PDFDocument(data: data)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
    static func dismantleUIView(_ view: PDFView, coordinator: ()) { view.document = nil }
}

private struct CrewDocumentExport: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .pdf) { value in value.data }
    }
}

private struct CrewDocumentScanner: UIViewControllerRepresentable {
    let completion: (Result<Data?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<Data?, Error>) -> Void
        init(completion: @escaping (Result<Data?, Error>) -> Void) { self.completion = completion }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(.success(nil)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            completion(.failure(CrewDocumentError.invalidFile))
        }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount <= 20 else { completion(.failure(CrewDocumentError.invalidFile)); return }
            // Normalize one page at a time instead of retaining every full-resolution image.
            Task {
                do {
                    let data = try await Task.detached { try CrewDocumentImport.scan(scan) }.value
                    completion(.success(data))
                } catch { completion(.failure(error)) }
            }
        }
    }
}
