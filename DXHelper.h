@interface DXHelper : NSObject
+(UIImage *)imageForMUBXWithPlaceholder:(BOOL)placeholder;
+(UIImage *)imageForName:(NSString *)imageName withSystemColor:(BOOL)withSystemColor completion:(void (^)(BOOL isThirteen, BOOL isCustomImagePath))handler;
+(UIImage *)imageFromArray:(NSArray *)array atIndex:(NSUInteger)index withSystemColor:(BOOL)withSystemColor completion:(void (^)(BOOL isThirteen, BOOL isCustomImagePath))handler;
+(NSString *)labelFromArray:(NSArray *)array atIndex:(NSUInteger)index;
+(NSString *)actionNameFromArray:(NSArray *)array atIndex:(NSUInteger)index;
+(void)showSearchCountEasterAlertFor:(id)object searchController:(UISearchController *)searchController count:(NSUInteger)count delay:(double)delay;
+(NSString *)localizedStringForActionNamed:(NSString *)actionName shortName:(BOOL)shortName bundle:(NSBundle *)tweakBundle;
+(NSString *)customNameForShortcutItem:(NSDictionary *)item;
+(NSString *)customIconForShortcutItem:(NSDictionary *)item;
+(NSString *)appIconBundleIDForShortcutItem:(NSDictionary *)item;
+(UIImage *)appIconImageForBundleID:(NSString *)bundleID;
+(UIImage *)imageForIconConfig:(NSString *)icon defaultSymbolName:(NSString *)defaultName;
+(NSString *)resolvedIconNameForShortcutItem:(NSDictionary *)item defaultName:(NSString *)defaultName;
@end
