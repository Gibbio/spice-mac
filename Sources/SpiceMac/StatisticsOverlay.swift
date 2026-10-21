// SPDX-License-Identifier: MIT
import AppKit
import CocoaSpice

/// View ▸ Show Statistics: a translucent panel in the top-left corner of the
/// display with what the connection, its video streams and the Mac's display path
/// are doing. Drawn by hand, sized to its text, and transparent to the mouse so
/// clicks still reach the guest.
final class StatisticsOverlayView: NSView {

    private static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        .foregroundColor: NSColor.white,
    ]
    private static let inset = NSSize(width: 10, height: 8)

    private var attributedText = NSAttributedString()

    var text = "" {
        didSet {
            attributedText = NSAttributedString(string: text, attributes: Self.attributes)
            needsDisplay = true
        }
    }

    /// The size that fits the current text.
    var fittingTextSize: NSSize {
        let size = attributedText.size()
        return NSSize(width: ceil(size.width) + 2 * Self.inset.width,
                      height: ceil(size.height) + 2 * Self.inset.height)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        attributedText.draw(at: NSPoint(x: Self.inset.width, y: Self.inset.height))
    }
}

/// Turns successive statistics snapshots into the overlay's text: rates are over
/// the time since the previous snapshot.
struct StatisticsFormatter {

    struct Sample {
        let time: CFTimeInterval
        let statistics: CSConnectionStatistics
        /// The renderer's running totals, see `SpiceDisplayView.presentTotals`.
        let present: (presented: Int, missed: Int, latencySum: Double)?
        let guestSize: CGSize
        let agentConnected: Bool
        let microphoneShared: Bool
    }

    private var previous: Sample?

    mutating func text(for sample: Sample) -> String {
        defer { previous = sample }
        let stats = sample.statistics
        let interval = previous.map { sample.time - $0.time } ?? 0
        var lines: [String] = []

        // Network
        let bytes = stats.bytesReceived.mapValues { $0.uint64Value }
        let total = bytes.values.reduce(0, +)
        let previousBytes = previous?.statistics.bytesReceived.mapValues { $0.uint64Value } ?? [:]
        func rate(_ channel: String) -> Double? {
            guard interval > 0, let now = bytes[channel], let before = previousBytes[channel],
                  now >= before else { return nil }
            return Double(now - before) * 8 / interval / 1_000_000
        }
        let totalRate: Double? = interval > 0 ? bytes.keys.compactMap(rate).reduce(0, +) : nil
        lines.append("Network")
        var received = "  Received    \(mbit(totalRate))  (\(megabytes(total)) total)"
        let parts = Self.channelNames.compactMap { channel, name -> String? in
            guard let value = rate(channel), value >= 0.05 || channel == "display" else { return nil }
            return "\(name) \(String(format: "%.1f", value))"
        }
        if !parts.isEmpty { received += "\n              " + parts.joined(separator: " · ") }
        lines.append(received)
        lines.append("  Round trip  " + (stats.roundTripTime >= 0 ? "\(stats.roundTripTime) ms (TCP)" : "—"))
        if let version = stats.tlsVersion {
            lines.append("  Encryption  \(version) · \(stats.tlsCipher ?? "?")")
        } else {
            lines.append("  Encryption  none")
        }

        // Display
        lines.append("Display")
        let guest = sample.guestSize == .zero ? "—"
            : "\(Int(sample.guestSize.width))×\(Int(sample.guestSize.height))"
        lines.append("  Guest       \(guest) · mouse \(stats.clientMouseMode ? "client" : "server")"
            + " · agent \(sample.agentConnected ? "on" : "off")")
        lines.append("  Mac         " + presentLine(sample, interval: interval))

        // Video
        lines.append("Video")
        if stats.streams.isEmpty {
            lines.append("  no stream (still screen, or content not seen as video)")
        }
        let previousStreams = Dictionary(
            (previous?.statistics.streams ?? []).map { ($0.streamID, $0) }, uniquingKeysWith: { a, _ in a })
        for stream in stats.streams {
            let size = "\(Int(stream.size.width))×\(Int(stream.size.height))"
            lines.append("  #\(stream.streamID)  \(Self.codecName(stream.codec)) · \(stream.decoder) · \(size)")
            var fps = "—"
            if interval > 0, let before = previousStreams[stream.streamID],
               stream.framesReceived >= before.framesReceived, stream.framesShown >= before.framesShown {
                let received = Double(stream.framesReceived - before.framesReceived) / interval
                let shown = Double(stream.framesShown - before.framesShown) / interval
                fps = String(format: "%.1f fps in · %.1f shown", received, shown)
            }
            lines.append("      \(fps) · late \(stream.framesLate) · dropped \(stream.framesDropped)")
            let clock: String
            if stream.playoutTarget <= 0 {
                clock = "server timing"
            } else if stream.audioSync {
                clock = "follows the audio"
            } else {
                clock = "target \(stream.playoutTarget) ms"
            }
            lines.append("      shown \(stream.playoutDelay) ms after arrival (\(clock))")
        }

        // Audio
        lines.append("Audio")
        if let codec = stats.audioCodec {
            var audio = "  \(codec) · " + (stats.audioPlaying ? "playing" : "idle")
            if stats.audioPlaying, stats.audioDelay > 0 {
                audio += " · output delay \(stats.audioDelay) ms"
                if stats.audioBuffered >= 0 {
                    audio += " (buffer \(stats.audioBuffered) of \(stats.audioBufferTarget)"
                        + " + device \(stats.audioDeviceLatency))"
                }
            }
            lines.append(audio)
            if stats.audioUnderruns >= 0 {
                lines.append("  \(stats.audioUnderruns) underruns · \(stats.audioSkipped) ms skipped")
            }
        } else {
            lines.append("  no audio channel")
        }
        let microphone: String
        switch (sample.microphoneShared, stats.guestRecording) {
        case _ where stats.audioBuffered < 0:
            microphone = "not available"
        case (true, true):   microphone = "shared · in use"
        case (true, false):  microphone = "shared · not in use"
        case (false, true):  microphone = "not shared · the VM is trying to record"
        case (false, false): microphone = "not shared"
        }
        lines.append("  Microphone  \(microphone)")
        return lines.joined(separator: "\n")
    }

    private func presentLine(_ sample: Sample, interval: CFTimeInterval) -> String {
        guard interval > 0, let now = sample.present, let before = previous?.present,
              now.presented >= before.presented else { return "—" }
        let frames = now.presented - before.presented
        var line = String(format: "%.1f fps drawn", Double(frames) / interval)
        if frames > 0 {
            let latency = (now.latencySum - before.latencySum) / Double(frames) * 1000
            line += String(format: " · upload to screen %.0f ms", latency)
        }
        let missed = now.missed - before.missed
        if missed > 0 { line += " · \(missed) not shown" }
        return line
    }

    /// The channels the Received line breaks down, in order.
    private static let channelNames: [(String, String)] = [
        ("display", "display"), ("playback", "audio"), ("cursor", "cursor"),
        ("usbredir", "usb"), ("record", "mic"), ("inputs", "input"), ("main", "main"),
    ]

    private static func codecName(_ codec: CSVideoCodec) -> String {
        switch codec.rawValue {
        case 1: return "MJPEG"
        case 2: return "VP8"
        case 3: return "H.264"
        case 4: return "VP9"
        case 5: return "H.265"
        default: return "codec \(codec.rawValue)"
        }
    }

    private func mbit(_ value: Double?) -> String {
        value.map { String(format: "%.1f Mbit/s", $0) } ?? "—"
    }

    private func megabytes(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_000_000
        return value >= 1000 ? String(format: "%.2f GB", value / 1000) : String(format: "%.0f MB", value)
    }
}
