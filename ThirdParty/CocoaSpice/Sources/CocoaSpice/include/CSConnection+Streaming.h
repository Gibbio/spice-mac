//
// CSConnection+Streaming.h
//
// spice-mac fork addition (Apache-2.0, same as CocoaSpice).
//
// Audio and video settings an application can change while connected (the
// preferred codecs, the playout delay, the microphone) and a statistics
// snapshot of the connection, on top of spice-gtk patches 0010, 0012 and 0013
// (the CoreAudio backend) in spice-mac's deps/patches.
//

#import "CSConnection.h"
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Video codecs, with the values of SPICE's `SpiceVideoCodecType`.
typedef NS_ENUM(NSInteger, CSVideoCodec) {
    CSVideoCodecMJPEG = 1,
    CSVideoCodecVP8 = 2,
    CSVideoCodecH264 = 3,
    CSVideoCodecVP9 = 4,
    CSVideoCodecH265 = 5,
};

/// One video stream, see `-[CSConnection readStatisticsWithCompletion:]`.
@interface CSStreamStatistics : NSObject

@property (nonatomic, readonly) NSUInteger streamID;
@property (nonatomic, readonly) CSVideoCodec codec;
/// What decodes the stream: "VideoToolbox", "GStreamer" or "built-in".
@property (nonatomic, readonly, copy) NSString *decoder;
@property (nonatomic, readonly) CGSize size;
/// Frames since the stream was created: received, shown, arrived after their
/// display time, and dropped by the decoder.
@property (nonatomic, readonly) NSUInteger framesReceived;
@property (nonatomic, readonly) NSUInteger framesShown;
@property (nonatomic, readonly) NSUInteger framesLate;
@property (nonatomic, readonly) NSUInteger framesDropped;
/// Milliseconds between the last frame's arrival and its display time.
@property (nonatomic, readonly) NSInteger playoutDelay;
/// The delay aimed at when no audio is playing; 0 when the video follows the
/// server's timestamps.
@property (nonatomic, readonly) NSInteger playoutTarget;
/// Whether the video follows the audio clock (lip sync).
@property (nonatomic, readonly) BOOL audioSync;

@end

/// A snapshot of a connection, see `-[CSConnection readStatisticsWithCompletion:]`.
@interface CSConnectionStatistics : NSObject

/// Bytes received so far, by channel type ("display", "playback", "cursor", …).
@property (nonatomic, readonly) NSDictionary<NSString *, NSNumber *> *bytesReceived;
/// The main channel's smoothed TCP round-trip time in ms, or -1 when unknown.
/// Through a proxy, this is the round trip to the proxy.
@property (nonatomic, readonly) NSInteger roundTripTime;
/// The main channel's TLS version and cipher, nil without TLS.
@property (nonatomic, readonly, copy, nullable) NSString *tlsVersion;
@property (nonatomic, readonly, copy, nullable) NSString *tlsCipher;
/// Whether the client draws the mouse cursor (client mouse mode).
@property (nonatomic, readonly) BOOL clientMouseMode;
/// Whether the guest is playing sound.
@property (nonatomic, readonly) BOOL audioPlaying;
/// "Opus" or "raw PCM"; nil without a playback channel.
@property (nonatomic, readonly, copy, nullable) NSString *audioCodec;
/// The audio output's delay in ms, 0 until known: the audio buffered before
/// the output device plus the device's own latency.
@property (nonatomic, readonly) NSInteger audioDelay;
/// With the CoreAudio backend, -1 otherwise: the audio buffered before the
/// output device (ms, averaged over a second) and the buffer it aims at (ms,
/// grows after underruns), the device's latency (ms), how many times the output
/// ran dry, and how much audio was skipped to keep the delay down (ms).
@property (nonatomic, readonly) NSInteger audioBuffered;
@property (nonatomic, readonly) NSInteger audioBufferTarget;
@property (nonatomic, readonly) NSInteger audioDeviceLatency;
@property (nonatomic, readonly) NSInteger audioUnderruns;
@property (nonatomic, readonly) NSInteger audioSkipped;
/// Whether the guest is recording, whether or not it gets the microphone.
@property (nonatomic, readonly) BOOL guestRecording;
/// The video streams of every display.
@property (nonatomic, readonly) NSArray<CSStreamStatistics *> *streams;

@end

@interface CSConnection (Streaming)

/// The video codecs to ask the server for, first one preferred, as
/// `CSVideoCodec` numbers; nil leaves the server's own order. Applied to every
/// display channel when it opens, and at once to the open ones. Changing it
/// makes the server restart its running streams.
@property (atomic, copy, nullable) NSArray<NSNumber *> *preferredVideoCodecs;

/// How many ms after arrival a video frame is shown when no audio is playing;
/// 0 follows the server's timestamps, a negative value keeps
/// `SPICE_STREAM_PLAYOUT_MS` (default 50). Applied like `preferredVideoCodecs`.
@property (atomic) NSInteger streamPlayoutDelay;

/// Whether video follows the audio while it plays (in step with the sound, as
/// late as it is heard) rather than staying `streamPlayoutDelay` after arrival:
/// 1 yes, 0 no, a negative value keeps `SPICE_STREAM_AUDIO_SYNC` (default yes).
/// Applied like `streamPlayoutDelay`.
@property (atomic) NSInteger streamAudioSync;

/// Whether the guest may record from the Mac's microphone (CoreAudio backend
/// only). Default NO: the guest can start recording at any time, and gets
/// nothing while this is off. Applies at once.
@property (atomic) BOOL microphoneEnabled;

/// Collects the statistics on the SPICE thread and calls `completion` on the
/// main queue.
- (void)readStatisticsWithCompletion:(void (^)(CSConnectionStatistics *statistics))completion;

@end

NS_ASSUME_NONNULL_END
