import SwiftUI
import AppKit
import AVFoundation
import PDFKit
import Speech
import UniformTypeIdentifiers
import UstaProto

/// One file the user attached to a prompt, already prepared for the daemon:
/// bytes for the visual formats, extracted text for the readable ones,
/// keyframes for video.
struct UstaAttachment: Identifiable, Equatable {
    let id = UUID()
    var kind: Usta_V1_Attachment.Kind
    var filename: String
    var mime: String
    var data: Data
    var extractedText: String = ""
    var frames: [Data] = []
    /// Small preview for the chip. Nil for non-visual files.
    var thumbnail: NSImage?

    static func == (a: UstaAttachment, b: UstaAttachment) -> Bool { a.id == b.id }

    var proto: Usta_V1_Attachment {
        Usta_V1_Attachment.with {
            $0.kind = kind
            $0.filename = filename
            $0.mime = mime
            $0.data = data
            $0.extractedText = extractedText
            $0.frames = frames
        }
    }

    var sizeLabel: String {
        let n = data.isEmpty ? extractedText.utf8.count : data.count
        if n > 1_000_000 { return String(format: "%.1f MB", Double(n) / 1e6) }
        if n > 1_000 { return String(format: "%.0f KB", Double(n) / 1e3) }
        return "\(n) B"
    }

    var icon: String {
        switch kind {
        case .image: return "photo"
        case .pdf:   return "doc.richtext"
        case .video: return "film"
        case .audio: return "waveform"
        case .text:  return "doc.plaintext"
        default:     return "paperclip"
        }
    }
}

// MARK: - Loading

enum AttachmentLoader {
    /// Anything bigger than this gets truncated (text) or rejected (binary):
    /// a 200MB video would blow up the gRPC message and the model context.
    static let maxBytes = 24 * 1024 * 1024
    static let maxTextChars = 40_000

    /// Build an attachment from a file on disk. Runs off the main thread —
    /// video keyframe extraction and PDF parsing are slow.
    static func load(url: URL) async -> UstaAttachment? {
        let name = url.lastPathComponent
        let ext = url.pathExtension.lowercased()
        let ut = UTType(filenameExtension: ext)

        // Images: hand over the bytes; the model sees them natively.
        if let ut, ut.conforms(to: .image) {
            guard let d = try? Data(contentsOf: url), d.count <= maxBytes else { return nil }
            return UstaAttachment(kind: .image, filename: name,
                                  mime: ut.preferredMIMEType ?? "image/png",
                                  data: d, thumbnail: NSImage(data: d))
        }

        // PDFs: send the bytes (Claude/Gemini read them natively) AND pull the
        // text out so text-only providers still get the content.
        if ext == "pdf" {
            guard let d = try? Data(contentsOf: url), d.count <= maxBytes else { return nil }
            var text = ""
            if let doc = PDFDocument(url: url) {
                text = String((doc.string ?? "").prefix(maxTextChars))
            }
            var thumb: NSImage? = nil
            if let page = PDFDocument(url: url)?.page(at: 0) {
                thumb = page.thumbnail(of: NSSize(width: 120, height: 150), for: .mediaBox)
            }
            return UstaAttachment(kind: .pdf, filename: name, mime: "application/pdf",
                                  data: d, extractedText: text, thumbnail: thumb)
        }

        // Video: models can't watch it, so extract representative frames.
        if let ut, ut.conforms(to: .movie) || ut.conforms(to: .video) {
            let frames = await videoFrames(url: url, count: 4)
            let thumb = frames.first.flatMap { NSImage(data: $0) }
            return UstaAttachment(
                kind: .video, filename: name,
                mime: ut.preferredMIMEType ?? "video/mp4",
                data: Data(),                 // the clip itself stays on disk
                extractedText: frames.isEmpty
                    ? "(video — no frames could be extracted)"
                    : "\(frames.count) keyframes extracted from this clip.",
                frames: frames, thumbnail: thumb)
        }

        // Audio: transcribe on-device so the words reach the model.
        if let ut, ut.conforms(to: .audio) {
            let transcript = await transcribe(url: url)
            return UstaAttachment(
                kind: .audio, filename: name,
                mime: ut.preferredMIMEType ?? "audio/mpeg",
                data: Data(),
                extractedText: transcript.isEmpty
                    ? "(audio — transcription unavailable)"
                    : transcript)
        }

        // Everything readable: inline the text.
        if let raw = try? String(contentsOf: url, encoding: .utf8) {
            return UstaAttachment(kind: .text, filename: name,
                                  mime: ut?.preferredMIMEType ?? "text/plain",
                                  data: Data(),
                                  extractedText: String(raw.prefix(maxTextChars)))
        }

        // Unknown binary: keep the bytes so it still lands in the workspace.
        guard let d = try? Data(contentsOf: url), d.count <= maxBytes else { return nil }
        return UstaAttachment(kind: .other, filename: name,
                              mime: ut?.preferredMIMEType ?? "application/octet-stream", data: d)
    }

    /// Pasted screenshot — no file on disk, just an image on the pasteboard.
    static func fromPasteboard() -> [UstaAttachment] {
        let pb = NSPasteboard.general
        var out: [UstaAttachment] = []
        // File URLs first (Finder copy).
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return []   // handled by the async path in the view
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let stamp = Int(Date().timeIntervalSince1970)
            out.append(UstaAttachment(kind: .image, filename: "pasted-\(stamp).png",
                                      mime: "image/png", data: png,
                                      thumbnail: NSImage(data: png)))
        }
        return out
    }

    static func pasteboardFileURLs() -> [URL] {
        (NSPasteboard.general.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
    }

    // MARK: helpers

    /// Evenly spaced PNG keyframes so a vision model can "watch" the clip.
    private static func videoFrames(url: URL, count: Int) async -> [Data] {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 1280, height: 1280)
        guard let dur = try? await asset.load(.duration), dur.seconds > 0 else { return [] }
        var out: [Data] = []
        for i in 0..<count {
            // Sample inside the clip, skipping the very first/last frames
            // which are often black.
            let frac = (Double(i) + 0.5) / Double(count)
            let t = CMTime(seconds: dur.seconds * frac, preferredTimescale: 600)
            guard let cg = try? await gen.image(at: t).image else { continue }
            let rep = NSBitmapImageRep(cgImage: cg)
            if let png = rep.representation(using: .png, properties: [:]) { out.append(png) }
        }
        return out
    }

    /// On-device transcription — no API key, no upload.
    private static func transcribe(url: URL) async -> String {
        guard await requestSpeechAuth() else { return "" }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), rec.isAvailable
        else { return "" }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.requiresOnDeviceRecognition = false
        return await withCheckedContinuation { cont in
            var resumed = false
            rec.recognitionTask(with: req) { result, error in
                if resumed { return }
                if let result, result.isFinal {
                    resumed = true
                    cont.resume(returning: result.bestTranscription.formattedString)
                } else if error != nil {
                    resumed = true
                    cont.resume(returning: "")
                }
            }
        }
    }

    static func requestSpeechAuth() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { st in cont.resume(returning: st == .authorized) }
        }
    }
}

// MARK: - UI

/// Drop zone + chips. Drop files, paste screenshots (⌘V), or click to browse.
struct AttachmentBar: View {
    @Binding var attachments: [UstaAttachment]
    var compact: Bool = false

    @State private var targeted = false
    @State private var loading = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty || loading > 0 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(attachments) { att in chip(att) }
                        if loading > 0 {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.5)
                                Text("reading…").font(.system(size: 11)).foregroundStyle(UstaTheme.dim)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .background(UstaTheme.cell)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .padding(.vertical, 1)
                }
                .frame(height: compact ? 46 : 58)
            }
            addRow
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            handleDrop(providers); return true
        }
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(UstaTheme.accentTeal, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .opacity(targeted ? 1 : 0)
                .allowsHitTesting(false)
        )
    }

    private var addRow: some View {
        HStack(spacing: 10) {
            Button { pick() } label: {
                Label("Attach files", systemImage: "paperclip")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(UstaTheme.accentTeal)

            Button { pasteFromClipboard() } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(UstaTheme.dim)
            .keyboardShortcut("v", modifiers: [.command, .shift])
            .help("Paste a screenshot or copied file (⇧⌘V)")

            Text("or drop images, PDFs, video, audio, code")
                .font(.system(size: 11)).foregroundStyle(UstaTheme.dim2)
            Spacer()
        }
    }

    private func chip(_ att: UstaAttachment) -> some View {
        HStack(spacing: 8) {
            if let t = att.thumbnail {
                Image(nsImage: t)
                    .resizable().aspectRatio(contentMode: .fill)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: att.icon)
                    .font(.system(size: 14))
                    .foregroundStyle(UstaTheme.accentTeal)
                    .frame(width: 30, height: 30)
                    .background(UstaTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(att.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: 150, alignment: .leading)
                Text(att.kind == .video && !att.frames.isEmpty
                     ? "\(att.frames.count) frames"
                     : att.sizeLabel)
                    .font(.system(size: 9)).foregroundStyle(UstaTheme.dim)
            }
            Button {
                attachments.removeAll { $0.id == att.id }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(UstaTheme.dim)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(UstaTheme.cell)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(UstaTheme.border))
        .help(att.extractedText.isEmpty ? att.filename
              : "\(att.filename)\n\n\(att.extractedText.prefix(280))…")
    }

    // MARK: actions

    private func pick() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.title = "Attach reference material"
        if panel.runModal() == .OK { ingest(panel.urls) }
    }

    private func pasteFromClipboard() {
        let urls = AttachmentLoader.pasteboardFileURLs()
        if !urls.isEmpty { ingest(urls); return }
        let pasted = AttachmentLoader.fromPasteboard()
        if !pasted.isEmpty { attachments.append(contentsOf: pasted) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in ingest([url]) }
            }
        }
    }

    private func ingest(_ urls: [URL]) {
        for url in urls {
            loading += 1
            Task {
                let att = await AttachmentLoader.load(url: url)
                await MainActor.run {
                    loading -= 1
                    if let att { attachments.append(att) }
                }
            }
        }
    }
}

// MARK: - Dictation

/// Push-to-talk dictation into a text binding. On-device where the OS
/// supports it; no API key either way.
@MainActor
final class DictationModel: ObservableObject {
    @Published var recording = false
    @Published var error: String?

    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    /// Text already in the field when recording started — the transcript is
    /// appended to it so dictation never eats what the user typed.
    private var prefix = ""

    func toggle(into binding: Binding<String>) {
        recording ? stop() : start(into: binding)
    }

    private func start(into binding: Binding<String>) {
        Task {
            guard await AttachmentLoader.requestSpeechAuth() else {
                error = "Speech recognition permission denied — enable it in System Settings › Privacy."
                return
            }
            guard let rec = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(),
                  rec.isAvailable else {
                error = "Speech recognition unavailable for this locale."
                return
            }
            prefix = binding.wrappedValue
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req

            let input = engine.inputNode
            input.removeTap(onBus: 0)
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buf, _ in
                req.append(buf)
            }
            engine.prepare()
            do { try engine.start() } catch {
                self.error = "Microphone unavailable: \(error.localizedDescription)"
                return
            }
            recording = true
            task = rec.recognitionTask(with: req) { [weak self] result, err in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    let joined = self.prefix.isEmpty ? spoken
                        : self.prefix.trimmingCharacters(in: .whitespacesAndNewlines) + " " + spoken
                    Task { @MainActor in binding.wrappedValue = joined }
                }
                if err != nil || (result?.isFinal ?? false) {
                    Task { @MainActor in self.stop() }
                }
            }
        }
    }

    func stop() {
        guard recording || engine.isRunning else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil; task = nil
        recording = false
    }
}

/// Mic button that dictates into a text binding.
struct DictationButton: View {
    @Binding var text: String
    @StateObject private var dictation = DictationModel()

    var body: some View {
        Button {
            dictation.toggle(into: $text)
        } label: {
            Image(systemName: dictation.recording ? "mic.fill" : "mic")
                .font(.system(size: 13))
                .foregroundStyle(dictation.recording ? UstaTheme.accentPink : UstaTheme.dim)
                .symbolEffect(.pulse, isActive: dictation.recording)
        }
        .buttonStyle(.plain)
        .help(dictation.recording ? "Stop dictation" : "Dictate instead of typing")
        .alert("Dictation", isPresented: Binding(
            get: { dictation.error != nil },
            set: { if !$0 { dictation.error = nil } }
        )) {
            Button("OK") { dictation.error = nil }
        } message: {
            Text(dictation.error ?? "")
        }
    }
}
