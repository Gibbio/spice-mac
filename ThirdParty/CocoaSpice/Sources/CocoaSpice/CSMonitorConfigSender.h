//
// CSMonitorConfigSender.h
//
// spice-mac fork addition (Apache-2.0, same as CocoaSpice).
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends the monitors config of all the connection's displays (multi-monitor;
/// CSConnection.m explains why a display never sends its own).
@protocol CSMonitorConfigSender <NSObject>

/// SPICE thread.
- (void)sendMonitorConfig;

@end

NS_ASSUME_NONNULL_END
