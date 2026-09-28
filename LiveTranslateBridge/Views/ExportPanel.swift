import AppKit
import UniformTypeIdentifiers

/// The save panel behind "Export as Document…".
///
/// One command rather than one per format: the format is chosen in the panel
/// itself, from a pop-up under the file name, the way TextEdit and Preview
/// offer theirs. The last choice is remembered, since someone who exports to
/// Word does it every time.
@MainActor
enum ExportPanel {
    static func present(_ record: SessionRecord) {
        let panel = NSSavePanel()
        let chooser = FormatChooser(panel: panel, record: record)
        panel.title = t("export.panel.title")
        panel.prompt = t("export.panel.prompt")
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.accessoryView = chooser.view
        chooser.apply(SubtitleModel.Defaults.exportFormat, renaming: true)

        // The chooser is the pop-up's target and AppKit holds targets weakly,
        // so the completion handler keeps it alive for as long as the panel is.
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            write(record, format: chooser.format, to: url)
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private static func write(_ record: SessionRecord, format: SessionExport.Format, to url: URL) {
        do {
            try SessionExport.data(record, format: format).write(to: url, options: .atomic)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = t("export.failed")
            if let window = NSApp.keyWindow ?? NSApp.mainWindow {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}

/// The pop-up under the file name, and the part that keeps the name's
/// extension in step with it.
@MainActor
private final class FormatChooser: NSObject {
    let view: NSView
    private(set) var format: SessionExport.Format = .markdown
    private let panel: NSSavePanel
    private let record: SessionRecord
    private let popUp = NSPopUpButton(frame: .zero, pullsDown: false)

    init(panel: NSSavePanel, record: SessionRecord) {
        self.panel = panel
        self.record = record
        let label = NSTextField(labelWithString: t("export.panel.format"))
        let stack = NSStackView(views: [label, popUp])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 20, bottom: 10, right: 20)
        view = stack
        super.init()
        for format in SessionExport.Format.allCases {
            popUp.addItem(withTitle: format.label)
            popUp.lastItem?.representedObject = format.rawValue
        }
        popUp.target = self
        popUp.action = #selector(formatChanged(_:))
    }

    func apply(_ format: SessionExport.Format, renaming: Bool) {
        self.format = format
        popUp.selectItem(at: SessionExport.Format.allCases.firstIndex(of: format) ?? 0)
        panel.allowedContentTypes = [format.contentType]
        if renaming {
            panel.nameFieldStringValue = SessionExport.suggestedFileName(record, format: format)
        } else {
            // Keep whatever name the user typed; only the extension follows.
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = base + "." + format.fileExtension
        }
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let format = SessionExport.Format(rawValue: raw) else { return }
        SubtitleModel.Defaults.exportFormat = format
        apply(format, renaming: false)
    }
}
