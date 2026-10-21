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

#import "CSDisplay.h"
#import "CSMonitorConfigSender.h"
#import "CSRenderer.h"

typedef struct _SpiceDisplayChannel SpiceDisplayChannel;

NS_ASSUME_NONNULL_BEGIN

@interface CSDisplay ()

@property (nonatomic, nullable, weak) id<CSMonitorConfigSender> monitorConfigSender;

/// spice-mac (multi-monitor), SPICE thread: the bounds `-requestResolution:` asked
/// for, CGRectNull until then and once the guest turns the display off.
@property (nonatomic) CGRect requestedBounds;

/// spice-mac (multi-monitor), SPICE thread: the guest's bounds for this display,
/// CGRectNull while it has none (off, or not known yet).
@property (nonatomic) CGRect guestBounds;

/// spice-mac (multi-monitor), SPICE thread: whether `guestBounds` is known: the
/// guest reported the display's monitor, or had none a second after the channel
/// opened.
@property (nonatomic) BOOL guestStateKnown;

/// True if currently rendering from GL backend
@property (nonatomic, readonly) BOOL isGLEnabled;

/// SPICE display channel
@property (nonatomic, nullable, readonly) SpiceDisplayChannel *channel;

@property (nonatomic, nullable, weak, readwrite) CSCursor *cursor;

@property (nonatomic) id<MTLDevice> device;

/// Set to true in CSConnection after seeing the first monitor config
@property (nonatomic) BOOL hasInitialConfig;

/// Create a new display for a given channel and monitor
/// @param channel Display channel
/// @param monitorID Monitor in the channel
- (instancetype)initWithChannel:(SpiceDisplayChannel *)channel NS_DESIGNATED_INITIALIZER;

/// spice-mac: paint the current framebuffer for a renderer that has just attached.
/// Dispatches onto the SPICE context (CSMain) and, if the primary surface already
/// exists, (re)builds the Metal canvas if it wasn't built yet (the device only
/// arrives when a renderer attaches, which can race after primary-create) and
/// repaints — so the view isn't blank on connect until the first server draw.
- (void)refreshContentsForNewRenderer;

@end

NS_ASSUME_NONNULL_END
