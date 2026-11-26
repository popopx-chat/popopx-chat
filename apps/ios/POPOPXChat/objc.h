//
//  objc.h
//  POPOPX (iOS)
//
//  Created by Stanislav Dmitrenko on 09.09.2024.
//  Copyright © 2024 SimpleX Chat. All rights reserved.
//  Modifications Copyright © 2026 POPOPX Chat.
//

#ifndef objc_h
#define objc_h

#import <Foundation/Foundation.h>

@interface ObjC : NSObject

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error;

@end

// MARK: - Copilot / Cactus bridge (DORMANT)
//
// The Objective-C half of the on-device assistant's optional model engine. It lives here, and not in a
// new .h/.m pair, for one reason: this header is already a Public header of the app target and is
// already pulled in by POPOPX.h (`#include <POPOPXChat/objc.h>`), which is the value of
// SWIFT_OBJC_BRIDGING_HEADER. So Swift sees these declarations with no project-file edit at all, and
// none was made.
//
// `PopopxCactusBridge.isCompiledIn` returns NO in the shipping build. The cactus_* calls below are
// inside a compile-time block that is off by default, which means `libcactus.a` is never referenced and
// a missing static library cannot break the link. The Swift layer (`PopopxNeedleEngine`, in
// Shared/Features/Discover/DiscoverCatalogModels.swift) keeps the deterministic engine as the answering
// engine. To turn this on, define POPPX_CACTUS_ENABLED=1 and add `-lcactus` plus its search path; the C
// prototypes come from the vendored `Vendor/cactus/cactus.h`, which objc.m reaches by relative path. Swift
// imports nothing — it calls this class.
//
// The measured reason it stays off: the published base weights route 1 of 6 calendar intents on this
// host and produce no usable Chinese output. Fine-tuning is a separate project.
//
// These declarations carry no nullability annotations, and that is deliberate rather than unfinished:
// clang's `-Wnullability-completeness` fires for a translation unit as soon as *any* annotation appears in
// it, and `objc.h:17` — an upstream line, `catchException:error:` — has an un-annotated block pointer, so
// one `_Nullable` anywhere below turns that line into 8 build warnings. Measured both ways on 2026-11-26
// with `xcrun --sdk iphoneos clang -fsyntax-only -fobjc-arc`: the annotation-free header prints nothing,
// a header with `NS_ASSUME_NONNULL_BEGIN` or with explicit `_Nonnull`/`_Nullable` prints one warning each.
// Swift therefore imports these as implicitly-unwrapped, which is what the call sites already assume; the
// nil-ability that matters here is written in the comment above each method.
@interface PopopxCactusBridge : NSObject

/// NO unless the C calls were compiled in. Every other method is safe to call when this returns NO:
/// they report failure rather than trapping.
+ (BOOL)isCompiledIn;

/// `cactus_load` over an already-verified buffer. The caller must have checked the SHA-256 first —
/// `PopopxNeedleAssets.loadVerifiedModel` is the only path that gets here.
+ (BOOL)loadModelData:(NSData *)data;

/// `cactus_init`. `toolIndexPath` may be nil, which the C API reads as "no index".
+ (BOOL)beginWithSystemPrompt:(NSString *)systemPrompt
                    toolsJson:(NSString *)toolsJson
                toolIndexPath:(NSString *)toolIndexPath;

/// `cactus_complete` with no audio. Returns the raw reply, or nil if the engine produced nothing.
+ (NSString *)complete:(NSString *)input maxNewTokens:(NSInteger)maxNewTokens;

/// `cactus_reset` — drops the conversation so the next summon does not answer from a stale context.
+ (void)reset;

/// `cactus_set_threads`.
+ (void)setThreadCount:(NSInteger)threads;

/// `cactus_last_error`. Empty when the bridge is dormant, so a caller can always show something.
+ (NSString *)lastError;

@end

#endif /* objc_h */
