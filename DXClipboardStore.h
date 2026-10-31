#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// MUBX 内置剪贴板历史——权威存储层（Schema 与 Kayoko history-v4 完全一致，
// 迁移 = 逐行复制，零格式转换）。仅在 SpringBoard 进程创建/写入；
// app 进程通过 cfprefsd 快照（kClipboardSnapshotKey）读取。
//
// 表 history_items 字段（与 Kayoko 对齐）：
//   id / history_key('history'|'favorites') / bundle_identifier / content
//   image_name / image_width / image_height / image_byte_count
//   rich_text_uti / rich_text_name / has_link / created_at / updated_at
//   sequence / tag_uuid / note / search_index_version
// 去重：UNIQUE(history_key, content)；重复内容 DELETE + INSERT 提升到顶部。
@interface DXClipboardStore : NSObject

+ (instancetype)sharedStore;

/// 打开（或创建）权威数据库并准备 schema。返回 NO 表示库不可用。
- (BOOL)prepareDatabase;

/// 插入一条剪贴板记录。history_key 为 @"history" 或 @"favorites"。
/// 同 content 已存在时先删除再插入（提升到顶部）；超上限按 sequence 淘汰最旧。
- (void)addItemWithHistoryKey:(NSString *)historyKey
            bundleIdentifier:(NSString *)bundleIdentifier
                     content:(NSString *)content
                   imageName:(nullable NSString *)imageName
                  imageWidth:(NSUInteger)imageWidth
                 imageHeight:(NSUInteger)imageHeight
                    hasLink:(BOOL)hasLink
                  capturedAt:(NSTimeInterval)capturedAt;

/// 查询历史（或收藏）。searchText 非空时按 content 子串过滤（大小写不敏感）。
/// 返回字典数组：id, history_key, bundle_identifier, content, image_name,
/// image_width, image_height, has_link, created_at。
- (NSArray<NSDictionary *> *)itemsForHistoryKey:(NSString *)historyKey
                                      searchText:(nullable NSString *)searchText
                                           limit:(NSUInteger)limit;

/// 收藏/取消收藏：把条目从 history 键移动到 favorites 键（或反向）。
/// 以 (historyKey, content) 定位（content 唯一）。
- (void)setFavorite:(BOOL)favorite
            historyKey:(NSString *)historyKey
               content:(NSString *)content;

/// 按记录 id 删除单条。返回是否删除了关联图片文件。
- (void)deleteItemWithID:(NSInteger)itemID;

/// 清空指定键的全部记录并删除关联图片文件。
- (void)clearHistoryKey:(NSString *)historyKey;

/// 当前记录数（指定键）。用于设置页展示与调试。
- (NSUInteger)countForHistoryKey:(NSString *)historyKey;

/// 保存图片数据到权威目录 + jbroot 镜像目录（app 沙盒可读）。返回文件名。
- (nullable NSString *)saveImageData:(NSData *)imageData extension:(NSString *)extension;

/// 删除图片文件（权威目录 + 镜像目录）。
- (void)removeImageNamed:(nullable NSString *)imageName;

/// 权威目录完整路径 / 镜像目录路径。
- (NSString *)imagesPath;
- (NSString *)imagesMirrorPath;

@end

NS_ASSUME_NONNULL_END