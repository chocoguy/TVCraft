// Worlds on Apple TV. tvOS keeps almost nothing an app writes: Library/Caches, where the game keeps its worlds (games/com.mojang/minecraftWorlds) and options
// (games/com.mojang/minecraftpe), can be purged while the app is closed. The preferences do last, so each world is copied there, packed, after the game saves it,
// and comes back by itself when its folder is missing at launch. Adapted from TVPort's dm/ios/SourcesTV/TVSaves.m (MIT).
//   - A unit is one world's folder, or the options folder: its files, packed into one archive and compressed with LZFSE. A 0.8.1 world's chunks.dat is a fixed
//     22 MB file, 70% zeros, that packs to about 700 KB in 0.1 s.
//   - NSUserDefaults abort the app past about 1 MB in all (TVPort, measured on an A15), so units go there while the total stays under STORE_LIMIT and to a
//     plain file in Library/Preferences/tv-saves beyond that, as TVPort does. Apple does not promise to keep that folder; tvcraft.py backup keeps copies on the Mac.
//   - The files are read on the main thread between frames, where the game writes them, so a copy never sees half a save; packing and storing run on a queue.
//   - A unit whose folder is gone after launch was deleted in the game: its copy goes too. Deleting the app deletes the copies.
#import <UIKit/UIKit.h>
#include <compression.h>
#include <stdio.h>
#include <string.h>
#import "TVSaves.h"

#define STORE_LIMIT (900 * 1024)
static NSString *const PREFIX = @"tvsave:";
static NSString *const OPTIONS_UNIT = @"options";
static NSMutableDictionary<NSString *, NSString *> *g_stored;   // unit -> the signature of what was last stored (main thread)
static dispatch_queue_t g_queue;

NSString *tv_saves_root(void) {
    NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
    return [caches stringByAppendingPathComponent:@"games/com.mojang"];
}
static NSString *worlds_dir(void) { return [tv_saves_root() stringByAppendingPathComponent:@"minecraftWorlds"]; }
static NSString *unit_dir(NSString *unit) {
    if ([unit isEqualToString:OPTIONS_UNIT]) return [tv_saves_root() stringByAppendingPathComponent:@"minecraftpe"];
    return [worlds_dir() stringByAppendingPathComponent:[unit substringFromIndex:@"world/".length]];
}
static NSString *spill_dir(void) {
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    return [library stringByAppendingPathComponent:@"Preferences/tv-saves"];
}
static NSString *spill_path(NSString *unit) {
    return [spill_dir() stringByAppendingPathComponent:[[unit stringByReplacingOccurrencesOfString:@"/" withString:@"|"] stringByAppendingString:@".tvz"]];
}
static NSString *unit_of_spill(NSString *file) {
    return [[file stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"|" withString:@"/"];
}

// The units on disk now: the options folder and each world folder that has a level.dat
static NSArray<NSString *> *units_on_disk(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray *units = [NSMutableArray array];
    if ([fm fileExistsAtPath:unit_dir(OPTIONS_UNIT)]) [units addObject:OPTIONS_UNIT];
    for (NSString *name in [fm contentsOfDirectoryAtPath:worlds_dir() error:nil] ?: @[])
        if ([fm fileExistsAtPath:[[worlds_dir() stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"level.dat"]])
            [units addObject:[@"world/" stringByAppendingString:name]];
    return units;
}

// The units stored: in the preferences, or spilled to files
static NSArray<NSString *> *units_stored(void) {
    NSMutableSet *units = [NSMutableSet set];
    for (NSString *key in NSUserDefaults.standardUserDefaults.dictionaryRepresentation)
        if ([key hasPrefix:PREFIX]) [units addObject:[key substringFromIndex:PREFIX.length]];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:spill_dir() error:nil] ?: @[])
        if ([file.pathExtension isEqualToString:@"tvz"]) [units addObject:unit_of_spill(file)];
    return units.allObjects;
}

static NSArray<NSString *> *unit_files(NSString *unit) {
    NSMutableArray *files = [NSMutableArray array];
    BOOL dir;
    for (NSString *name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:unit_dir(unit) error:nil] ?: @[] sortedArrayUsingSelector:@selector(compare:)])
        if ([NSFileManager.defaultManager fileExistsAtPath:[unit_dir(unit) stringByAppendingPathComponent:name] isDirectory:&dir] && !dir) [files addObject:name];
    return files;
}

// What a unit holds now, cheaply: each file's name, size and time of change
static NSString *signature(NSString *unit) {
    NSMutableString *sig = [NSMutableString string];
    for (NSString *name in unit_files(unit)) {
        NSDictionary *a = [NSFileManager.defaultManager attributesOfItemAtPath:[unit_dir(unit) stringByAppendingPathComponent:name] error:nil];
        [sig appendFormat:@"%@:%llu:%.3f;", name, [a[NSFileSize] unsignedLongLongValue], [a[NSFileModificationDate] timeIntervalSince1970]];
    }
    return sig;
}

// Archive: "TVW1", then for each file: name length (u16), name, size (u64), bytes. Stored as "TVZ1", the archive's size (u64), and the archive packed with LZFSE
static NSData *pack(NSString *unit) {
    NSMutableData *archive = [NSMutableData dataWithBytes:"TVW1" length:4];
    for (NSString *name in unit_files(unit)) {
        NSData *bytes = [NSData dataWithContentsOfFile:[unit_dir(unit) stringByAppendingPathComponent:name]];
        if (!bytes) continue;
        NSData *utf8 = [name dataUsingEncoding:NSUTF8StringEncoding];
        uint16_t n = (uint16_t)utf8.length; uint64_t size = bytes.length;
        [archive appendBytes:&n length:2]; [archive appendData:utf8];
        [archive appendBytes:&size length:8]; [archive appendData:bytes];
    }
    return archive;
}
static NSData *compress(NSData *archive) {
    size_t room = archive.length + archive.length / 8 + 65536;   // compression can grow what it cannot shrink, and fails rather than overrun
    NSMutableData *z = [NSMutableData dataWithLength:12 + room];
    memcpy(z.mutableBytes, "TVZ1", 4);
    uint64_t size = archive.length; memcpy((uint8_t *)z.mutableBytes + 4, &size, 8);
    size_t n = compression_encode_buffer((uint8_t *)z.mutableBytes + 12, room, (const uint8_t *)archive.bytes, archive.length, NULL, COMPRESSION_LZFSE);
    if (!n) return nil;
    z.length = 12 + n;
    return z;
}

static NSUInteger others_size(NSUserDefaults *d, NSString *key) {
    NSUInteger total = 0;
    NSDictionary *all = d.dictionaryRepresentation;
    for (NSString *k in all) if ([k hasPrefix:PREFIX] && ![k isEqualToString:key]) total += [all[k] length];
    return total;
}

static void store(NSString *unit, NSData *z) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    NSString *key = [PREFIX stringByAppendingString:unit], *spill = spill_path(unit);
    NSFileManager *fm = NSFileManager.defaultManager;
    if (others_size(d, key) + z.length > STORE_LIMIT) {
        [fm createDirectoryAtPath:spill_dir() withIntermediateDirectories:YES attributes:nil error:nil];
        if (![z writeToFile:spill atomically:YES]) { fprintf(stderr, "[RED] saves: writing %s failed\n", spill.fileSystemRepresentation); return; }
        [d removeObjectForKey:key];
        fprintf(stderr, "saves: %s packed to %lu bytes, past the preferences' budget: kept in Library/Preferences\n", unit.UTF8String, (unsigned long)z.length);
        return;
    }
    [d setObject:z forKey:key];
    [fm removeItemAtPath:spill error:nil];
    fprintf(stderr, "saves: %s packed to %lu bytes in the preferences\n", unit.UTF8String, (unsigned long)z.length);
}

static void forget(NSString *unit) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:[PREFIX stringByAppendingString:unit]];
    [NSFileManager.defaultManager removeItemAtPath:spill_path(unit) error:nil];
    fprintf(stderr, "saves: %s is gone from the game, its copy too\n", unit.UTF8String);
}

static BOOL unpack(NSString *unit) {
    NSData *z = [NSUserDefaults.standardUserDefaults dataForKey:[PREFIX stringByAppendingString:unit]] ?: [NSData dataWithContentsOfFile:spill_path(unit)];
    if (z.length <= 12 || memcmp(z.bytes, "TVZ1", 4)) { fprintf(stderr, "[RED] saves: the copy of %s is damaged\n", unit.UTF8String); return NO; }
    uint64_t size; memcpy(&size, (const uint8_t *)z.bytes + 4, 8);
    NSMutableData *archive = [NSMutableData dataWithLength:size];
    if (!archive || compression_decode_buffer((uint8_t *)archive.mutableBytes, size, (const uint8_t *)z.bytes + 12, z.length - 12, NULL, COMPRESSION_LZFSE) != size
        || size < 4 || memcmp(archive.bytes, "TVW1", 4)) {
        fprintf(stderr, "[RED] saves: the copy of %s does not unpack\n", unit.UTF8String); return NO;
    }
    NSString *dir = unit_dir(unit);
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    const uint8_t *p = (const uint8_t *)archive.bytes + 4, *end = (const uint8_t *)archive.bytes + size;
    int files = 0;
    while (p + 2 <= end) {
        uint16_t n; memcpy(&n, p, 2); p += 2;
        if (p + n + 8 > end) break;
        NSString *name = [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding]; p += n;
        uint64_t len; memcpy(&len, p, 8); p += 8;
        if (!name || [name containsString:@"/"] || p + len > end) break;
        [[NSData dataWithBytes:p length:len] writeToFile:[dir stringByAppendingPathComponent:name] atomically:YES];
        p += len; files++;
    }
    fprintf(stderr, "saves: brought back %s (%d files)\n", unit.UTF8String, files);
    return YES;
}

void tv_saves_restore(void) {
    g_stored = [NSMutableDictionary dictionary];
    g_queue = dispatch_queue_create("tvcraft.saves", DISPATCH_QUEUE_SERIAL);
    NSSet *onDisk = [NSSet setWithArray:units_on_disk()];
    NSArray *stored = units_stored();
    int back = 0;
    for (NSString *unit in stored) if (![onDisk containsObject:unit] && unpack(unit)) back++;
    for (NSString *unit in units_on_disk()) if ([stored containsObject:unit]) g_stored[unit] = @"";   // stored before: the next sync compares
    fprintf(stderr, "saves: %lu stored, %d brought back after a purge\n", (unsigned long)stored.count, back);
}

void tv_saves_sync(BOOL leaving) {
    if (!g_stored) return;
    NSMutableArray<NSString *> *units = [NSMutableArray array];
    NSMutableArray<NSData *> *archives = [NSMutableArray array];
    NSMutableArray<NSString *> *sigs = [NSMutableArray array];
    NSArray *onDisk = units_on_disk();
    for (NSString *unit in onDisk) {
        NSString *sig = signature(unit);
        if ([g_stored[unit] isEqualToString:sig]) continue;
        [units addObject:unit]; [sigs addObject:sig];
        [archives addObject:pack(unit)];   // read here, between frames, while the game is not writing
    }
    NSMutableArray *gone = [NSMutableArray array];
    for (NSString *unit in g_stored.allKeys) if (![onDisk containsObject:unit]) { [gone addObject:unit]; [g_stored removeObjectForKey:unit]; }
    if (!units.count && !gone.count) return;
    for (NSUInteger i = 0; i < units.count; i++) g_stored[units[i]] = sigs[i];

    // Packing and storing take a moment: off the main thread, and finished even when the app is leaving
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    if (leaving) task = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Save worlds" expirationHandler:^{
        [UIApplication.sharedApplication endBackgroundTask:task]; task = UIBackgroundTaskInvalid; }];
    dispatch_async(g_queue, ^{
        for (NSString *unit in gone) forget(unit);
        for (NSUInteger i = 0; i < units.count; i++) {
            NSData *z = compress(archives[i]);
            if (z) store(units[i], z);
            else fprintf(stderr, "[RED] saves: %s did not compress\n", units[i].UTF8String);
        }
        if (task != UIBackgroundTaskInvalid) dispatch_async(dispatch_get_main_queue(), ^{ [UIApplication.sharedApplication endBackgroundTask:task]; });
    });
}
