// SPDX-License-Identifier: MIT
import AppKit
import Combine
import CocoaSpice
import SpiceController
import DisplayScale

/// Owns one window of a SPICE session, for one guest display: hosts the
/// `SpiceDisplayView`, resizes to the guest, and exposes the Connection/USB menu
/// actions via the responder chain. Display 0's window is the session's: it also
/// reflects the connection state and opens a window for each other display the
/// guest has on.
final class SpiceWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {

    private let client: SpiceClient
    private let sourceURL: URL
    private let displayView = SpiceDisplayView()
    private let containerView = NSView()
    private let statusLabel = NSTextField(labelWithString: "Connecting…")
    private var cancellables = Set<AnyCancellable>()

    /// View ▸ Show Statistics, refreshed once a second while shown and connected.
    private let statisticsOverlay = StatisticsOverlayView()
    private var statisticsTimer: Timer?
    private var statisticsFormatter = StatisticsFormatter()
    private var isConnected = false

    /// Files dropped on the display are copied into the guest; the bar at the top
    /// shows how far along.
    private let transferBar = FileTransferBarView()
    private var transfers: [ObjectIdentifier: CSFileTransfer] = [:]
    private var transferProgress = FileTransferProgress()
    private var transferTimer: Timer?
    private var transferBarHide: DispatchWorkItem?

    /// Called when the window closes so the app can drop its reference.
    var onClose: (() -> Void)?

    /// The guest display this window shows (`CSDisplay.monitorID`). Display 0's
    /// window connects, shows the connection's state, owns the windows of the
    /// other displays (`displayWindows`) and closes them, and the connection, when
    /// it closes. Closing another display's window only hides it (see
    /// `windowShouldClose`).
    let monitorID: Int
    private weak var sessionWindow: SpiceWindowController?
    private var displayWindows: [Int: SpiceWindowController] = [:]
    private var isSessionWindow: Bool { monitorID == 0 }
    /// Closed while in full screen: hidden once out of it.
    private var hidesAfterFullScreen = false

    /// The last guest size we asked for. Suppresses a redundant monitor-config,
    /// which costs a real mode switch; cleared when the display/agent state
    /// restarts.
    private var lastRequestedGuestSize: CGSize?

    /// Coalesces resolution requests: one drag across a screen boundary fires
    /// several.
    private var pendingResolutionRequest: DispatchWorkItem?

    /// Block-based NotificationCenter observers, removed on close.
    private var notificationObservers: [NSObjectProtocol] = []

    /// Backing scale of the screen this window was last seen on. Seeded at creation
    /// so a window that merely OPENS on a Retina screen is not mistaken for one
    /// that MOVED onto it, which would resize a window the user had deliberately
    /// sized.
    private var lastKnownBackingScale: CGFloat = 0

    /// The zoom THIS window is at. Per-window because each window is its own
    /// session on its own display: a level picked in one has no business
    /// reconfiguring another's guest. Seeded from `Preferences.displayZoom` (the
    /// last level picked anywhere) and changed only by the menu commands below.
    private var displayZoom: DisplayZoom = Preferences.displayZoom

    convenience init(client: SpiceClient, sourceURL: URL) {
        self.init(client: client, sourceURL: sourceURL, monitorID: 0, session: nil)
    }

    private init(client: SpiceClient, sourceURL: URL, monitorID: Int, session: SpiceWindowController?) {
        self.client = client
        self.sourceURL = sourceURL
        self.monitorID = monitorID
        self.sessionWindow = session
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.acceptsMouseMovedEvents = true
        window.title = baseTitle
        window.center()
        lastKnownBackingScale = window.backingScaleFactor
        setupViews()
        if isSessionWindow {
            wireClient()
            applyVideoPreferences()
        } else {
            wireAgent()
        }
        wireNotifications()
    }

    deinit {
        pendingResolutionRequest?.cancel()
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var baseTitle: String {
        let title = client.title ?? sourceURL.deletingPathExtension().lastPathComponent
        return isSessionWindow ? title : "\(title) — Display \(monitorID + 1)"
    }

    // MARK: - Views

    private func setupViews() {
        guard let window else { return }
        containerView.frame = NSRect(x: 0, y: 0, width: 1024, height: 768)
        displayView.autoresizingMask = [.width, .height]
        displayView.frame = containerView.bounds
        containerView.addSubview(displayView)
        // One of the signals for "this window is on a different display"; they all
        // funnel into screenChanged(), which is idempotent about the duplicates.
        displayView.onBackingScaleChange = { [weak self] _ in
            self?.screenChanged()
        }

        statusLabel.alignment = .center
        statusLabel.maximumNumberOfLines = 0
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: 15)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusLabel)
        statisticsOverlay.autoresizingMask = [.maxXMargin, .minYMargin]   // stays top-left
        statisticsOverlay.isHidden = true
        containerView.addSubview(statisticsOverlay)

        transferBar.isHidden = true
        transferBar.translatesAutoresizingMaskIntoConstraints = false
        transferBar.onCancel = { [weak self] in self?.stopFileTransfers() }
        containerView.addSubview(transferBar)
        let barWidth = transferBar.widthAnchor.constraint(equalToConstant: 520)
        barWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            transferBar.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 12),
            transferBar.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            transferBar.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, constant: -24),
            barWidth,
        ])
        displayView.onFileDragChanged = { [weak self] dragging in self?.fileDragChanged(dragging) }
        displayView.onFilesDropped = { [weak self] files in self?.copyIntoGuest(files) }

        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: containerView.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: containerView.widthAnchor, multiplier: 0.8),
        ])

        window.contentView = containerView
        window.initialFirstResponder = displayView
    }

    // MARK: - Client wiring

    private func wireClient() {
        client.onDisplayCreated = { [weak self] display in self?.displayCreated(display) }
        // NB: do NOT resize the window when the guest resolution changes. The view
        // re-fits the viewport via its displaySize KVO, so the window stays the
        // user's size. Resizing here would chase the guest size and, combined with
        // requestResolution, oscillate (the guest reconfigures → window resizes →
        // we request a new resolution → …).
        client.onDisplayDestroyed = { [weak self] display in self?.displayDestroyed(display) }
        // One inputs channel for every display's window.
        client.onInputAvailable = { [weak self] input in
            guard let self else { return }
            self.displayView.router.input = input
            self.displayView.router.requestMouseMode(server: false)
            self.window?.makeFirstResponder(self.displayView)
            for controller in self.displayWindows.values { controller.displayView.router.input = input }
        }
        client.onInputUnavailable = { [weak self] _ in
            guard let self else { return }
            self.displayView.router.input = nil
            for controller in self.displayWindows.values { controller.displayView.router.input = nil }
        }

        client.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.update(for: $0) }
            .store(in: &cancellables)

        wireAgent()
    }

    /// Every display's window asks for its own resolution when the agent comes.
    private func wireAgent() {
        client.$agentConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                guard let self else { return }
                // A fresh agent means a fresh guest display stack, so forget what we
                // asked the previous one for.
                self.lastRequestedGuestSize = nil
                if connected { self.scheduleResolutionRequest(after: 0.15) }
            }
            .store(in: &cancellables)
    }

    private func wireNotifications() {
        let center = NotificationCenter.default
        // Hotplug/removal, sleep/wake, and Displays "scaled resolution" changes,
        // which resize the window WITHOUT a live resize. Longer delay: AppKit keeps
        // shuffling windows for a while after these.
        notificationObservers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
            self?.screenChanged(after: 0.6)
        })
        // The rest is the connection's, so the session window's.
        guard isSessionWindow else { return }
        notificationObservers.append(center.addObserver(
            forName: .videoSettingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.applyVideoPreferences()
        })
        notificationObservers.append(center.addObserver(
            forName: .showStatisticsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatisticsOverlay()
        })
        notificationObservers.append(center.addObserver(
            forName: .microphoneSettingChanged, object: nil, queue: .main) { [weak self] _ in
            self?.client.shareMicrophone = Preferences.shareMicrophone
        })
    }

    /// Connection ▸ Prefer H.264 Video and Video Delay, unless the launch
    /// environment sets them. With H.264 off nothing is asked for at connect (the
    /// server's own order puts MJPEG first); turned off later, it asks for MJPEG
    /// first again. SpiceClient sends only what changed.
    private func applyVideoPreferences() {
        if !Preferences.videoCodecsFromEnvironment {
            if Preferences.preferH264Video {
                client.preferredVideoCodecs = [.H264, .MJPEG]
            } else if client.preferredVideoCodecs != nil {
                client.preferredVideoCodecs = [.MJPEG]
            }
        }
        if !Preferences.videoDelayFromEnvironment {
            client.streamPlayoutDelay = Preferences.videoDelay.rawValue
        }
    }

    // MARK: - Statistics overlay

    private func updateStatisticsOverlay() {
        let show = Preferences.showStatistics && isConnected
        statisticsOverlay.isHidden = !show
        displayView.collectsPresentStatistics = show
        if show, statisticsTimer == nil {
            statisticsFormatter = StatisticsFormatter()
            setStatisticsText("Collecting statistics…")
            // .common, so it keeps ticking during live resize and menu tracking.
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refreshStatistics() }
            RunLoop.main.add(timer, forMode: .common)
            statisticsTimer = timer
            refreshStatistics()
        } else if !show {
            statisticsTimer?.invalidate()
            statisticsTimer = nil
        }
    }

    private func refreshStatistics() {
        client.readStatistics { [weak self] statistics in
            guard let self, self.statisticsTimer != nil else { return }
            let sample = StatisticsFormatter.Sample(
                time: CACurrentMediaTime(),
                statistics: statistics,
                present: self.displayView.presentTotals,
                guestSize: self.displayView.attachedDisplay?.displaySize ?? .zero,
                agentConnected: self.client.agentConnected,
                microphoneShared: self.client.shareMicrophone)
            self.setStatisticsText(self.statisticsFormatter.text(for: sample))
        }
    }

    private func setStatisticsText(_ text: String) {
        statisticsOverlay.text = text
        let size = statisticsOverlay.fittingTextSize
        let bounds = containerView.bounds
        statisticsOverlay.frame = NSRect(x: 12, y: bounds.height - size.height - 12,
                                         width: size.width, height: size.height)
    }

    private func attachDisplay(_ display: CSDisplay) {
        displayView.attachDisplay(display)
        lastRequestedGuestSize = nil   // a re-attach means a fresh guest surface
        // Another display's window stays where makeDisplayWindow put it.
        resizeToDisplay(display.displaySize, recenter: isSessionWindow)
        // The agent-connected and display-created edges race, and whichever loses
        // has to be the one that asks. Safe against the oscillation rule:
        // spiceDisplayCreated is a one-shot per display channel (later configs fire
        // spiceDisplayUpdated).
        scheduleResolutionRequest(after: 0.15)
        statusLabel.isHidden = true
        window?.makeFirstResponder(displayView)
        if client.prefersFullscreen, window?.styleMask.contains(.fullScreen) == false {
            window?.toggleFullScreen(nil)
        }
    }

    // MARK: - The guest's other displays

    private func displayCreated(_ display: CSDisplay) {
        guard display.monitorID != monitorID else {
            attachDisplay(display)
            return
        }
        let controller = displayWindows[display.monitorID] ?? makeDisplayWindow(display.monitorID)
        // Shown before attaching, which may take it to full screen.
        controller.window?.orderFront(nil)
        controller.attachDisplay(display)
    }

    /// The guest turned a display off (or it never came up).
    private func displayDestroyed(_ display: CSDisplay) {
        if display.monitorID == monitorID {
            displayView.detach()
        } else {
            displayWindows.removeValue(forKey: display.monitorID)?.close()
        }
    }

    /// On a screen of its own while there are screens without a SpiceMac window;
    /// otherwise cascaded from this one.
    private func makeDisplayWindow(_ id: Int) -> SpiceWindowController {
        let controller = SpiceWindowController(client: client, sourceURL: sourceURL, monitorID: id, session: self)
        controller.displayView.router.input = client.primaryInput
        if let window = controller.window, let sessionWindow = self.window {
            let others = displayWindows.keys.sorted().compactMap { displayWindows[$0]?.window }
            let taken = Set(([sessionWindow] + others).compactMap(\.screen))
            if let screen = NSScreen.screens.first(where: { !taken.contains($0) }) {
                let area = screen.visibleFrame
                window.setFrameOrigin(NSPoint(x: area.midX - window.frame.width / 2,
                                              y: area.midY - window.frame.height / 2))
            } else {
                let from = others.last ?? sessionWindow
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: from.frame.minX, y: from.frame.maxY)))
            }
        }
        displayWindows[id] = controller
        return controller
    }

    private func closeDisplayWindows() {
        let controllers = displayWindows.values
        displayWindows.removeAll()
        for controller in controllers { controller.close() }
    }

    /// Another display's close button hides its window: the guest keeps the
    /// display, and View ▸ Displays shows it again. Turning the display off, as
    /// virt-viewer does, breaks Windows guests: spice-vdagent-win 0.10 cannot turn
    /// a QXL display back on until the guest restarts, and fails every resolution
    /// change until then, the other displays' too.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isSessionWindow else { return true }
        if sender.styleMask.contains(.fullScreen) {
            hidesAfterFullScreen = true
            sender.toggleFullScreen(nil)
        } else {
            sender.orderOut(nil)
        }
        return false
    }

    // MARK: - View ▸ Displays

    /// Fills View ▸ Displays with the session's displays; false when not connected.
    func addDisplayItems(to menu: NSMenu) -> Bool {
        if let sessionWindow { return sessionWindow.addDisplayItems(to: menu) }
        let displays = client.displays
        guard client.status == .connected, !displays.isEmpty else { return false }
        for display in displays {
            let id = display.monitorID
            let item = NSMenuItem(title: "Display \(id + 1)",
                                  action: #selector(showGuestDisplay(_:)), keyEquivalent: "")
            item.target = self
            item.tag = id
            if let window = id == monitorID ? window : displayWindows[id]?.window {
                item.state = window.isVisible ? .on : .off
            } else {
                item.title += " (Off)"
                item.toolTip = "Turn this display on in the VM (needs its SPICE agent)."
            }
            menu.addItem(item)
        }
        return true
    }

    /// Shows a display's window, or asks the guest to turn the display on, at this
    /// window's size; its window opens once the guest has it on.
    @objc private func showGuestDisplay(_ sender: NSMenuItem) {
        let id = sender.tag
        if id == monitorID {
            window?.makeKeyAndOrderFront(nil)
        } else if let controller = displayWindows[id] {
            controller.window?.makeKeyAndOrderFront(nil)
        } else if client.supportsDynamicResolution,
                  let display = client.displays.first(where: { $0.monitorID == id }) {
            let size = displayView.attachedDisplay?.displaySize ?? CGSize(width: 1280, height: 720)
            display.requestResolution(CGRect(origin: .zero, size: size))
        }
    }

    private func update(for status: SpiceClient.Status) {
        switch status {
        case .idle:
            displayView.isHidden = false
            statusLabel.stringValue = ""
        case .connecting:
            displayView.isHidden = false
            showStatus("Connecting…")
        case .connected:
            displayView.isHidden = false
            statusLabel.isHidden = true
            client.usbManager?.delegate = self
            refreshUSBMenu()
        case .disconnected:
            // The SPICE ticket is single-use, so reconnecting needs a fresh file.
            // Hide the (now static) display: detach() leaves the last guest frame
            // frozen on the opaque MTKView, so without this the stale screen stays
            // up and the message below is lost behind it. Hiding reveals the window
            // background so the centered message is readable.
            displayView.isHidden = true
            showStatus("Disconnected.\nOpen a fresh .vv file to reconnect.")
            closeDisplayWindows()
        case .failed(let message):
            displayView.isHidden = true
            showStatus("Connection failed.\n\(message)")
            closeDisplayWindows()
        }
        window?.title = title(for: status)
        isConnected = status == .connected
        updateStatisticsOverlay()
    }

    private func title(for status: SpiceClient.Status) -> String {
        switch status {
        case .connecting:   return "\(baseTitle) — Connecting…"
        case .disconnected: return "\(baseTitle) — Disconnected"
        case .failed:       return "\(baseTitle) — Failed"
        case .connected, .idle: return baseTitle
        }
    }

    private func showStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = false
    }

    // MARK: - Sizing

    /// Backing scale of the screen this window is currently on.
    private var currentBackingScale: CGFloat {
        window?.backingScaleFactor ?? displayView.backingScale
    }

    /// Size the window so `size` guest pixels occupy `guest × zoom / backingScale`
    /// points, clamped to what the screen can show. `recenter` only on attach; a
    /// later zoom change keeps the window's top-left where the user put it.
    private func resizeToDisplay(_ size: CGSize, recenter: Bool) {
        guard size.width > 1, size.height > 1, let window,
              window.styleMask.contains(.fullScreen) == false else { return }
        // Clamp against the CONTENT rect the visible frame allows, not the frame
        // itself — the title bar takes ~28 pt off the top.
        let allowed = (window.screen ?? NSScreen.main)
            .map { window.contentRect(forFrameRect: $0.visibleFrame).size }
        let target = DisplayScale.windowContentPoints(guest: size,
                                                      zoom: displayZoom,
                                                      backingScale: window.backingScaleFactor,
                                                      maximum: allowed)
        if recenter {
            window.setContentSize(target)
            window.center()
        } else {
            // setContentSize keeps the frame's bottom-left; users expect the
            // top-left to stay put. Constrain afterwards so the title bar stays
            // reachable.
            let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            window.setContentSize(target)
            window.setFrameTopLeftPoint(topLeft)
            window.setFrame(window.constrainFrameRect(window.frame, to: window.screen),
                            display: true)
        }
    }

    /// Ask the guest for `windowPoints × backingScale / zoom` — exactly `zoom` host
    /// pixels per guest pixel once it reconfigures. `SpiceDisplayView`'s aspect-fit
    /// then derives the same factor, so the renderer and the input router follow
    /// for free.
    private func requestResolutionForCurrentSize() {
        guard client.supportsDynamicResolution,
              let display = displayView.attachedDisplay else { return }
        let target = DisplayScale.targetGuestSize(viewPoints: displayView.bounds.size,
                                                  backingScale: currentBackingScale,
                                                  zoom: displayZoom)
        guard DisplayScale.needsRequest(target: target,
                                        current: display.displaySize,
                                        lastRequested: lastRequestedGuestSize) else { return }
        lastRequestedGuestSize = target
        display.requestResolution(CGRect(origin: .zero, size: target))
    }

    /// Coalesced entry point for a resolution request.
    ///
    /// NB: every caller is a HOST-side geometry event or the one-shot agent edge.
    /// Nothing guest-side may call it — a guest resolution change must only re-fit
    /// the viewport, or the resize↔request oscillation this app already fixed comes
    /// back.
    private func scheduleResolutionRequest(after delay: TimeInterval = 0.3) {
        pendingResolutionRequest?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingResolutionRequest = nil
            // Never fire mid-drag; windowDidEndLiveResize will reschedule us.
            guard self.window?.inLiveResize != true else { return }
            self.requestResolutionForCurrentSize()
        }
        pendingResolutionRequest = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The user picked a new zoom.
    ///
    /// With a guest agent the window is the user's chosen viewport and must NOT
    /// change: only the guest's pixel density does, so we re-request. Without one
    /// the guest resolution is fixed, so the only way to honour the zoom is the
    /// other side of the equation — resize the window to `guest × zoom /
    /// backingScale` points. That cannot reopen the oscillation: a programmatic
    /// setContentSize is not a live resize.
    private func applyZoomChange() {
        if client.supportsDynamicResolution {
            scheduleResolutionRequest(after: 0.05)   // discrete user action: near-immediate
        } else if let size = displayView.attachedDisplay?.displaySize {
            resizeToDisplay(size, recenter: false)
        }
        // Disconnected: nothing to do; the level applies once a display attaches.
    }

    /// The window may now be on a different display, so re-apply the geometry: at a
    /// fixed level the target is `points × backingScale / Z` and the move just
    /// changed the backing scale. The zoom LEVEL is never touched — a level the
    /// user picked is a decision. Every request goes through
    /// `DisplayScale.needsRequest` and is coalesced, so the several events one drag
    /// produces cost at most one guest mode switch.
    private func screenChanged(after delay: TimeInterval = 0.3) {
        let scale = currentBackingScale
        let moved = lastKnownBackingScale > 0 && abs(scale - lastKnownBackingScale) > 0.001
        lastKnownBackingScale = scale

        if client.supportsDynamicResolution {
            // Run on every screen event, not just a scale change: two 1x monitors
            // differ in the clamp a later resize applies.
            scheduleResolutionRequest(after: delay)
        } else if moved, let size = displayView.attachedDisplay?.displaySize {
            // No agent: the guest resolution is fixed, so honour the zoom on the
            // other side of the equation. Gated on a REAL scale change, so a move
            // between two same-scale monitors cannot snap back a window the user
            // resized.
            resizeToDisplay(size, recenter: false)
        }
    }

    // Request a matching guest resolution only at DISCRETE moments — never on the
    // continuous windowDidResize, which (during a live drag, or when a programmatic
    // resize fires it) creates the resize↔request oscillation.
    func windowDidEndLiveResize(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    // The three ways AppKit reports a display change, all funnelled into the same
    // idempotent handler because one drag does not reliably produce all three.
    // windowDidChangeScreen is kept because it is the only one that also fires for a
    // move between two SAME-scale monitors.
    func windowDidChangeScreen(_ notification: Notification) {
        screenChanged()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        screenChanged()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        scheduleResolutionRequest()
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        if hidesAfterFullScreen {
            hidesAfterFullScreen = false
            window?.orderOut(nil)
        }
        scheduleResolutionRequest()
    }

    // MARK: - Window lifecycle

    func windowDidBecomeKey(_ notification: Notification) {
        window?.makeFirstResponder(displayView)
        client.usbManager?.delegate = self
        refreshUSBMenu()
    }

    func windowDidResignKey(_ notification: Notification) {
        // Release any held input so it does not stay latched in the guest when the
        // user switches away, and restore the macOS cursor — the window is no longer
        // key, so updateHostCursorVisibility() shows it (covers same-app window
        // switches / miniaturize that don't deactivate the app).
        displayView.router.releaseAll()
        displayView.updateHostCursorVisibility()
    }

    func windowWillClose(_ notification: Notification) {
        pendingResolutionRequest?.cancel()
        pendingResolutionRequest = nil
        statisticsTimer?.invalidate()
        statisticsTimer = nil
        stopFileTransfers()
        transferTimer?.invalidate()
        transferTimer = nil
        for observer in notificationObservers { NotificationCenter.default.removeObserver(observer) }
        notificationObservers.removeAll()
        displayView.router.releaseAll()
        if isSessionWindow {
            closeDisplayWindows()
            client.disconnect()
        }
        displayView.detach()
        onClose?()
    }

    // MARK: - Copying files into the guest

    private func fileDragChanged(_ dragging: Bool) {
        guard !transferProgress.isActive else { return }   // the bar shows the copy
        if dragging {
            transferBarHide?.cancel()
            transferBar.show(.dragging)
        } else if transferBarHide == nil {
            transferBar.isHidden = true
        }
    }

    private func copyIntoGuest(_ urls: [URL]) {
        let isFolder = { (url: URL) in (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let files = urls.filter { !isFolder($0) }
        let folders = urls.count - files.count
        guard !files.isEmpty else {
            showTransferOutcome("Folders cannot be copied: drop the files in them, or a .zip of the folder",
                                failed: true)
            return
        }
        var id: ObjectIdentifier?
        let transfer = client.copyFilesToGuest(files, progress: { [weak self] sent, total in
            guard let self, let id else { return }
            self.transferProgress.update(id, sent: sent, total: total, now: CACurrentMediaTime())
        }, completion: { [weak self] error in
            guard let self, let id else { return }
            self.transfers[id] = nil
            self.transferProgress.finish(id, error: error)
            if !self.transferProgress.isActive {
                self.transferTimer?.invalidate()
                self.transferTimer = nil
                let outcome = self.transferProgress.outcome
                self.showTransferOutcome(outcome.text, failed: outcome.failed)
            }
        })
        guard let transfer else {
            showTransferOutcome("Not connected", failed: true)
            return
        }
        id = ObjectIdentifier(transfer)
        transfers[ObjectIdentifier(transfer)] = transfer
        transferProgress.start(ObjectIdentifier(transfer), files: files, foldersSkipped: folders)
        transferBarHide?.cancel()
        transferBarHide = nil
        refreshTransferBar()
        if transferTimer == nil {
            // .common, so it keeps ticking during live resize and menu tracking.
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.refreshTransferBar() }
            RunLoop.main.add(timer, forMode: .common)
            transferTimer = timer
        }
    }

    private func refreshTransferBar() {
        guard transferProgress.isActive else { return }
        let status = transferProgress.status(now: CACurrentMediaTime())
        transferBar.show(.copying(status.text, fraction: status.fraction))
    }

    private func stopFileTransfers() {
        for transfer in transfers.values { transfer.cancel() }
    }

    /// Shows how a copy ended for a few seconds (longer for an error).
    private func showTransferOutcome(_ text: String, failed: Bool) {
        transferBar.show(failed ? .failed(text) : .finished(text))
        transferBarHide?.cancel()
        let hide = DispatchWorkItem { [weak self] in
            guard let self, !self.transferProgress.isActive else { return }
            self.transferBar.isHidden = true
            self.transferBarHide = nil
        }
        transferBarHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + (failed ? 8 : 4), execute: hide)
    }

    // MARK: - Connection actions (responder chain targets)

    @objc func sendCtrlAltDel(_ sender: Any?) {
        guard let input = displayView.router.input else { return }
        // Left Ctrl (0x1D) + Left Alt (0x38) + Delete (extended 0xE053 → 0x153).
        let combo: [Int32] = [0x1D, 0x38, 0x153]
        for code in combo { input.send(.press, code: code) }
        for code in combo.reversed() { input.send(.release, code: code) }
    }

    @objc func releaseCursor(_ sender: Any?) {
        displayView.router.releaseAll()
    }

    // MARK: - Zoom menu (responder chain targets)
    //
    // Per-window, so these live here rather than on the app delegate. With no session
    // open nothing answers the selector and AppKit greys the submenu out.

    @objc func setDisplayZoom(_ sender: NSMenuItem) {
        guard let level = DisplayZoom(rawValue: sender.tag) else { return }
        apply(zoom: level)
    }

    @objc func zoomIn(_ sender: Any?) { apply(zoom: steppedZoom(by: 1)) }
    @objc func zoomOut(_ sender: Any?) { apply(zoom: steppedZoom(by: -1)) }

    /// The next rung for this window, resolved against its own screen — which is
    /// what turns `.automatic` into a percentage to step away from.
    private func steppedZoom(by direction: Int) -> DisplayZoom {
        DisplayScale.step(displayZoom, by: direction, backingScale: currentBackingScale)
    }

    private func apply(zoom: DisplayZoom) {
        displayZoom = zoom
        // Purely the seed for the next window; it does not reach any already open.
        Preferences.displayZoom = zoom
        applyZoomChange()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(sendCtrlAltDel(_:)), #selector(releaseCursor(_:)):
            return displayView.router.input != nil
        case #selector(showGuestDisplay(_:)):
            return menuItem.tag == monitorID || displayWindows[menuItem.tag] != nil
                || client.supportsDynamicResolution
        case #selector(setDisplayZoom(_:)):
            // Radio-style: exactly one level checked, recomputed on every menu open
            // so it tracks this window, including after ⌃⌘+ / ⌃⌘-.
            menuItem.state = (menuItem.tag == displayZoom.rawValue) ? .on : .off
            if menuItem.tag == DisplayZoom.automatic.rawValue {
                // Show what Automatic currently resolves to on this window's screen.
                let percent = Int((currentBackingScale * 100).rounded())
                menuItem.title = "\(DisplayZoom.automatic.title) (\(percent)%)"
            }
        case #selector(zoomIn(_:)):
            return steppedZoom(by: 1) != displayZoom
        case #selector(zoomOut(_:)):
            return steppedZoom(by: -1) != displayZoom
        default:
            break
        }
        return true
    }

    // MARK: - USB menu

    @objc func toggleUSBDevice(_ sender: NSMenuItem) {
        guard let device = sender.representedObject as? CSUSBDevice,
              let usb = client.usbManager else { return }
        if usb.isUsbDeviceConnected(device) {
            usb.disconnectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        } else {
            var message: NSString?
            guard usb.canRedirectUsbDevice(device, errorMessage: &message) else {
                presentTransientError((message as String?) ?? "This USB device cannot be redirected.")
                return
            }
            usb.connectUsbDevice(device) { [weak self] error in self?.handleUSBResult(error) }
        }
    }

    private func handleUSBResult(_ error: Error?) {
        DispatchQueue.main.async {
            if let error { self.presentTransientError(error.localizedDescription) }
            self.refreshUSBMenu()
        }
    }

    private func refreshUSBMenu() {
        // The USB submenu is shared app-wide; only the key window owns it, so
        // background windows' USB delegate callbacks don't retarget its items.
        guard window?.isKeyWindow == true, let menu = MainMenu.usbSubmenu else { return }
        menu.removeAllItems()
        guard let usb = client.usbManager else {
            menu.addItem(disabledItem("Not connected"))
            return
        }
        let devices = usb.usbDevices
        if devices.isEmpty {
            menu.addItem(disabledItem("No USB devices"))
            return
        }
        for device in devices {
            let item = NSMenuItem(title: label(for: device),
                                  action: #selector(toggleUSBDevice(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device
            item.state = usb.isUsbDeviceConnected(device) ? .on : .off
            menu.addItem(item)
        }
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func label(for device: CSUSBDevice) -> String {
        let name = device.name ?? device.usbProductName ?? "USB Device"
        return String(format: "%@ (%04lx:%04lx)", name, device.usbVendorId, device.usbProductId)
    }

    private func presentTransientError(_ message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "USB Redirection"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window)
    }
}

// MARK: - CSUSBManagerDelegate

extension SpiceWindowController: CSUSBManagerDelegate {
    func spiceUsbManager(_ usbManager: CSUSBManager, deviceAttached device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceRemoved device: CSUSBDevice) {
        DispatchQueue.main.async { self.refreshUSBMenu() }
    }

    func spiceUsbManager(_ usbManager: CSUSBManager, deviceError error: String, for device: CSUSBDevice) {
        DispatchQueue.main.async { self.presentTransientError(error) }
    }
}
