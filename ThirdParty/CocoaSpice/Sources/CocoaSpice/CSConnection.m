//
// Copyright © 2022 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

#import "CocoaSpice.h"
#import "CSConnection+Proxmox.h" // spice-mac fork addition
#import "CSConnection+Streaming.h" // spice-mac fork addition
#import "CSConnection+FileTransfer.h" // spice-mac fork addition
#import "CSChannel+Protected.h"
#import "CSCursor+Protected.h"
#import "CSDisplay+Protected.h"
#import "CSInput+Protected.h"
#import "CSSession+Protected.h"
#import "CSPort+Protected.h"
#if defined(WITH_USB_SUPPORT)
#import "CSUSBDevice+Protected.h"
#import "CSUSBManager+Protected.h"
#endif
#import <glib.h>
#import <spice-client.h>
#import <spice/vd_agent.h>
#import <netinet/tcp.h>

@interface CSConnection () <CSMonitorConfigSender>

@property (nonatomic, readwrite) BOOL isTLSOnly;
@property (nonatomic, readwrite) CSSession *session;
@property (nonatomic, readwrite) CSUSBManager *usbManager;
@property (nonatomic, readwrite) NSMutableArray<CSChannel *> *mutableChannels;
@property (nonatomic, readwrite) SpiceSession *spiceSession;
@property (nonatomic, readwrite) SpiceMainChannel *spiceMain;
@property (nonatomic, readwrite) SpiceAudio *spiceAudio;
// spice-mac: storage for CSConnection (Streaming)
@property (atomic, copy, nullable) NSArray<NSNumber *> *videoCodecsSetting;
@property (atomic) NSInteger playoutDelaySetting;
@property (atomic) BOOL microphoneSetting;
// spice-mac (multi-monitor): a config to send once every display's state is known
@property (nonatomic) BOOL monitorConfigPending;

@end

// spice-mac fork addition: see CSConnection+Streaming.h
@interface CSStreamStatistics ()
@property (nonatomic, readwrite) NSUInteger streamID;
@property (nonatomic, readwrite) CSVideoCodec codec;
@property (nonatomic, readwrite, copy) NSString *decoder;
@property (nonatomic, readwrite) CGSize size;
@property (nonatomic, readwrite) NSUInteger framesReceived;
@property (nonatomic, readwrite) NSUInteger framesShown;
@property (nonatomic, readwrite) NSUInteger framesLate;
@property (nonatomic, readwrite) NSUInteger framesDropped;
@property (nonatomic, readwrite) NSInteger playoutDelay;
@property (nonatomic, readwrite) NSInteger playoutTarget;
@property (nonatomic, readwrite) BOOL audioSync;
@end

@implementation CSStreamStatistics
@end

@interface CSConnectionStatistics ()
@property (nonatomic, readwrite) NSDictionary<NSString *, NSNumber *> *bytesReceived;
@property (nonatomic, readwrite) NSInteger roundTripTime;
@property (nonatomic, readwrite, copy, nullable) NSString *tlsVersion;
@property (nonatomic, readwrite, copy, nullable) NSString *tlsCipher;
@property (nonatomic, readwrite) BOOL clientMouseMode;
@property (nonatomic, readwrite) BOOL audioPlaying;
@property (nonatomic, readwrite, copy, nullable) NSString *audioCodec;
@property (nonatomic, readwrite) NSInteger audioDelay;
@property (nonatomic, readwrite) NSInteger audioBuffered;
@property (nonatomic, readwrite) NSInteger audioBufferTarget;
@property (nonatomic, readwrite) NSInteger audioDeviceLatency;
@property (nonatomic, readwrite) NSInteger audioUnderruns;
@property (nonatomic, readwrite) NSInteger audioSkipped;
@property (nonatomic, readwrite) BOOL guestRecording;
@property (nonatomic, readwrite) NSArray<CSStreamStatistics *> *streams;
@end

@implementation CSConnectionStatistics
@end

// spice-mac fork addition: see CSConnection+FileTransfer.h
@implementation CSFileTransfer {
    GCancellable *_cancellable;
}

- (instancetype)init {
    if (self = [super init]) {
        _cancellable = g_cancellable_new();
    }
    return self;
}

- (void)dealloc {
    g_object_unref(_cancellable);
}

- (GCancellable *)cancellable {
    return _cancellable;
}

- (void)cancel {
    g_cancellable_cancel(_cancellable);   // thread-safe
}

@end

/// The blocks of one copy, owned by spice-gtk's callbacks until it completes
@interface CSFileTransferCallbacks : NSObject
@property (nonatomic, copy) void (^progress)(int64_t sent, int64_t total);
@property (nonatomic, copy) void (^completion)(NSError * _Nullable error);
/// The first file's own error (SPICE thread): the copy's only says "Transferring
/// 1 files: 0 succeed, 0 cancelled, 1 failed"
@property (nonatomic, copy, nullable) NSString *fileError;
@end

@implementation CSFileTransferCallbacks
@end

@implementation CSConnection

static void cs_main_channel_event(SpiceChannel *channel, SpiceChannelEvent event,
                               gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    const GError *error = NULL;
    NSString *genericMsg = NSLocalizedString(@"An error occurred trying to connect to SPICE.", @"CSConnection");
    NSInteger code = kCSConnectionErrorNone;
    
    switch (event) {
        case SPICE_CHANNEL_OPENED:
            g_message("main channel: opened");
            [self.delegate spiceConnected:self];
            break;
        case SPICE_CHANNEL_SWITCHING:
            g_message("main channel: switching host");
            break;
        case SPICE_CHANNEL_CLOSED:
            /* this event is only sent if the channel was succesfully opened before */
            g_message("main channel: closed");
            spice_session_disconnect(self.spiceSession);
            break;
        case SPICE_CHANNEL_ERROR_IO:
        case SPICE_CHANNEL_ERROR_TLS:
        case SPICE_CHANNEL_ERROR_LINK:
        case SPICE_CHANNEL_ERROR_CONNECT:
        case SPICE_CHANNEL_ERROR_AUTH:
            error = spice_channel_get_error(channel);
            if (error && event != SPICE_CHANNEL_ERROR_CONNECT) {
                g_message("channel error: %s", error->message);
            }
            switch (event) {
                case SPICE_CHANNEL_ERROR_IO: code = kCSConnectionErrorIO; break;
                case SPICE_CHANNEL_ERROR_TLS:
                case SPICE_CHANNEL_ERROR_LINK:
                case SPICE_CHANNEL_ERROR_AUTH: code = kCSConnectionErrorAuthentication; break;
                case SPICE_CHANNEL_ERROR_CONNECT: code = kCSConnectionErrorConnect; break;
                default: code = kCSConnectionErrorUnknown; break;
            }
            [self.delegate spiceError:self code:code message:(error ? [NSString stringWithUTF8String:error->message] : genericMsg)];
            break;
        default:
            /* TODO: more sophisticated error handling */
            g_warning("unknown main channel event: %u", event);
            /* connection_disconnect(conn); */
            break;
    }
}

#pragma mark - Monitors config (spice-mac, multi-monitor)

// Every monitors config this client sends lists all the guest's displays.
// spice-vdagent-win (0.10) turns off a display that a config leaves out or sends
// as 0x0 with no depth, fails the whole config for one sent as 0x0 with a depth,
// and once it has turned a QXL display off it cannot turn it back on until the
// guest restarts: every later config fails, for the other displays too. So a
// display the application has not resized goes out as the guest has it, and
// nothing goes out until the guest's state of every display is known: it reported
// the display's monitor, or there was still none a second after the channel
// opened: then the display is off, unless it has a surface, whose size it is
// sent at (sending it as off would turn it off). spice-gtk's own table is only
// written then, since
// spice-gtk also sends it by itself whenever the agent (re)connects. SPICE thread.
static void cs_sync_monitors(CSConnection *self, BOOL send)
{
    SpiceMainChannel *main = self.spiceMain;
    NSMutableArray<CSDisplay *> *displays = [NSMutableArray array];
    gboolean agent = FALSE;

    if (main == NULL) {
        return;
    }
    for (CSChannel *channel in self.channels) {
        if (![channel isKindOfClass:CSDisplay.class]) {
            continue;
        }
        CSDisplay *display = (CSDisplay *)channel;
        if (!display.guestStateKnown && CGRectIsNull(display.requestedBounds)) {
            SPICE_DEBUG("[CocoaSpice] monitors config held: display %ld not known yet", display.channelID);
            self.monitorConfigPending = self.monitorConfigPending || send;
            return;
        }
        [displays addObject:display];
    }
    for (CSDisplay *display in displays) {
        int id = (int)display.monitorID;
        CGRect bounds = CGRectIsNull(display.requestedBounds) ? display.guestBounds : display.requestedBounds;

        if (id < 0 || id >= 16) { // spice-gtk's MAX_DISPLAY
            continue;
        }
        if (!display.isEnabled || CGRectIsNull(bounds) || CGRectIsEmpty(bounds)) {
            spice_main_channel_update_display_enabled(main, id, FALSE, FALSE);
        } else {
            spice_main_channel_update_display_enabled(main, id, TRUE, FALSE);
            spice_main_channel_update_display(main, id, MAX(0, bounds.origin.x), MAX(0, bounds.origin.y),
                                              bounds.size.width, bounds.size.height, FALSE);
        }
    }
    if (send || self.monitorConfigPending) {
        self.monitorConfigPending = NO;
        g_object_get(main, "agent-connected", &agent, NULL);
        if (agent) {
            spice_main_channel_send_monitor_config(main);
        }
    }
}

- (void)sendMonitorConfig {
    cs_sync_monitors(self, YES);
}

static gboolean cs_display_state_timeout(gpointer data)
{
    dispatch_block_t timeout = (__bridge dispatch_block_t)data;

    timeout();
    return G_SOURCE_REMOVE;
}

static void cs_display_state_timeout_release(gpointer data)
{
    CFRelease(data);
}

// A display channel just opened: the server sends its surface and monitor right
// away when the guest has the display on; without them a second later, it is off.
// With a surface but still no monitor, it counts as on at the surface's size.
static void cs_watch_display_state(CSConnection *self, CSDisplay *display)
{
    __weak CSConnection *weakSelf = self;
    __weak CSDisplay *weakDisplay = display;
    dispatch_block_t timeout = ^{
        CSConnection *connection = weakSelf;
        CSDisplay *timedOut = weakDisplay;
        SpiceDisplayPrimary primary;
        if (connection == nil || timedOut == nil || timedOut.guestStateKnown) {
            return;
        }
        if (spice_display_channel_get_primary(timedOut.spiceChannel, 0, &primary)) {
            SPICE_DEBUG("[CocoaSpice] display %ld has no monitor yet, but a %dx%d surface",
                        timedOut.channelID, primary.width, primary.height);
            timedOut.guestBounds = CGRectMake(0, 0, primary.width, primary.height);
        } else {
            SPICE_DEBUG("[CocoaSpice] display %ld has no monitor: off", timedOut.channelID);
        }
        timedOut.guestStateKnown = YES;
        cs_sync_monitors(connection, NO);
    };
    GSource *source = g_timeout_source_new(1000);
    g_source_set_callback(source, cs_display_state_timeout, (void *)CFBridgingRetain(timeout),
                          cs_display_state_timeout_release);
    g_source_attach(source, CSMain.sharedInstance.glibMainContext);
    g_source_unref(source);
}

static void cs_display_monitors(SpiceChannel *channel, GParamSpec *pspec,
                             gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    GArray *cfgs = NULL;
    CSDisplay *display = nil;
    
    g_object_get(channel,
                 "monitors", &cfgs,
                 NULL);
    g_return_if_fail(cfgs != NULL);
    
    for (CSChannel *candidate in self.channels) {
        if (candidate.spiceChannel == channel) {
            assert([candidate isKindOfClass:CSDisplay.class]);
            display = (CSDisplay *)candidate;
            break;
        }
    }
    
    assert(display);
    
    SPICE_DEBUG("[CocoaSpice] display %ld now has %d monitors", display.channelID, cfgs->len);
    // spice-mac (security): never g_assert on attacker-controlled SPICE fields. A
    // multi-head monitors config (len >= 2) is protocol-legal; the original
    // g_assert(cfgs->len == 1) aborted the whole process on such a config (a remote
    // DoS from a malicious/compromised guest). This app is single-display per
    // channel, so any non-empty config means the display exists — create/update it
    // and let cs_update_monitor_area (CSDisplay.m) pick out our head's geometry by
    // id. Treat an empty config as the display being gone.
    //
    // spice-mac (multi-monitor): the guest's bounds for the display come from the
    // first head. A display goes away only once it was there: the config is also
    // empty for a moment while a channel starts. When it comes back it is created
    // again.
    if (cfgs->len > 0) {
        SpiceDisplayMonitorConfig *head = &g_array_index(cfgs, SpiceDisplayMonitorConfig, 0);
        display.guestBounds = CGRectMake(head->x, head->y, head->width, head->height);
        display.guestStateKnown = YES;
        if (display.hasInitialConfig) {
            [self.delegate spiceDisplayUpdated:self display:display];
        } else {
            [self.delegate spiceDisplayCreated:self display:display];
            display.hasInitialConfig = YES;
        }
    } else {
        display.guestBounds = CGRectNull;
        if (display.hasInitialConfig) {
            display.requestedBounds = CGRectNull;
            display.hasInitialConfig = NO;
            [self.delegate spiceDisplayDestroyed:self display:display];
        }
    }
    cs_sync_monitors(self, NO);
    
    g_clear_pointer(&cfgs, g_array_unref);
}

static void cs_main_agent_update(SpiceChannel *main, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    gboolean agent_connected = false;
    CSConnectionAgentFeature features = kCSConnectionAgentFeatureNone;
    
    g_object_get(main, "agent-connected", &agent_connected, NULL);
    SPICE_DEBUG("[CocoaSpice] SPICE agent connected: %d", agent_connected);
    if (agent_connected) {
        if (spice_main_channel_agent_test_capability(SPICE_MAIN_CHANNEL(main), VD_AGENT_CAP_MONITORS_CONFIG)) {
            features |= kCSConnectionAgentFeatureMonitorsConfig;
        }
        [self.delegate spiceAgentConnected:self supportingFeatures:features];
    } else {
        [self.delegate spiceAgentDisconnected:self];
    }
}

static void cs_port_opened(SpiceChannel *channel, GParamSpec *pspec,
                           gpointer user)
{
    CSConnection *self = (__bridge CSConnection *)user;
    CSPort *port = nil;
    
    for (CSPort *candidate in self.channels) {
        if (candidate.spiceChannel == channel) {
            assert([candidate isKindOfClass:CSPort.class]);
            port = (CSPort *)candidate;
            break;
        }
    }
    
    assert(port);
    SPICE_DEBUG("[CocoaSpice] port %s opened:%d", [port.name cStringUsingEncoding:NSASCIIStringEncoding], port.isOpen);

    if (port.isOpen) {
        [self.delegate spiceForwardedPortOpened:self port:port];
    } else {
        [self.delegate spiceForwardedPortClosed:self port:port];
    }
}

// spice-mac: apply CSConnection (Streaming)'s video settings to a display
// channel; SPICE thread. Before the channel is open the server's capabilities
// are unknown and spice-gtk refuses the codecs: cs_display_channel_event()
// applies them again then.
static void cs_apply_video_settings(CSConnection *self, SpiceChannel *channel,
                                    BOOL applyCodecs, BOOL applyPlayout)
{
    NSArray<NSNumber *> *codecs = self.videoCodecsSetting;
    NSInteger delay = self.playoutDelaySetting;

    if (applyCodecs && codecs.count > 0) {
        gint types[SPICE_VIDEO_CODEC_TYPE_ENUM_END];
        gsize n = 0;
        GError *err = NULL;

        for (NSNumber *codec in codecs) {
            if (n < G_N_ELEMENTS(types)) {
                types[n++] = (gint)codec.integerValue;
            }
        }
        if (!spice_display_channel_change_preferred_video_codec_types(channel, types, n, &err)) {
            SPICE_DEBUG("[CocoaSpice] preferred video codecs not set: %s", err->message);
            g_clear_error(&err);
        }
    }
    if (applyPlayout && delay >= 0) {
        spice_display_channel_set_stream_playout(channel, (gint)delay);
    }
}

// spice-mac: the CoreAudio backend's "record-enabled" (spice-gtk patch 0013);
// SPICE thread. Other backends have no such property and keep their behaviour.
static void cs_apply_microphone_setting(CSConnection *self)
{
    SpiceAudio *audio = self.spiceAudio;

    if (audio != NULL && g_object_class_find_property(G_OBJECT_GET_CLASS(audio), "record-enabled")) {
        g_object_set(audio, "record-enabled", (gboolean)self.microphoneSetting, NULL);
    }
}

static void cs_display_channel_event(SpiceChannel *channel, SpiceChannelEvent event,
                                     gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;

    if (event == SPICE_CHANNEL_OPENED) {
        cs_apply_video_settings(self, channel, YES, YES);
        for (CSChannel *candidate in self.channels) {
            if (candidate.spiceChannel == channel && [candidate isKindOfClass:CSDisplay.class]) {
                cs_watch_display_state(self, (CSDisplay *)candidate);
                break;
            }
        }
    }
}

static void cs_channel_new(SpiceSession *s, SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    int chid;
    
    g_object_get(channel, "channel-id", &chid, NULL);
    SPICE_DEBUG("new channel (#%d)", chid);
    
    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        SPICE_DEBUG("new main channel");
        g_assert(!self.spiceMain); // should only be 1 main channel
        self.spiceMain = SPICE_MAIN_CHANNEL(channel);
        SPICE_DEBUG("[CocoaSpice] %s:%d", __FUNCTION__, __LINE__);
        g_signal_connect(channel, "channel-event",
                         G_CALLBACK(cs_main_channel_event), (__bridge void *)self);
        g_signal_connect(channel, "main_agent_update",
                         G_CALLBACK(cs_main_agent_update), (__bridge void *)self);
    }
    
    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        SPICE_DEBUG("new display channel (#%d)", chid);
        CSDisplay *display = [[CSDisplay alloc] initWithChannel:SPICE_DISPLAY_CHANNEL(channel)];
        display.spiceMain = self.spiceMain;
        display.monitorConfigSender = self;
        [self.mutableChannels addObject:display];
        g_signal_connect_after(channel, "notify::monitors",
                               G_CALLBACK(cs_display_monitors), (__bridge void *)self);
        g_signal_connect(channel, "channel-event",
                         G_CALLBACK(cs_display_channel_event), (__bridge void *)self);
        // spice-mac (multi-monitor): no `display.isEnabled = YES` here: it marked
        // each display enabled at 0x0 in spice-gtk's table, and a config with a
        // second display at 0x0 is one spice-vdagent-win rejects whole, the first
        // display's new size included. See cs_sync_monitors().
        // find and connect to any existing cursor channel
        for (CSChannel *candidate in self.channels) {
            if ([candidate isKindOfClass:CSCursor.class] && candidate.channelID == chid) {
                CSCursor *cursor = (CSCursor *)candidate;
                display.cursor = cursor;
                break;
            }
        }
        spice_channel_connect(channel);
    }
    
    if (SPICE_IS_CURSOR_CHANNEL(channel)) {
        SPICE_DEBUG("new cursor channel (#%d)", chid);
        CSCursor *cursor = [[CSCursor alloc] initWithChannel:SPICE_CURSOR_CHANNEL(channel)];
        cursor.spiceMain = self.spiceMain;
        [self.mutableChannels addObject:cursor];
        // find and connect to any existing display channel
        for (CSChannel *candidate in self.channels) {
            if ([candidate isKindOfClass:CSDisplay.class] && candidate.channelID == chid) {
                CSDisplay *display = (CSDisplay *)candidate;
                display.cursor = cursor;
                break;
            }
        }
        spice_channel_connect(channel);
    }
    
    if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        SPICE_DEBUG("new inputs channel");
        CSInput *input = [[CSInput alloc] initWithChannel:SPICE_INPUTS_CHANNEL(channel)];
        input.spiceMain = self.spiceMain;
        [self.mutableChannels addObject:input];
        [self.delegate spiceInputAvailable:self input:input];
        spice_channel_connect(channel);
    }
    
    if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {
        SPICE_DEBUG("new audio channel");
        if (self.audioEnabled) {
            self.spiceAudio = spice_audio_get(s, [CSMain sharedInstance].glibMainContext);
            cs_apply_microphone_setting(self);
            spice_channel_connect(channel);
        } else {
            SPICE_DEBUG("audio disabled");
        }
    }

    if (SPICE_IS_PORT_CHANNEL(channel)) {
        SPICE_DEBUG("new port channel");
        CSPort *port = [[CSPort alloc] initWithChannel:SPICE_PORT_CHANNEL(channel)];
        port.spiceMain = self.spiceMain;
        port.connection = self;
        [self.mutableChannels addObject:port];
        g_signal_connect_after(channel, "notify::port-opened",
                               G_CALLBACK(cs_port_opened), (__bridge void *)self);
        spice_channel_connect(channel);
    }
}

static void cs_channel_destroy(SpiceSession *s, SpiceChannel *channel, gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    int chid;
    
    g_object_get(channel, "channel-id", &chid, NULL);
    if (SPICE_IS_MAIN_CHANNEL(channel)) {
        SPICE_DEBUG("[CocoaSpice] %s:%d", __FUNCTION__, __LINE__);
        SPICE_DEBUG("zap main channel");
        self.spiceMain = NULL;
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_main_channel_event), (__bridge void *)self);
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_main_agent_update), (__bridge void *)self);
    }
    
    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
        SPICE_DEBUG("zap display channel (#%d)", chid);
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_display_monitors), (__bridge void *)self);
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_display_channel_event), (__bridge void *)self);
    }
    
    if (SPICE_IS_INPUTS_CHANNEL(channel)) {
        SPICE_DEBUG("zap inputs channel");
    }
    
    if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {
        SPICE_DEBUG("zap audio channel");
        self.spiceAudio = NULL;
    }
    
    if (SPICE_IS_PORT_CHANNEL(channel)) {
        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_port_opened), (__bridge void *)self);
    }
    
    for (NSInteger i = self.mutableChannels.count-1; i >= 0; i--) {
        CSChannel* wrap = self.mutableChannels[i];
        if (wrap.spiceChannel == channel) {
            [self.mutableChannels removeObjectAtIndex:i];
            if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
                [self.delegate spiceDisplayDestroyed:self display:(CSDisplay *)wrap];
            } else if (SPICE_IS_PORT_CHANNEL(channel)) {
                [self.delegate spiceForwardedPortClosed:self port:(CSPort *)wrap];
            } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {
                [self.delegate spiceInputUnavailable:self input:(CSInput *)wrap];
            }
        }
    }

    // ideally we do this in cs_connection_destroy() but because that happens so late, it opens us up
    // to retain cycles if the caller waits for `spiceDisconnect:` to cleanup.
    if (self.channels.count == 0) {
        [self.delegate spiceDisconnected:self];
    }
}

static void cs_connection_destroy(SpiceSession *session,
                               gpointer data)
{
    CSConnection *self = (__bridge CSConnection *)data;
    SPICE_DEBUG("spice connection destroyed");
    // this happens pretty late--after every SpiceChannel has been deallocated
}

- (void)setHost:(NSString *)host {
    g_object_set(self.spiceSession, "host", [host UTF8String], NULL);
}

- (NSString *)host {
    gchar *strhost;
    g_object_get(self.spiceSession, "host", &strhost, NULL);
    NSString *nshost = [NSString stringWithUTF8String:strhost];
    g_free(strhost);
    return nshost;
}

- (void)setPort:(NSString *)port {
    g_object_set(self.spiceSession, self.isTLSOnly ? "tls-port" : "port", [port UTF8String], NULL);
}

- (NSString *)port {
    gchar *strhost;
    g_object_get(self.spiceSession, self.isTLSOnly ? "tls-port" : "port", &strhost, NULL);
    NSString *nshost = [NSString stringWithUTF8String:strhost];
    g_free(strhost);
    return nshost;
}

- (void)setUnixSocketURL:(NSURL *)unixSocketURL {
    g_object_set(self.spiceSession, "unix-path", unixSocketURL.relativePath.UTF8String, NULL);
    _unixSocketURL = unixSocketURL;
}

- (void)setTlsServerPublicKey:(NSData *)tlsServerPublicKey {
    GByteArray *array = NULL;

    if (!tlsServerPublicKey) {
        goto end;
    }
    array = g_byte_array_new();
    [tlsServerPublicKey enumerateByteRangesUsingBlock:^(const void * _Nonnull bytes, NSRange byteRange, BOOL * _Nonnull stop) {
        g_byte_array_append(array, bytes, (guint)byteRange.length);
    }];
    _tlsServerPublicKey = tlsServerPublicKey;
end:
    g_object_set(self.spiceSession, "pubkey", array, NULL);
    if (array) {
        g_byte_array_unref(array);
    }
}

- (NSString *)password {
    gchar *value;
    g_object_get(self.spiceSession, "password", &value, NULL);
    if (!value) {
        return nil;
    }
    NSString *nsvalue = [NSString stringWithUTF8String:value];
    g_free(value);
    return nsvalue;
}

- (void)setPassword:(NSString *)password {
    g_object_set(self.spiceSession, "password", [password UTF8String], NULL);
}

- (NSArray<CSChannel *> *)channels {
    return self.mutableChannels;
}

- (NSArray<CSDisplay *> *)displays {
    __block NSMutableArray<CSDisplay *> *displays = [NSMutableArray array];
    [CSMain.sharedInstance syncWith:^{
        for (CSChannel *channel in self.mutableChannels) {
            if ([channel isKindOfClass:CSDisplay.class]) {
                [displays addObject:(CSDisplay *)channel];
            }
        }
    }];
    [displays sortUsingComparator:^NSComparisonResult(CSDisplay *a, CSDisplay *b) {
        return a.monitorID < b.monitorID ? NSOrderedAscending
            : a.monitorID > b.monitorID ? NSOrderedDescending : NSOrderedSame;
    }];
    return displays;
}

- (void)setSpiceMain:(SpiceMainChannel *)spiceMain {
    SpiceMainChannel *old = _spiceMain;
    _spiceMain = spiceMain ? g_object_ref(spiceMain) : NULL;
    for (CSChannel *channel in self.channels) {
        channel.spiceMain = spiceMain;
    }
    if (old) {
        [CSMain.sharedInstance syncWith:^{
            g_object_unref(old);
        }];
    }
}

- (void)dealloc {
    SPICE_DEBUG("[CocoaSpice] %s:%d", __FUNCTION__, __LINE__);
    SpiceSession *spiceSession = self.spiceSession;
    gpointer data = (__bridge void *)self;

    [CSMain.sharedInstance syncWith:^{
        g_signal_handlers_disconnect_by_func(spiceSession, G_CALLBACK(cs_channel_new), data);
        g_signal_handlers_disconnect_by_func(spiceSession, G_CALLBACK(cs_channel_destroy), data);
        g_signal_handlers_disconnect_by_func(spiceSession, G_CALLBACK(cs_connection_destroy), data);
        for (NSInteger i = self.channels.count-1; i >= 0; i--) {
            CSChannel* wrap = self.channels[i];
            cs_channel_destroy(spiceSession, wrap.spiceChannel, data);
        }
        if (self.spiceMain) {
            cs_channel_destroy(spiceSession, SPICE_CHANNEL(self.spiceMain), data);
        }
        g_object_unref(spiceSession);
    }];
}

- (void)finishInit {
    SPICE_DEBUG("[CocoaSpice] %s:%d", __FUNCTION__, __LINE__);
    self.playoutDelaySetting = -1; // spice-mac: see CSConnection (Streaming)
    g_signal_connect(self.spiceSession, "channel-new",
                     G_CALLBACK(cs_channel_new), (__bridge void *)self);
    g_signal_connect(self.spiceSession, "channel-destroy",
                     G_CALLBACK(cs_channel_destroy), (__bridge void *)self);
    g_signal_connect(self.spiceSession, "disconnected",
                     G_CALLBACK(cs_connection_destroy), (__bridge void *)self);
    
#if defined(WITH_USB_SUPPORT)
    SpiceUsbDeviceManager *manager = spice_usb_device_manager_get(self.spiceSession, NULL);
    g_assert(manager != NULL);
    self.usbManager = [[CSUSBManager alloc] initWithUsbDeviceManager:manager];
#endif
    self.session = [[CSSession alloc] initWithSession:self.spiceSession];
    self.mutableChannels = [NSMutableArray<CSChannel *> array];
}

- (instancetype)initWithHost:(NSString *)host port:(NSString *)port {
    if (self = [super init]) {
        self.spiceSession = spice_session_new();
        self.host = host;
        self.port = port;
        [self finishInit];
    }
    return self;
}

- (instancetype)initWithHost:(NSString *)host tlsPort:(NSString *)tlsPort serverPublicKey:(NSData *)serverPublicKey {
    gchar *channels[] = { "all", NULL };

    if (self = [super init]) {
        self.spiceSession = spice_session_new();
        self.isTLSOnly = YES;
        self.host = host;
        self.port = tlsPort;
        self.tlsServerPublicKey = serverPublicKey;
        g_object_set(self.spiceSession, "secure-channels", channels, NULL);
        [self finishInit];
    }
    return self;
}

- (instancetype)initWithUnixSocketFile:(NSURL *)socketFile {
    if (self = [super init]) {
        self.spiceSession = spice_session_new();
        self.unixSocketURL = socketFile;
        [self finishInit];
    }
    return self;
}

- (BOOL)connect {
    return spice_session_connect(self.spiceSession);
}

- (void)disconnect {
    spice_session_disconnect(self.spiceSession);
}

#pragma mark - Proxmox (spice-mac fork addition)

- (void)setProxy:(NSString *)proxy ca:(NSString *)caPEM certSubject:(NSString *)certSubject {
    if (proxy != nil) {
        // Empty string clears any previously configured proxy.
        g_object_set(self.spiceSession, "proxy", proxy.UTF8String, NULL);
    }
    if (caPEM != nil) {
        GByteArray *array = g_byte_array_new();
        NSData *data = [caPEM dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length > 0) {
            g_byte_array_append(array, data.bytes, (guint)data.length);
        }
        // spice-gtk parses this blob as PEM text; NUL-terminate so it is safe to
        // treat as a C string, matching how virt-viewer hands over the CA.
        const guint8 nul = 0;
        g_byte_array_append(array, &nul, 1);
        g_object_set(self.spiceSession, "ca", array, NULL);
        g_byte_array_unref(array);
    }
    if (certSubject != nil) {
        // Verify the peer by certificate subject instead of hostname/pubkey: the
        // Proxmox node cluster cert subject is what matches, not the proxy/token.
        g_object_set(self.spiceSession,
                     "cert-subject", certSubject.UTF8String,
                     "verify", SPICE_SESSION_VERIFY_SUBJECT,
                     NULL);
    }
}

#pragma mark - Streaming (spice-mac fork addition)

- (NSArray<NSNumber *> *)preferredVideoCodecs {
    return self.videoCodecsSetting;
}

- (void)setPreferredVideoCodecs:(NSArray<NSNumber *> *)codecs {
    self.videoCodecsSetting = codecs;
    [self applyVideoSettingsToOpenDisplaysWithCodecs:YES playout:NO];
}

- (NSInteger)streamPlayoutDelay {
    return self.playoutDelaySetting;
}

- (void)setStreamPlayoutDelay:(NSInteger)milliseconds {
    self.playoutDelaySetting = milliseconds;
    [self applyVideoSettingsToOpenDisplaysWithCodecs:NO playout:YES];
}

- (BOOL)microphoneEnabled {
    return self.microphoneSetting;
}

- (void)setMicrophoneEnabled:(BOOL)enabled {
    self.microphoneSetting = enabled;
    __weak CSConnection *weakSelf = self;
    [CSMain.sharedInstance asyncWith:^{
        CSConnection *strongSelf = weakSelf;
        if (strongSelf != nil) {
            cs_apply_microphone_setting(strongSelf);
        }
    }];
}

- (void)applyVideoSettingsToOpenDisplaysWithCodecs:(BOOL)codecs playout:(BOOL)playout {
    __weak CSConnection *weakSelf = self;
    [CSMain.sharedInstance asyncWith:^{
        CSConnection *strongSelf = weakSelf;
        for (CSChannel *channel in strongSelf.channels) {
            if ([channel isKindOfClass:CSDisplay.class]) {
                cs_apply_video_settings(strongSelf, channel.spiceChannel, codecs, playout);
            }
        }
    }];
}

/// The smoothed TCP round-trip time of a channel's socket in ms, or -1
static NSInteger cs_channel_round_trip_time(SpiceChannel *channel)
{
    GSocket *socket = NULL;
    struct tcp_connection_info info;
    socklen_t len = sizeof(info);
    NSInteger rtt = -1;

    g_object_get(channel, "socket", &socket, NULL);
    if (socket == NULL) {
        return -1;
    }
    if (getsockopt(g_socket_get_fd(socket), IPPROTO_TCP, TCP_CONNECTION_INFO, &info, &len) == 0) {
        rtt = info.tcpi_srtt;
    }
    g_object_unref(socket);
    return rtt;
}

- (void)readStatisticsWithCompletion:(void (^)(CSConnectionStatistics *))completion {
    SpiceSession *session = g_object_ref(self.spiceSession);
    __weak CSConnection *weakSelf = self;

    [CSMain.sharedInstance asyncWith:^{
        CSConnectionStatistics *stats = [CSConnectionStatistics new];
        NSMutableDictionary<NSString *, NSNumber *> *bytes = [NSMutableDictionary dictionary];
        NSMutableArray<CSStreamStatistics *> *streams = [NSMutableArray array];
        GList *channels = spice_session_get_channels(session);

        stats.roundTripTime = -1;
        stats.audioBuffered = stats.audioBufferTarget = stats.audioDeviceLatency = -1;
        stats.audioUnderruns = stats.audioSkipped = -1;
        SpiceAudio *audio = weakSelf.spiceAudio;
        if (audio != NULL && g_object_class_find_property(G_OBJECT_GET_CLASS(audio), "playback-buffer")) {
            guint buffered = 0, target = 0, latency = 0, underruns = 0, skipped = 0;
            gboolean recording = FALSE;

            g_object_get(audio, "playback-buffer", &buffered, "playback-target", &target,
                         "output-latency", &latency,
                         "playback-underruns", &underruns, "playback-skipped", &skipped,
                         "recording", &recording, NULL);
            stats.audioBuffered = buffered;
            stats.audioBufferTarget = target;
            stats.audioDeviceLatency = latency;
            stats.audioUnderruns = underruns;
            stats.audioSkipped = skipped;
            stats.guestRecording = recording;
        }
        for (GList *l = channels; l != NULL; l = l->next) {
            SpiceChannel *channel = l->data;
            gint type = 0;
            gulong read = 0;

            g_object_get(channel, "channel-type", &type, "total-read-bytes", &read, NULL);
            NSString *name = @(spice_channel_type_to_string(type) ?: "other");
            bytes[name] = @(bytes[name].unsignedLongLongValue + read);

            if (SPICE_IS_MAIN_CHANNEL(channel)) {
                const gchar *version = NULL, *cipher = NULL;
                gint mouseMode = 0;

                if (spice_channel_get_tls_info(channel, &version, &cipher)) {
                    stats.tlsVersion = version ? @(version) : nil;
                    stats.tlsCipher = cipher ? @(cipher) : nil;
                }
                g_object_get(channel, "mouse-mode", &mouseMode, NULL);
                stats.clientMouseMode = mouseMode == SPICE_MOUSE_MODE_CLIENT;
                stats.roundTripTime = cs_channel_round_trip_time(channel);
            } else if (SPICE_IS_DISPLAY_CHANNEL(channel)) {
                SpiceDisplayStreamStats st[16];
                guint n = spice_display_channel_get_stream_stats(channel, st, G_N_ELEMENTS(st));

                for (guint i = 0; i < n; i++) {
                    CSStreamStatistics *stream = [CSStreamStatistics new];
                    stream.streamID = st[i].id;
                    stream.codec = st[i].codec_type;
                    stream.decoder = st[i].decoder ? @(st[i].decoder) : @"?";
                    stream.size = CGSizeMake(st[i].width, st[i].height);
                    stream.framesReceived = st[i].frames_received;
                    stream.framesShown = st[i].frames_shown;
                    stream.framesLate = st[i].frames_late;
                    stream.framesDropped = st[i].frames_dropped;
                    stream.playoutDelay = st[i].playout_delay;
                    stream.playoutTarget = st[i].playout_target;
                    stream.audioSync = st[i].audio_sync;
                    [streams addObject:stream];
                }
            } else if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {
                SpicePlaybackStats playback;

                spice_playback_channel_get_stats(SPICE_PLAYBACK_CHANNEL(channel), &playback);
                stats.audioPlaying = playback.active;
                stats.audioCodec = playback.mode == SPICE_AUDIO_DATA_MODE_OPUS ? @"Opus" :
                                   playback.mode == SPICE_AUDIO_DATA_MODE_RAW ? @"raw PCM" : @"?";
                stats.audioDelay = playback.delay;
            }
        }
        g_list_free(channels);
        g_object_unref(session);
        stats.bytesReceived = bytes;
        stats.streams = streams;
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(stats);
        });
    }];
}

#pragma mark - File transfer (spice-mac fork addition)

/* SPICE thread */
static void cs_file_transfer_progress(goffset sent, goffset total, gpointer data)
{
    CSFileTransferCallbacks *callbacks = (__bridge CSFileTransferCallbacks *)data;
    void (^progress)(int64_t, int64_t) = callbacks.progress;

    dispatch_async(dispatch_get_main_queue(), ^{
        progress(sent, total);
    });
}

/* SPICE thread: a file of a copy ended */
static void cs_file_transfer_task_finished(SpiceFileTransferTask *task, GError *error, gpointer data)
{
    CSFileTransferCallbacks *callbacks = (__bridge CSFileTransferCallbacks *)data;

    if (error != NULL && callbacks.fileError == nil && !g_error_matches(error, G_IO_ERROR, G_IO_ERROR_CANCELLED)) {
        callbacks.fileError = @(error->message);
    }
}

static void cs_file_transfer_release(gpointer data, GClosure *closure)
{
    CFBridgingRelease(data);
}

/* SPICE thread: spice-gtk announces each file of a copy, from within
 * spice_main_channel_file_copy_async() */
static void cs_file_transfer_new(SpiceMainChannel *main, SpiceFileTransferTask *task, gpointer data)
{
    g_signal_connect_data(task, "finished", G_CALLBACK(cs_file_transfer_task_finished),
                          (void *)CFBridgingRetain((__bridge id)data), cs_file_transfer_release, 0);
}

static void cs_file_transfer_release_report(gpointer data)
{
    CFRelease(data);
}

static gboolean cs_file_transfer_report(gpointer data)
{
    dispatch_block_t report = (__bridge dispatch_block_t)data;

    report();
    return G_SOURCE_REMOVE;
}

/* SPICE thread; called once, after the last progress */
static void cs_file_transfer_done(GObject *source, GAsyncResult *result, gpointer data)
{
    CSFileTransferCallbacks *callbacks = (__bridge_transfer CSFileTransferCallbacks *)data;
    GError *err = NULL;
    BOOL ok = spice_main_channel_file_copy_finish(SPICE_MAIN_CHANNEL(source), result, &err);
    BOOL cancelled = !ok && g_error_matches(err, G_IO_ERROR, G_IO_ERROR_CANCELLED);
    NSString *message = ok ? nil : (err != NULL ? @(err->message) : @"The file transfer failed.");
    gint code = err != NULL ? err->code : 0;

    g_clear_error(&err);
    // The files' own "finished" handlers can run right after this, in the same
    // signal emission: report from the next main-context iteration.
    dispatch_block_t report = ^{
        NSError *error = nil;
        if (cancelled) {
            error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSUserCancelledError userInfo:nil];
        } else if (message != nil) {
            error = [NSError errorWithDomain:@"CSFileTransfer" code:code
                                    userInfo:@{NSLocalizedDescriptionKey: callbacks.fileError ?: message}];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            callbacks.completion(error);
        });
    };
    GSource *idle = g_idle_source_new();
    g_source_set_callback(idle, cs_file_transfer_report, (void *)CFBridgingRetain(report),
                          cs_file_transfer_release_report);
    g_source_attach(idle, CSMain.sharedInstance.glibMainContext);
    g_source_unref(idle);
}

- (CSFileTransfer *)copyFilesToGuest:(NSArray<NSURL *> *)files
                            progress:(void (^)(int64_t, int64_t))progress
                          completion:(void (^)(NSError *))completion {
    CSFileTransfer *transfer = [CSFileTransfer new];
    CSFileTransferCallbacks *callbacks = [CSFileTransferCallbacks new];
    GCancellable *cancellable = g_object_ref([transfer cancellable]);
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    __weak CSConnection *weakSelf = self;

    callbacks.progress = progress;
    callbacks.completion = completion;
    for (NSURL *file in files) {
        if (file.isFileURL) {
            [paths addObject:file.path];
        }
    }
    [CSMain.sharedInstance asyncWith:^{
        SpiceMainChannel *main = weakSelf.spiceMain;

        if (main == NULL || paths.count == 0) {
            NSString *message = main == NULL ? @"Not connected." : @"There is no file to copy.";
            NSError *error = [NSError errorWithDomain:@"CSFileTransfer" code:0
                                             userInfo:@{NSLocalizedDescriptionKey: message}];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(error);
            });
            g_object_unref(cancellable);
            return;
        }
        GFile **sources = g_new0(GFile *, paths.count + 1);
        for (NSUInteger i = 0; i < paths.count; i++) {
            sources[i] = g_file_new_for_path(paths[i].fileSystemRepresentation);
        }
        void *data = (__bridge_retained void *)callbacks;
        gulong announced = g_signal_connect(main, "new-file-transfer", G_CALLBACK(cs_file_transfer_new), data);
        spice_main_channel_file_copy_async(main, sources, G_FILE_COPY_NONE, cancellable,
                                           cs_file_transfer_progress, data,
                                           cs_file_transfer_done, data);
        g_signal_handler_disconnect(main, announced);
        for (NSUInteger i = 0; i < paths.count; i++) {
            g_object_unref(sources[i]);   // the transfer tasks hold their own
        }
        g_free(sources);
        g_object_unref(cancellable);
    }];
    return transfer;
}

@end
