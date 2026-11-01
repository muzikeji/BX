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

// 迁移两个 legacy 位置：
//   1. kClipboardDatabasePathLegacyJB = /var/jb/Library/MUBX（1.0.4 及更早，
//      App 沙盒只读，写失败的历史根因位置）
//   2. kClipboardDatabasePathLegacy = /var/mobile/Library/...（1.0.3 及更早，
//      真实文件系统路径，仅 SpringBoard 可读）
// 首个存在的 source 迁移后即停止，目标已存在则跳过。仅 SpringBoard 进程
// 能读取真实路径 legacy；App 进程读取该路径会失败（沙盒），但读取
// legacyJB（jbroot 顶层 Library）可行，因此两个入口都保留。
- (void)migrateLegacyStoreIfNeeded {
    NSFileManager *fileManager = self.fileManager;
    if ([fileManager fileExistsAtPath:self.databasePath]) return;

    NSString *directory = [self.databasePath stringByDeletingLastPathComponent];
    if (![self ensureDirectory:directory]) return;

    BOOL copiedAnything = NO;
    NSArray<NSString *> *legacyDatabaseCandidates = @[
        kClipboardDatabasePathLegacyJB,
        kClipboardDatabasePathLegacy,
    ];
    for (NSString *legacyPath in legacyDatabaseCandidates) {
        if (![fileManager fileExistsAtPath:legacyPath]) continue;
        BOOL ok = YES;
        for (NSString *suffix in @[ @"", @"-wal", @"-shm" ]) {
            NSString *legacy = [legacyPath stringByAppendingString:suffix];
            if (![fileManager fileExistsAtPath:legacy]) continue;
            NSString *newPath = [self.databasePath stringByAppendingString:suffix];
            NSError *error = nil;
            if (![fileManager copyItemAtPath:legacy toPath:newPath error:&error]) {
                ok = NO;
                NSLog(@"[MUBX][Clipboard] legacy database migration failed for %@ (%@): %@",
                      suffix, legacyPath, error);
                DXLogClipboard(@"[MUBX][Clipboard] legacy database migration failed for %@ (%@): %@",
                               suffix, legacyPath, error);
                break;
            }
            [fileManager setAttributes:@{ NSFilePosixPermissions: @0666 }
                          ofItemAtPath:newPath error:nil];
        }
        if (ok) {
            copiedAnything = YES;
            NSLog(@"[MUBX][Clipboard] migrated legacy database from %@ to %@",
                  legacyPath, self.databasePath);
            DXLogClipboard(@"[MUBX][Clipboard] migrated legacy database from %@ to %@",
                           legacyPath, self.databasePath);
            break; // 成功迁移后停止，防止双份重复迁移
        }
    }

    NSArray<NSString *> *legacyImagesCandidates = @[
        kClipboardImagesPathLegacyJB,
        kClipboardImagesPathLegacy,
    ];
    // 图片合并复制：不因单个源失败而跳过其他源（目标已存在则跳过，
    // 重复源之间不会互相覆盖）。
    for (NSString *legacyImages in legacyImagesCandidates) {
        if (![fileManager fileExistsAtPath:legacyImages]) continue;
        [self ensureDirectory:self.imagesDirectoryPath];
        NSArray *imageNames = [fileManager contentsOfDirectoryAtPath:legacyImages error:nil];
        for (NSString *imageName in imageNames) {
            NSString *source = [legacyImages stringByAppendingPathComponent:imageName];
            NSString *destination = [self.imagesDirectoryPath stringByAppendingPathComponent:imageName];
            if (![fileManager fileExistsAtPath:destination]) {
                [fileManager copyItemAtPath:source toPath:destination error:nil];
            }
        }
    }

    if (copiedAnything) {
        NSLog(@"[MUBX][Clipboard] migrated legacy clipboard store to %@", self.databasePath);
        DXLogClipboard(@"[MUBX][Clipboard] migrated legacy clipboard store to %@", self.databasePath);
    }
}

// 沙盒可写性探测（诊断用）：打印当前进程、沙盒状态与目标路径的
// 存在/可写情况，用于定位"系统 App 可用、用户 App 不可用"的沙盒差异。
- (void)probeWritability {
    NSFileManager *fileManager = self.fileManager;
    NSString *processName = [[[NSProcessInfo processInfo] arguments] firstObject].lastPathComponent ?: @"?";
    BOOL sandboxed = [DXPrefsManager isRunningInSandbox];
    NSString *directory = [self.databasePath stringByDeletingLastPathComponent];

    BOOL directoryExists = [fileManager fileExistsAtPath:directory];
    BOOL directoryWritable = [fileManager isWritableFileAtPath:directory];
    BOOL dbExists = [fileManager fileExistsAtPath:self.databasePath];
    BOOL dbWritable = dbExists && [fileManager isWritableFileAtPath:self.databasePath];
    BOOL legacyJBWritable = [fileManager isWritableFileAtPath:kClipboardDatabasePathLegacyJB];

    NSLog(@"[MUBX][Clipboard][diag] process=%@ sandboxed=%d dbPath=%@ dirExists=%d dirWritable=%d dbExists=%d dbWritable=%d legacyJB(ro?)=%@",
          processName, sandboxed, self.databasePath,
          directoryExists, directoryWritable, dbExists, dbWritable,
          (legacyJBWritable ? @"writable" : @"READONLY"));
    DXLogClipboard(@"[MUBX][Clipboard][diag] process=%@ sandboxed=%d dbPath=%@ dirExists=%d dirWritable=%d dbExists=%d dbWritable=%d legacyJB(ro?)=%@",
                   processName, sandboxed, self.databasePath,
                   directoryExists, directoryWritable, dbExists, dbWritable,
                   (legacyJBWritable ? @"writable" : @"READONLY"));
}

- (BOOL)prepareDatabase {
    if (_database) return YES;

    // postinst normally performs this migration. Keep a runtime fallback for
    // upgrades where the package script could not access the old location.
    [self migrateLegacyStoreIfNeeded];

    NSString *dir = [self.databasePath stringByDeletingLastPathComponent];
    if (![self ensureDirectory:dir]) return NO;

    // 诊断：进程身份 + 路径可写性（区分系统 App/用户 App 的沙盒差异）。
    [self probeWritability];

    if (sqlite3_open(self.databasePath.UTF8String, &_database) != SQLITE_OK) {
        NSLog(@"[MUBX][Clipboard] sqlite3_open failed: %s", sqlite3_errmsg(_database));
        DXLogClipboard(@"[MUBX][Clipboard] sqlite3_open failed: %@",
                       @(sqlite3_errmsg(_database) ?: "?"));
        sqlite3_close(_database);
        _database = NULL;
        return NO;
    }

    // WAL 提升并发读（app 进程与 SpringBoard 多进程共享同一 SQLite）。
    char *walError = NULL;
    int walResult = sqlite3_exec(_database, "PRAGMA journal_mode=WAL", NULL, NULL, &walError);
    if (walResult != SQLITE_OK) {
        NSLog(@"[MUBX][Clipboard][diag] journal_mode=WAL failed: %s", walError ? walError : "?");
        DXLogClipboard(@"[MUBX][Clipboard][diag] journal_mode=WAL failed: %@",
                       @(walError ? walError : "?"));
        if (walError) sqlite3_free(walError);
    }
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
        NSLog(@"[MUBX][Clipboard] schema prepare failed: %s", error ? error : "?");
        DXLogClipboard(@"[MUBX][Clipboard] schema prepare failed: %@", @(error ? error : "?"));
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

- (BOOL)addItemWithHistoryKey:(NSString *)historyKey
            bundleIdentifier:(NSString *)bundleIdentifier
                     content:(NSString *)content
                   imageName:(nullable NSString *)imageName
                  imageWidth:(NSUInteger)imageWidth
                 imageHeight:(NSUInteger)imageHeight
                    hasLink:(BOOL)hasLink
                  capturedAt:(NSTimeInterval)capturedAt {
    if (![self prepareDatabase]) return NO;
    if (!historyKey.length) historyKey = kDXClipboardHistoryKey;
    content = content ?: @"";
    if (content.length == 0 && imageName.length == 0) return NO;

    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    sqlite3_int64 sequence = [self nextSequence];

    // 去重提升：同 (key, content) 先删除，再插入新序列号（Kayoko 同款行为）。
    [self executeStatement:"DELETE FROM history_items WHERE history_key = ? AND content = ?"
                 withBindings:@[ historyKey, content ]];

    BOOL inserted = [self executeStatement:
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
    return inserted;
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

- (BOOL)setFavorite:(BOOL)favorite
            historyKey:(NSString *)historyKey
               content:(NSString *)content {
    if (!content.length) return NO;
    if (![self prepareDatabase]) return NO;

    if (favorite) {
        // 复制语义：收藏 = 在 favorites 下新增一份副本，历史记录保留。
        // 源可能来自 history 或 favorites（收藏页再次收藏）。
        NSArray *items = [self itemsForHistoryKey:historyKey searchText:nil limit:200];
        NSDictionary *found = nil;
        for (NSDictionary *item in items) {
            if ([item[@"content"] isEqual:content]) { found = item; break; }
        }
        if (!found) return NO;
        // addItemWithHistoryKey 内部按 (key, content) 去重后插入，重复收藏
        // 只会更新序列号，不会产生重复行；history 侧不受影响。
        return [self addItemWithHistoryKey:kDXClipboardFavoritesKey
                          bundleIdentifier:found[@"bundle_identifier"]
                                   content:content
                                 imageName:found[@"image_name"]
                                imageWidth:[found[@"image_width"] unsignedIntegerValue]
                               imageHeight:[found[@"image_height"] unsignedIntegerValue]
                                  hasLink:[found[@"has_link"] boolValue]
                                capturedAt:[found[@"created_at"] doubleValue]];
    } else {
        // 取消收藏 = 仅从 favorites 删除，历史记录保留（复制语义下历史本就在）。
        return [self executeStatement:"DELETE FROM history_items WHERE history_key = ? AND content = ?"
                     withBindings:@[ kDXClipboardFavoritesKey, content ]];
    }
}

- (BOOL)deleteItemWithID:(NSInteger)itemID {
    if (![self prepareDatabase]) return NO;
    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database, "SELECT image_name FROM history_items WHERE id = ?", -1, &statement, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_int64(statement, 1, (sqlite3_int64)itemID);
    NSString *imageName = nil;
    if (sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(statement, 0);
        if (name) imageName = @((const char *)name);
    }
    sqlite3_finalize(statement);

    BOOL deleted = [self executeStatement:"DELETE FROM history_items WHERE id = ?" withBindings:@[ @(itemID) ]];
    if (imageName.length) [self removeImageNamed:imageName];
    return deleted;
}

- (BOOL)clearHistoryKey:(NSString *)historyKey {
    if (!historyKey.length) historyKey = kDXClipboardHistoryKey;
    if (![self prepareDatabase]) return NO;

    sqlite3_stmt *statement = NULL;
    if (sqlite3_prepare_v2(_database,
        "SELECT image_name FROM history_items WHERE history_key = ? AND image_name <> ''",
        -1, &statement, NULL) != SQLITE_OK) return NO;
    sqlite3_bind_text(statement, 1, historyKey.UTF8String, -1, SQLITE_TRANSIENT);
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    while (sqlite3_step(statement) == SQLITE_ROW) {
        const unsigned char *name = sqlite3_column_text(statement, 0);
        if (name) [images addObject:@((const char *)name)];
    }
    sqlite3_finalize(statement);

    BOOL cleared = [self executeStatement:"DELETE FROM history_items WHERE history_key = ?" withBindings:@[ historyKey ]];
    for (NSString *imageName in images) {
        if (imageName.length) [self removeImageNamed:imageName];
    }
    return cleared;
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