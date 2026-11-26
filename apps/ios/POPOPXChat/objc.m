//
//  objc.m
//  POPOPXChat
//
//  Created by Stanislav Dmitrenko on 09.09.2024.
//  Copyright © 2024 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//

#import "objc.h"

@implementation ObjC

// https://stackoverflow.com/a/36454808
+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error {
    @try {
        tryBlock();
        return YES;
    }
    @catch (NSException *exception) {
        *error = [[NSError alloc] initWithDomain: exception.name code: 0 userInfo: exception.userInfo];
        return NO;
    }
}

@end

// MARK: - Copilot / Cactus bridge (DORMANT)
//
// See the header for why this exists and why it is off. The one thing worth restating: the block below
// is the only place in the app that names a `cactus_*` symbol, so while POPPX_CACTUS_ENABLED is
// undefined the linker never looks for libcactus.a and the project builds with no library added.
//
// The `#import "../Vendor/cactus/cactus.h"` form is quoted, not angle-bracketed, on purpose: clang searches
// the directory of the importing file first, so the header resolves to `apps/ios/Vendor/cactus/cactus.h` —
// the vendored copy — with no HEADER_SEARCH_PATHS edit and no second copy of the file to keep in sync.
// That mirrors hs_init.c:9 (`#include "hs_init.h"`), the technique this target already uses for local C
// headers. The import sits inside the guard, so while the flag is off clang never opens the path at all.
#if defined(POPPX_CACTUS_ENABLED) && POPPX_CACTUS_ENABLED
#import "../Vendor/cactus/cactus.h"
#define POPPX_CACTUS_COMPILED 1
#else
#define POPPX_CACTUS_COMPILED 0
#endif

/// The reply ceiling for one `cactus_complete`. The engine emits a JSON envelope of at most five tool
/// calls, so 8 KiB is generous, and the capacity is what keeps a runaway generation from writing past
/// the buffer — `cactus_complete` takes the capacity precisely so the caller owns the bound.
#define POPPX_CACTUS_REPLY_CAPACITY 8192

@implementation PopopxCactusBridge

+ (BOOL)isCompiledIn {
    return POPPX_CACTUS_COMPILED ? YES : NO;
}

+ (BOOL)loadModelData:(NSData *)data {
#if POPPX_CACTUS_COMPILED
    if (data.length == 0) return NO;
    // 0 is success, which is the convention `cactus_last_error()` implies. Not verified against a real
    // device run — see the patch list's "unverified" note; a flipped flag is the first time this line
    // executes.
    return cactus_load((const unsigned char *)data.bytes, (unsigned long long)data.length) == 0;
#else
    (void)data;
    return NO;
#endif
}

// No nullability specifier on `toolIndexPath`, even though nil is a valid argument: the declaration in
// objc.h is un-annotated on purpose (see the note there), and a specifier that appears only on the
// definition makes the two spellings of one signature disagree.
+ (BOOL)beginWithSystemPrompt:(NSString *)systemPrompt
                    toolsJson:(NSString *)toolsJson
                toolIndexPath:(NSString *)toolIndexPath {
#if POPPX_CACTUS_COMPILED
    return cactus_init(systemPrompt.UTF8String, toolsJson.UTF8String,
                       toolIndexPath == nil ? NULL : toolIndexPath.UTF8String) == 0;
#else
    (void)systemPrompt;
    (void)toolsJson;
    (void)toolIndexPath;
    return NO;
#endif
}

+ (NSString *)complete:(NSString *)input maxNewTokens:(NSInteger)maxNewTokens {
#if POPPX_CACTUS_COMPILED
    // No audio: this engine is used as a text tool-caller only.
    char buffer[POPPX_CACTUS_REPLY_CAPACITY] = {0};
    const int status = cactus_complete(input.UTF8String, NULL, 0, (int)maxNewTokens, buffer, POPPX_CACTUS_REPLY_CAPACITY);
    if (status != 0) return nil;
    NSString *reply = [NSString stringWithUTF8String:buffer];
    if (reply == nil) {
        // A generation cut off mid-multibyte-sequence is not valid UTF-8. Keeping the bytes as latin-1
        // lets the envelope parser report "unparseable engine reply", which is the truth, instead of the
        // caller seeing a nil and concluding the engine said nothing.
        reply = [[NSString alloc] initWithBytes:buffer length:strlen(buffer) encoding:NSISOLatin1StringEncoding] ?: @"";
    }
    return reply;
#else
    (void)input;
    (void)maxNewTokens;
    return nil;
#endif
}

+ (void)reset {
#if POPPX_CACTUS_COMPILED
    cactus_reset();
#endif
}

+ (void)setThreadCount:(NSInteger)threads {
#if POPPX_CACTUS_COMPILED
    cactus_set_threads((int)threads);
#else
    (void)threads;
#endif
}

+ (NSString *)lastError {
#if POPPX_CACTUS_COMPILED
    const char *message = cactus_last_error();
    if (message == NULL) return @"";
    NSString *text = [NSString stringWithUTF8String:message];
    return text ?: [[NSString alloc] initWithBytes:message length:strlen(message) encoding:NSISOLatin1StringEncoding] ?: @"";
#else
    return @"";
#endif
}

@end
