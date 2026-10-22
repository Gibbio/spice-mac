// SPDX-License-Identifier: MIT
import Foundation
import DisplayScale

/// App preferences, backed by `UserDefaults`.
enum Preferences {
    private static let hideHostCursorKey = "HideHostCursor"

    /// When true, the macOS cursor is hidden over the display so only the guest
    /// cursor shows. Default off. Changing it posts `.hideHostCursorChanged`.
    static var hideHostCursor: Bool {
        get { UserDefaults.standard.bool(forKey: hideHostCursorKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: hideHostCursorKey)
            NotificationCenter.default.post(name: .hideHostCursorChanged, object: nil)
        }
    }

    private static let shareClipboardKey = "ShareClipboard"

    /// Whether to share the clipboard with the guest (both directions). Default
    /// ON (matches virt-viewer and the working behavior). Disable it when
    /// connecting to an untrusted VM — while on, anything you copy on the Mac is
    /// sent to the guest. Takes effect on the next connection.
    static var shareClipboard: Bool {
        get { (UserDefaults.standard.object(forKey: shareClipboardKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: shareClipboardKey) }
    }

    private static let trashAfterUseKey = "TrashConnectionFileAfterUse"

    /// Whether to move a `.vv` connection file to the Trash after using it to
    /// connect. Proxmox SPICE tickets are single-use and the file also carries the
    /// cluster CA, so keeping it around is pointless and a mild secret-hygiene risk.
    /// Default ON. It goes to the Trash (recoverable), not a permanent delete.
    static var trashConnectionFileAfterUse: Bool {
        get { (UserDefaults.standard.object(forKey: trashAfterUseKey) as? Bool) ?? true }
        set { UserDefaults.standard.set(newValue, forKey: trashAfterUseKey) }
    }

    private static let displayZoomKey = "DisplayZoom"

    /// The zoom level a NEWLY opened window starts at: host physical pixels per
    /// guest pixel. A seed, NOT a live global — zoom belongs to the window (see
    /// `SpiceWindowController.displayZoom`), so writing this notifies nobody.
    /// Default `.automatic` (zoom = backingScaleFactor), and raw 0 == `.automatic`,
    /// so a missing key reads as automatic.
    static var displayZoom: DisplayZoom {
        get { DisplayZoom(rawValue: UserDefaults.standard.integer(forKey: displayZoomKey)) ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: displayZoomKey) }
    }
}

extension Preferences {
    private static let preferH264VideoKey = "PreferH264Video"

    /// Whether to ask the server for H.264 video, decoded by VideoToolbox, instead
    /// of MJPEG. Default off: the node then does the encoding — in software (x264,
    /// from gstreamer1.0-plugins-ugly) unless set up for VA-API, see
    /// docs/server-side-video.md — and a node without an H.264 encoder keeps
    /// sending MJPEG. Applies to open connections at once; changing it posts
    /// `.videoSettingsChanged`.
    static var preferH264Video: Bool {
        get { UserDefaults.standard.bool(forKey: preferH264VideoKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: preferH264VideoKey)
            NotificationCenter.default.post(name: .videoSettingsChanged, object: nil)
        }
    }

    private static let videoDelayKey = "VideoDelay"

    /// How long after arrival a streamed frame is shown while no audio plays.
    /// Applies like `preferH264Video`.
    static var videoDelay: VideoDelay {
        get { VideoDelay(rawValue: UserDefaults.standard.integer(forKey: videoDelayKey)) ?? .standard }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: videoDelayKey)
            NotificationCenter.default.post(name: .videoSettingsChanged, object: nil)
        }
    }

    private static let syncVideoToAudioKey = "SyncVideoToAudio"

    /// Whether video follows the audio while it plays: in step with the sound,
    /// and so as late as it is heard (~85 ms on the built-in output, ~280 with
    /// AirPods), pausing when the output device changes. Default off: desktop
    /// sound is mostly short alerts, and video then stays `videoDelay` after
    /// arrival, the sound coming after it. Applies like `preferH264Video`.
    static var syncVideoToAudio: Bool {
        get { UserDefaults.standard.bool(forKey: syncVideoToAudioKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: syncVideoToAudioKey)
            NotificationCenter.default.post(name: .videoSettingsChanged, object: nil)
        }
    }

    /// SPICE_PREFERRED_VIDEO_CODECS / SPICE_STREAM_PLAYOUT_MS /
    /// SPICE_STREAM_AUDIO_SYNC in the launch environment take precedence over the
    /// three settings above (for testing); the menu items are disabled then.
    static let videoCodecsFromEnvironment = ProcessInfo.processInfo.environment["SPICE_PREFERRED_VIDEO_CODECS"] != nil
    static let videoDelayFromEnvironment = ProcessInfo.processInfo.environment["SPICE_STREAM_PLAYOUT_MS"] != nil
    static let audioSyncFromEnvironment = ProcessInfo.processInfo.environment["SPICE_STREAM_AUDIO_SYNC"] != nil

    private static let shareMicrophoneKey = "ShareMicrophone"

    /// Whether the guest may record from the Mac's microphone. Default off: a
    /// guest can start recording at any time and nothing would tell the user;
    /// with it on, macOS asks once whether SpiceMac may use the microphone.
    /// Applies to open connections at once; changing it posts
    /// `.microphoneSettingChanged`.
    static var shareMicrophone: Bool {
        get { UserDefaults.standard.bool(forKey: shareMicrophoneKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: shareMicrophoneKey)
            NotificationCenter.default.post(name: .microphoneSettingChanged, object: nil)
        }
    }

    private static let showStatisticsKey = "ShowStatistics"

    /// Whether each window shows the statistics overlay. Default off. Changing it
    /// posts `.showStatisticsChanged`.
    static var showStatistics: Bool {
        get { UserDefaults.standard.bool(forKey: showStatisticsKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: showStatisticsKey)
            NotificationCenter.default.post(name: .showStatisticsChanged, object: nil)
        }
    }
}

/// Connection ▸ Video Delay: how long after arrival a streamed frame is shown
/// while no audio is playing (spice-gtk patch 0007), in ms. Longer absorbs more
/// network jitter, shorter lags less. With audio playing, the video follows the
/// audio instead, for lip sync.
enum VideoDelay: Int, CaseIterable {
    case lowest = 30
    case standard = 50
    case smoother = 80

    var title: String {
        switch self {
        case .lowest:   return "30 ms (Lowest Latency)"
        case .standard: return "50 ms (Default)"
        case .smoother: return "80 ms (Smoother)"
        }
    }

    /// The median click-to-screen time we measured on a LAN, MJPEG, 1280×720.
    var toolTip: String {
        switch self {
        case .lowest:   return "Click to screen in our LAN test: median 128 ms."
        case .standard: return "Click to screen in our LAN test: median 154 ms."
        case .smoother: return "Click to screen in our LAN test: median 185 ms. "
            + "More room for network jitter, e.g. on Wi-Fi."
        }
    }
}

extension Notification.Name {
    static let hideHostCursorChanged = Notification.Name("SpiceMac.hideHostCursorChanged")
    static let videoSettingsChanged = Notification.Name("SpiceMac.videoSettingsChanged")
    static let showStatisticsChanged = Notification.Name("SpiceMac.showStatisticsChanged")
    static let microphoneSettingChanged = Notification.Name("SpiceMac.microphoneSettingChanged")
}
