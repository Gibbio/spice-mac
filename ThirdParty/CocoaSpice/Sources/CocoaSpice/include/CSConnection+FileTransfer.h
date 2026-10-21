//
// CSConnection+FileTransfer.h
//
// spice-mac fork addition (Apache-2.0, same as CocoaSpice).
//
// Copying files from the host into the guest through the SPICE agent
// (spice-gtk's spice_main_channel_file_copy_async), for drag and drop.
//

#import "CSConnection.h"

NS_ASSUME_NONNULL_BEGIN

/// One copy of files to the guest, see `-[CSConnection copyFilesToGuest:progress:completion:]`.
@interface CSFileTransfer : NSObject

/// Stops the copy; its completion then reports `NSUserCancelledError`.
- (void)cancel;

@end

@interface CSConnection (FileTransfer)

/// Copies regular files (not folders) into the guest, where its agent saves
/// them (spice-vdagent on Windows: on the Desktop). Needs the agent; without it,
/// or with file transfer disabled in the guest, the completion reports why.
///
/// `progress` receives the bytes sent so far and the total of all the files;
/// both blocks are called on the main queue, `completion` exactly once, with nil
/// on success.
- (CSFileTransfer *)copyFilesToGuest:(NSArray<NSURL *> *)files
                            progress:(void (^)(int64_t sent, int64_t total))progress
                          completion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
