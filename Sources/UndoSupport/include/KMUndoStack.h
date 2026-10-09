#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Owns the NSUndoManager KeePassKit registers tree changes with. Swift marks NSUndoManager as
/// main-actor only, but the loader edits the tree on its own actor; NSUndoManager works on any
/// thread when grouping by run-loop events is off, so this wrapper exposes it without that restriction.
@interface KMUndoStack : NSObject

/// Handed to KeePassKit through the tree delegate.
@property (nonatomic, readonly) NSUndoManager *manager;
@property (nonatomic, readonly) BOOL canUndo;
@property (nonatomic, readonly) BOOL canRedo;
@property (nonatomic, readonly, copy) NSString *undoActionName;
@property (nonatomic, readonly, copy) NSString *redoActionName;

- (instancetype)initWithLevels:(NSUInteger)levels NS_DESIGNATED_INITIALIZER;
/// A throwaway manager for changes that must not become undo steps (merges): it records into
/// groups that are never undone, so KeePassKit can register freely.
+ (instancetype)discardingStack;
- (instancetype)init NS_UNAVAILABLE;

- (void)enableRegistration;
- (void)disableRegistration;
- (void)beginGroup;
- (void)endGroupWithActionName:(NSString *)actionName;
- (void)undo;
- (void)redo;
- (void)removeAllActions;

@end

NS_ASSUME_NONNULL_END
