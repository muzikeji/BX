#import "DXPSFSymbolCatalog.h"

@interface DXPSFSymbolCategory ()
- (instancetype)initWithIdentifier:(NSString *)identifier metadata:(NSDictionary *)metadata names:(NSArray<NSString *> *)names;
@end

@implementation DXPSFSymbolCategory
- (instancetype)initWithIdentifier:(NSString *)identifier metadata:(NSDictionary *)metadata names:(NSArray<NSString *> *)names {
    if ((self = [super init])) {
        _identifier = [identifier copy];
        id icon = metadata[@"icon"];
        _iconName = [icon isKindOfClass:NSString.class] ? [icon copy] : nil;
        for (NSString *key in @[@"title", @"name", @"label"]) {
            id title = metadata[key];
            if ([title isKindOfClass:NSString.class] && [title length]) {
                _title = [title copy];
                break;
            }
        }
        _symbolNames = [names copy];
    }
    return self;
}
@end

// The format adapters follow SFSymbolReplacer's local catalog reader.
// Only names are read here; no replacement hooks or built-in catalog is used.
static void DXPAppendSymbolName(id value, NSMutableOrderedSet<NSString *> *names) {
    if (![value isKindOfClass:NSString.class]) return;
    NSString *name = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (name.length) [names addObject:name];
}

static id DXPReadCatalogPlist(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data.length ? [NSPropertyListSerialization propertyListWithData:data
        options:NSPropertyListImmutable format:NULL error:NULL] : nil;
}

static void DXPCollectCategoryDefinitions(id object, NSMutableOrderedSet<NSString *> *order,
                                          NSMutableDictionary<NSString *, NSDictionary *> *definitions) {
    if ([object isKindOfClass:NSDictionary.class]) {
        id categories = object[@"categories"];
        if ([categories isKindOfClass:NSArray.class]) object = categories;
    }
    if (![object isKindOfClass:NSArray.class]) return;
    for (id entry in object) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        id key = entry[@"key"];
        if (![key isKindOfClass:NSString.class]) continue;
        NSString *identifier = [key stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (!identifier.length) continue;
        [order addObject:identifier];
        if (!definitions[identifier]) definitions[identifier] = entry;
    }
}

static void DXPCollectSymbolNames(id object, NSMutableOrderedSet<NSString *> *names, NSUInteger depth) {
    if (depth > 8) return;
    if ([object isKindOfClass:NSArray.class]) {
        for (id entry in object) {
            if ([entry isKindOfClass:NSString.class]) {
                DXPAppendSymbolName(entry, names);
            } else if ([entry isKindOfClass:NSDictionary.class]) {
                for (NSString *key in @[@"name", @"symbol", @"Name"]) {
                    id value = entry[key];
                    if ([value isKindOfClass:NSString.class] && [value length]) {
                        DXPAppendSymbolName(value, names);
                        break;
                    }
                }
            }
        }
    } else if ([object isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = object;
        // Wrapped catalogs contain metadata such as year_to_release alongside
        // symbols. Those metadata keys must not become candidate symbol names.
        if (dictionary[@"names"] || dictionary[@"symbols"]) {
            for (NSString *key in @[@"names", @"symbols"]) {
                id value = dictionary[key];
                if ([value isKindOfClass:NSArray.class] || [value isKindOfClass:NSDictionary.class]) {
                    DXPCollectSymbolNames(value, names, depth + 1);
                }
            }
            return;
        }
        NSMutableArray<NSString *> *keys = [NSMutableArray array];
        for (id key in dictionary) {
            if ([key isKindOfClass:NSString.class] && ![key hasPrefix:@"CF"] &&
                ![key isEqualToString:@"version"] && ![key isEqualToString:@"year_to_release"]) {
                [keys addObject:key];
            }
        }
        [keys sortUsingSelector:@selector(compare:)];
        for (NSString *key in keys) DXPAppendSymbolName(key, names);
    }
}

@implementation DXPSFSymbolCatalog

+ (NSArray<NSString *> *)systemResourceDirectories {
    NSMutableOrderedSet<NSString *> *directories = [NSMutableOrderedSet orderedSet];
    for (NSString *resourceRoot in @[
        @"/System/Library/CoreServices/CoreGlyphs.bundle",
        @"/System/Library/PrivateFrameworks/CoreGlyphs.framework/CoreGlyphs.bundle",
        @"/System/Library/PrivateFrameworks/SFSymbols.framework",
    ]) {
        // System resources keep their real /System path on RootHide.
        [directories addObject:resourceRoot];
        [directories addObject:[resourceRoot stringByAppendingPathComponent:@"Resources"]];
        NSString *resolvedResources = [NSBundle bundleWithPath:resourceRoot].resourcePath;
        if (resolvedResources.length) [directories addObject:resolvedResources];
    }
    return directories.array;
}

+ (NSArray<NSString *> *)namesFromResourceDirectories:(NSArray<NSString *> *)directories
                                         sourcePaths:(NSArray<NSString *> **)sourcePaths {
    NSMutableOrderedSet<NSString *> *names = [NSMutableOrderedSet orderedSet];
    NSMutableOrderedSet<NSString *> *sources = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    // Preserve symbol_order order; availability adds names missing from it.
    for (NSString *fileName in @[@"symbol_order.plist", @"name_availability.plist"]) {
        for (NSString *directory in directories) {
            if (![directory isKindOfClass:NSString.class] || !directory.length) continue;
            NSString *path = [[directory stringByAppendingPathComponent:fileName] stringByStandardizingPath];
            if ([visited containsObject:path]) continue;
            [visited addObject:path];
            id object = DXPReadCatalogPlist(path);
            NSMutableOrderedSet<NSString *> *fileNames = [NSMutableOrderedSet orderedSet];
            DXPCollectSymbolNames(object, fileNames, 0);
            if (!fileNames.count) continue;
            [names addObjectsFromArray:fileNames.array];
            [sources addObject:path];
        }
    }
    if (sourcePaths) *sourcePaths = sources.array;
    // No failure cache: a later retry always reads disk again.
    return names.array;
}

+ (NSArray<DXPSFSymbolCategory *> *)categoriesFromResourceDirectories:(NSArray<NSString *> *)directories
                                                    availableNames:(NSArray<NSString *> *)availableNames
                                                       sourcePaths:(NSArray<NSString *> **)sourcePaths {
    NSMutableOrderedSet<NSString *> *validNames = [NSMutableOrderedSet orderedSet];
    for (id name in availableNames) DXPAppendSymbolName(name, validNames);
    NSMutableOrderedSet<NSString *> *order = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSDictionary *> *definitions = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSMutableOrderedSet<NSString *> *> *membership = [NSMutableDictionary dictionary];
    NSMutableOrderedSet<NSString *> *sources = [NSMutableOrderedSet orderedSet];
    NSMutableSet<NSString *> *visited = [NSMutableSet set];
    for (NSString *directory in directories) {
        if (![directory isKindOfClass:NSString.class] || !directory.length) continue;
        for (NSString *fileName in @[@"categories.plist", @"symbol_categories.plist"]) {
            NSString *path = [[directory stringByAppendingPathComponent:fileName] stringByStandardizingPath];
            if ([visited containsObject:path]) continue;
            [visited addObject:path];
            id object = DXPReadCatalogPlist(path);
            if ([fileName isEqualToString:@"categories.plist"]) {
                NSUInteger before = order.count;
                DXPCollectCategoryDefinitions(object, order, definitions);
                if (order.count > before) [sources addObject:path];
                continue;
            }
            if (![object isKindOfClass:NSDictionary.class]) continue;
            if ([object[@"symbols"] isKindOfClass:NSDictionary.class]) object = object[@"symbols"];
            BOOL parsed = NO;
            for (NSString *name in validNames) {
                id categories = object[name];
                if ([categories isKindOfClass:NSDictionary.class]) categories = categories[@"categories"];
                if (![categories isKindOfClass:NSArray.class]) continue;
                NSMutableOrderedSet<NSString *> *identifiers = membership[name];
                if (!identifiers) identifiers = [NSMutableOrderedSet orderedSet];
                for (id identifier in categories) DXPAppendSymbolName(identifier, identifiers);
                if (identifiers.count) {
                    membership[name] = identifiers;
                    parsed = YES;
                }
            }
            if (parsed) [sources addObject:path];
        }
    }
    if (sourcePaths) *sourcePaths = sources.array;
    if (!validNames.count) return @[];

    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *groups = [NSMutableDictionary dictionary];
    for (NSString *name in validNames) {
        for (NSString *identifier in membership[name]) {
            if (!groups[identifier]) groups[identifier] = [NSMutableArray array];
            [groups[identifier] addObject:name];
        }
    }
    NSMutableArray<DXPSFSymbolCategory *> *result = [NSMutableArray arrayWithObject:
        [[DXPSFSymbolCategory alloc] initWithIdentifier:@"all" metadata:definitions[@"all"] names:validNames.array]];
    // Match the category browser order: All, Multicolor, Variable Color, then
    // semantic categories in system order. New-symbol collections come last.
    NSMutableOrderedSet<NSString *> *displayOrder = [NSMutableOrderedSet orderedSetWithArray:@[@"multicolor", @"variable"]];
    for (NSString *identifier in order) {
        if (![identifier isEqualToString:@"whatsnew"]) [displayOrder addObject:identifier];
    }
    // A missing definition must not hide membership from a readable resource.
    for (NSString *identifier in [[groups allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
        if (![identifier isEqualToString:@"whatsnew"]) [displayOrder addObject:identifier];
    }
    [displayOrder addObject:@"whatsnew"];
    for (NSString *identifier in displayOrder) {
        NSArray *names = groups[identifier];
        if ([identifier isEqualToString:@"all"] || !names.count) continue;
        [result addObject:[[DXPSFSymbolCategory alloc] initWithIdentifier:identifier
            metadata:definitions[identifier] names:names]];
    }
    return [result copy];
}

@end
