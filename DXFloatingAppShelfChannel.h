#import "DXFloatingAppShelfState.h"

FOUNDATION_EXPORT const char *DXFloatingShelfChangedName;
// SpringBoard alone publishes. Two pinned banks and a commit word prevent torn reads.
FOUNDATION_EXPORT BOOL DXPublishFloatingShelf(NSDictionary *snapshot);
FOUNDATION_EXPORT NSDictionary *DXReadFloatingShelf(void);
