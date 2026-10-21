// SPDX-License-Identifier: MIT
import Foundation
import VVConfig
import CocoaSpice
import CocoaSpiceRenderer

/// Drives a single SPICE session on top of (the forked) CocoaSpice: starts the
/// GLib worker, builds and configures the `CSConnection` (including the Proxmox
/// TLS-via-proxy knobs), implements `CSConnectionDelegate`, and surfaces state to
/// the UI. Delegate callbacks arrive on the GLib worker thread, so all observable
/// state is mutated on the main queue.
public final class SpiceClient: NSObject, ObservableObject {

    public enum Status: Equatable {
        case idle
        case connecting
        case connected
        case disconnected
        case failed(String)
    }

    /// High-level connection state, for the UI.
    @Published public private(set) var status: Status = .idle
    /// Whether the guest SPICE agent (vdagent) is connected — required for
    /// clipboard sharing and dynamic resolution.
    @Published public private(set) var agentConnected = false
    /// Whether the connected agent advertises dynamic monitor configuration.
    @Published public private(set) var supportsDynamicResolution = false

    // The UI sets these to receive channel lifecycle on the main thread.
    public var onDisplayCreated: ((CSDisplay) -> Void)?
    public var onDisplayUpdated: ((CSDisplay) -> Void)?
    public var onDisplayDestroyed: ((CSDisplay) -> Void)?
    public var onInputAvailable: ((CSInput) -> Void)?
    public var onInputUnavailable: ((CSInput) -> Void)?

    public private(set) var connection: CSConnection?
    /// The most recently announced inputs channel (keyboard/mouse).
    public private(set) var primaryInput: CSInput?

    /// Whether to share the clipboard with the guest (both directions). Set before
    /// `connect()`. While on, anything copied on the host is sent to the guest, so
    /// disable it for untrusted VMs.
    public var shareClipboard: Bool = true

    /// Whether the guest may record from the Mac's microphone. Default off: the
    /// guest can start recording at any time. Set before `connect()` or while
    /// connected; a change applies at once.
    public var shareMicrophone = false {
        didSet {
            guard shareMicrophone != oldValue else { return }
            connection?.microphoneEnabled = shareMicrophone
        }
    }

    /// USB redirection manager for the active connection, if any.
    public var usbManager: CSUSBManager? { connection?.usbManager }

    /// Every display channel of the connection, by `monitorID`, including those
    /// the guest has off (`onDisplayCreated` reports a display once it is on).
    public var displays: [CSDisplay] { connection?.displays ?? [] }

    /// The video codecs to ask the server for, first one preferred; nil leaves the
    /// server's own order. Set before `connect()` or while connected: a change
    /// applies at once, and makes the server restart its running streams.
    public var preferredVideoCodecs: [CSVideoCodec]? {
        didSet {
            guard preferredVideoCodecs != oldValue else { return }
            connection?.preferredVideoCodecs = preferredVideoCodecs?.map { NSNumber(value: $0.rawValue) }
        }
    }

    /// How many ms after arrival a streamed frame is shown while no audio plays;
    /// nil keeps `SPICE_STREAM_PLAYOUT_MS` (default 50). Applies like
    /// `preferredVideoCodecs`, from the next frame on.
    public var streamPlayoutDelay: Int? {
        didSet {
            guard streamPlayoutDelay != oldValue else { return }
            connection?.streamPlayoutDelay = streamPlayoutDelay ?? -1
        }
    }

    private let parameters: SpiceConnectionParameters
    private let pasteboard: SpicePasteboardBridge
    /// Whether a connection attempt has already been made. The Proxmox ticket is
    /// single-use, so we never silently reconnect with the same parameters — the
    /// user must open a fresh `.vv`.
    private var didAttemptConnect = false

    public init(parameters: SpiceConnectionParameters,
                pasteboard: SpicePasteboardBridge = SpicePasteboardBridge()) {
        self.parameters = parameters
        self.pasteboard = pasteboard
        super.init()
    }

    /// The window title hint from the `.vv` file, if any.
    public var title: String? { parameters.title }
    /// Whether the `.vv` requested fullscreen.
    public var prefersFullscreen: Bool { parameters.fullscreen }

    // MARK: - Lifecycle

    /// Build the connection and start connecting. Safe to call once; subsequent
    /// calls are ignored (the SPICE ticket is single-use). Always runs on the main
    /// queue so observable state is mutated there.
    public func connect() {
        onMain { self.performConnect() }
    }

    private func performConnect() {
        guard connection == nil, !didAttemptConnect else { return }
        didAttemptConnect = true

        // Fail closed: certificate-subject verification is meaningless without a CA
        // to anchor the chain. (A real Proxmox .vv always provides both; this guards
        // a malformed/hostile file from a weakened-verification connect.)
        if parameters.isTLS && parameters.verifySubject && (parameters.caPEM?.isEmpty ?? true) {
            status = .failed("Refusing to connect: the file requests certificate-subject verification but supplies no CA certificate.")
            return
        }

        let main = CSMain.shared
        if !main.running {
            guard main.spiceStart() else {
                status = .failed("Could not start the SPICE worker thread.")
                return
            }
        }

        status = .connecting

        let conn: CSConnection
        if parameters.isTLS {
            // TLS path. For Proxmox we verify by certificate subject + CA rather
            // than a pinned public key, so pass an empty key and override
            // verification below via the fork's setProxy:ca:certSubject:.
            conn = CSConnection(host: parameters.host,
                                tlsPort: String(parameters.tlsPort ?? 0),
                                serverPublicKey: Data())
        } else {
            conn = CSConnection(host: parameters.host,
                                port: String(parameters.port ?? 0))
        }

        conn.delegate = self
        conn.password = parameters.password
        conn.audioEnabled = true

        if parameters.requiresProxyExtension {
            conn.setProxy(parameters.proxy,
                          ca: parameters.caPEM,
                          certSubject: parameters.certSubject)
        }

        conn.microphoneEnabled = shareMicrophone

        // Applied by CocoaSpice to each display channel as it opens.
        if let preferredVideoCodecs {
            conn.preferredVideoCodecs = preferredVideoCodecs.map { NSNumber(value: $0.rawValue) }
        }
        if let streamPlayoutDelay {
            conn.streamPlayoutDelay = streamPlayoutDelay
        }

        // Clipboard sharing (opt-out; requires the guest vdagent to take effect).
        conn.session.shareClipboard = shareClipboard
        conn.session.pasteboardDelegate = pasteboard

        connection = conn

        if !conn.connect() {
            status = .failed("Failed to initiate the SPICE connection.")
            connection = nil
            return
        }

        // Poll the host pasteboard so host→guest copy works (macOS has no native
        // pasteboard-change notification) — only when sharing is enabled.
        if shareClipboard {
            pasteboard.startMonitoring()
        }
    }

    /// A statistics snapshot of the connection, delivered on the main queue; never
    /// called back when not connected.
    public func readStatistics(_ completion: @escaping (CSConnectionStatistics) -> Void) {
        connection?.readStatistics(completion: completion)
    }

    /// Copies files (not folders) into the guest through its agent. `progress`
    /// gets the bytes sent and the total, `completion` the error if any (an
    /// `NSUserCancelledError` after `cancel()`); both on the main queue. Nil when
    /// not connected.
    public func copyFilesToGuest(_ files: [URL],
                                 progress: @escaping (Int64, Int64) -> Void,
                                 completion: @escaping (Error?) -> Void) -> CSFileTransfer? {
        connection?.copyFiles(toGuest: files, progress: progress, completion: completion)
    }

    /// Request disconnect. Final teardown is reported via `spiceDisconnected:`.
    public func disconnect() {
        onMain { self.connection?.disconnect() }
    }

    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }
}

// MARK: - CSConnectionDelegate

extension SpiceClient: CSConnectionDelegate {

    public func spiceConnected(_ connection: CSConnection) {
        onMain { self.status = .connected }
    }

    public func spiceDisconnected(_ connection: CSConnection) {
        onMain {
            self.pasteboard.stopMonitoring()
            // An error drop fires spiceError(...) (status = .failed(reason)) and
            // THEN this. Keep the specific reason instead of downgrading it to the
            // generic "disconnected" message.
            if case .failed = self.status {} else {
                self.status = .disconnected
            }
            self.agentConnected = false
            self.supportsDynamicResolution = false
            self.primaryInput = nil
            self.connection = nil
        }
    }

    public func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
        onMain {
            self.status = .failed(message ?? "SPICE connection error (code \(code.rawValue)).")
        }
    }

    public func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
        onMain {
            self.primaryInput = input
            self.onInputAvailable?(input)
        }
    }

    public func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {
        onMain {
            if self.primaryInput === input { self.primaryInput = nil }
            self.onInputUnavailable?(input)
        }
    }

    public func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {
        onMain { self.onDisplayCreated?(display) }
    }

    public func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {
        onMain { self.onDisplayUpdated?(display) }
    }

    public func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {
        onMain { self.onDisplayDestroyed?(display) }
    }

    public func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {
        onMain {
            self.agentConnected = true
            self.supportsDynamicResolution = features.contains(.monitorsConfig)
        }
    }

    public func spiceAgentDisconnected(_ connection: CSConnection) {
        onMain {
            self.agentConnected = false
            self.supportsDynamicResolution = false
        }
    }

    public func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
    public func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
}
