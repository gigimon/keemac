import AppKit
import Domain
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - File types

enum AttachmentKind {
    case image
    case pdf
    case text
    case other

    private static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "gif", "tif", "tiff", "webp", "bmp"]
    private static let textExtensions: Set<String> = [
        "txt", "json", "pub", "pem", "key", "conf", "config", "cfg", "yml", "yaml",
        "ini", "env", "toml", "md", "log", "csv", "xml", "asc"
    ]

    init(_ attachment: VaultAttachment) {
        let ext = AttachmentInfo.fileExtension(attachment.name)
        if Self.imageExtensions.contains(ext) {
            self = NSImage(data: attachment.data) == nil ? .other : .image
        } else if ext == "pdf" {
            self = PDFDocument(data: attachment.data) == nil ? .other : .pdf
        } else if ext.isEmpty || Self.textExtensions.contains(ext) {
            self = String(data: attachment.data, encoding: .utf8) == nil ? .other : .text
        } else {
            self = .other
        }
    }

    var canPreview: Bool { self != .other }
}

enum AttachmentInfo {
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else {
            return ""
        }
        return name[name.index(after: dot)...].lowercased()
    }

    static func typeDescription(_ name: String) -> String {
        let ext = fileExtension(name)
        if ext.isEmpty {
            return name.hasPrefix("id_") ? L("OpenSSH private key") : L("Plain text")
        }
        let known: [String: String] = [
            "png": L("PNG image"), "jpg": L("JPEG image"), "jpeg": L("JPEG image"), "heic": L("HEIC image"), "gif": L("GIF image"),
            "pdf": L("PDF document"), "txt": L("Plain text"), "json": "JSON", "pub": L("SSH public key"), "pem": L("PEM key"),
            "key": L("Private key"), "zip": L("ZIP archive"), "pfx": L("PKCS #12 certificate"), "p12": L("PKCS #12 certificate")
        ]
        return known[ext] ?? L("\(ext.uppercased()) file")
    }

    static func size(_ attachment: VaultAttachment) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file)
    }

    /// "PNG image · 12 KB" — the second line of an attachment row.
    static func meta(_ attachment: VaultAttachment) -> String {
        "\(typeDescription(attachment.name)) · \(size(attachment))"
    }

    static func symbol(_ name: String) -> (name: String, color: Color) {
        let ext = fileExtension(name)
        switch AttachmentKind.extensionKind(ext) {
        case .image:
            return ("photo.fill", Color(lightHex: 0x248A3D, darkHex: 0x30D158))
        case .pdf:
            return ("doc.richtext.fill", KM.danger)
        default:
            break
        }
        if name.hasPrefix("id_") || ["pem", "key", "pfx", "p12", "pub"].contains(ext) {
            return ("key.fill", Color(lightHex: 0xC75F00, darkHex: 0xFF9F0A))
        }
        if AttachmentKind.extensionKind(ext) == .text {
            return ("doc.text.fill", KM.accent)
        }
        return (ext == "zip" ? "doc.zipper" : "doc.fill", KM.textSecondary)
    }

    @MainActor
    static func save(_ attachment: VaultAttachment) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = attachment.name
        panel.title = L("Save Attachment")
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }
        do {
            try attachment.data.write(to: destinationURL, options: [.atomic])
            CopyFeedbackCenter.shared.show(L("Saved “\(attachment.name)”"))
        } catch {
            NSSound.beep()
        }
    }
}

private extension AttachmentKind {
    /// Kind guessed from the extension alone, for icons (no decoding).
    static func extensionKind(_ ext: String) -> AttachmentKind {
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if ext.isEmpty || textExtensions.contains(ext) { return .text }
        return .other
    }
}

/// Dragging an attachment to Finder saves a decrypted copy there.
struct AttachmentTransfer: Transferable {
    let attachment: VaultAttachment

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { $0.attachment.data }
            .suggestedFileName { $0.attachment.name }
    }
}

// MARK: - Tile

/// File icon, or a thumbnail for images.
struct AttachmentTile: View {
    let attachment: VaultAttachment
    var width: CGFloat = 28
    var height: CGFloat = 32
    var symbolSize: CGFloat = 15

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(KM.raisedButtonBackground)
            if let image = thumbnail {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: width, height: height)
                    .clipped()
            } else {
                let symbol = AttachmentInfo.symbol(attachment.name)
                Image(systemName: symbol.name)
                    .font(.system(size: symbolSize))
                    .foregroundStyle(symbol.color)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(KM.chromeBorder, lineWidth: 0.5)
        )
        .accessibilityHidden(true)
    }

    private var thumbnail: NSImage? {
        guard AttachmentKind.extensionKind(AttachmentInfo.fileExtension(attachment.name)) == .image else {
            return nil
        }
        return NSImage(data: attachment.data)
    }
}

// MARK: - Row in the entry card

struct AttachmentRow: View {
    let attachment: VaultAttachment
    let onPreview: () -> Void

    @State private var isHovered = false

    var body: some View {
        let kind = AttachmentKind(attachment)
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? KM.textSecondary : Color.clear)
                .frame(width: 12)
            AttachmentTile(attachment: attachment)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 13))
                Text(AttachmentInfo.meta(attachment))
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
            if isHovered {
                HStack(spacing: 4) {
                    if kind.canPreview {
                        Button(action: onPreview) {
                            Image(systemName: "eye")
                                .font(.system(size: 13))
                        }
                        .buttonStyle(KMIconButtonStyle(size: 28, cornerRadius: 8))
                        .iconHelp(L("Preview"))
                    }
                    Button(L("Save…")) {
                        AttachmentInfo.save(attachment)
                    }
                    .buttonStyle(KMButtonStyle(kind: .secondary, height: 26, horizontalPadding: 12, fontWeight: .regular, fontSize: 12))
                }
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .frame(height: 44)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(isHovered ? KM.rowHover : Color.clear)
        )
        .contentShape(Rectangle())
        .padding(.leading, -12)
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onPreview)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attachment.name + ", " + AttachmentInfo.meta(attachment))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onPreview() }
        .accessibilityActions {
            if kind.canPreview {
                Button(L("Preview"), action: onPreview)
            }
            Button(L("Save…")) {
                AttachmentInfo.save(attachment)
            }
        }
        .draggable(AttachmentTransfer(attachment: attachment))
        .help(kind.canPreview ? L("Click to preview · Drag to Finder to save a copy") : L("Click for details · Drag to Finder to save a copy"))
    }
}

// MARK: - Preview sheet

struct AttachmentPreviewSheet: View {
    let attachments: [VaultAttachment]
    @State var index: Int
    let onClose: () -> Void

    @State private var imageZoomsToFit = true
    @State private var wrapsLines = true
    @State private var pdf = PDFPreviewController()

    private var attachment: VaultAttachment { attachments[index] }
    private var kind: AttachmentKind { AttachmentKind(attachment) }

    var body: some View {
        VStack(spacing: 0) {
            header
            if kind != .other {
                toolbar
                    .frame(height: 38)
                    .overlay(alignment: .top) { divider }
            }
            content
                .frame(height: 430)
                .background(Color(lightHex: 0xECECEF, darkHex: 0x1C1C1E))
                .overlay(alignment: .top) { divider }
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 10))
                Text(L("Decrypted in memory for this preview. Nothing is written to disk unless you save it."))
            }
            .font(.system(size: 11))
            .foregroundStyle(KM.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.vertical, 9)
            .overlay(alignment: .top) { divider }
        }
        .frame(width: 740)
        .background(KM.sheetBackground)
        .background(keyboardShortcuts)
        .onChange(of: index, initial: true) { _, _ in
            imageZoomsToFit = true
            if kind == .pdf {
                pdf.load(attachment.data)
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(KM.hairline).frame(height: 0.5)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            AttachmentTile(attachment: attachment, width: 30, height: 36, symbolSize: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(meta)
                    .font(.system(size: 11))
                    .foregroundStyle(KM.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if attachments.count > 1 {
                HStack(spacing: 0) {
                    Button {
                        step(-1)
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 24, width: 26, cornerRadius: 12, tint: KM.textPrimary))
                    .disabled(index == 0)
                    .iconHelp(L("Previous Attachment (←)"))
                    Text(L("\(index + 1) of \(attachments.count)"))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .padding(.horizontal, 4)
                    Button {
                        step(1)
                    } label: {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(KMIconButtonStyle(size: 24, width: 26, cornerRadius: 12, tint: KM.textPrimary))
                    .disabled(index == attachments.count - 1)
                    .iconHelp(L("Next Attachment (→)"))
                }
                .padding(.horizontal, 2)
                .frame(height: 28)
                .background(Capsule(style: .continuous).fill(KM.subtleFill))
            }

            if kind == .image || kind == .text {
                Button(action: copyContents) {
                    Image(systemName: "doc.on.doc").font(.system(size: 13))
                }
                .buttonStyle(KMIconButtonStyle(size: 30, cornerRadius: 8))
                .iconHelp(kind == .image ? L("Copy Image") : L("Copy Text"))
            }
            Button(L("Save…")) {
                AttachmentInfo.save(attachment)
            }
            .buttonStyle(KMButtonStyle(kind: .secondary, height: 28, horizontalPadding: 14, fontWeight: .regular, fontSize: 12))
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 13))
            }
            .buttonStyle(KMIconButtonStyle(size: 30, cornerRadius: 8))
            .iconHelp(L("Close (Esc)"))
            .keyboardShortcut(.cancelAction)
        }
        .padding(.leading, 18)
        .padding(.trailing, 12)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private var meta: String {
        var parts = [AttachmentInfo.size(attachment), AttachmentInfo.typeDescription(attachment.name)]
        switch kind {
        case .image:
            if let rep = NSImage(data: attachment.data)?.representations.first {
                parts.append("\(rep.pixelsWide) × \(rep.pixelsHigh)")
            }
        case .pdf:
            parts.append(L("\(pdf.pageCount) pages"))
        case .text:
            let count = lines.count
            parts.append(L("\(count) lines"))
        case .other:
            break
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Toolbar

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            switch kind {
            case .image:
                KMSegmentedControl(
                    options: [(true, L("Fit")), (false, L("Actual Size"))],
                    selection: $imageZoomsToFit,
                    fontSize: 12,
                    horizontalPadding: 12
                )
                Spacer()
                Text(imageZoomLabel)
                    .foregroundStyle(KM.textSecondary)
                    .monospacedDigit()
            case .pdf:
                Button {
                    pdf.previousPage()
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 8))
                .iconHelp(L("Previous Page (↑)"))
                Button {
                    pdf.nextPage()
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(KMIconButtonStyle(size: 26, cornerRadius: 8))
                .iconHelp(L("Next Page (↓)"))
                Text(L("Page \(pdf.pageIndex + 1) of \(pdf.pageCount)"))
                    .monospacedDigit()
                Spacer()
            case .text:
                Text(L("\(lines.count) lines") + " · UTF-8")
                    .foregroundStyle(KM.textSecondary)
                Spacer()
                Text(L("Wrap Lines"))
                Toggle("", isOn: $wrapsLines)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(KM.success)
            case .other:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .padding(.leading, 18)
        .padding(.trailing, 14)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch kind {
        case .image:
            imageContent
        case .pdf:
            HStack(spacing: 0) {
                PDFThumbnailRepresentable(controller: pdf)
                    .frame(width: 104)
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(KM.hairline).frame(width: 0.5)
                    }
                PDFViewRepresentable(controller: pdf)
            }
        case .text:
            textContent
        case .other:
            unsupportedContent
        }
    }

    private var image: NSImage? {
        NSImage(data: attachment.data)
    }

    private var imagePixelSize: CGSize {
        guard let rep = image?.representations.first else {
            return .zero
        }
        return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }

    /// Scale used by "Fit" inside the 740 × 430 area with 24 pt padding.
    private var fitScale: CGFloat {
        let size = imagePixelSize
        guard size.width > 0, size.height > 0 else {
            return 1
        }
        return min(1, (740 - 48) / size.width, (430 - 48) / size.height)
    }

    private var imageZoomLabel: String {
        "\(Int((imageZoomsToFit ? fitScale : 1) * 100))%"
    }

    @ViewBuilder
    private var imageContent: some View {
        if let image {
            let size = imagePixelSize
            let scale = imageZoomsToFit ? fitScale : 1
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size.width * scale, height: size.height * scale)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 8)
                    .onTapGesture {
                        imageZoomsToFit.toggle()
                    }
                    .padding(24)
                    .frame(minWidth: 740, minHeight: 430)
            }
            .scrollDisabled(imageZoomsToFit)
        }
    }

    private var lines: [Substring] {
        let text = String(data: attachment.data, encoding: .utf8) ?? ""
        return text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    private var textContent: some View {
        let lines = lines
        return ScrollView(wrapsLines ? .vertical : [.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { number, line in
                    HStack(alignment: .top, spacing: 0) {
                        Text("\(number + 1)")
                            .foregroundStyle(Color(lightHex: 0xAEAEB2, darkHex: 0x636366))
                            .frame(width: 44, alignment: .trailing)
                            .padding(.trailing, 12)
                        Text(String(line))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: !wrapsLines, vertical: true)
                            .frame(maxWidth: wrapsLines ? .infinity : nil, alignment: .leading)
                            .padding(.trailing, 16)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 18)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 14)
        }
        .background(Color(lightHex: 0xFFFFFF, darkHex: 0x1E1E20))
    }

    private var unsupportedContent: some View {
        let symbol = AttachmentInfo.symbol(attachment.name)
        let ext = AttachmentInfo.fileExtension(attachment.name)
        return VStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(KM.raisedButtonBackground)
                    .shadow(color: .black.opacity(0.1), radius: 8, y: 6)
                Image(systemName: symbol.name)
                    .font(.system(size: 34))
                    .foregroundStyle(symbol.color)
                    .frame(maxHeight: .infinity)
                Text(ext.isEmpty ? L("FILE") : ext.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(KM.textSecondary)
                    .padding(.bottom, 8)
            }
            .frame(width: 76, height: 92)
            Text(attachment.name)
                .font(.system(size: 15, weight: .semibold))
                .padding(.top, 12)
            Text(meta)
                .font(.system(size: 12))
                .foregroundStyle(KM.textSecondary)
            Text(L("No preview for this file type"))
                .font(.system(size: 13))
                .padding(.top, 10)
            Button(L("Save…")) {
                AttachmentInfo.save(attachment)
            }
            .buttonStyle(KMButtonStyle(kind: .primary, height: 30, horizontalPadding: 18, fontWeight: .semibold))
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { step(-1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { step(1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            if kind == .pdf {
                Button("") { pdf.previousPage() }
                    .keyboardShortcut(.upArrow, modifiers: [])
                Button("") { pdf.nextPage() }
                    .keyboardShortcut(.downArrow, modifiers: [])
            }
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard attachments.indices.contains(next) else {
            return
        }
        index = next
    }

    private func copyContents() {
        switch kind {
        case .text:
            SensitiveClipboard.shared.copySensitiveText(String(data: attachment.data, encoding: .utf8) ?? "", label: L("Text"))
        case .image:
            guard let image else {
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([image])
            CopyFeedbackCenter.shared.show(L("Image copied"), duration: 2.4)
        case .pdf, .other:
            break
        }
    }
}

// MARK: - PDF

@MainActor
@Observable
final class PDFPreviewController {
    let pdfView: PDFView = {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePage
        view.displaysPageBreaks = true
        view.backgroundColor = .clear
        return view
    }()

    private(set) var pageIndex = 0
    private(set) var pageCount = 0
    @ObservationIgnored private var observer: NSObjectProtocol?

    func load(_ data: Data) {
        let document = PDFDocument(data: data)
        pdfView.document = document
        pageCount = document?.pageCount ?? 0
        pageIndex = 0
        if observer == nil {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: pdfView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.updatePageIndex()
                }
            }
        }
    }

    func previousPage() {
        pdfView.goToPreviousPage(nil)
    }

    func nextPage() {
        pdfView.goToNextPage(nil)
    }

    private func updatePageIndex() {
        guard let page = pdfView.currentPage, let document = pdfView.document else {
            return
        }
        pageIndex = document.index(for: page)
    }
}

private struct PDFViewRepresentable: NSViewRepresentable {
    let controller: PDFPreviewController

    func makeNSView(context: Context) -> PDFView {
        controller.pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {}
}

private struct PDFThumbnailRepresentable: NSViewRepresentable {
    let controller: PDFPreviewController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.pdfView = controller.pdfView
        view.thumbnailSize = CGSize(width: 60, height: 85)
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {}
}
