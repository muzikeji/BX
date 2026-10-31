#import "common.h"
#import "DXHelper.h"
#import "UIImage+Resize.h"

#define UIKitBundleArtwork @"/System/Library/PrivateFrameworks/UIKitCore.framework/Artwork.bundle"

// Name prefix marking a shortcut icon that renders an installed app's icon.
// Resolved names flow through the toolbar's string arrays just like the
// CUSTOM_ image-path prefix.
static NSString * const DXAppIconNamePrefix = @"APP_";

// Icon slot size shared by every custom icon source: 24pt matches the custom
// image path and sits at the SF Symbol scale, so a bundle-ID icon never
// renders larger than the symbol it replaces.
static const CGFloat DXAppIconSide = 24.0;

// Private UIKit lookup backed by the system icon cache; available far below
// this tweak's deployment target, but resolved defensively all the same.
@interface UIImage (MUBXAppIcon)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(NSInteger)format;
@end

@implementation DXHelper

+(UIImage *)imageForMUBXWithPlaceholder:(BOOL)placeholder{
    if (placeholder){
        return [UIImage imageWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"MUBX_Placeholder.png"]];
    }
    return [UIImage imageWithContentsOfFile:[bundlePath stringByAppendingPathComponent:@"MUBX.png"]];
}

+(UIImage *)imageForName:(NSString *)imageName withSystemColor:(BOOL)withSystemColor completion:(void (^)(BOOL isThirteen, BOOL isCustomImagePath))handler{
    UIImage *image;
    NSString *customPrefix = @"CUSTOM_";
    NSString *customPath;
    UIColor *systemBlueColor = [UIColor systemBlueColor];
    BOOL isCustomImagePath = [imageName hasPrefix:customPrefix];
    BOOL isThirteen = NO;
    if (isCustomImagePath){
        customPath = [imageName substringFromIndex:[customPrefix length]];
    }
    BOOL isAppIconPath = [imageName hasPrefix:DXAppIconNamePrefix];

    UIImage* (^cacheAndLoadImage)(NSString *, NSString *) = ^(NSString *inputImagePath, NSString *cacheFilePath){
        UIImage *resizedImage;
        if (![[NSFileManager defaultManager] fileExistsAtPath:cacheFilePath]){
            resizedImage = [UIImage imageWithImage:[UIImage imageWithContentsOfFile:inputImagePath] resize:CGSizeMake(24, 24)];
            //resizedImage = [UIImage imageWithImage:[UIImage imageWithContentsOfFile:inputImagePath] scaledToFitToSize:CGSizeMake(24, 24)];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
                [UIImagePNGRepresentation(resizedImage) writeToFile:cacheFilePath options:NSDataWritingAtomic error:nil];
            });
        }else{
            resizedImage = [UIImage imageWithImage:[UIImage imageWithContentsOfFile:cacheFilePath] resize:CGSizeMake(24, 24)];
            //resizedImage = [UIImage imageWithCGImage:[[UIImage imageWithData:[NSData dataWithContentsOfFile:cacheFilePath]] CGImage] scale:0.5 orientation:UIImageOrientationUp];
        }
        return resizedImage;
    };
    
    NSString *cachedImagePath = [NSString stringWithFormat:@"%@/%lu.png", MUBXCachePath, customPath.hash];
    
    if (@available(iOS 13.0, *)){
        isThirteen = YES;

        if (isAppIconPath){
            NSString *bundleID = [imageName substringFromIndex:[DXAppIconNamePrefix length]];
            UIImage *appIcon = [self appIconImageForBundleID:bundleID];
            if (appIcon){
                // App icons keep their artwork: always-original rendering
                // stops UIButton's default templating from flattening them
                // into monochrome silhouettes, and the system tint is skipped
                // for the same reason.
                image = [appIcon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
            }else{
                // Unresolvable bundle ID falls back to a tintable placeholder
                // instead of a blank shortcut.
                image = [UIImage systemImageNamed:@"app"];
            }
        }else if (isCustomImagePath){
            image = cacheAndLoadImage(customPath, cachedImagePath);
            if (withSystemColor){
                image = [image imageWithTintColor:systemBlueColor];
            }
        }else{
            image = [UIImage systemImageNamed:imageName];
        }
    }else{
        if (isCustomImagePath){
            image = cacheAndLoadImage(customPath, cachedImagePath);
            image = [image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
        }else{
            image = [UIImage imageNamed:imageName inBundle:[NSBundle bundleWithPath:UIKitBundleArtwork] compatibleWithTraitCollection:NULL];
        }
    }
    if (handler){
        handler(isThirteen, isCustomImagePath);
    }
    return image;
}

+(UIImage *)imageFromArray:(NSArray *)array atIndex:(NSUInteger)index withSystemColor:(BOOL)withSystemColor completion:(void (^)(BOOL isThirteen, BOOL isCustomImagePath))handler{
    UIImage *image;
    __block BOOL isThirteen = NO;
    __block BOOL isCustomImagePath = NO;
    if (@available(iOS 13.0, *)){
        NSArray* imagelistDict = [array filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%@ IN self.@allKeys" , @"images13"]];
        NSArray *imagelist = [imagelistDict valueForKey:@"images13"];
        NSString *imageNameAtIndex = [imagelist objectAtIndex:index];
        
        dispatch_semaphore_t smp = dispatch_semaphore_create(0);
        image = [self imageForName:imageNameAtIndex withSystemColor:withSystemColor completion:^(BOOL thirteen, BOOL customPath){
            isThirteen = thirteen;
            isCustomImagePath = customPath;
            dispatch_semaphore_signal(smp);
        }];
        dispatch_semaphore_wait(smp, DISPATCH_TIME_FOREVER);
        
    }else{
        NSArray* imagelistDict = [array filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%@ IN self.@allKeys" , @"images12"]];
        NSArray *imagelist = [imagelistDict valueForKey:@"images12"];
        NSString *imageNameAtIndex = [imagelist objectAtIndex:index];
        
        dispatch_semaphore_t smp = dispatch_semaphore_create(0);
        image = [self imageForName:imageNameAtIndex withSystemColor:withSystemColor completion:^(BOOL thirteen, BOOL customPath){
            isThirteen = thirteen;
            isCustomImagePath = customPath;
            dispatch_semaphore_signal(smp);
        }];
        dispatch_semaphore_wait(smp, DISPATCH_TIME_FOREVER);
    }
    if (handler){
        handler(isThirteen, isCustomImagePath);
    }
    return image;
}

+(NSString *)labelFromArray:(NSArray *)array atIndex:(NSUInteger)index{
    NSArray* labelTextlistDict = [array filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%@ IN self.@allKeys" , @"label" ]];
    NSArray *labelTextlist = [labelTextlistDict valueForKey:@"label"];
    return [labelTextlist objectAtIndex:index];
}

+(NSString *)actionNameFromArray:(NSArray *)array atIndex:(NSUInteger)index{
    NSArray* labelTextlistDict = [array filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"%@ IN self.@allKeys" , @"selector" ]];
    NSArray *labelTextlist = [labelTextlistDict valueForKey:@"selector"];
    return [labelTextlist objectAtIndex:index];
}

+(void)showSearchCountEasterAlertFor:(id)object searchController:(UISearchController *)searchController count:(NSUInteger)count delay:(double)delay{
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Fact" message:[NSString stringWithFormat:@"Little did you know you've tapped the search bar %ld times. Have you finally found the look you're looking for? \U0001F92A", count] preferredStyle:UIAlertControllerStyleAlert];
        UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"Continue" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [searchController.searchBar becomeFirstResponder];
        }];
        [alert addAction:okAction];
        [object presentViewController:alert animated:YES completion:nil];
    });
}

+(NSString *)localizedStringForActionNamed:(NSString *)actionName shortName:(BOOL)shortName bundle:(NSBundle *)tweakBundle{
    actionName = [actionName stringByReplacingOccurrencesOfString:@"Action:" withString:@""];
    NSRegularExpression *regexp = [NSRegularExpression regularExpressionWithPattern:@"([a-z])([A-Z])" options:0 error:NULL];
    actionName = [regexp stringByReplacingMatchesInString:actionName options:0 range:NSMakeRange(0, actionName.length) withTemplate:@"$1_$2"];
    if (shortName){
        actionName = [NSString stringWithFormat:@"SHORT_%@", [actionName uppercaseString]];
    }else{
        actionName = [NSString stringWithFormat:@"LONG_%@", [actionName uppercaseString]];
    }
    return [tweakBundle localizedStringForKey:actionName value:@"" table:nil];
}

// Per-shortcut overrides live inside the shortcut dictionaries stored under the
// shortcuts keys ("name" / "icon").  An empty or missing value means the built-in
// label stays in effect.
+(NSString *)customNameForShortcutItem:(NSDictionary *)item{
    NSString *name = item[@"name"];
    return ([name isKindOfClass:[NSString class]] && name.length > 0) ? name : nil;
}

// Custom icons accept standard SF Symbol names only.  An unknown symbol fails
// systemImageNamed: here, so every consumer falls back to the default icon.
+(NSString *)customIconForShortcutItem:(NSDictionary *)item{
    NSString *icon = item[@"icon"];
    if (![icon isKindOfClass:[NSString class]] || icon.length == 0) return nil;
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:icon] ? icon : nil;
    }
    return nil;
}

// Reverse-DNS shape test shared by the bundle-ID icon classification.  Kept
// strict so ordinary icon typos never get handed to the app-icon loader.
+(BOOL)looksLikeBundleIdentifier:(NSString *)value{
    if (value.length == 0 || value.length > 256) return NO;
    NSRegularExpression *expression = [NSRegularExpression regularExpressionWithPattern:@"^[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?(?:\\.[A-Za-z0-9_](?:[A-Za-z0-9_-]*[A-Za-z0-9_])?)+$"
                                                                                options:0
                                                                                  error:nil];
    return [expression firstMatchInString:value options:0 range:NSMakeRange(0, value.length)] != nil;
}

// Icon config that is not a valid SF Symbol but is a bundle identifier is
// treated as an app icon request.  iOS 12 has no SF Symbols to win the first
// check, so bundle-ID icons stay disabled there like custom symbols are.
+(NSString *)appIconBundleIDForShortcutItem:(NSDictionary *)item{
    NSString *icon = item[@"icon"];
    if (![icon isKindOfClass:[NSString class]] || icon.length == 0) return nil;
    if (@available(iOS 13.0, *)) {
        if ([UIImage systemImageNamed:icon]) return nil;
        return [self looksLikeBundleIdentifier:icon] ? icon : nil;
    }
    return nil;
}

// Loads one app icon at the shared 24pt icon-slot size, rounded like the home
// screen.  Lookups go memory cache -> PNG staged under the shared snapshot
// (readable by sandboxed hosts) -> the private UIKit icon lookup, whose result
// is staged back to disk asynchronously so sandboxed processes can read it
// later.  Returns nil only when every source fails.
+(UIImage *)appIconImageForBundleID:(NSString *)bundleID{
    if (![self looksLikeBundleIdentifier:bundleID]) return nil;

    static NSCache *cache;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 64;
    });
    UIImage *cached = [cache objectForKey:bundleID];
    if (cached) return cached;

    NSString *cachedFilePath = [NSString stringWithFormat:@"%@/appicons/%@.png", MUBXCachePath, bundleID];
    UIImage *icon = nil;
    if ([[NSFileManager defaultManager] fileExistsAtPath:cachedFilePath]){
        icon = [UIImage imageWithContentsOfFile:cachedFilePath];
        // PNGs carry no scale metadata: the icon is stored at screen pixel
        // density and reads back as a scale-1.0 image that fills the whole
        // button. Re-tag from the pixel width so it stays at the shared
        // 24pt icon slot alongside SF Symbols.
        if (icon && icon.size.width > 0){
            icon = [UIImage imageWithCGImage:icon.CGImage
                                       scale:icon.size.width / DXAppIconSide
                                 orientation:UIImageOrientationUp];
        }
    }

    if (!icon && [UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:)]){
        UIImage *base = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2];
        if (!base) base = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0];
        if (base){
            CGFloat side = DXAppIconSide;
            UIGraphicsImageRendererFormat *format = [[UIGraphicsImageRendererFormat alloc] init];
            format.scale = [UIScreen mainScreen].scale;
            format.opaque = NO;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:format];
            icon = [renderer imageWithActions:^(UIGraphicsImageRendererContext *rendererContext) {
                [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, side, side)
                                            cornerRadius:side * 0.225] addClip];
                [base drawInRect:CGRectMake(0, 0, side, side)];
            }];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [[NSFileManager defaultManager] createDirectoryAtPath:[cachedFilePath stringByDeletingLastPathComponent]
                                          withIntermediateDirectories:YES attributes:nil error:nil];
                [UIImagePNGRepresentation(icon) writeToFile:cachedFilePath options:NSDataWritingAtomic error:nil];
            });
        }
    }

    if (icon){
        icon = [icon imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        [cache setObject:icon forKey:bundleID];
    }
    return icon;
}

// Resolves one raw icon config string (a link action's or shortcut's "icon"
// field) into a UIImage: SF Symbol wins, then the app icon for bundle IDs,
// then the named fallback symbol.
+(UIImage *)imageForIconConfig:(NSString *)icon defaultSymbolName:(NSString *)defaultName{
    if (@available(iOS 13.0, *)) {
        if (icon.length > 0){
            UIImage *symbol = [UIImage systemImageNamed:icon];
            if (symbol) return symbol;
            UIImage *appIcon = [self appIconImageForBundleID:icon];
            if (appIcon) return appIcon;
        }
        return [UIImage systemImageNamed:defaultName];
    }
    return nil;
}

+(NSString *)resolvedIconNameForShortcutItem:(NSDictionary *)item defaultName:(NSString *)defaultName{
    NSString *sfName = [self customIconForShortcutItem:item];
    if (sfName) return sfName;
    NSString *bundleID = [self appIconBundleIDForShortcutItem:item];
    if (bundleID) return [DXAppIconNamePrefix stringByAppendingString:bundleID];
    return defaultName;
}

@end
