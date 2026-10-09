#import "KMUndoStack.h"

@interface KMUndoStack ()
@property (nonatomic) NSUInteger levels;
/// Our own action names: KeePassKit sets its own names ("Set Title") while undoing, which would
/// replace the manager's. Every group holds a marker action, so no group is ever empty and these
/// stacks stay in step with the manager's.
@property (nonatomic) NSMutableArray<NSString *> *undoNames;
@property (nonatomic) NSMutableArray<NSString *> *redoNames;
@end

@implementation KMUndoStack

- (instancetype)initWithLevels:(NSUInteger)levels {
    self = [super init];
    if (self) {
        _levels = levels;
        _undoNames = [NSMutableArray array];
        _redoNames = [NSMutableArray array];
        _manager = [[NSUndoManager alloc] init];
        _manager.groupsByEvent = NO;
        _manager.levelsOfUndo = levels;
    }
    return self;
}

+ (instancetype)discardingStack {
    KMUndoStack *stack = [[self alloc] initWithLevels:1];
    stack.manager.groupsByEvent = YES;
    return stack;
}

- (BOOL)canUndo { return self.manager.canUndo && self.undoNames.count > 0; }
- (BOOL)canRedo { return self.manager.canRedo && self.redoNames.count > 0; }
- (NSString *)undoActionName { return self.undoNames.lastObject ?: @""; }
- (NSString *)redoActionName { return self.redoNames.lastObject ?: @""; }

- (void)enableRegistration { [self.manager enableUndoRegistration]; }
- (void)disableRegistration { [self.manager disableUndoRegistration]; }

- (void)beginGroup {
    [self.manager beginUndoGrouping];
    [self.manager registerUndoWithTarget:self selector:@selector(marker:) object:nil];
}

/// Undoing or redoing a group runs this; registering it again puts the marker into the opposite group.
- (void)marker:(id)sender {
    [self.manager registerUndoWithTarget:self selector:@selector(marker:) object:nil];
}

- (void)endGroupWithActionName:(NSString *)actionName {
    [self.manager setActionName:actionName];
    [self.manager endUndoGrouping];
    [self.undoNames addObject:actionName];
    [self.redoNames removeAllObjects];
    while (self.undoNames.count > self.levels) {
        [self.undoNames removeObjectAtIndex:0];
    }
}

- (void)undo {
    if (!self.canUndo) {
        return;
    }
    [self.manager undo];
    [self.redoNames addObject:self.undoNames.lastObject];
    [self.undoNames removeLastObject];
}

- (void)redo {
    if (!self.canRedo) {
        return;
    }
    [self.manager redo];
    [self.undoNames addObject:self.redoNames.lastObject];
    [self.redoNames removeLastObject];
}

/// NSUndoManager's removeAllActions also turns registration back on; keep it as it was.
- (void)removeAllActions {
    BOOL wasEnabled = self.manager.isUndoRegistrationEnabled;
    [self.manager removeAllActions];
    [self.undoNames removeAllObjects];
    [self.redoNames removeAllObjects];
    if (!wasEnabled) {
        [self.manager disableUndoRegistration];
    }
}

@end
