// SPDX-License-Identifier: MIT
import AppKit

/// The bar at the top of the display for files dropped on it: that a drag can be
/// released, then what is being copied into the guest, how far along, the speed
/// and the time left, with a button to stop, then how the copy ended.
final class FileTransferBarView: NSView {

    enum State {
        case dragging
        case copying(String, fraction: Double)
        case finished(String)
        case failed(String)
    }

    var onCancel: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let stopButton = NSButton()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.75).cgColor
        layer?.cornerRadius = 10

        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.controlSize = .small
        stopButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop copying")
        stopButton.isBordered = false
        stopButton.contentTintColor = .white
        stopButton.toolTip = "Stop copying"
        stopButton.target = self
        stopButton.action = #selector(stop)

        for view in [label, progress, stopButton] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: stopButton.leadingAnchor, constant: -8),
            stopButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stopButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progress.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ state: State) {
        isHidden = false
        switch state {
        case .dragging:
            label.stringValue = "Release to copy into the VM"
            label.textColor = .white
            progress.isHidden = true
            stopButton.isHidden = true
        case .copying(let text, let fraction):
            label.stringValue = text
            label.textColor = .white
            progress.isHidden = false
            progress.doubleValue = fraction
            stopButton.isHidden = false
        case .finished(let text):
            label.stringValue = text
            label.textColor = .white
            progress.isHidden = false
            progress.doubleValue = 1
            stopButton.isHidden = true
        case .failed(let text):
            label.stringValue = text
            label.textColor = .systemOrange
            progress.isHidden = true
            stopButton.isHidden = true
        }
    }

    @objc private func stop() { onCancel?() }

    /// Only the stop button takes clicks: the rest of the bar lets them through
    /// to the guest.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point), !stopButton.isHidden, hit.isDescendant(of: stopButton) else {
            return nil
        }
        return hit
    }
}

/// The copies in flight, and what the bar says about them.
struct FileTransferProgress {

    private struct Copy {
        let name: String
        let files: Int
        var sent: Int64 = 0
        var total: Int64 = 0
    }

    private var copies: [ObjectIdentifier: Copy] = [:]
    /// Bytes sent by every copy since the first started, never decreasing.
    private var sentSoFar: Int64 = 0
    /// (time, sentSoFar) over the last few seconds, for the speed.
    private var samples: [(time: CFTimeInterval, sent: Int64)] = []
    private(set) var filesCopied = 0
    private(set) var foldersSkipped = 0
    private(set) var errors: [String] = []
    private(set) var cancelled = false

    var isActive: Bool { !copies.isEmpty }

    mutating func start(_ id: ObjectIdentifier, files: [URL], foldersSkipped: Int) {
        if copies.isEmpty {
            self = FileTransferProgress()
        }
        let name = files.count == 1 ? files[0].lastPathComponent : "\(files.count) files"
        copies[id] = Copy(name: name, files: files.count)
        self.foldersSkipped += foldersSkipped
    }

    mutating func update(_ id: ObjectIdentifier, sent: Int64, total: Int64, now: CFTimeInterval) {
        guard var copy = copies[id] else { return }
        sentSoFar += max(0, sent - copy.sent)
        copy.sent = sent
        copy.total = total
        copies[id] = copy
        samples.append((now, sentSoFar))
        samples.removeAll { now - $0.time > 5 }
    }

    mutating func finish(_ id: ObjectIdentifier, error: Error?) {
        guard let copy = copies.removeValue(forKey: id) else { return }
        if let error = error as NSError? {
            if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
                cancelled = true
            } else {
                errors.append("\(copy.name): \(error.localizedDescription)")
            }
        } else {
            filesCopied += copy.files
        }
    }

    /// While copying: what, how much, how fast, how long still.
    func status(now: CFTimeInterval) -> (text: String, fraction: Double) {
        let sent = copies.values.reduce(0) { $0 + $1.sent }
        let total = copies.values.reduce(0) { $0 + $1.total }
        let names = copies.values.map(\.name)
        let what = names.count == 1 ? names[0] : "\(copies.values.reduce(0) { $0 + $1.files }) files"
        guard total > 0 else { return ("Copying \(what) into the VM…", 0) }

        var text = "Copying \(what) into the VM — \(Self.size(sent)) of \(Self.size(total))"
        if let first = samples.first, let last = samples.last, last.time - first.time >= 1 {
            let speed = Double(last.sent - first.sent) / (last.time - first.time)
            if speed > 0 {
                text += " · \(Self.size(Int64(speed)))/s · \(Self.duration(Double(total - sent) / speed)) left"
            }
        }
        return (text, Double(sent) / Double(total))
    }

    /// Once nothing is left to copy: how it went, and whether it is an error.
    var outcome: (text: String, failed: Bool) {
        var parts: [String] = []
        if filesCopied > 0 {
            parts.append("Copied \(filesCopied == 1 ? "1 file" : "\(filesCopied) files") into the VM")
        }
        if cancelled {
            parts.append("Copy stopped")
        }
        if foldersSkipped > 0 {
            parts.append(foldersSkipped == 1 ? "1 folder skipped" : "\(foldersSkipped) folders skipped")
        }
        parts += errors.map { "Could not copy \($0)" }
        return (parts.joined(separator: " · "), !errors.isEmpty)
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private static func duration(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds.rounded())) ?? "—"
    }
}
