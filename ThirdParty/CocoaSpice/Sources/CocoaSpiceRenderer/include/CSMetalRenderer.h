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

@import MetalKit;
@import CoreGraphics;

@protocol CSRenderSource;
@protocol CSRenderer;

NS_ASSUME_NONNULL_BEGIN

/// Simple platform independent renderer for CocoaSpice
@interface CSMetalRenderer : NSObject<MTKViewDelegate, CSRenderer>

/// Create a new renderer for a MTKView
/// @param mtkView The MetalKit View
- (nonnull instancetype)initWithMetalKitView:(nonnull MTKView *)mtkView;

/// Modify upscaler and downscaler settings
/// @param upscaler Upscaler to use
/// @param downscaler Downscaler to use
- (void)changeUpscaler:(MTLSamplerMinMagFilter)upscaler downscaler:(MTLSamplerMinMagFilter)downscaler;

/// spice-mac: measure how long each uploaded frame takes to reach the screen
/// (also on with SPICE_DEBUG, which logs it once a second). Main thread.
@property (nonatomic) BOOL collectsPresentStatistics;

/// spice-mac: running totals of those measurements, main thread: uploaded
/// frames that reached the screen, ones that never did, and the sum of their
/// upload-to-screen times in seconds. Sample them to get rates and averages.
@property (nonatomic, readonly) NSUInteger presentedFrameCount;
@property (nonatomic, readonly) NSUInteger missedFrameCount;
@property (nonatomic, readonly) CFTimeInterval presentLatencySum;

@end

NS_ASSUME_NONNULL_END
