#import "DXClipboardStore.h"
#import "DXPrefsManager.h"
#import "common.h"
#import <sqlite3.h>
#import <ImageIO/ImageIO.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *const kDXClipboardHistoryKey = @"history";
static NSString *const kDXClipboardFavoritesKey = @"favorites";

// 与 Kayoko 的 kKayokoHistoryKey* 完全一致（迁移时直接按原键复制）。

@interface DXClipboardStore () {
    sqlite3 *_database;
}
@property(nonatomic, copy) NSString *databasePath;
@property(nonatomic, copy) NSString *imagesDirectoryPath;
@property(nonatomic, copy) NSString *imagesMirrorDirectoryPath;
@property(nonatomic, strong) NSFileManager *fileManager;
@end

@implementation DXClipboardStore

+ (instancetype)sharedStore {
    static DXClipboardStore *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
    });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _databasePath = kClipboardDatabasePath;
        _imagesDirectoryPath = kClipboardImagesPath;
        _imagesMirrorDirectoryPath = kClipboardImagesMirrorPath;
        _fileManager = [NSFileManager defaultManager];
    }
    return self;
}

- (void)dealloc {
    if (_database) {
        sqlite3_close(_database);
        _database = NULL;
    }
}

#pragma mark - Paths / directories

- (NSString *)imagesPath {
    return self.imagesDirectoryPath;
}

- (NSString *)imagesMirrorPath {
    return self.imagesMirrorDirectoryPath;
}

- (BOOL)ensureDirectory:(NSString *)path {
    if (!path.length) return NO;
    if ([self.fileManager fileExistsAtPath:path]) return YES;
    return [self.fileManager createDirectoryAtPath:path
                        withIntermediateDirectories:YES
                                         attributes:nil
                                              error:nil];
}

#pragma mark - Database

- (BOOL)prepareDatabase {
    if (_database) return YES;

    NSString *dir = [self.databasePath stringByDeletingLastPathComponent];
    if (![self ensureDirectory:dir]) return NO;

    if (sqlite3_open(self.databasePath.UTF8String, &_database) != SQLITE_OK) {
        NSLog(@"[TypeX][Clipboard] sqlite3_open failed: %s", sqlite3_errmsg(_database));
        sqlite3_close(_database);
        _database = NULL;
        return NO;
    }

    // WAL 提升并发读（app 进程只读打开不必等待写锁）。
    sqlite3_exec(_database, "PRAGMA journal_mode=WAL", NULL, NULL, NULL);
    sqlite3_busy_timeout(_database, 3000);

    static const char *schema =
        "CREATE TABLE IF NOT EXISTS history_items ("
        " id INTEGER PRIMARY KEY AUTOINCREMENT,"
        " history_key TEXT NOT NULL,"
        " bundle_identifier TEXT NOT NULL,"
        " content TEXT NOT NULL,"
        " image_name TEXT NOT NULL,"
        " image_width INTEGER NOT NULL DEFAULT 0,"
        " image_height INTEGER NOT NULL DEFAULT 0,"
        " image_byte_count INTEGER NOT NULL DEFAULT 0,"
        " rich_text_uti TEXT NULL,"
        " rich_text_name TEXT NOT NULL DEFAULT '',"
        " has_link INTEGER NOT NULL DEFAULT 0,"
        " created_at REAL NOT NULL,"
        " updated_at REAL NOT NULL,"
        " sequence INTEGER NOT NULL,"
        " tag_uuid TEXT NULL,"
        " note TEXT NULL,"
        " search_index_version INTEGER NOT NULL DEFAULT 0"
        ");"
        "CREATE UNIQUE INDEX IF NOT EXISTS history_items_unique_content "
        " ON history_items(history_key, content);"
        "CREATE INDEX IF NOT EXISTS history_items_ordered "
        " ON history_items(history_key, sequence DESC);";

    char *error = NULL;
    if (sqlite3_exec(_database, schema, NULL, NULL, &error) != SQLITE_OK) {
        NSLog(@"[TypeX][Clipboard] schema prepare failed: %s", error ? error : "?");
        if (error) sqlite3_free(error);
        return NO;
    }

    [self ensureDirectory:self.imagesDirectoryPath];
    [self ensureDirectory:self.imagesMirrorDirectoryPath];
    return YES;
}

- (BOOL)executeStatement:(const char *)sql withBindings:(NSArray *)bindings {
    if (!_database) return NO;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) != SQLITE_OK) return NO;

    for (int i = 0; i < bindings.count; i++) {
        id value = bindings[i];
        int index = i + 1;
        if ([value isKindOfClass:[NSNull class]] || value == nil) {
            sqlite3_bind_null(statement, index);
        } else if ([value isKindOfClass:[NSNumber class]]) {
            sqlite3_bind_double(statement, index, [value doubleValue]);
        } else if ([value isKindOfClass:[NSString class]]) {
            sqlite3_bind_text(statement, index, [value UTF8String], -1, SQLITE_TRANSIENT);
        } else if ([value isKindOfClass:[NSData class]]) {
            sqlite3_bind_blob(statement, index, [value bytes], (int)[value length], SQLITE_TRANSIENT);
        } else {
            sqlite3_bind_null(statement, index);
        }
    }

    int result = sqlite3_step(statement);
    sqlite3_finalize(statement);
    return result == SQLITE_DONE;
}

- (sqlite3_int64)nextSequence {
    if (!_database) return 1;
    sqlite3_stmt *statement = NULL;
    sqlite3_int64 sequence = 1;
    if (sqlite3_prepare_v2(_database, "SELECT COALESCE(MAX(sequence), 0) + 1 FROM history_items", -1, &statement, NULL) == SQLITE_OK) {
        if (sqlite3_step(statement) == SQLITE_ROW) {
            sequence = sqlite3_column_int64(statement, 0);
        }
    }
    sqlite3_finalize(statement);
    return sequence;
}

#pragma mark - Add / trim

- (void)addItemWithHistoryKey:(NSString *)historyKey
            bundleIdentifier:(NSString *)bundleIdentifier
                     content:(NSString *)content
                   imageName:(nullable NSString *)imageName
                  imageWidth:(NSUInteger)imageWidth
                 imageHeight:(NSUInteger)imageHeight
                    hasLink:(BOOL)hasLink
                  capturedAt:(NSTimeInterval)capturedAt {
    if (![self prepareDatabase]) return;
    if (!historyKey.length) historyKey = kDXClipboardHistoryKey;
    content = content ?: @"";
    if (content.length == 0 && imageName.length == 0) return;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    sqlite3_int64 sequence = [self nextSequence];

    // 去重提升：同 (key, content) 先删除，再插入新序列号（Kayoko 同款行为）。
    [self executeStatement:"DELETE FROM history_items WHERE history_key = ? AND content = ?"
                 withBindings:@[ historyKey, content ]];

    [self executeStatement:
        "INSERT INTO history_items "
        "(history_key, bundle_identifier, content, image_name, image_width, image_height, "
        " image_byte_count, rich_text_uti, rich_text_name, has_link, created_at, updated_at, "
        " sequence, tag_uuid, note, search_index_version) "
        "VALUES (?, ?, ?, ?, ?, ?, 0, NULL, '', ?, ?, ?, ?, NULL, NULL, 0)"
                  withBindings:@[
                      historyKey,
                      bundleIdentifier.length ? bundleIdentifier : @"unknown",
                      content,
                      imageName.length ? imageName : @"",
                      @(imageWidth),
                      @(imageHeight),
                      @(hasLink),
                      @(capturedAt > 0 ? capturedAt : now),
                      @(now),
                      @(sequence),
                  ]];

    [self trimHistoryKey:historyKey];
}

- (void)trimHistoryKey:(NSString *)historyKey {
    NSUInteger limit = kClipboardMaxCountDefault;
    id stored = [DXPrefsManager.sharedInstance getValueForKey:kClipboardMaxCountKey];
    if ([stored respondsToSelector:@selector(unsignedIntegerValue)]) {
        limit = [stored unsignedIntegerValue];
    }
    if (limit == 0) limit = kClipboardMaxCountDefault;
    if ([historyKey isEqualToString:kDXClipboardFavoritesKey]) return; // 收藏不淘汰

    // 删除超出上限的最旧序列号，同时收集其图片名。
    sqlite3_stmt *statement = NULL;
    const char *sql = "SELECT id, image_name FROM history_items "
                      "WHERE history_key = ? ORDER BY sequence DESC LIMIT -1 OFFSET ?";
    if (sqlite3_prepare_v2(_database, sql, -1, &statement, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(statement, 1, historyKey.UTF8String, -1, SQLITE_TRANSIENT);
    sqlite3_bind_int64(statement, 2, (sqlite3_int64)limit);

    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        [ids addObject:@(sqlite3_column_int64(statement, 0))];
        const unsigned char *name = sqlite3_column_text(statement, 1);
        if (name) [images addObject:@((const char *)name)];
    }
    sqlite3_finalize(statement);

    for (NSNumber *itemID in ids) {
        [self executeStatement:"DELETE FROM history_items WHERE id = ?" withBindings:@[ itemID ]];
    }
    for (NSString *imageName in images) {
        if (imageName.length) [self removeImageNamed:imageName];
    }
}

#pragma mark - Query

- (NSArray<NSDictionary *> *)itemsForHistoryKey:(NSString *)historyKey
                                      searchText:(nullable NSString *)searchText
                                           limit:(NSUInteger)limit {
    if (![self prepareDatabase]) return @[];
    if (!historyKey.length) historyKey = kDXClipboardHistoryKey;

    NSMutableString *sql = [NSMutableString stringWithString:
        @"SELECT id, history_key, bundle_identifier, content, image_name, "
        @" image_width, image_height, has_link, created_at "
        @"FROM history_items WHERE history_key = ?"];
    NSMutableArray *bindings = [NSMutableArray arrayWithObject:historyKey];
    if (searchText.length) {
        [sql appendString:@" AND content LIKE ? COLLATE NOCASE"];
        [bindings addObject:[NSString stringWithFormat:@"%%%@%%", searchText]];
    }
    [sql appendString:@" ORDER BY sequence DESC LIMIT ?"];
    [bindings addObject:@(limit ?: 200)];

    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, sql.UTF8String, -1, &statement, NULL) != SQLITE_OK) return @[];

    for (int i = 0; i < bindings.count; i++) {
        id value = bindings[i];
        int index = i + 1;
        if ([value isKindOfClass:[NSString class]]) {
            sqlite3_bind_text(statement, index, [value UTF8String], -1, SQLITE_TRANSIENT);
        } else if ([value isKindOfClass:[NSNumber class]]) {
            sqlite3_bind_int64(statement, index, (sqlite3_int64)[value integerValue]);
        }
    }

    NSMutableArray *items = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        const unsigned char *historyKeyText = sqlite3_column_text(statement, 1);
        const unsigned char *bundleText = sqlite3_column_text(statement, 2);
        const unsigned char *contentText = sqlite3_column_text(statement, 3);
        const unsigned char *imageNameText = sqlite3_column_text(statement, 4);
        item[@"id"] = @(sqlite3_column_int64(statement, 0));
        item[@"history_key"] = historyKeyText ? @((const char *)historyKeyText) : @"history";
        item[@"bundle_identifier"] = bundleText ? @((const char *)bundleText) : @"unknown";
        item[@"content"] = contentText ? @((const char *)contentText) : @"";
        item[@"image_name"] = imageNameText ? @((const char *)imageNameText) : @"";
        item[@"image_width"] = @(sqlite3_column_int64(statement, 5));
        item[@"image_height"] = @(sqlite3_column_int64(statement, 6));
        item[@"has_link"] = @(sqlite3_column_int64(statement, 7) != 0);
        item[@"created_at"] = @(sqlite3_column_double(statement, 8));
        [items addObject:item];
    }
    sqlite3_finalize(statement);
    return items;
}

#pragma mark - Favorite / delete / clear

- (void)setFavorite:(BOOL)favorite
            historyKey:(NSString *)historyKey
               content:(NSString *)content {
    if (!content.length) return;
    [self prepareDatabase];

    if (favorite) {
        // 查找原记录（可能来自 history 或 favorites），整体搬移。
        NSArray *items = [self itemsForHistoryKey:historyKey searchText:nil limit:200];
        NSDictionary *found = nil;
        for (NSDictionary *item in items) {
            if ([item[@"content"] isEqual:content]) { found = item; break; }
        }
        if (!found) return;
        [self executeStatement:"DELETE FROM history_items WHERE history_key = ? AND content = ?"
                     withBindings:@[ historyKey, content ]];
        [self addItemWithHistoryKey:kDXClipboardFavoritesKey
                  bundleIdentifier:found[@"bundle_identifier"]
                           content:content
                         imageName:found[@"image_name"]
                        imageWidth:[found[@"image_width"] unsignedIntegerValue]
                       imageHeight:[found[@"image_height"] unsignedIntegerValue]
                          hasLink:[found[@"has_link"] boolValue]
                        capturedAt:[found[@"created_at"] doubleValue]];
    } else {
        NSArray *items = [self itemsForHistoryKey:kDXClipboardFavoritesKey searchText:nil limit:200];
        NSDictionary *found = nil;
        for (NSDictionary *item in items) {
            if ([item[@"content"] isEqual:content]) { found = item; break; }
        }
        if (!found) return;
        [self executeStatement:"DELETE FROM history_items WHERE history_key = ? AND content = ?"
                     withBindings:@[ kDXClipboardFavoritesKey, content ]];
        [self addItemWithHistoryKey:kDXClipboardHistoryKey
                  bundleIdentifier:found[@"bundle_identifier"]
                           content:content
                         imageName:found[@"image_name"]
                        imageWidth:[found[@"image_width"] unsignedIntegerValue]
                       imageHeight:[found[@"image_height"] unsignedIntegerValue]
                          hasLink:[found[@"has_link"] boolValue]
                        capturedAt:[found[@"created_at"] doubleValue]];
    }
}

- (void)deleteItemWithID:(NSInteger)itemID {
    [self prepareDatabase];
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, "SELECT image_name FROM history_items WHERE id = ?", -1, &statement, NULL) != SQLITE_OK) return;
    sqlite3_bind_int64(statement, 1, (sqlite3_int64)itemID);
    NSString *imageName = nil;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(statement, 0);
        if (name) imageName = @((const char *)name);
    }
    sqlite3_finalize(statement);

    [self executeStatement:"DELETE FROM history_items WHERE id = ?" withBindings:@[ @(itemID) ]];
    if (imageName.length) [self removeImageNamed:imageName];
}

- (void)clearHistoryKey:(NSString *)historyKey {
    if (!historyKey.length) historyKey = kDXClipboardHistoryKey;
    [self prepareDatabase];

    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database,
        "SELECT image_name FROM history_items WHERE history_key = ? AND image_name <> ''",
        -1, &statement, NULL) != SQLITE_OK) return;
    sqlite3_bind_text(statement, 1, historyKey.UTF8String, -1, SQLITE_TRANSIENT);
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(statement, 0);
        if (name) [images addObject:@((const char *)name)];
    }
    sqlite3_finalize(statement);

    [self executeStatement:"DELETE FROM history_items WHERE history_key = ?" withBindings:@[ historyKey ]];
    for (NSString *imageName in images) {
        if (imageName.length) [self removeImageNamed:imageName];
    }
}

- (NSUInteger)countForHistoryKey:(NSString *)historyKey {
    if (![self prepareDatabase]) return 0;
    if (!historyKey.length) historyKey = kDXClipboardHistoryKey;
    sqlite3_stmt *statement = NULL;
    NSUInteger count = 0;
    if (sqlite3_prepare_v2(_database, "SELECT COUNT(*) FROM history_items WHERE history_key = ?", -1, &statement, NULL) == SQLITE_OK) {
        sqlite3_bind_text(statement, 1, historyKey.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(statement) == SQLITE_ROW) count = (NSUInteger)sqlite3_column_int64(statement, 0);
    }
    sqlite3_finalize(statement);
    return count;
}

#pragma mark - Images

- (nullable NSString *)saveImageData:(NSData *)imageData extension:(NSString *)extension {
    if (!imageData.length) return nil;
    [self prepareDatabase];

    // 内容寻址命名（SHA-256 前 16 字节）：相同图片数据得到相同文件名。
    // App 采集队列和 SB 轮询可能对同一次复制各入库一次，
    // UNIQUE(history_key, content) 以 content=imageName 去重，因此文件名
    // 必须由内容决定，否则同一张图会生成两个随机名、产生两条重复记录。
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(imageData.bytes, (CC_LONG)imageData.length, digest);
    NSMutableString *name = [NSMutableString stringWithCapacity:32 + 4];
    for (NSUInteger i = 0; i < 16; i++) {
        [name appendFormat:@"%02x", digest[i]];
    }
    if (extension.length) [name appendFormat:@".%@", extension];

    NSString *primaryPath = [self.imagesDirectoryPath stringByAppendingPathComponent:name];
    if (![imageData writeToFile:primaryPath options:NSDataWritingAtomic error:nil]) return nil;

    // 镜像到 jbroot 前缀（app 沙盒可读），失败不影响权威存储。
    if (![self ensureDirectory:self.imagesMirrorDirectoryPath]) return name;
    NSString *mirrorPath = [self.imagesMirrorDirectoryPath stringByAppendingPathComponent:name];
    [imageData writeToFile:mirrorPath options:NSDataWritingAtomic error:nil];
    return name;
}

- (void)removeImageNamed:(nullable NSString *)imageName {
    if (!imageName.length) return;
    NSString *primaryPath = [self.imagesDirectoryPath stringByAppendingPathComponent:imageName];
    if ([self.fileManager fileExistsAtPath:primaryPath]) {
        [self.fileManager removeItemAtPath:primaryPath error:nil];
    }
    NSString *mirrorPath = [self.imagesMirrorDirectoryPath stringByAppendingPathComponent:imageName];
    if ([self.fileManager fileExistsAtPath:mirrorPath]) {
        [self.fileManager removeItemAtPath:mirrorPath error:nil];
    }
}

@end