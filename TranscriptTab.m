// Transcript Tab — Premiere-style text-based editing as a fifth tab in Final Cut Pro's inspector.
// A SpliceKit plugin (https://github.com/elliotttate/SpliceKit). Built for FCP 12.4 + SpliceKit 3.3.9;
// it uses FCP's private classes, so other versions may need changes.
// Copyright (c) 2026 Inner Parakeet. MIT License (see LICENSE).
#import <dlfcn.h>
#import <AppKit/AppKit.h>
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString *const kTabIdent = @"SKInspectorTabTranscriptIdentifier";
static NSString *kLog = @"/tmp/transcript-tab.log";
static void TLog(NSString *fmt, ...) {
    va_list a; va_start(a, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:a]; va_end(a);
    FILE *f = fopen(kLog.UTF8String, "a");
    if (f) { fprintf(f, "%s\n", s.UTF8String); fclose(f); }
}

@interface FFInspectorModule : NSResponder
- (void)setCurrentItems:(id)items;
- (void)setView:(NSView *)view;
- (NSView *)view;
@end

// Does `obj` answer `sel` with a CMTimeRange? Checked once per (class, selector) with the method
// signature, then called directly through objc_msgSend (arm64 returns the 48-byte struct through
// the same entry point). This replaced an NSInvocation per call, which dominated refresh time.
static BOOL SKReturnsRange(id obj, SEL sel) {
    struct SKRangeCacheEntry { Class cls; SEL sel; BOOL ok; };
    static struct SKRangeCacheEntry cache[48]; static int n;
    Class c = object_getClass(obj);
    for (int i = 0; i < n; i++) if (cache[i].cls == c && cache[i].sel == sel) return cache[i].ok;
    NSMethodSignature *sig = [obj methodSignatureForSelector:sel];
    BOOL ok = sig && sig.methodReturnLength == sizeof(CMTimeRange);
    if (n < 48) { cache[n].cls = c; cache[n].sel = sel; cache[n].ok = ok; n++; }
    return ok;
}
static CMTimeRange SKTimeRange(id obj) {
    static SEL sel; if (!sel) sel = NSSelectorFromString(@"timeRange");
    if (!SKReturnsRange(obj, sel)) return kCMTimeRangeZero;
    return ((CMTimeRange(*)(id,SEL))objc_msgSend)(obj, sel);
}

// One rendered word: where it sits in the text view, in the source media and on the timeline.
@interface SKWord : NSObject
@property (nonatomic) NSRange range;
@property (nonatomic) double srcStart, srcEnd;
@property (nonatomic) double tlStart, tlEnd;   // NAN when the word has no timeline position (source view)
@property (nonatomic) BOOL pause;              // a silence item rather than a spoken word
@property (nonatomic) BOOL filler;             // um / uh and friends
@property (nonatomic, copy) NSString *speaker;   // display name, nil when unknown
@property (nonatomic, copy) NSString *mediaPath; // source file the word comes from
@property (nonatomic, copy) NSString *original;  // FCP's text for the word
@property (nonatomic, copy) NSString *text;      // what we show: the original or a correction
@property (nonatomic) BOOL paragraphStart;       // first word of a phrase paragraph
@property (nonatomic, strong) id sourceClip;     // browser clip the word belongs to (source view only)
@property (nonatomic) CMTime clipOrigin;         // that clip's start time, i.e. its media timecode origin
@property (nonatomic) CMTime clipFrame;          // that clip's frame duration (may differ from the project's)
@property (nonatomic, strong) id connectedClip;  // timeline view: the connected clip the word is from (nil = primary storyline)
@end
@implementation SKWord
@end

@class SKInspectorModuleTranscript;
@interface SKTranscriptTextView : NSTextView
@property (nonatomic, weak) SKInspectorModuleTranscript *module;
- (BOOL)sk_handleClickAtViewPoint:(NSPoint)p;
@end

// Inspector-style section header (v63): bold title on the inspector ground, "Hide" / "Show" at
// the right while the pointer is over it, click anywhere to fold the section.
@interface SKSectionHeaderView : NSView
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, weak) id owner;
@property (nonatomic, strong) NSTextField *titleLabel, *hideLabel;
@property (nonatomic) BOOL collapsed;
@end

// Speaker color picker (v64), drawn like FCP's role color picker: a dark rounded panel with a
// pointer on its right edge and the 2 x 9 role palette as touching swatches.
@interface SKRoleColorPicker : NSView
@property (nonatomic) NSInteger selected, hover;
@property (nonatomic) CGFloat arrowY;                         // pointer position, from the top
@property (nonatomic, copy) void (^onPick)(NSInteger index);
@end

// Flat fill (the lighter gray behind parameter rows, the footer band), with optional row separators.
@interface SKFillView : NSView
@property (nonatomic, strong) NSColor *fill;
@property (nonatomic) CGFloat rowHeight;     // > 0: draw a separator between rows of this height
@property (nonatomic) BOOL topLine;          // a dark hairline along the top edge
@end

@interface SKInspectorModuleTranscript : FFInspectorModule <NSTextFieldDelegate, NSSearchFieldDelegate>
@property (nonatomic, strong) SKTranscriptTextView *textView;
@property (nonatomic, strong) NSScrollView *scroll;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, strong) NSArray<SKWord *> *words;      // items drawn in the text view
@property (nonatomic, strong) NSArray<SKWord *> *allItems;   // every timeline item in order, including filtered-out ones
@property (nonatomic, strong) NSArray<NSString *> *mediaPaths;
@property (nonatomic, strong) NSDictionary<NSString *, NSString *> *proxyPaths;   // media path -> FCP proxy file, when one exists
@property (nonatomic, strong) NSPopUpButton *speakerPopup, *assignPopup;
@property (nonatomic, strong) NSButton *detectButton;
@property (nonatomic, strong) NSSearchField *searchField;
@property (nonatomic, strong) NSTextField *replaceField, *findCount, *editField;
@property (nonatomic, strong) NSButton *prevButton, *nextButton, *replaceButton, *replaceAllButton;
@property (nonatomic, strong) NSArray<NSValue *> *findMatches;
@property (nonatomic) NSInteger findIndex;
@property (nonatomic, strong) SKWord *editingWord;
@property (nonatomic, copy) NSString *editingSpeaker;          // set while a speaker name is being renamed
@property (nonatomic, strong) NSArray<NSArray *> *labelRanges; // @[NSValue range, name] for each speaker label drawn
@property (nonatomic, strong) NSPopUpButton *exportPopup;
@property (nonatomic, strong) NSButton *captionsButton;
@property (nonatomic, strong) NSButton *transcribeButton;   // under the "no transcript yet" line (v62)
@property (nonatomic, strong) NSSegmentedControl *sizeControl;
@property (nonatomic, strong) NSPopUpButton *thresholdPopup;
@property (nonatomic, strong) NSArray<NSDictionary *> *sections;   // @{id, header, box?, rows?} top to bottom (v63)
@property (nonatomic, strong) SKFillView *footer;
@property (nonatomic, strong) NSStackView *footerStack;
@property (nonatomic, strong) NSPopUpButton *timecodePopup;
@property (nonatomic, strong) NSButton *barsCheckbox;
@property (nonatomic, strong) NSButton *darkCheckbox;   // View › Background: dark instead of the row gray (v74)
@property (nonatomic, strong) NSArray<NSArray *> *blocks;        // @[NSValue range name…last word, NSColor] per speaker run
@property (nonatomic, strong) NSArray<NSValue *> *pauseRanges;   // pause items, drawn as capsules
@property (nonatomic) CGFloat barX;                              // color bar x, in text-container coordinates
@property (nonatomic, strong) NSPanel *colorPanel;               // the open speaker color picker, if any
@property (nonatomic, strong) id colorLocalMonitor, colorGlobalMonitor;
@property (nonatomic) NSUInteger menuIndex;                      // character the last right-click menu was for
@property (nonatomic, strong) NSButton *colorWheelButton;        // FCP's role color circle, beside the speaker name under the pointer (v68)
@property (nonatomic, copy) NSString *hoverSpeaker;              // the name that circle belongs to
@property (nonatomic, strong) NSArray<NSButton *> *sourceButtons;
@property (nonatomic) BOOL sourceMarked;
@property (nonatomic) NSRange highlighted;
@property (nonatomic, strong) NSView *container;
@property (nonatomic, strong) NSButton *fillerButton, *pauseButton;
@property (nonatomic) BOOL built;
@property (nonatomic) NSUInteger tickCount;
@property (nonatomic, copy) NSString *renderedSignature, *renderedKey;
@property (nonatomic) BOOL needsRefresh, refreshQueued;   // coalesced, visible-only redraws
- (void)sk_refresh;
- (void)sk_requestRefresh;
- (BOOL)sk_deleteAllFillers:(BOOL)fillers;
- (NSArray<SKWord *> *)sk_selectedWords;
- (void)sk_rebuildSpeakerMenus:(NSArray<NSString *> *)names;
- (void)sk_setFilter:(NSString *)name;
- (void)sk_detectSpeakers:(id)sender;
- (BOOL)sk_assignSpeaker:(NSString *)name;
- (NSArray<SKWord *> *)sk_selectedSpokenWords;
- (NSMenu *)sk_contextMenuAtIndex:(NSUInteger)idx;
- (BOOL)sk_renameSpeaker:(NSString *)old to:(NSString *)new;
- (void)sk_beginEditingWord:(SKWord *)w;
- (void)sk_endEditing:(BOOL)commit;
- (NSString *)sk_speakerLabelAtIndex:(NSUInteger)idx;
- (void)sk_beginEditingSpeakerAtIndex:(NSUInteger)idx;
- (void)sk_updateFind:(BOOL)reveal;
- (void)sk_findStep:(NSInteger)delta;
- (NSUInteger)sk_replaceAll:(BOOL)all;
- (void)sk_focusSearch;
- (SKWord *)sk_wordAtIndex:(NSUInteger)idx;
- (BOOL)sk_export:(NSInteger)kind toPath:(NSString *)path;
- (BOOL)sk_createCaptions:(id)sender;
- (BOOL)sk_seekSourceWord:(SKWord *)w;
- (BOOL)sk_markSourceSelection;
- (void)sk_updateSourceButtons;
- (BOOL)sk_editSource:(NSString *)kind;
- (void)sk_tickSource:(SKWord *)sample;
- (void)sk_reattachIfNeeded;
- (void)sk_focusPlaybackOwner;
- (NSSegmentedControl *)sk_makeSizeControl;
- (void)sk_sizeChanged:(NSSegmentedControl *)sender;
- (void)sk_applyControlScale;
- (void)sk_layoutSections;
- (void)sk_toggleSection:(NSString *)sid;
- (void)sk_drawDecorationsInRect:(NSRect)dirty;
- (void)sk_showColorPickerFor:(NSString *)name anchor:(NSPoint)anchor;
- (void)sk_hoverAtViewPoint:(NSPoint)p;
- (void)sk_closeColorPicker;
- (void)sk_tick;
- (BOOL)sk_clickedCharacterAtIndex:(NSUInteger)idx;
- (void)sk_snapSelectionToWords;
- (BOOL)sk_deleteSelectionLift:(BOOL)lift;
@end

static __weak id gTabModule;                          // FCP's FFInspectorTabModule (set from the ids hook)
static __weak SKInspectorModuleTranscript *gModule;   // live module instance
static NSArray *gItems;                               // last items FCP asked the tab controller about
static NSMapTable *gTranscribeState;                  // asset -> @"running" or a failure reason (on-demand transcription)
static NSRange gRetryRange = {NSNotFound, 0};         // the blank line the Transcribe / Try again button sits on
static NSString *gTranscribeLabel;                    // that button's title
static NSArray *gUntranscribedClips, *gUntranscribedAssets;   // what that link would transcribe (from the last render)
static NSMutableDictionary *gSpeakers;                // media path -> speaker data (see Speakers)
static NSString *gSpeakerFilter;                      // display name to show exclusively, or nil
static BOOL gDetecting;
// Transcript text size: 1.0 (FCP's normal inspector size), 1.25 or 1.5. Remembered in user defaults.
static NSString *const kSKTextScaleKey = @"SKTranscriptTabTextScale";
static const double kSKTextScales[] = {1.0, 1.25, 1.5};
static double SKTextScale(void) {
    double v = [[NSUserDefaults standardUserDefaults] doubleForKey:kSKTextScaleKey];
    return v >= 1.0 && v <= 1.5 ? v : 1.0;
}
static CGFloat SKPt(CGFloat base) { return round(base * SKTextScale()); }
static double gPauseThreshold = 0.5;                  // shortest silence shown as a pause item, seconds

#pragma mark - FCP helpers

static id SKTimelineModule(void) {
    id delegate = [NSApp delegate];
    SEL aec = NSSelectorFromString(@"activeEditorContainer"), tm = NSSelectorFromString(@"timelineModule");
    if (![delegate respondsToSelector:aec]) return nil;
    id container = ((id(*)(id,SEL))objc_msgSend)(delegate, aec);
    return [container respondsToSelector:tm] ? ((id(*)(id,SEL))objc_msgSend)(container, tm) : nil;
}

static void SKTimelineAction(NSString *selName) {
    id tl = SKTimelineModule();
    SEL sel = NSSelectorFromString(selName);
    if ([tl respondsToSelector:sel]) ((void(*)(id,SEL,id))objc_msgSend)(tl, sel, nil);
    else if (![NSApp sendAction:sel to:nil from:nil]) TLog(@"nothing handled %@", selName);   // window-level commands such as goToTimeline:
}

static BOOL SKInvokeRange(id obj, NSString *selName, id arg, CMTimeRange *out) {
    SEL sel = NSSelectorFromString(selName);
    if (!SKReturnsRange(obj, sel)) return NO;
    *out = ((CMTimeRange(*)(id,SEL,id))objc_msgSend)(obj, sel, arg);
    return YES;
}

// The timeline's player clock (its FFContext), which tracks playback frame by frame — the same
// source the browser view follows. Falls back to the timeline module's currentSequenceTime.
static id SKTimelineContext(void) {
    id tl = SKTimelineModule();
    return [tl respondsToSelector:@selector(context)] ? ((id(*)(id,SEL))objc_msgSend)(tl, @selector(context)) : nil;
}
static double SKPlayheadSeconds(void) {
    id ctx = SKTimelineContext();
    if ([ctx respondsToSelector:NSSelectorFromString(@"time")]) {
        CMTime t = ((CMTime(*)(id,SEL))objc_msgSend)(ctx, NSSelectorFromString(@"time"));
        if (CMTIME_IS_NUMERIC(t)) return CMTimeGetSeconds(t);
    }
    id tl = SKTimelineModule();
    SEL sel = NSSelectorFromString(@"currentSequenceTime");
    if (![tl respondsToSelector:sel]) return -1;
    return CMTimeGetSeconds(((CMTime(*)(id,SEL))objc_msgSend)(tl, sel));
}
static BOOL SKTimelinePlaying(void) {
    id ctx = SKTimelineContext();
    return [ctx respondsToSelector:NSSelectorFromString(@"rate")] && ((double(*)(id,SEL))objc_msgSend)(ctx, NSSelectorFromString(@"rate")) != 0;
}

// The sequence's frame duration, or 1/600s if it can't be read.
static CMTime SKFrameDuration(void) {
    id tl = SKTimelineModule();
    SEL fdSel = NSSelectorFromString(@"sequenceFrameDuration");
    if ([tl respondsToSelector:fdSel]) {
        CMTime fd = ((CMTime(*)(id,SEL))objc_msgSend)(tl, fdSel);
        if (fd.timescale > 0 && fd.value > 0) return fd;
    }
    return CMTimeMake(1, 600);
}

// Seconds -> frame-aligned CMTime. direction > 0 picks the first frame at or after the time,
// < 0 the last frame at or before it, 0 the nearest.
static CMTime SKFrameTime(double seconds, int direction) {
    CMTime fd = SKFrameDuration();
    double frames = seconds * fd.timescale / fd.value;
    int64_t n = direction > 0 ? (int64_t)ceil(frames - 1e-6) : direction < 0 ? (int64_t)floor(frames + 1e-6) : (int64_t)llround(frames);
    return CMTimeMake(MAX(n, 0) * fd.value, fd.timescale);
}

static void SKSeek(double seconds) {
    id tl = SKTimelineModule();
    SEL set = NSSelectorFromString(@"setPlayheadTime:");
    if ([tl respondsToSelector:set]) ((void(*)(id,SEL,CMTime))objc_msgSend)(tl, set, SKFrameTime(seconds, 1));
}

// Clips in the open project's primary storyline, in timeline order.
static NSArray *SKPrimaryItems(void) {
    @try {
        id tl = SKTimelineModule();
        id sequence = [tl respondsToSelector:@selector(sequence)] ? ((id(*)(id,SEL))objc_msgSend)(tl, @selector(sequence)) : nil;
        id primary = [sequence respondsToSelector:NSSelectorFromString(@"primaryObject")] ? [sequence valueForKey:@"primaryObject"] : nil;
        id items = [primary valueForKey:@"containedItems"];
        return [items isKindOfClass:[NSArray class]] ? items : nil;
    } @catch (id e) { return nil; }
}

// Where a primary-storyline clip sits: its start on the timeline, and where its trim begins in
// the media. FCP's transcript word times count from the start of the file, while a clip's
// ranges are in its own time, which starts at the camera timecode (e.g. 19:14:00:00); the
// unclipped range's start is that origin, so subtracting it puts the trim in word time.
static BOOL SKClipPlacement(id clip, double *tlStart, double *trimStart, double *duration) {
    @try {
        id tl = SKTimelineModule();
        id sequence = ((id(*)(id,SEL))objc_msgSend)(tl, @selector(sequence));
        id primary = [sequence valueForKey:@"primaryObject"];
        CMTimeRange eff, clipped = kCMTimeRangeZero, unclipped = kCMTimeRangeZero;
        if (!SKInvokeRange(primary, @"effectiveRangeOfObject:", clip, &eff)) return NO;
        SKInvokeRange(clip, @"clippedRange", nil, &clipped);
        SKInvokeRange(clip, @"unclippedRange", nil, &unclipped);
        *tlStart = CMTimeGetSeconds(eff.start);
        *duration = CMTimeGetSeconds(eff.duration);
        *trimStart = CMTimeGetSeconds(clipped.start) - CMTimeGetSeconds(unclipped.start);
        return *duration > 0;
    } @catch (id e) { TLog(@"placement threw %@", e); return NO; }
}

static NSArray *SKAssetsForItem(id item);
// Connected clips (v76). Their words are shown only where the primary storyline is a gap, so
// primary dialogue is never interrupted and nothing overlaps. Gaps as {start, end} seconds.
static NSArray<NSValue *> *SKPrimaryGaps(NSArray *primary) {
    NSMutableArray *gaps = [NSMutableArray array];
    for (id it in primary) {
        if (![NSStringFromClass([it class]) containsString:@"Gap"]) continue;
        double a = 0, t = 0, d = 0;
        if (SKClipPlacement(it, &a, &t, &d)) [gaps addObject:[NSValue valueWithPoint:NSMakePoint(a, a + d)]];
    }
    return gaps;
}
static BOOL SKTimeInGaps(NSArray<NSValue *> *gaps, double t) {
    for (NSValue *v in gaps) if (t >= v.pointValue.x - 1e-4 && t < v.pointValue.y + 1e-4) return YES;
    return NO;
}
static BOOL SKCallBool(id obj, NSString *sel) {
    SEL s = NSSelectorFromString(sel);
    return [obj respondsToSelector:s] && ((BOOL(*)(id,SEL))objc_msgSend)(obj, s);
}
// Connected clips (and clips inside connected storylines) with media that overlap a primary gap,
// each as @{clip, tl, trim, dur} in timeline seconds (trim = where the visible part starts in the media).
static NSArray<NSDictionary *> *SKConnectedOverGaps(NSArray *primary, NSArray<NSValue *> *gaps) {
    NSMutableArray *out = [NSMutableArray array];
    if (!gaps.count) return out;
    @try {
        id seq = ((id(*)(id,SEL))objc_msgSend)(SKTimelineModule(), @selector(sequence));
        id prim = [seq valueForKey:@"primaryObject"];
        void (^add)(id, double, double) = ^(id item, double start, double dur) {
            if (dur <= 0 || !SKAssetsForItem(item).count) return;
            BOOL overGap = NO;
            for (NSValue *g in gaps) if (start < g.pointValue.y - 1e-4 && start + dur > g.pointValue.x + 1e-4) { overGap = YES; break; }
            if (!overGap) return;
            CMTimeRange clipped = kCMTimeRangeZero, unclipped = kCMTimeRangeZero;
            SKInvokeRange(item, @"clippedRange", nil, &clipped);
            SKInvokeRange(item, @"unclippedRange", nil, &unclipped);
            [out addObject:@{@"clip": item, @"tl": @(start), @"dur": @(dur),
                             @"trim": @(CMTimeGetSeconds(clipped.start) - CMTimeGetSeconds(unclipped.start))}];
        };
        for (id p in primary) {
            id anchored = [p respondsToSelector:NSSelectorFromString(@"anchoredItems")] ? [p valueForKey:@"anchoredItems"] : nil;
            NSArray *list = [anchored isKindOfClass:[NSSet class]] ? [(NSSet *)anchored allObjects] : [anchored isKindOfClass:[NSArray class]] ? anchored : @[];
            for (id a in list) {
                NSString *cls = NSStringFromClass([a class]);
                if ([cls containsString:@"Caption"] || [cls containsString:@"Marker"]) continue;
                CMTimeRange eff;
                if (!SKInvokeRange(prim, @"effectiveRangeOfObject:", a, &eff)) continue;
                double start = CMTimeGetSeconds(eff.start), dur = CMTimeGetSeconds(eff.duration);
                if (SKCallBool(a, @"isConnectedStoryline")) {
                    // Clips inside a connected storyline: their range in the storyline's own time,
                    // shifted to where the storyline sits on the timeline.
                    CMTimeRange sc = kCMTimeRangeZero; SKInvokeRange(a, @"clippedRange", nil, &sc);
                    for (id inner in [a valueForKey:@"containedItems"]) {
                        CMTimeRange ie;
                        if (!SKInvokeRange(a, @"effectiveRangeOfObject:", inner, &ie)) continue;
                        add(inner, start + CMTimeGetSeconds(ie.start) - CMTimeGetSeconds(sc.start), CMTimeGetSeconds(ie.duration));
                    }
                } else add(a, start, dur);
            }
        }
    } @catch (id e) { TLog(@"connected clips threw %@", e); }
    return out;
}

// The FCP proxy file for an asset, if FCP has one on disk. Proxies keep every audio channel and
// the original's timing, and are a fraction of the size, so audio comes out of them far faster
// (39 min: ~7 s from the proxy vs ~145 s from a 4K MXF on the same drive).
static NSString *SKProxyPathUncached(id asset) {
    @try {
        SEL avail = NSSelectorFromString(@"proxyAvailable"), rep = NSSelectorFromString(@"proxyMediaRep");
        if (![asset respondsToSelector:avail] || !((BOOL(*)(id,SEL))objc_msgSend)(asset, avail) || ![asset respondsToSelector:rep]) return nil;
        id mediaRep = ((id(*)(id,SEL))objc_msgSend)(asset, rep);
        NSURL *url = [mediaRep respondsToSelector:NSSelectorFromString(@"fileURL")] ? [mediaRep valueForKey:@"fileURL"] : nil;
        NSString *path = [url.path stringByResolvingSymlinksInPath];
        return path && [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
    } @catch (id e) { return nil; }
}

static NSString *SKProxyPath(id asset) {
    static NSMapTable *cache; static CFAbsoluteTime born;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!cache || now - born > 900) { cache = [NSMapTable strongToStrongObjectsMapTable]; born = now; }
    id hit = [cache objectForKey:asset];
    if (hit) return [hit isKindOfClass:[NSNull class]] ? nil : hit;
    NSString *p = SKProxyPathUncached(asset);
    [cache setObject:p ?: (id)[NSNull null] forKey:asset];
    return p;
}

static NSArray *SKAssetsForItem(id item) {
    if (![item respondsToSelector:NSSelectorFromString(@"assets")]) return @[];
    id a = [item valueForKey:@"assets"];
    return [a isKindOfClass:[NSSet class]] ? [(NSSet *)a allObjects] : @[];
}

// FCP's stored transcript for an asset, else one we generated this session, else nil.
static NSString *SKMediaPath(id asset);
static id SKTranscriptForAsset(id asset) {
    id retriever = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFTranscriptRetriever"), NSSelectorFromString(@"sharedInstance"));
    if (((BOOL(*)(id,SEL,id))objc_msgSend)(retriever, NSSelectorFromString(@"hasTranscriptForAsset:"), asset)) {
        NSError *err = nil;
        id t = ((id(*)(id,SEL,id,NSError**))objc_msgSend)(retriever, NSSelectorFromString(@"fetchTranscriptForAsset:error:"), asset, &err);
        // A stored transcript with no words (e.g. from an interrupted transcription) counts as
        // missing, so the panel offers Transcribe instead of "No speech" (v72).
        if (t) {
            for (id phrase in (NSArray *)[t valueForKey:@"phrases"]) if ([[phrase valueForKey:@"words"] count]) return t;
            static NSMutableSet *loggedEmpty;
            if (!loggedEmpty) loggedEmpty = [NSMutableSet set];
            if (![loggedEmpty containsObject:asset]) { [loggedEmpty addObject:asset]; TLog(@"stored transcript for %@ has no words; treating it as missing", SKMediaPath(asset).lastPathComponent); }
            return nil;
        }
        TLog(@"stored transcript fetch failed: %@", err);
    }
    return nil;
}

// A short-lived cache of each asset's words (and media / proxy paths). Fetching FCP's stored
// transcript and walking it through KVC for every refresh was the bulk of a refresh. Only
// transcripts WITH words are cached (a missing one is re-checked every time, so the Transcribe flow
// sees it appear at once); everything expires after 15 min, and a finished transcription clears it.
@interface SKRawWord : NSObject
@property (nonatomic, copy) NSString *text;
@property (nonatomic) double s, e;
@end
@implementation SKRawWord
@end
static NSMapTable *gPhraseCache;       // asset -> NSArray<NSArray<SKRawWord *> *>
static CFAbsoluteTime gPhraseCacheBorn;
static void SKClearAssetCaches(void) { gPhraseCache = nil; }
static NSArray<NSArray<SKRawWord *> *> *SKPhrasesForAsset(id asset) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!gPhraseCache || now - gPhraseCacheBorn > 900) { gPhraseCache = [NSMapTable strongToStrongObjectsMapTable]; gPhraseCacheBorn = now; }
    NSArray *hit = [gPhraseCache objectForKey:asset];
    if (hit) return hit;
    id transcript = SKTranscriptForAsset(asset);
    if (!transcript) return nil;
    NSMutableArray *phrases = [NSMutableArray array];
    for (id phrase in (NSArray *)[transcript valueForKey:@"phrases"]) {
        NSArray *pw = [phrase valueForKey:@"words"];
        if (![pw isKindOfClass:[NSArray class]]) continue;
        NSMutableArray *list = [NSMutableArray arrayWithCapacity:pw.count];
        for (id w in pw) {
            NSString *t = [[w valueForKey:@"text"] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (!t.length) continue;
            CMTimeRange tr = SKTimeRange(w);
            SKRawWord *rw = [SKRawWord new];
            rw.text = t; rw.s = CMTimeGetSeconds(tr.start); rw.e = rw.s + CMTimeGetSeconds(tr.duration);
            [list addObject:rw];
        }
        [phrases addObject:list];
    }
    [gPhraseCache setObject:phrases forKey:asset];
    return phrases;
}

// Browser clips (event clips) whose media is one of `assets`, across all open libraries.
// Analyze and Fix works on browser clips, so a project or timeline clip is transcribed through
// the browser clip of the same media — what you'd select by hand.
static NSArray *SKBrowserClipsForAssets(NSArray *assets) {
    NSMutableArray *out = [NSMutableArray array];
    NSSet *want = [NSSet setWithArray:assets];
    id libs = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
    for (id lib in libs) for (id ev in [lib valueForKey:@"events"]) {
        id proj = [ev respondsToSelector:@selector(project)] ? [ev valueForKey:@"project"] : nil;
        id clips = [proj respondsToSelector:NSSelectorFromString(@"ownedClips")] ? [proj valueForKey:@"ownedClips"] : nil;
        for (id clip in clips) {
            NSArray *ca = SKAssetsForItem(clip);
            if (ca.count == 1 && [want containsObject:ca.firstObject] && ![out containsObject:clip]) [out addObject:clip];
        }
    }
    return out;
}

static void SKRefreshModule(void);
static void SKClearAssetCaches(void);
// Every 2 s: redraw as transcripts land in FCP's store. If FCP has no transcription task running
// for 15 s and some are still missing, mark those as failed so the panel can offer Try again.
static void SKPollTranscription(NSArray *assets, CFAbsoluteTime started) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        static CFAbsoluteTime lastBusy;
        id coord = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFTranscriptionCoordinator"), NSSelectorFromString(@"sharedCoordinator"));
        BOOL busy = ((BOOL(*)(id,SEL))objc_msgSend)(coord, NSSelectorFromString(@"hasTranscriptionTasksInProgress"));
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (busy) lastBusy = now;
        double idleFor = now - MAX(lastBusy, started);
        NSUInteger done = 0; NSMutableArray *pending = [NSMutableArray array];
        for (id a in assets) {
            if (![[gTranscribeState objectForKey:a] isEqualToString:@"running"]) continue;
            if (SKTranscriptForAsset(a)) { [gTranscribeState removeObjectForKey:a]; done++; }
            else [pending addObject:a];
        }
        if (done) { TLog(@"transcribe: %lu transcript(s) stored by FCP", (unsigned long)done); SKClearAssetCaches(); SKRefreshModule(); }
        if (!pending.count) return;
        if (!busy && idleFor > 15) {
            TLog(@"transcribe: FCP idle with %lu asset(s) still untranscribed after %.0fs", (unsigned long)pending.count, now - started);
            for (id a in pending) [gTranscribeState setObject:@"Final Cut Pro finished without producing a transcript" forKey:a];
            SKRefreshModule();
            return;
        }
        SKPollTranscription(pending, started);
    });
}

#pragma mark - Speakers
// FCP's transcripts carry no speaker information, so speakers are kept here, per media file:
//   words:     @[@[start, end, speakerID], …] from SpliceKit's parakeet-transcriber --speakers
//   overrides: @[@[start, end, speakerID], …] manual assignments in source time; later entries win
//   names:     @{speakerID: display name}
// Saved as JSON so labels survive an FCP restart.

static NSString *SKSpeakerStorePath(void) {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/SpliceKit"];
    return [dir stringByAppendingPathComponent:@"transcript-tab-speakers.json"];
}

static void SKLoadSpeakers(void) {
    if (gSpeakers) return;
    gSpeakers = [NSMutableDictionary dictionary];
    NSData *data = [NSData dataWithContentsOfFile:SKSpeakerStorePath()];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:NULL] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return;
    // Merge entries saved under a library's link path into the real file path (older builds
    // keyed by the link). Detected words: keep the larger set; everything else is combined.
    BOOL migrated = NO;
    for (NSString *key in json) {
        NSString *real = [key stringByResolvingSymlinksInPath];
        NSMutableDictionary *in = json[key], *have = gSpeakers[real];
        if (![real isEqualToString:key]) migrated = YES;
        if (!have) { gSpeakers[real] = in; continue; }
        if ([in[@"words"] count] > [have[@"words"] count]) have[@"words"] = in[@"words"];
        if ([in[@"overrides"] count]) have[@"overrides"] = [[have[@"overrides"] ?: @[] arrayByAddingObjectsFromArray:in[@"overrides"]] mutableCopy];
        NSMutableDictionary *names = [have[@"names"] mutableCopy] ?: [NSMutableDictionary dictionary];
        [names addEntriesFromDictionary:in[@"names"] ?: @{}]; have[@"names"] = names;
        NSMutableDictionary *corr = [have[@"corrections"] mutableCopy] ?: [NSMutableDictionary dictionary];
        [corr addEntriesFromDictionary:in[@"corrections"] ?: @{}]; have[@"corrections"] = corr;
        migrated = YES;
    }
    TLog(@"speaker store: %lu file(s)%@", (unsigned long)gSpeakers.count, migrated ? @", merged by real path" : @"");
    if (migrated) {
        NSData *out = [NSJSONSerialization dataWithJSONObject:gSpeakers options:0 error:NULL];
        [out writeToFile:SKSpeakerStorePath() atomically:YES];
    }
}

static void SKSaveSpeakers(void) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:gSpeakers options:0 error:NULL];
    [data writeToFile:SKSpeakerStorePath() atomically:YES];
}

static NSMutableDictionary *SKSpeakerEntry(NSString *path, BOOL create) {
    SKLoadSpeakers();
    if (!path) return nil;
    NSMutableDictionary *e = gSpeakers[path];
    if (!e && create) {
        e = [@{@"words": @[], @"overrides": [NSMutableArray array], @"names": [NSMutableDictionary dictionary], @"corrections": [NSMutableDictionary dictionary]} mutableCopy];
        gSpeakers[path] = e;
    }
    return e;
}

// The media file behind an asset, with symlinks resolved. Each library reaches an external
// file through its own link (…/Library.fcpbundle/Event/Original Media/clip.mxf), so the real
// path is what lets speaker labels and corrections follow a clip between libraries.
static NSString *SKMediaPathUncached(id asset) {
    for (NSString *keyPath in @[@"resolvedURL", @"originalMediaURL", @"URL", @"assetMediaReference.resolvedURL", @"media.originalMediaURL", @"originalMediaRep.URL"]) {
        @try {
            id v = [asset valueForKeyPath:keyPath];
            if ([v isKindOfClass:[NSURL class]]) return [[(NSURL *)v path] stringByResolvingSymlinksInPath];
        } @catch (id e) {}
    }
    return nil;
}
// Cached for 60 s (a failed key path throws, and the symlink resolution hits the disk).
static NSString *SKMediaPath(id asset) {
    static NSMapTable *cache; static CFAbsoluteTime born;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!cache || now - born > 900) { cache = [NSMapTable strongToStrongObjectsMapTable]; born = now; }
    id hit = [cache objectForKey:asset];
    if (hit) return [hit isKindOfClass:[NSNull class]] ? nil : hit;
    NSString *p = SKMediaPathUncached(asset);
    [cache setObject:p ?: (id)[NSNull null] forKey:asset];
    return p;
}

// Speaker ID at a source time: manual overrides first, then the detected word nearest in time.
static NSString *SKSpeakerIDAt(NSDictionary *entry, double t) {
    for (NSArray *o in [entry[@"overrides"] reverseObjectEnumerator])
        if (t >= [o[0] doubleValue] && t < [o[1] doubleValue]) return o[2];
    NSArray *words = entry[@"words"];
    if (words.count == 0) return nil;
    NSUInteger lo = 0, hi = words.count;   // last word starting at or before t
    while (hi - lo > 1) { NSUInteger mid = (lo + hi) / 2; if ([words[mid][0] doubleValue] <= t) lo = mid; else hi = mid; }
    NSArray *w = words[lo];
    if (t > [w[1] doubleValue] && lo + 1 < words.count && [words[lo + 1][0] doubleValue] - t < t - [w[1] doubleValue]) w = words[lo + 1];
    return w[2];
}

static NSString *SKSpeakerName(NSDictionary *entry, NSString *sid) {
    NSString *name = entry[@"names"][sid];
    if (name.length) return name;
    if ([sid hasPrefix:@"S"] && [[sid substringFromIndex:1] integerValue] > 0) return [NSString stringWithFormat:@"Speaker %@", [sid substringFromIndex:1]];
    return sid;
}

// The ID a display name maps to in this file, or the name itself for a brand-new speaker.
static NSString *SKSpeakerIDForName(NSMutableDictionary *entry, NSString *name) {
    NSMutableSet *ids = [NSMutableSet setWithArray:[entry[@"names"] allKeys]];
    for (NSArray *w in entry[@"words"]) [ids addObject:w[2]];
    for (NSArray *o in entry[@"overrides"]) [ids addObject:o[2]];
    for (NSString *sid in ids) if ([SKSpeakerName(entry, sid) isEqualToString:name]) return sid;
    entry[@"names"][name] = name;
    return name;
}

// FCP's role color palette (the role color picker, 2 columns x 9 rows), averaged from a screenshot.
// Speakers take these colors; each name keeps its color everywhere (saved in FCP's defaults).
static const uint32_t kSKRolePalette[18] = {0x1E3452, 0x18532D, 0x1A565B, 0x4F3783, 0x7F4F1D, 0x581D31, 0x415F1A, 0x863E1B, 0x1A5647,
                                            0x532362, 0x852919, 0x604E19, 0x2B3561, 0x21581B, 0x591F4C, 0x284A5A, 0x585B1A, 0x362E69};
static const int kSKSpeakerColorOrder[18] = {0, 7, 1, 3, 2, 10, 11, 9, 15, 6, 4, 8, 12, 5, 13, 14, 16, 17};   // distinct hues first
static NSString *const kSKSpeakerColorsKey = @"SKTranscriptTabSpeakerColors";
static NSColor *SKRoleColor(NSInteger i) {
    uint32_t h = kSKRolePalette[MAX(0, MIN(17, i))];
    return [NSColor colorWithSRGBRed:((h >> 16) & 255) / 255.0 green:((h >> 8) & 255) / 255.0 blue:(h & 255) / 255.0 alpha:1];
}
// The palette index for a speaker name; a new name gets the first unused color in kSKSpeakerColorOrder.
static NSInteger SKSpeakerColorIndex(NSString *name) {
    if (!name.length) return -1;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSDictionary *saved = [d dictionaryForKey:kSKSpeakerColorsKey] ?: @{};
    NSNumber *n = saved[name];
    if ([n isKindOfClass:[NSNumber class]] && n.integerValue >= 0 && n.integerValue < 18) return n.integerValue;
    NSSet *used = [NSSet setWithArray:saved.allValues];
    NSInteger pick = kSKSpeakerColorOrder[saved.count % 18];
    for (int i = 0; i < 18; i++) if (![used containsObject:@(kSKSpeakerColorOrder[i])]) { pick = kSKSpeakerColorOrder[i]; break; }
    NSMutableDictionary *m = [saved mutableCopy];
    m[name] = @(pick);
    [d setObject:m forKey:kSKSpeakerColorsKey];
    return pick;
}
static void SKSetSpeakerColorIndex(NSString *name, NSInteger i) {
    if (!name.length) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSMutableDictionary *m = [[d dictionaryForKey:kSKSpeakerColorsKey] mutableCopy] ?: [NSMutableDictionary dictionary];
    if (i < 0) [m removeObjectForKey:name]; else m[name] = @(i);
    [d setObject:m forKey:kSKSpeakerColorsKey];
}
// The swatch, brightened in its own hue and lightened so it reads as text (and as a bar) on the dark inspector.
static NSColor *SKSpeakerTextColor(NSString *name) {
    NSInteger i = SKSpeakerColorIndex(name);
    if (i < 0) return [NSColor secondaryLabelColor];
    uint32_t h = kSKRolePalette[i];
    double c[3] = {(h >> 16) & 255, (h >> 8) & 255, h & 255}, mx = MAX(1, MAX(c[0], MAX(c[1], c[2])));
    for (int k = 0; k < 3; k++) { c[k] = MIN(255, c[k] * 255 / mx * 0.92); c[k] += (255 - c[k]) * 0.28; }
    return [NSColor colorWithSRGBRed:c[0] / 255 green:c[1] / 255 blue:c[2] / 255 alpha:1];
}
static NSImage *SKSwatchImage(NSColor *c) {
    return [NSImage imageWithSize:NSMakeSize(16, 12) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [c setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(r, 1, 1) xRadius:2 yRadius:2] fill];
        return YES;
    }];
}

// View settings (v63), saved in FCP's defaults.
static NSString *const kSKTimecodeKey = @"SKTranscriptTabTimecode";             // 0 short, 1 min:sec:frames, 2 project timecode, 3 hidden
static NSString *const kSKColorBarsKey = @"SKTranscriptTabColorBars";
static NSString *const kSKCollapsedKey = @"SKTranscriptTabCollapsedSections";
static NSString *const kSKDarkBackgroundKey = @"SKTranscriptTabDarkBackground";   // NO (default): row gray #2D2D2D; YES: inspector dark #1F1F1F
static NSColor *SKTranscriptBackground(void) {
    return [NSColor colorWithWhite:[[NSUserDefaults standardUserDefaults] boolForKey:kSKDarkBackgroundKey] ? 0.122 : 0.176 alpha:1];
}
static NSInteger SKTimecodeMode(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kSKTimecodeKey];
    return v ? MAX(0, MIN(3, [v integerValue])) : 1;
}
static BOOL SKColorBars(void) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:kSKColorBarsKey];
    return v ? [v boolValue] : YES;
}
static NSArray *SKCollapsedSections(void) {
    return [[NSUserDefaults standardUserDefaults] arrayForKey:kSKCollapsedKey] ?: @[@"find"];   // Find & Replace starts folded
}
static NSString *SKTimecodeDF(double t);
// A transcript line's time in the chosen style. `frame` is the frame duration to count in.
static NSString *SKStampText(double t, CMTime frame, NSInteger mode) {
    if (mode == 3) return @"";
    if (frame.value <= 0 || frame.timescale <= 0) frame = CMTimeMake(1, 30);
    int64_t fps = MAX(1, llround((double)frame.timescale / frame.value));
    int64_t frames = (int64_t)floor(MAX(0, t) * frame.timescale / frame.value + 1e-6), secs = frames / fps, ff = frames % fps;
    if (mode == 0) return [NSString stringWithFormat:@"%lld:%02lld", secs / 60, secs % 60];
    if (mode == 1) return [NSString stringWithFormat:@"%lld:%02lld:%02lld", secs / 60, secs % 60, ff];
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld:%02lld", secs / 3600, secs / 60 % 60, secs % 60, ff];
}

#pragma mark - Section header and fill views

@implementation SKSectionHeaderView
- (instancetype)initWithTitle:(NSString *)title sectionID:(NSString *)sid owner:(id)owner {
    self = [super initWithFrame:NSMakeRect(0, 0, 400, 22)];
    if (!self) return nil;
    self.sectionID = sid; self.owner = owner;
    self.titleLabel = [NSTextField labelWithString:title];
    self.titleLabel.textColor = [NSColor colorWithWhite:0.69 alpha:1];
    self.hideLabel = [NSTextField labelWithString:@"Hide"];
    self.hideLabel.textColor = [NSColor colorWithWhite:0.45 alpha:1];
    self.hideLabel.hidden = YES;
    [self addSubview:self.titleLabel]; [self addSubview:self.hideLabel];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil]];
    return self;
}
- (void)setFont:(NSFont *)bold plain:(NSFont *)plain {
    self.titleLabel.font = bold; self.hideLabel.font = plain;
    [self resizeSubviewsWithOldSize:self.bounds.size];
}
- (void)resizeSubviewsWithOldSize:(NSSize)old {
    NSSize t = self.titleLabel.intrinsicContentSize, h = self.hideLabel.intrinsicContentSize;
    CGFloat H = NSHeight(self.bounds), W = NSWidth(self.bounds);
    self.titleLabel.frame = NSMakeRect(10, floor((H - t.height) / 2), MAX(0, W - 20 - h.width - 8), t.height);
    self.hideLabel.frame = NSMakeRect(W - 10 - h.width, floor((H - h.height) / 2), h.width, h.height);
}
- (void)setCollapsed:(BOOL)collapsed {
    _collapsed = collapsed;
    self.hideLabel.stringValue = collapsed ? @"Show" : @"Hide";
    [self resizeSubviewsWithOldSize:self.bounds.size];
    self.toolTip = collapsed ? [NSString stringWithFormat:@"Show %@", self.titleLabel.stringValue] : [NSString stringWithFormat:@"Hide %@", self.titleLabel.stringValue];
}
- (void)mouseEntered:(NSEvent *)e { self.hideLabel.hidden = NO; }
- (void)mouseExited:(NSEvent *)e { self.hideLabel.hidden = YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (void)mouseDown:(NSEvent *)e { [(SKInspectorModuleTranscript *)self.owner sk_toggleSection:self.sectionID]; }
- (void)drawRect:(NSRect)dirty {
    [[NSColor colorWithWhite:0.078 alpha:1] setFill];   // hairline between sections (#141414)
    NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1, NSWidth(self.bounds), 1));
}
@end

static const CGFloat kSKSwatch = 30, kSKSwatchH = 31, kSKPickerPad = 2, kSKPickerArrow = 10;   // measured from FCP's role color picker

@implementation SKRoleColorPicker
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (NSRect)sk_cell:(NSInteger)i { return NSMakeRect(kSKPickerPad + (i % 2) * kSKSwatch, kSKPickerPad + (i / 2) * kSKSwatchH, kSKSwatch, kSKSwatchH); }
- (NSInteger)sk_indexAt:(NSPoint)p {
    for (NSInteger i = 0; i < 18; i++) if (NSPointInRect(p, [self sk_cell:i])) return i;
    return -1;
}
- (void)updateTrackingAreas {
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
    [super updateTrackingAreas];
}
- (void)mouseMoved:(NSEvent *)e {
    NSInteger i = [self sk_indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i != self.hover) { self.hover = i; [self setNeedsDisplay:YES]; }
}
- (void)mouseExited:(NSEvent *)e { self.hover = -1; [self setNeedsDisplay:YES]; }
- (void)mouseDown:(NSEvent *)e {}
- (void)mouseUp:(NSEvent *)e {
    NSInteger i = [self sk_indexAt:[self convertPoint:e.locationInWindow fromView:nil]];
    if (i >= 0 && self.onPick) self.onPick(i);
}
- (void)drawRect:(NSRect)dirty {
    // Matches FCP's role color picker (measured from a screenshot): the swatches fill the panel,
    // framed by a 1 px #494949 line inside a 1 px near-black outline, and nothing else (v67: a light
    // inner edge read as a thicker frame); the grid has rounded ends; a slate-blue pointer sits on the right edge.
    NSRect grid = NSMakeRect(kSKPickerPad, kSKPickerPad, kSKSwatch * 2, kSKSwatchH * 9);
    CGFloat rad = 13;
    [[NSColor colorWithSRGBRed:0.04 green:0.03 blue:0.07 alpha:1] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(grid, -2, -2) xRadius:rad + 2 yRadius:rad + 2] fill];
    [[NSColor colorWithWhite:0.286 alpha:1] setFill];   // #494949
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(grid, -1, -1) xRadius:rad + 1 yRadius:rad + 1] fill];
    [NSGraphicsContext saveGraphicsState];
    NSBezierPath *clip = [NSBezierPath bezierPathWithRoundedRect:grid xRadius:rad yRadius:rad];
    [clip addClip];
    for (NSInteger i = 0; i < 18; i++) { [SKRoleColor(i) setFill]; NSRectFill([self sk_cell:i]); }
    [NSGraphicsContext restoreGraphicsState];
    if (self.selected >= 0 && self.selected < 18) {
        NSBezierPath *sel = [NSBezierPath bezierPathWithRect:NSInsetRect([self sk_cell:self.selected], 1.5, 1.5)];
        sel.lineWidth = 2; [[NSColor whiteColor] setStroke]; [sel stroke];
    }
    if (self.hover >= 0 && self.hover != self.selected) {
        NSBezierPath *hv = [NSBezierPath bezierPathWithRect:NSInsetRect([self sk_cell:self.hover], 1, 1)];
        hv.lineWidth = 1.5; [[NSColor colorWithWhite:1 alpha:0.6] setStroke]; [hv stroke];
    }
    // Pointer: from the panel's right edge out to the tip, level with arrowY.
    CGFloat h = 11, baseX = NSMaxX(grid) + 1, tipX = baseX + kSKPickerArrow - 1;
    CGFloat ay = MAX(NSMinY(grid) + rad + h, MIN(NSMaxY(grid) - rad - h, self.arrowY));
    NSBezierPath *arrow = [NSBezierPath bezierPath];
    [arrow moveToPoint:NSMakePoint(baseX, ay - h)];
    [arrow lineToPoint:NSMakePoint(tipX, ay)];
    [arrow lineToPoint:NSMakePoint(baseX, ay + h)];
    [arrow closePath];
    [[NSColor colorWithSRGBRed:0.243 green:0.302 blue:0.451 alpha:1] setFill];   // #3E4D73
    [arrow fill];
    NSBezierPath *edge = [NSBezierPath bezierPath];
    [edge moveToPoint:NSMakePoint(baseX, ay - h)];
    [edge lineToPoint:NSMakePoint(tipX, ay)];
    [edge lineToPoint:NSMakePoint(baseX, ay + h)];
    edge.lineWidth = 2; edge.lineJoinStyle = NSLineJoinStyleRound;
    [[NSColor colorWithSRGBRed:0.08 green:0.09 blue:0.13 alpha:1] setStroke]; [edge stroke];   // dark outline
    edge.lineWidth = 1;
    [[NSColor colorWithSRGBRed:0.325 green:0.373 blue:0.490 alpha:1] setStroke]; [edge stroke];   // #535F7D lighter edge
}
@end

@implementation SKFillView
- (void)drawRect:(NSRect)dirty {
    [self.fill setFill];
    NSRectFill(dirty);
    if (self.rowHeight > 0) {
        [[NSColor colorWithWhite:0.15 alpha:1] setFill];   // #262626 between parameter rows
        for (CGFloat y = self.rowHeight; y < NSHeight(self.bounds) - 1; y += self.rowHeight) NSRectFill(NSMakeRect(0, round(y), NSWidth(self.bounds), 1));
    }
    if (self.topLine) {
        [[NSColor colorWithWhite:0.078 alpha:1] setFill];
        NSRectFill(NSMakeRect(0, NSHeight(self.bounds) - 1, NSWidth(self.bounds), 1));
    }
}
@end

#pragma mark - Text view

@implementation SKTranscriptTextView
- (void)drawViewBackgroundInRect:(NSRect)rect {
    [super drawViewBackgroundInRect:rect];
    [self.module sk_drawDecorationsInRect:rect];
}
// Hover over a speaker name's line shows FCP's role color circle beside the name.
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *t in self.trackingAreas) if (t.owner == self && (t.options & NSTrackingMouseMoved)) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveInActiveApp | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e {
    [super mouseMoved:e];
    [self.module sk_hoverAtViewPoint:[self convertPoint:e.locationInWindow fromView:nil]];
}
- (void)mouseExited:(NSEvent *)e {
    [super mouseExited:e];
    [self.module sk_hoverAtViewPoint:NSMakePoint(-1e6, -1e6)];
}
// Map a point in view coordinates to a character and tell the module. Returns NO if the point is not on a glyph.
- (BOOL)sk_handleClickAtViewPoint:(NSPoint)p {
    p.x -= self.textContainerOrigin.x; p.y -= self.textContainerOrigin.y;
    CGFloat frac = 0;
    NSUInteger glyph = [self.layoutManager glyphIndexForPoint:p inTextContainer:self.textContainer fractionOfDistanceThroughGlyph:&frac];
    NSRect r = [self.layoutManager boundingRectForGlyphRange:NSMakeRange(glyph, 1) inTextContainer:self.textContainer];
    if (!NSPointInRect(p, r)) return NO;
    if ([self.module sk_clickedCharacterAtIndex:[self.layoutManager characterIndexForGlyphAtIndex:glyph]]) {
        // Hand keyboard focus to whatever the transcript belongs to once the click finishes, so
        // Space/JKL drive playback straight away instead of landing in this text view.
        dispatch_async(dispatch_get_main_queue(), ^{ [self.module sk_focusPlaybackOwner]; });
    }
    return YES;
}

// A plain click seeks; a drag leaves a selection, which we widen to whole words and keep focus for.
// Right-click: speaker menu for the clicked line (or the current selection).
- (NSMenu *)menuForEvent:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSPoint q = NSMakePoint(p.x - self.textContainerOrigin.x, p.y - self.textContainerOrigin.y);
    NSUInteger glyph = [self.layoutManager glyphIndexForPoint:q inTextContainer:self.textContainer];
    NSMenu *menu = [self.module sk_contextMenuAtIndex:[self.layoutManager characterIndexForGlyphAtIndex:glyph]];
    return menu ?: [super menuForEvent:event];
}

// A double-click opens the word for correction.
- (void)mouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    [super mouseDown:event];   // returns after mouse-up
    if (event.clickCount == 2) {
        NSPoint q = NSMakePoint(p.x - self.textContainerOrigin.x, p.y - self.textContainerOrigin.y);
        NSUInteger glyph = [self.layoutManager glyphIndexForPoint:q inTextContainer:self.textContainer];
        NSUInteger idx = [self.layoutManager characterIndexForGlyphAtIndex:glyph];
        if ([self.module sk_speakerLabelAtIndex:idx]) [self.module sk_beginEditingSpeakerAtIndex:idx];
        else [self.module sk_beginEditingWord:[self.module sk_wordAtIndex:idx]];
        return;
    }
    if (self.selectedRange.length == 0) [self sk_handleClickAtViewPoint:p];
    else { [self.module sk_snapSelectionToWords]; [self.module sk_markSourceSelection]; }
}

// Delete cuts the selected words out of the timeline (Shift-Delete leaves a gap). Every other
// key belongs to FCP: pass it to the timeline, then take focus back so the selection stays live.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.window.firstResponder == self && (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) == NSEventModifierFlagCommand
        && [event.charactersIgnoringModifiers isEqualToString:@"f"]) { [self.module sk_focusSearch]; return YES; }
    return [super performKeyEquivalent:event];
}

- (void)keyDown:(NSEvent *)event {
    if ((event.keyCode == 36 || event.keyCode == 76) && self.selectedRange.length > 0) {   // Return: correct the selected word
        [self.module sk_beginEditingWord:[self.module sk_wordAtIndex:self.selectedRange.location]];
        return;
    }
    BOOL isDelete = event.keyCode == 51 || event.keyCode == 117;
    if (isDelete && self.selectedRange.length > 0) {
        TLog(@"keyDown delete (shift=%d)", (event.modifierFlags & NSEventModifierFlagShift) != 0);
        if (![self.module sk_deleteSelectionLift:(event.modifierFlags & NSEventModifierFlagShift) != 0]) NSBeep();
        return;
    }
    static BOOL forwarding;
    if (forwarding) return;
    forwarding = YES;
    [self.module sk_focusPlaybackOwner];
    [NSApp sendEvent:event];
    forwarding = NO;
    if (self.selectedRange.length > 0) [self.window makeFirstResponder:self];
}
@end

#pragma mark - Module

@implementation SKInspectorModuleTranscript
- (void)sk_build {
    if (self.built) return;
    self.built = YES;
    gModule = self;
    self.highlighted = NSMakeRange(NSNotFound, 0);
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 600)];
    container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSButton *(^barButton)(SEL) = ^(SEL action) {
        NSButton *b = [NSButton buttonWithTitle:@"" target:self action:action];
        b.bezelStyle = NSBezelStylePush; b.controlSize = NSControlSizeSmall;
        b.font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]];
        return b;
    };
    self.fillerButton = barButton(@selector(sk_deleteFillersClicked:));
    self.pauseButton = barButton(@selector(sk_deletePausesClicked:));
    NSPopUpButton *threshold = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    threshold.controlSize = NSControlSizeSmall; threshold.font = self.fillerButton.font;
    for (NSNumber *tenths in @[@3, @5, @10, @20]) {
        [threshold addItemWithTitle:[NSString stringWithFormat:@"≥ %.1fs", tenths.intValue / 10.0]];
        threshold.lastItem.tag = tenths.intValue;
    }
    [threshold selectItemWithTag:(NSInteger)llround(gPauseThreshold * 10)];
    threshold.target = self; threshold.action = @selector(sk_thresholdChanged:);
    threshold.toolTip = @"Shortest silence shown as a pause";
    self.thresholdPopup = threshold;
    NSPopUpButton *(^barPopup)(BOOL) = ^(BOOL pullsDown) {
        NSPopUpButton *pop = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:pullsDown];
        pop.controlSize = NSControlSizeSmall; pop.font = self.fillerButton.font;
        return pop;
    };
    self.speakerPopup = barPopup(NO);
    self.speakerPopup.target = self; self.speakerPopup.action = @selector(sk_filterChanged:);
    self.speakerPopup.toolTip = @"Show only one speaker";
    self.assignPopup = barPopup(YES);
    self.assignPopup.toolTip = @"Label the selected words";
    self.detectButton = barButton(@selector(sk_detectSpeakers:));
    // Row 3: find.  Row 4: replace.
    self.searchField = [[NSSearchField alloc] initWithFrame:NSZeroRect];
    self.searchField.controlSize = NSControlSizeSmall; self.searchField.font = self.fillerButton.font;
    self.searchField.placeholderString = @"Find in transcript";
    self.searchField.sendsSearchStringImmediately = YES;
    self.searchField.delegate = self;
    self.findCount = [NSTextField labelWithString:@""];
    self.findCount.font = self.fillerButton.font; self.findCount.textColor = [NSColor secondaryLabelColor];
    self.prevButton = barButton(@selector(sk_findPrev:)); self.prevButton.title = @"‹";
    self.nextButton = barButton(@selector(sk_findNext:)); self.nextButton.title = @"›";
    self.replaceField = [NSTextField textFieldWithString:@""];
    self.replaceField.controlSize = NSControlSizeSmall; self.replaceField.font = self.fillerButton.font;
    self.replaceField.placeholderString = @"Replace with";
    self.replaceField.delegate = self;
    self.replaceButton = barButton(@selector(sk_replaceOneClicked:)); self.replaceButton.title = @"Replace";
    self.replaceAllButton = barButton(@selector(sk_replaceAllClicked:)); self.replaceAllButton.title = @"All";
    for (NSControl *f in @[self.searchField, self.replaceField]) {
        [f setContentHuggingPriority:NSLayoutPriorityDefaultLow - 10 forOrientation:NSLayoutConstraintOrientationHorizontal];
        [f.widthAnchor constraintGreaterThanOrEqualToConstant:120].active = YES;
    }
    // Row 5: export and captions.
    self.exportPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:YES];
    self.exportPopup.controlSize = NSControlSizeSmall; self.exportPopup.font = self.fillerButton.font;
    [self.exportPopup addItemWithTitle:@"Export"];
    NSArray *exportItems = @[@[@"Transcript with timecodes…", @3], @[@"Plain text (no timecodes)…", @0], @[@"Subtitles (SRT)…", @2]];
    for (NSArray *e in exportItems) {
        NSMenuItem *it = [self.exportPopup.menu addItemWithTitle:e[0] action:@selector(sk_exportMenu:) keyEquivalent:@""];
        it.target = self; it.tag = [e[1] integerValue];
    }
    self.captionsButton = barButton(@selector(sk_createCaptions:)); self.captionsButton.title = @"Create Captions";
    self.captionsButton.toolTip = @"Add the transcript to the timeline as native captions";
    // View settings: timecode style, text size, color bars.
    self.timecodePopup = barPopup(NO);
    for (NSArray *t in @[@[@"Short (0:10)", @0], @[@"Min:Sec:Frames (0:10:12)", @1], @[@"Project Timecode (00:00:10:12)", @2], @[@"Hidden", @3]]) {
        [self.timecodePopup addItemWithTitle:t[0]];
        self.timecodePopup.lastItem.tag = [t[1] integerValue];
    }
    [self.timecodePopup selectItemWithTag:SKTimecodeMode()];
    self.timecodePopup.target = self; self.timecodePopup.action = @selector(sk_timecodeChanged:);
    self.timecodePopup.toolTip = @"How each line's time is shown";
    self.barsCheckbox = [NSButton checkboxWithTitle:@"Mark each speaker's lines" target:self action:@selector(sk_barsChanged:)];
    self.barsCheckbox.controlSize = NSControlSizeSmall;
    self.barsCheckbox.state = SKColorBars() ? NSControlStateValueOn : NSControlStateValueOff;
    self.barsCheckbox.toolTip = @"A bar in the speaker's color beside their lines";
    self.darkCheckbox = [NSButton checkboxWithTitle:@"Dark" target:self action:@selector(sk_darkChanged:)];
    self.darkCheckbox.controlSize = NSControlSizeSmall;
    self.darkCheckbox.state = [[NSUserDefaults standardUserDefaults] boolForKey:kSKDarkBackgroundKey] ? NSControlStateValueOn : NSControlStateValueOff;
    self.darkCheckbox.toolTip = @"Darker transcript background (otherwise the same gray as these rows)";

    // FCP inspector layout (v63): sections with a header band, labelled rows on the lighter gray,
    // the transcript below, and Export / Create Captions in a footer bar.
    NSMutableArray *sections = [NSMutableArray array];
    NSArray *(^makeRow)(NSString *, NSArray *) = ^NSArray *(NSString *label, NSArray *views) {
        NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 400, 26)];
        NSTextField *l = [NSTextField labelWithString:label];
        l.alignment = NSTextAlignmentRight;
        l.textColor = [NSColor colorWithWhite:0.71 alpha:1];
        NSStackView *st = [NSStackView stackViewWithViews:views];
        st.orientation = NSUserInterfaceLayoutOrientationHorizontal; st.spacing = 6;
        st.alignment = NSLayoutAttributeCenterY;
        st.translatesAutoresizingMaskIntoConstraints = YES;
        [row addSubview:l]; [row addSubview:st];
        return @[row, l, st];
    };
    void (^addSection)(NSString *, NSString *, NSArray *) = ^(NSString *sid, NSString *title, NSArray *rows) {
        SKSectionHeaderView *h = [[SKSectionHeaderView alloc] initWithTitle:title sectionID:sid owner:self];
        h.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
        [container addSubview:h];
        NSMutableDictionary *sec = [@{@"id": sid, @"header": h} mutableCopy];
        if (rows.count) {
            SKFillView *box = [[SKFillView alloc] initWithFrame:NSMakeRect(0, 0, 400, 26 * rows.count)];
            box.fill = [NSColor colorWithWhite:0.176 alpha:1];   // #2D2D2D, FCP's parameter rows
            box.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
            for (NSArray *r in rows) [box addSubview:r[0]];
            [container addSubview:box];
            sec[@"box"] = box; sec[@"rows"] = rows;
        }
        [sections addObject:sec];
    };
    addSection(@"cleanup", @"Cleanup", @[makeRow(@"Fillers", @[self.fillerButton]), makeRow(@"Pauses", @[self.pauseButton, threshold])]);
    addSection(@"speakers", @"Speakers", @[makeRow(@"Show", @[self.speakerPopup, self.detectButton])]);
    addSection(@"view", @"View", @[makeRow(@"Timecode", @[self.timecodePopup]), makeRow(@"Text size", @[[self sk_makeSizeControl]]),
                                   makeRow(@"Color bars", @[self.barsCheckbox]), makeRow(@"Background", @[self.darkCheckbox])]);
    addSection(@"find", @"Find & Replace", @[makeRow(@"Find", @[self.searchField, self.findCount, self.prevButton, self.nextButton]),
                                             makeRow(@"Replace", @[self.replaceField, self.replaceButton, self.replaceAllButton])]);
    addSection(@"transcript", @"Transcript", @[]);
    self.sections = sections;
    SKFillView *footer = [[SKFillView alloc] initWithFrame:NSMakeRect(0, 0, 400, 30)];
    footer.fill = [NSColor colorWithWhite:0.122 alpha:1]; footer.topLine = YES;
    footer.autoresizingMask = NSViewWidthSizable | NSViewMaxYMargin;
    NSStackView *fst = [[NSStackView alloc] initWithFrame:footer.bounds];
    fst.orientation = NSUserInterfaceLayoutOrientationHorizontal; fst.spacing = 6;
    fst.translatesAutoresizingMaskIntoConstraints = YES;
    fst.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [fst addView:self.exportPopup inGravity:NSStackViewGravityLeading];
    [fst addView:self.captionsButton inGravity:NSStackViewGravityTrailing];
    [footer addSubview:fst];
    [container addSubview:footer];
    self.footer = footer; self.footerStack = fst;
    NSScrollView *sv = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 30, 400, 400)];
    sv.hasVerticalScroller = YES;
    sv.drawsBackground = YES; sv.backgroundColor = SKTranscriptBackground();   // row gray #2D2D2D (v73), or dark with View › Background (v74)
    sv.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    SKTranscriptTextView *tv = [[SKTranscriptTextView alloc] initWithFrame:sv.bounds];
    tv.module = self;
    tv.editable = NO; tv.drawsBackground = NO;
    tv.textContainerInset = NSMakeSize(10, 8);
    tv.autoresizingMask = NSViewWidthSizable;
    sv.documentView = tv;
    self.transcribeButton = barButton(@selector(sk_transcribeClicked:));
    self.transcribeButton.title = @"Transcribe";
    self.transcribeButton.bezelStyle = NSBezelStyleRounded;
    self.transcribeButton.toolTip = @"Transcribe with Final Cut Pro (same as Modify › Analyze and Fix › Transcribe); the transcript is saved in the library";
    self.transcribeButton.hidden = YES;
    [tv addSubview:self.transcribeButton];
    NSImage *wheel = [([[NSBundle bundleWithIdentifier:@"com.apple.Flexo"] imageForResource:@"F_RoleEditor_Color"] ?: [NSImage imageNamed:NSImageNameColorPanel]) copy];   // a copy: resizing the shared image would shrink FCP's own
    wheel.size = NSMakeSize(16, 16);
    self.colorWheelButton = [NSButton buttonWithImage:wheel target:self action:@selector(sk_colorWheelClicked:)];
    self.colorWheelButton.bordered = NO;
    self.colorWheelButton.imageScaling = NSImageScaleProportionallyDown;
    self.colorWheelButton.frame = NSMakeRect(0, 0, 16, 16);
    self.colorWheelButton.hidden = YES;
    self.colorWheelButton.toolTip = @"Change this speaker's color";
    [tv addSubview:self.colorWheelButton];
    [container addSubview:sv];
    self.textView = tv; self.scroll = sv; self.container = container;
    [self sk_applyControlScale];
    [self setView:container];
    __weak SKInspectorModuleTranscript *weakSelf = self;
    self.timer = [NSTimer timerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { [weakSelf sk_tick]; }];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    TLog(@"module view built");
    // Test hooks (no real mouse needed): post these NSNotifications with a string object.
    //   SKTranscriptTestClick  "word"          click that word
    //   SKTranscriptTestSelect "some words"    select that text and focus the view
    //   SKTranscriptTestDelete "ripple"|"lift" delete the current selection
    //   SKTranscriptTestBulk   "fillers"|"pauses" run the bulk-delete buttons
    //   SKTranscriptTestThreshold "0.2"        set the pause threshold in seconds
    //   SKTranscriptTestFind "find:text" | "next" | "replace:new" | "replaceall:new" | "edit:word" | "editspeaker:Name" | "type:text" | "key:return|tab|escape"
    //   SKTranscriptTestExport "txt:/path" | "tc:/path" | "srt:/path" | "premiere:/path" | "captions"
    //   SKTranscriptTestSource "append" | "insert" | "overwrite" | "connect"
    //   SKTranscriptTestSize "0" | "1" | "2"   text size: normal, 125%, 150%
    //   SKTranscriptTestSpeaker "detect" | "filter:Name" | "filter:" | "assign:Name" | "rename:Old=New" | "selectall" | "context:word=Menu item"
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    [nc addObserverForName:@"SKTranscriptTestClick" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        SKInspectorModuleTranscript *m = weakSelf;
        NSRange r = [m.textView.string rangeOfString:[n.object description]];
        if (r.location == NSNotFound) { TLog(@"test click: word not found"); return; }
        NSRange g = [m.textView.layoutManager glyphRangeForCharacterRange:r actualCharacterRange:NULL];
        NSRect rect = [m.textView.layoutManager boundingRectForGlyphRange:g inTextContainer:m.textView.textContainer];
        NSPoint p = NSMakePoint(NSMidX(rect) + m.textView.textContainerOrigin.x, NSMidY(rect) + m.textView.textContainerOrigin.y);
        TLog(@"test click '%@' hit=%d", n.object, [m.textView sk_handleClickAtViewPoint:p]);
    }];
    [nc addObserverForName:@"SKTranscriptTestSelect" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        SKInspectorModuleTranscript *m = weakSelf;
        // "from…to" selects from the first match of `from` through the next match of `to`.
        NSString *text = m.textView.string;
        NSArray *ends = [[n.object description] componentsSeparatedByString:@"…"];
        NSRange r = [text rangeOfString:ends.firstObject];
        if (ends.count == 2 && r.location != NSNotFound) {
            NSRange tail = [text rangeOfString:ends[1] options:0 range:NSMakeRange(r.location, text.length - r.location)];
            r = tail.location == NSNotFound ? tail : NSUnionRange(r, tail);
        }
        if (r.location == NSNotFound) { TLog(@"test select: text not found (%@)", n.object); return; }
        [m.textView.window makeFirstResponder:m.textView];
        m.textView.selectedRange = r;
        [m sk_snapSelectionToWords];
        [m sk_markSourceSelection];
        TLog(@"test select '%@' -> %lu item(s) firstResponder=%@", n.object, (unsigned long)[m sk_selectedWords].count, [m.textView.window.firstResponder class]);
    }];
    [nc addObserverForName:@"SKTranscriptTestDelete" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        TLog(@"test delete %@ ok=%d", n.object, [weakSelf sk_deleteSelectionLift:[[n.object description] isEqualToString:@"lift"]]);
    }];
    [nc addObserverForName:@"SKTranscriptTestThreshold" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        gPauseThreshold = [[n.object description] doubleValue];
        [weakSelf sk_refresh];
    }];
    [nc addObserverForName:@"SKTranscriptTestSpeaker" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        SKInspectorModuleTranscript *m = weakSelf;
        NSString *cmd = [n.object description], *arg = @"";
        NSRange colon = [cmd rangeOfString:@":"];
        if (colon.location != NSNotFound) { arg = [cmd substringFromIndex:colon.location + 1]; cmd = [cmd substringToIndex:colon.location]; }
        if ([cmd isEqualToString:@"detect"]) [m sk_detectSpeakers:nil];
        else if ([cmd isEqualToString:@"filter"]) [m sk_setFilter:arg];
        else if ([cmd isEqualToString:@"assign"]) TLog(@"test assign ok=%d", [m sk_assignSpeaker:arg]);
        else if ([cmd isEqualToString:@"rename"]) {
            NSArray *parts = [arg componentsSeparatedByString:@"="];
            TLog(@"test rename ok=%d", parts.count == 2 && [m sk_renameSpeaker:parts[0] to:parts[1]]);
        } else if ([cmd isEqualToString:@"context"]) {   // "context:word=Item title"
            NSArray *parts = [arg componentsSeparatedByString:@"="];
            NSRange r = [m.textView.string rangeOfString:parts.firstObject];
            NSMenu *menu = r.location == NSNotFound ? nil : [m sk_contextMenuAtIndex:r.location];
            if (parts.count == 2) for (NSMenuItem *it in menu.itemArray) if ([it.title isEqualToString:parts[1]] && it.action) {
                ((void(*)(id,SEL,id))objc_msgSend)(it.target, it.action, it); TLog(@"test context chose '%@'", it.title); break;
            }
        } else if ([cmd isEqualToString:@"color"]) {   // "color:Name" or "color:Name=index"
            NSArray *parts = [arg componentsSeparatedByString:@"="];
            if (parts.count == 2) { SKSetSpeakerColorIndex(parts[0], [parts[1] integerValue]); [m sk_refresh]; TLog(@"test color set"); return; }
            for (NSArray *l in m.labelRanges) if ([l[1] isEqualToString:arg]) {
                NSLayoutManager *lm = m.textView.layoutManager;
                NSRect nr = [lm boundingRectForGlyphRange:[lm glyphRangeForCharacterRange:[l[0] rangeValue] actualCharacterRange:NULL] inTextContainer:m.textView.textContainer];
                [m sk_hoverAtViewPoint:NSMakePoint(m.textView.textContainerOrigin.x + NSMidX(nr), m.textView.textContainerOrigin.y + NSMidY(nr))];
                TLog(@"test color: circle %@ at %@", m.colorWheelButton.hidden ? @"hidden" : @"shown", NSStringFromRect(m.colorWheelButton.frame));
                [m.colorWheelButton performClick:nil];
                NSButton *wb = m.colorWheelButton;
                TLog(@"test color: after click circle hidden=%d image=%@ super=%@ panel=%d", wb.hidden, NSStringFromSize(wb.image.size), [wb.superview class], m.colorPanel != nil);
                NSRect around = NSInsetRect(wb.frame, -90, -14);
                NSBitmapImageRep *tr = [m.textView bitmapImageRepForCachingDisplayInRect:around];
                [m.textView cacheDisplayInRect:around toBitmapImageRep:tr];
                [[tr representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/sk-wheel.png" atomically:YES];
                NSView *v = m.colorPanel.contentView;
                NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
                [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
                [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@"/tmp/sk-color-picker.png" atomically:YES];
                TLog(@"test color picker shown, saved /tmp/sk-color-picker.png");
                break;
            }
        } else if ([cmd isEqualToString:@"selectall"]) {
            [m.textView.window makeFirstResponder:m.textView];
            m.textView.selectedRange = NSMakeRange(0, m.textView.string.length);
            TLog(@"test selectall: %lu item(s)", (unsigned long)[m sk_selectedWords].count);
        }
    }];
    [nc addObserverForName:@"SKTranscriptTestFind" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        SKInspectorModuleTranscript *m = weakSelf;
        NSString *cmd = [n.object description], *arg = @"";
        NSRange colon = [cmd rangeOfString:@":"];
        if (colon.location != NSNotFound) { arg = [cmd substringFromIndex:colon.location + 1]; cmd = [cmd substringToIndex:colon.location]; }
        if ([cmd isEqualToString:@"find"]) { m.searchField.stringValue = arg; m.findIndex = 0; [m sk_updateFind:YES]; }
        else if ([cmd isEqualToString:@"next"]) [m sk_findStep:+1];
        else if ([cmd isEqualToString:@"replace"] || [cmd isEqualToString:@"replaceall"]) { m.replaceField.stringValue = arg; [m sk_replaceAll:[cmd isEqualToString:@"replaceall"]]; }
        else if ([cmd isEqualToString:@"key"] && m.editField) {   // what Return / Tab / Escape send to the editor
            SEL sel = [arg isEqualToString:@"tab"] ? @selector(insertTab:) : [arg isEqualToString:@"escape"] ? @selector(cancelOperation:) : @selector(insertNewline:);
            [m control:m.editField textView:(NSTextView *)m.editField.currentEditor doCommandBySelector:sel];
        }
        else if ([cmd isEqualToString:@"editspeaker"]) {
            for (NSArray *l in m.labelRanges) if ([l[1] isEqualToString:arg]) { [m sk_beginEditingSpeakerAtIndex:[l[0] rangeValue].location]; break; }
        }
        else if ([cmd isEqualToString:@"type"] && m.editField) m.editField.stringValue = arg;
        else if ([cmd isEqualToString:@"edit"]) {
            NSRange r = [m.textView.string rangeOfString:arg];
            [m sk_beginEditingWord:r.location == NSNotFound ? nil : [m sk_wordAtIndex:r.location]];
        }
        TLog(@"test find %@ -> count label '%@' playhead %.2f", n.object, m.findCount.stringValue, SKPlayheadSeconds());
    }];
    [nc addObserverForName:@"SKTranscriptTestExport" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        SKInspectorModuleTranscript *m = weakSelf;
        NSString *cmd = [n.object description];
        if ([cmd isEqualToString:@"captions"]) { TLog(@"test captions ok=%d", [m sk_createCaptions:nil]); return; }
        NSRange colon = [cmd rangeOfString:@":"];
        if (colon.location == NSNotFound) return;
        NSInteger kind = [@[@"txt", @"tc", @"srt", @"premiere"] indexOfObject:[cmd substringToIndex:colon.location]];
        if (kind != NSNotFound) [m sk_export:kind toPath:[cmd substringFromIndex:colon.location + 1]];
    }];
    // Find a browser clip by name in any open library, report it, and select it whole in the browser.
    [nc addObserverForName:@"SKTranscriptTestSize" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        weakSelf.sizeControl.selectedSegment = [[n.object description] integerValue];
        [weakSelf sk_sizeChanged:weakSelf.sizeControl];
    }];
    [nc addObserverForName:@"SKTranscriptTestSource" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        TLog(@"test source %@ ok=%d", n.object, [weakSelf sk_editSource:[n.object description]]);
    }];
    [nc addObserverForName:@"SKTranscriptTestBulk" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        TLog(@"test bulk %@ ok=%d", n.object, [weakSelf sk_deleteAllFillers:[[n.object description] isEqualToString:@"fillers"]]);
    }];
    [self sk_refresh];
}
// FCP can create a fresh module for the tab (e.g. after the app is deactivated and reactivated)
// without asking it to load a view, which left the tab blank. Build at creation instead.
- (instancetype)init {
    self = [super init];
    if (self) { TLog(@"module created %p", self); [self sk_build]; }
    return self;
}
- (void)dealloc { TLog(@"module released %p", self); [_timer invalidate]; }
// Text size: three segments drawn as "A" at increasing sizes.
- (NSSegmentedControl *)sk_makeSizeControl {
    NSMutableArray *images = [NSMutableArray array];
    for (NSNumber *pt in @[@9, @11, @13]) {
        NSAttributedString *a = [[NSAttributedString alloc] initWithString:@"A" attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:pt.doubleValue weight:NSFontWeightMedium], NSForegroundColorAttributeName: [NSColor blackColor]}];
        NSImage *img = [NSImage imageWithSize:NSMakeSize(12, 14) flipped:NO drawingHandler:^BOOL(NSRect r) {
            NSSize sz = a.size;
            [a drawAtPoint:NSMakePoint((r.size.width - sz.width) / 2, (r.size.height - sz.height) / 2)];
            return YES;
        }];
        img.template = YES;
        [images addObject:img];
    }
    NSSegmentedControl *seg = [NSSegmentedControl segmentedControlWithImages:images trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(sk_sizeChanged:)];
    seg.controlSize = NSControlSizeSmall;
    seg.segmentStyle = NSSegmentStyleRounded;
    NSArray *labels = @[@"Normal text", @"Larger text (125%)", @"Largest text (150%)"];
    for (NSInteger i = 0; i < 3; i++) {
        [seg setToolTip:labels[i] forSegment:i];
        [seg.cell setTag:i forSegment:i];
        if (fabs(kSKTextScales[i] - SKTextScale()) < 0.01) seg.selectedSegment = i;
    }
    seg.toolTip = @"Transcript text size";
    self.sizeControl = seg;
    return seg;
}
- (void)sk_sizeChanged:(NSSegmentedControl *)sender {
    NSInteger i = MAX(0, MIN(2, sender.selectedSegment));
    [[NSUserDefaults standardUserDefaults] setDouble:kSKTextScales[i] forKey:kSKTextScaleKey];
    TLog(@"text size -> %.0f%%", kSKTextScales[i] * 100);
    [self sk_endEditing:YES];
    [self sk_applyControlScale];
    [self sk_refresh];
}

// Sets the controls' size and fonts, then lays the sections out.
- (void)sk_applyControlScale {
    // Controls, section headers and the footer stay at FCP's inspector size: Text size only scales
    // the transcript. Before v71 it scaled the whole panel.
    NSControlSize size = NSControlSizeSmall;
    NSFont *font = [NSFont systemFontOfSize:[NSFont systemFontSizeForControlSize:NSControlSizeSmall]];
    for (NSControl *c in @[self.fillerButton, self.pauseButton, self.thresholdPopup, self.speakerPopup, self.detectButton,
                           self.exportPopup, self.captionsButton, self.searchField, self.prevButton, self.nextButton,
                           self.replaceField, self.replaceButton, self.replaceAllButton, self.transcribeButton]) {
        c.controlSize = size; c.font = font;
    }
    self.findCount.font = font;
    self.sizeControl.controlSize = size;
    self.timecodePopup.controlSize = size; self.timecodePopup.font = font;
    self.barsCheckbox.controlSize = size; self.barsCheckbox.font = font;
    self.darkCheckbox.controlSize = size; self.darkCheckbox.font = font;
    NSFont *bold = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], *plain = [NSFont systemFontOfSize:11];
    for (NSDictionary *sec in self.sections) {
        [(SKSectionHeaderView *)sec[@"header"] setFont:bold plain:plain];
        for (NSArray *r in sec[@"rows"]) ((NSTextField *)r[1]).font = plain;
    }
    [self sk_layoutSections];
}

// Stack the sections from the top: header, then its rows unless folded. The transcript fills the
// space down to the footer. Folded sections are remembered in FCP's defaults.
- (void)sk_layoutSections {
    const double sc = 1.0;   // fixed: Text size scales only the transcript
    CGFloat W = NSWidth(self.container.bounds), H = NSHeight(self.container.bounds);
    CGFloat hh = round(22 * sc), rh = round(26 * sc), fh = round(30 * sc), labelW = round(78 * sc), y = H;
    NSArray *collapsed = SKCollapsedSections();
    for (NSDictionary *sec in self.sections) {
        BOOL closed = [collapsed containsObject:sec[@"id"]];
        SKSectionHeaderView *h = sec[@"header"];
        h.frame = NSMakeRect(0, y - hh, W, hh); y -= hh;
        h.collapsed = closed;
        SKFillView *box = sec[@"box"];
        if (box) {
            NSArray *rows = sec[@"rows"];
            box.hidden = closed;
            if (closed) continue;
            CGFloat bh = rh * rows.count;
            box.frame = NSMakeRect(0, y - bh, W, bh); box.rowHeight = rh; y -= bh;
            for (NSUInteger i = 0; i < rows.count; i++) {
                NSArray *r = rows[i];
                ((NSView *)r[0]).frame = NSMakeRect(0, bh - rh * (i + 1), W, rh);
                NSTextField *l = r[1];
                CGFloat lh = ceil(l.intrinsicContentSize.height);
                l.frame = NSMakeRect(4, floor((rh - lh) / 2), labelW, lh);
                ((NSView *)r[2]).frame = NSMakeRect(labelW + 12, 0, MAX(0, W - labelW - 22), rh);
            }
            [box setNeedsDisplay:YES];
        } else {   // the transcript
            self.scroll.hidden = closed;
            self.scroll.frame = NSMakeRect(0, fh, W, MAX(0, y - fh));
            y = fh;
        }
    }
    self.footer.frame = NSMakeRect(0, 0, W, fh);
    self.footerStack.frame = NSMakeRect(10, 0, MAX(0, W - 20), fh - 1);
}
- (void)sk_toggleSection:(NSString *)sid {
    NSMutableArray *c = [SKCollapsedSections() mutableCopy];
    if ([c containsObject:sid]) [c removeObject:sid]; else [c addObject:sid];
    [[NSUserDefaults standardUserDefaults] setObject:c forKey:kSKCollapsedKey];
    TLog(@"section %@ %@", sid, [c containsObject:sid] ? @"hidden" : @"shown");
    [self sk_layoutSections];
}
- (void)sk_timecodeChanged:(NSPopUpButton *)sender {
    [[NSUserDefaults standardUserDefaults] setInteger:sender.selectedTag forKey:kSKTimecodeKey];
    TLog(@"timecode style -> %ld", (long)sender.selectedTag);
    [self sk_refresh];
}
- (void)sk_darkChanged:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.state == NSControlStateValueOn forKey:kSKDarkBackgroundKey];
    self.scroll.backgroundColor = SKTranscriptBackground();
    TLog(@"transcript background -> %@", sender.state == NSControlStateValueOn ? @"dark" : @"gray");
}
- (void)sk_barsChanged:(NSButton *)sender {
    [[NSUserDefaults standardUserDefaults] setBool:sender.state == NSControlStateValueOn forKey:kSKColorBarsKey];
    [self sk_refresh];
}

// Color bars (one per speaker run: from the top of the name to the baseline of their last word)
// and pause capsules, drawn behind the text.
- (void)sk_drawDecorationsInRect:(NSRect)dirty {
    NSTextView *tv = self.textView;
    NSLayoutManager *lm = tv.layoutManager;
    NSTextContainer *tcont = tv.textContainer;
    NSPoint o = tv.textContainerOrigin;
    NSUInteger len = tv.textStorage.length;
    [[NSColor colorWithWhite:1 alpha:0.075] setFill];
    for (NSValue *v in self.pauseRanges) {
        NSRange r = v.rangeValue;
        if (r.location == NSNotFound || NSMaxRange(r) > len) continue;
        NSRange g = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
        [lm enumerateEnclosingRectsForGlyphRange:g withinSelectedGlyphRange:NSMakeRange(NSNotFound, 0) inTextContainer:tcont usingBlock:^(NSRect rr, BOOL *stop) {
            rr = NSInsetRect(NSOffsetRect(rr, o.x, o.y), 0, 1.5);
            if (NSIntersectsRect(rr, dirty)) [[NSBezierPath bezierPathWithRoundedRect:rr xRadius:NSHeight(rr) / 2 yRadius:NSHeight(rr) / 2] fill];
        }];
    }
    if (!SKColorBars()) return;
    for (NSArray *b in self.blocks) {
        NSRange r = [b[0] rangeValue];
        if (r.length == 0 || NSMaxRange(r) > len) continue;
        NSUInteger g0 = [lm glyphIndexForCharacterAtIndex:r.location], g1 = [lm glyphIndexForCharacterAtIndex:NSMaxRange(r) - 1];
        NSRect f0 = [lm lineFragmentRectForGlyphAtIndex:g0 effectiveRange:NULL], f1 = [lm lineFragmentRectForGlyphAtIndex:g1 effectiveRange:NULL];
        CGFloat base0 = NSMinY(f0) + [lm locationForGlyphAtIndex:g0].y, base1 = NSMinY(f1) + [lm locationForGlyphAtIndex:g1].y;
        NSFont *nameFont = [tv.textStorage attribute:NSFontAttributeName atIndex:r.location effectiveRange:NULL];
        CGFloat top = base0 - (nameFont ? nameFont.capHeight : 8);
        NSRect bar = NSMakeRect(o.x + self.barX, o.y + top, 2, MAX(2, base1 - top));
        if (!NSIntersectsRect(bar, dirty)) continue;
        [(NSColor *)b[1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:1 yRadius:1] fill];
    }
}

// Row 6: edit the marked source range into the timeline.
- (NSArray *)sk_makeSourceButtons:(NSButton *(^)(SEL))barButton {
    NSMutableArray *buttons = [NSMutableArray array];
    for (NSArray *b in @[@[@"Append", @"append", @"E"], @[@"Insert", @"insert", @"W"], @[@"Overwrite", @"overwrite", @"D"], @[@"Connect", @"connect", @"Q"]]) {
        NSButton *btn = barButton(@selector(sk_sourceButton:));
        btn.title = b[0]; btn.identifier = b[1];
        btn.toolTip = [NSString stringWithFormat:@"%@ the marked range to the timeline (%@)", b[0], b[2]];
        btn.enabled = NO;
        [buttons addObject:btn];
    }
    self.sourceButtons = buttons;
    return buttons;
}
- (BOOL)loadView { [self sk_build]; return YES; }
- (void)loadNib { [self sk_build]; }
- (BOOL)isNibLoaded { return self.built; }
- (NSView *)view { [self sk_build]; return self.container; }
- (BOOL)shouldDisplayModuleWithItems:(id)items { return YES; }
- (void)setCurrentItems:(id)items {
    @try { [super setCurrentItems:items]; } @catch (id e) { TLog(@"super setCurrentItems threw %@", e); }
    [self sk_build];
    [self sk_requestRefresh];
}

#pragma mark Rendering

static BOOL SKIsFiller(NSString *text) {
    static NSSet *fillers; static NSCharacterSet *strip;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fillers = [NSSet setWithArray:@[@"um", @"umm", @"uhm", @"uh", @"uhh", @"er", @"erm", @"ah", @"hmm", @"hm", @"mm", @"mhm"]];
        strip = [[NSCharacterSet letterCharacterSet] invertedSet];
    });
    return [fillers containsObject:[[text lowercaseString] stringByTrimmingCharactersInSet:strip]];
}

// Redraw requests from FCP events (selection changes, inspector show/hide) are coalesced into
// one per run-loop turn, and the (expensive) rebuild only happens while the tab is on screen. If it
// isn't, the request is remembered and sk_tick draws when the tab appears.
- (BOOL)sk_isShowing {
    NSView *v = self.container;
    BOOL showing = v.window && v.window.isVisible && !v.isHiddenOrHasHiddenAncestor;
    static int last = -1;
    if (last != (int)showing) { last = showing; TLog(@"showing=%d", showing); }
    return showing;
}
// Everything that decides what a refresh would draw, except what user actions change (those call
// sk_refresh directly). Selecting any clips of the primary storyline draws the same whole-timeline
// text, so they share one key.
- (NSString *)sk_renderKeyWithSignature:(NSString *)sig {
    NSArray *items = gItems, *primary = SKPrimaryItems();
    BOOL seq = items.count && primary.count;
    for (id it in items) if (![primary containsObject:it]) { seq = NO; break; }
    NSMutableString *k = [NSMutableString string];
    if (seq) [k appendString:@"SEQ"]; else for (id it in items) [k appendFormat:@"%p,", it];
    [k appendFormat:@"|%@|%@|%.3f|%ld|%d|%g|%.0f", sig, gSpeakerFilter ?: @"", gPauseThreshold, (long)SKTimecodeMode(), SKColorBars(), SKTextScale(), gPhraseCacheBorn];
    return k;
}
- (void)sk_requestRefresh {
    self.needsRefresh = YES;
    if (self.refreshQueued) return;
    self.refreshQueued = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self.refreshQueued = NO;
        if (!(self.needsRefresh && [self sk_isShowing])) return;
        if (self.words.count && self.renderedKey && [[self sk_renderKeyWithSignature:SKTimelineSignature()] isEqualToString:self.renderedKey]) { self.needsRefresh = NO; return; }   // nothing that matters changed
        [self sk_refresh];
    });
}

// Rebuild the text. If the selection is in the primary storyline we show the whole
// timeline's transcript (every primary clip, trimmed-out words omitted) with words mapped
// to timeline time, fillers tinted, silences of at least gPauseThreshold shown as
// "[… 0.8s]" items, and a speaker label wherever the speaker changes. With a speaker filter
// on, only that speaker's words are drawn (pauses are hidden too). Otherwise (e.g. a
// browser clip) we show that clip's source transcript.
- (void)sk_refresh {
    if (!self.textView) return;
    self.needsRefresh = NO;
    CFAbsoluteTime tRefresh0 = CFAbsoluteTimeGetCurrent();
    SKLoadSpeakers();
    NSArray *items = gItems;
    NSDictionary *body = @{NSFontAttributeName: [NSFont systemFontOfSize:SKPt(13)], NSForegroundColorAttributeName: [NSColor labelColor]};
    NSDictionary *dim = @{NSFontAttributeName: [NSFont systemFontOfSize:SKPt(11)], NSForegroundColorAttributeName: [NSColor secondaryLabelColor]};
    NSFont *stampFont = [NSFont monospacedDigitSystemFontOfSize:SKPt(10) weight:NSFontWeightRegular];
    NSDictionary *stamp = @{NSFontAttributeName: stampFont, NSForegroundColorAttributeName: [NSColor tertiaryLabelColor]};
    NSDictionary *pauseAttrs = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:SKPt(10) weight:NSFontWeightRegular], NSForegroundColorAttributeName: [NSColor secondaryLabelColor], NSCursorAttributeName: [NSCursor pointingHandCursor]};
    // Layout (v63): "\t<time>\t<words>" — the time right-aligned in its own column, the words (and
    // their wrapped lines) hanging at textX; the speaker's color bar sits just left of textX.
    NSInteger tcMode = SKTimecodeMode();
    BOOL bars = SKColorBars();
    NSString *sample = @[@"00:00", @"00:00:00", @"00:00:00:00", @""][tcMode];
    CGFloat tcW = tcMode == 3 ? 0 : ceil([sample sizeWithAttributes:@{NSFontAttributeName: stampFont}].width);
    CGFloat textX = tcW + (tcW > 0 ? SKPt(8) : 0) + (bars ? SKPt(10) : 0);
    self.barX = textX - SKPt(10);
    NSMutableParagraphStyle *linePS = [NSMutableParagraphStyle new];
    linePS.headIndent = textX;
    linePS.firstLineHeadIndent = tcW > 0 ? 0 : textX;
    linePS.tabStops = tcW > 0 ? @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentRight location:tcW options:@{}],
                                  [[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:textX options:@{}]] : @[];
    linePS.paragraphSpacing = SKPt(6);
    NSMutableParagraphStyle *namePS = [linePS mutableCopy];
    namePS.firstLineHeadIndent = textX; namePS.paragraphSpacingBefore = SKPt(6); namePS.paragraphSpacing = SKPt(2);
    NSMutableParagraphStyle *pausePS = [linePS mutableCopy];
    pausePS.firstLineHeadIndent = textX;
    NSMutableParagraphStyle *plainPS = [NSMutableParagraphStyle new];
    plainPS.paragraphSpacing = SKPt(6);
    NSMutableArray<NSValue *> *nameParas = [NSMutableArray array], *pauseParas = [NSMutableArray array], *pauseRanges = [NSMutableArray array];
    NSMutableArray<NSArray *> *blocks = [NSMutableArray array];
    __block NSUInteger blockStart = NSNotFound, blockEnd = 0;
    __block NSString *blockSpeaker = nil;
    void (^closeBlock)(void) = ^{
        if (blockStart != NSNotFound && blockEnd > blockStart)
            [blocks addObject:@[[NSValue valueWithRange:NSMakeRange(blockStart, blockEnd - blockStart)], SKSpeakerTextColor(blockSpeaker)]];
        blockStart = NSNotFound; blockEnd = 0;
    };
    NSUInteger statusStart = NSNotFound;
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSMutableArray<SKWord *> *words = [NSMutableArray array], *all = [NSMutableArray array];
    NSMutableArray<NSArray *> *labels = [NSMutableArray array];
    NSMutableArray *missingAssets = [NSMutableArray array], *missingClips = [NSMutableArray array];
    NSMutableOrderedSet<NSString *> *speakerNames = [NSMutableOrderedSet orderedSet], *mediaPaths = [NSMutableOrderedSet orderedSet];
    NSMutableDictionary<NSString *, NSString *> *proxies = [NSMutableDictionary dictionary];
    void (^add)(NSString *, NSDictionary *) = ^(NSString *s, NSDictionary *a) { [out appendAttributedString:[[NSAttributedString alloc] initWithString:s attributes:a]]; };
    // Append a pause item covering [from, to) on the timeline.
    void (^addPause)(double, double, BOOL) = ^(double from, double to, BOOL ownLine) {
        SKWord *p = [SKWord new];
        p.pause = YES; p.tlStart = from; p.tlEnd = to; p.srcStart = p.srcEnd = NAN;
        [all addObject:p];
        if (gSpeakerFilter) { p.range = NSMakeRange(NSNotFound, 0); return; }
        // A small capsule (drawn behind the text): "1.7s pause" on its own line, just "0.1s" inside a line.
        NSString *t = [NSString stringWithFormat:ownLine ? @"\u2002%.1fs pause\u2002" : @"\u2002%.1fs\u2002", to - from];
        NSUInteger paraStart = out.length;
        p.range = NSMakeRange(out.length, t.length);
        [pauseRanges addObject:[NSValue valueWithRange:p.range]];
        add(t, pauseAttrs); add(ownLine ? @"\n" : @" ", body);
        if (ownLine) [pauseParas addObject:[NSValue valueWithRange:NSMakeRange(paraStart, out.length - paraStart)]];
        [words addObject:p];
    };
    NSUInteger fillerCount = 0, pauseCount = 0;

    gRetryRange = NSMakeRange(NSNotFound, 0);
    @try {
        NSArray *primary = SKPrimaryItems();
        // Connected clips over primary gaps join the timeline view (v76; always on since v77).
        NSArray<NSValue *> *gaps = primary.count ? SKPrimaryGaps(primary) : @[];
        NSArray<NSDictionary *> *connected = gaps.count ? SKConnectedOverGaps(primary, gaps) : @[];
        NSArray *connectedClips = [connected valueForKey:@"clip"];
        BOOL sequenceMode = items.count > 0 && primary.count > 0;
        for (id item in items) if (![primary containsObject:item] && ![connectedClips containsObject:item]) sequenceMode = NO;
        NSArray *clips = sequenceMode ? primary : items;
        // What to walk, in timeline order: primary items, then each connected clip at its start.
        NSMutableArray<NSDictionary *> *entries = [NSMutableArray array];
        for (id c in clips) {
            double a = 0, t = 0, d = 0;
            BOOL ok = sequenceMode && SKClipPlacement(c, &a, &t, &d);
            [entries addObject:ok ? @{@"clip": c, @"tl": @(a), @"trim": @(t), @"dur": @(d)} : @{@"clip": c}];
        }
        if (sequenceMode && connected.count) {
            for (NSDictionary *c in connected) { NSMutableDictionary *m = [c mutableCopy]; m[@"conn"] = @YES; [entries addObject:m]; }
            [entries sortWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
                double a = [x[@"tl"] doubleValue], b = [y[@"tl"] doubleValue];
                if (fabs(a - b) > 1e-4) return a < b ? NSOrderedAscending : NSOrderedDescending;
                return [x[@"conn"] boolValue] == [y[@"conn"] boolValue] ? NSOrderedSame : ([x[@"conn"] boolValue] ? NSOrderedDescending : NSOrderedAscending);
            }];
        }
        BOOL connectedSince = NO;   // connected words drawn since the last primary word (no pause item then)

        double prevEnd = 0, timelineEnd = 0;   // end of the last spoken word, and of the last primary item
        NSString *lastSpeaker = nil;           // speaker of the last word drawn
        BOOL skipped = NO;                     // filtered-out words since the last word drawn
        for (NSDictionary *entry in entries) {
            id clip = entry[@"clip"];
            BOOL isConn = [entry[@"conn"] boolValue];
            BOOL placed = sequenceMode && entry[@"tl"] != nil;
            double tlStart = [entry[@"tl"] doubleValue], trimStart = [entry[@"trim"] doubleValue], clipDur = [entry[@"dur"] doubleValue];
            CMTimeRange clipRange = kCMTimeRangeZero;
            CMTime clipFrame = CMTimeMake(1, 600);
            if (!sequenceMode) {
                SKInvokeRange(clip, @"clippedRange", nil, &clipRange);
                if ([clip respondsToSelector:NSSelectorFromString(@"frameDuration")]) {
                    CMTime f = ((CMTime(*)(id,SEL))objc_msgSend)(clip, NSSelectorFromString(@"frameDuration"));
                    if (f.timescale > 0 && f.value > 0) clipFrame = f;
                }
            }
            if (placed && !isConn) timelineEnd = MAX(timelineEnd, tlStart + clipDur);
            NSArray *assets = SKAssetsForItem(clip);
            if (assets.count == 0) continue;   // gaps, generators: their time shows up as a pause
            for (id asset in assets) {
                NSArray<NSArray<SKRawWord *> *> *rawPhrases = SKPhrasesForAsset(asset);
                if (!rawPhrases) { [missingAssets addObject:asset]; if (![missingClips containsObject:clip]) [missingClips addObject:clip]; continue; }
                NSString *path = SKMediaPath(asset);
                if (path) {
                    [mediaPaths addObject:path];
                    if (!proxies[path]) { NSString *proxy = SKProxyPath(asset); if (proxy) proxies[path] = proxy; }
                }
                NSDictionary *entry = SKSpeakerEntry(path, NO);
                NSDictionary *corrections = [entry[@"corrections"] isKindOfClass:[NSDictionary class]] ? entry[@"corrections"] : nil;
                for (NSArray<SKRawWord *> *pw in rawPhrases) {
                    BOOL opened = NO;
                    for (SKRawWord *rw in pw) {
                        NSString *t = rw.text;
                        double s = rw.s, e = rw.e;
                        if (placed && (s < trimStart - 0.001 || s >= trimStart + clipDur - 0.001)) continue;   // trimmed away
                        SKWord *word = [SKWord new];
                        word.srcStart = s; word.srcEnd = e; word.mediaPath = path;
                        if (!sequenceMode) { word.sourceClip = clip; word.clipOrigin = clipRange.start; word.clipFrame = clipFrame; }
                        word.original = t;
                        NSString *fixed = corrections[[NSString stringWithFormat:@"%.3f", s]];
                        word.text = fixed ?: t;
                        word.tlStart = placed ? tlStart + (s - trimStart) : NAN;
                        word.tlEnd = placed ? MIN(tlStart + (e - trimStart), tlStart + clipDur) : NAN;
                        word.filler = SKIsFiller(word.text);
                        NSString *sid = entry ? SKSpeakerIDAt(entry, (s + e) / 2) : nil;
                        word.speaker = sid ? SKSpeakerName(entry, sid) : nil;
                        if (word.speaker) [speakerNames addObject:word.speaker];

                        if (isConn) {
                            // Only where the primary storyline is a gap (by the word's middle).
                            if (!SKTimeInGaps(gaps, (word.tlStart + word.tlEnd) / 2)) continue;
                            word.connectedClip = clip;
                            connectedSince = YES;
                        } else if (placed) {
                            // No pause item across a gap that connected speech fills: deleting it would delete the gap and the clips on it.
                            if (!connectedSince && word.tlStart - prevEnd >= gPauseThreshold - 1e-6) { addPause(prevEnd, word.tlStart, !opened); if (!gSpeakerFilter) pauseCount++; }
                            connectedSince = NO;
                            prevEnd = word.tlEnd;
                        }
                        [all addObject:word];
                        if (gSpeakerFilter && ![word.speaker isEqualToString:gSpeakerFilter]) { word.range = NSMakeRange(NSNotFound, 0); skipped = YES; continue; }
                        if (word.text.length == 0) { word.range = NSMakeRange(NSNotFound, 0); continue; }   // merged into a neighbour by a replace

                        // New paragraph when the speaker changes or filtered-out speech was skipped.
                        BOOL speakerChanged = word.speaker && ![word.speaker isEqualToString:lastSpeaker];
                        if (opened && (speakerChanged || skipped)) { add(@"\n", body); opened = NO; }
                        if (speakerChanged) {
                            closeBlock();
                            NSUInteger nameStart = out.length;
                            [labels addObject:@[[NSValue valueWithRange:NSMakeRange(out.length, word.speaker.length)], word.speaker]];
                            add([word.speaker stringByAppendingString:@"\n"], @{NSFontAttributeName: [NSFont systemFontOfSize:SKPt(11) weight:NSFontWeightSemibold],
                                NSForegroundColorAttributeName: SKSpeakerTextColor(word.speaker),
                                NSToolTipAttributeName: @"Double-click to rename this speaker everywhere; right-click to change its color"});
                            [nameParas addObject:[NSValue valueWithRange:NSMakeRange(nameStart, out.length - nameStart)]];
                            blockStart = nameStart; blockSpeaker = word.speaker;
                            lastSpeaker = word.speaker;
                        }
                        skipped = NO;
                        word.paragraphStart = !opened;
                        if (!opened) {
                            if (tcW > 0) {
                                // Timeline: timeline time. Browser clip: time into the media, or the clip's own timecode.
                                NSString *tc = placed ? (tcMode == 2 ? SKTimecodeDF(word.tlStart) : SKStampText(word.tlStart, SKFrameDuration(), tcMode))
                                                      : SKStampText(tcMode == 2 ? CMTimeGetSeconds(clipRange.start) + s : s, clipFrame, tcMode);
                                add([NSString stringWithFormat:@"\t%@\t", tc], stamp);
                            }
                            opened = YES;
                        }
                        NSMutableDictionary *attrs = [body mutableCopy];
                        if (placed || word.sourceClip) attrs[NSCursorAttributeName] = [NSCursor pointingHandCursor];
                        if (word.filler) { attrs[NSForegroundColorAttributeName] = [NSColor systemOrangeColor]; if (placed && !isConn) fillerCount++; }
                        if (fixed) attrs[NSUnderlineStyleAttributeName] = @(NSUnderlineStyleSingle | NSUnderlinePatternDot);   // corrected text
                        word.range = NSMakeRange(out.length, word.text.length);
                        add(word.text, attrs); add(@" ", body);
                        [words addObject:word];
                        if (blockStart != NSNotFound) blockEnd = NSMaxRange(word.range);
                    }
                    if (opened) add(@"\n", body);
                }
            }
        }
        if (sequenceMode && all.count && !connectedSince && timelineEnd - prevEnd >= gPauseThreshold - 1e-6) { addPause(prevEnd, timelineEnd, YES); if (!gSpeakerFilter) pauseCount++; }
        if (connected.count) TLog(@"connected: %lu clip(s) over %lu gap(s)", (unsigned long)connected.count, (unsigned long)gaps.count);
        closeBlock();
        if (missingAssets.count || words.count == 0) statusStart = out.length;
        if (missingAssets.count) {
            if (!gTranscribeState) gTranscribeState = [NSMapTable strongToStrongObjectsMapTable];
            // Nothing starts on its own: transcribing writes into the library, so it waits for the
            // Transcribe button below.
            NSMutableArray *idleAssets = [NSMutableArray array], *idleClips = [NSMutableArray array];
            for (id a in missingAssets) if (![[gTranscribeState objectForKey:a] isEqualToString:@"running"]) [idleAssets addObject:a];
            for (id c in missingClips) for (id a in SKAssetsForItem(c)) if ([idleAssets containsObject:a]) { [idleClips addObject:c]; break; }
            gUntranscribedClips = idleClips; gUntranscribedAssets = idleAssets;
            NSUInteger running = 0, failed = 0, notStarted = 0;
            NSMutableOrderedSet *reasons = [NSMutableOrderedSet orderedSet];
            for (id a in missingAssets) {
                NSString *st = [gTranscribeState objectForKey:a];
                if ([st isEqualToString:@"running"]) running++;
                else if (st) { failed++; [reasons addObject:st]; }
                else notStarted++;
            }
            NSString *(^clipsWord)(NSUInteger) = ^(NSUInteger n) { return n == 1 ? @"1 clip" : [NSString stringWithFormat:@"%lu clips", (unsigned long)n]; };
            if (running) add([NSString stringWithFormat:@"Transcribing %@ with Final Cut Pro… The transcript appears here when it's done (progress: Window › Background Tasks).\n", clipsWord(running)], dim);
            if (notStarted) add([NSString stringWithFormat:@"%@ no transcript yet. ", notStarted == 1 ? @"This clip has" : [NSString stringWithFormat:@"%lu clips have", (unsigned long)notStarted]], dim);
            if (failed) add([NSString stringWithFormat:@"Couldn't transcribe %@: %@. ", clipsWord(failed), [reasons.array componentsJoinedByString:@"; "]], dim);
            if (notStarted || failed) {
                // A real button (self.transcribeButton) is laid over this blank line after the text is set.
                add(@"\n", dim);
                NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
                ps.minimumLineHeight = ps.maximumLineHeight = SKPt(30);
                NSMutableDictionary *slot = [dim mutableCopy]; slot[NSParagraphStyleAttributeName] = ps;
                gTranscribeLabel = notStarted ? @"Transcribe" : @"Try again";
                gRetryRange = NSMakeRange(out.length, 1);
                add(@"\u200B\n", slot);
            }
        } else if (words.count == 0) add(gSpeakerFilter ? @"Nothing from this speaker on the timeline.\n" : @"No speech in this selection.\n", dim);
        TLog(@"render: sequenceMode=%d clips=%lu shown=%lu of %lu fillers=%lu pauses=%lu (>=%.1fs) speakers=[%@] filter=%@", sequenceMode, (unsigned long)clips.count,
             (unsigned long)words.count, (unsigned long)all.count, (unsigned long)fillerCount, (unsigned long)pauseCount, gPauseThreshold,
             [speakerNames.array componentsJoinedByString:@", "], gSpeakerFilter);
    } @catch (id e) { add([NSString stringWithFormat:@"\n[error: %@]", e], dim); TLog(@"refresh threw %@", e); }
    // Paragraph styles: word lines by default, then names, pause lines and the status message.
    if (out.length) {
        [out addAttribute:NSParagraphStyleAttributeName value:linePS range:NSMakeRange(0, out.length)];
        for (NSValue *v in nameParas) [out addAttribute:NSParagraphStyleAttributeName value:namePS range:v.rangeValue];
        for (NSValue *v in pauseParas) [out addAttribute:NSParagraphStyleAttributeName value:pausePS range:v.rangeValue];
        if (statusStart != NSNotFound && statusStart < out.length) {
            NSUInteger end = gRetryRange.location != NSNotFound ? gRetryRange.location : out.length;
            if (end > statusStart) [out addAttribute:NSParagraphStyleAttributeName value:plainPS range:NSMakeRange(statusStart, end - statusStart)];
        }
    }
    self.blocks = blocks;
    self.pauseRanges = pauseRanges;

    self.words = words;
    self.allItems = all;
    self.labelRanges = labels;
    self.mediaPaths = mediaPaths.array;
    self.proxyPaths = proxies;
    self.renderedSignature = SKTimelineSignature();
    self.renderedKey = [self sk_renderKeyWithSignature:self.renderedSignature];
    NSRange oldHighlight = self.highlighted;
    self.highlighted = NSMakeRange(NSNotFound, 0);
    // A redraw that produces the same text (selection changes in the browser, timeline
    // polling) keeps the user's selection and any range already marked from it.
    BOOL sameText = [out.string isEqualToString:self.textView.string];
    NSRange keep = self.textView.selectedRange;
    // When the rebuilt text is identical (inspector toggles, tab switches, re-selecting the same
    // clip) keep the existing storage: replacing it throws away the glyphs and layout, which cost
    // more than the rebuild itself. The playhead tint is not part of `out`, so lift it for the
    // comparison; sk_tick puts it back.
    CFAbsoluteTime tBuilt = CFAbsoluteTimeGetCurrent();
    BOOL identical = NO;
    if (sameText) {
        NSTextStorage *ts = self.textView.textStorage;
        if (oldHighlight.location != NSNotFound && NSMaxRange(oldHighlight) <= ts.length) [ts removeAttribute:NSBackgroundColorAttributeName range:oldHighlight];
        identical = [ts isEqualToAttributedString:out];
    }
    if (!identical) [self.textView.textStorage setAttributedString:out];
    if (!self.colorPanel) { self.colorWheelButton.hidden = YES; self.hoverSpeaker = nil; }
    if (gRetryRange.location != NSNotFound && NSMaxRange(gRetryRange) <= out.length) {
        NSLayoutManager *lm = self.textView.layoutManager;
        [lm ensureLayoutForTextContainer:self.textView.textContainer];
        NSRange g = [lm glyphRangeForCharacterRange:gRetryRange actualCharacterRange:NULL];
        NSRect line = [lm lineFragmentRectForGlyphAtIndex:g.location effectiveRange:NULL];
        NSButton *b = self.transcribeButton;
        b.title = gTranscribeLabel ?: @"Transcribe";
        [b sizeToFit];
        NSPoint o = self.textView.textContainerOrigin;
        [b setFrameOrigin:NSMakePoint(o.x - 4, o.y + NSMinY(line) + round((NSHeight(line) - NSHeight(b.frame)) / 2))];
        b.hidden = NO;
    } else self.transcribeButton.hidden = YES;
    self.textView.selectedRange = sameText && NSMaxRange(keep) <= out.length ? keep : NSMakeRange(0, 0);
    if (!sameText) self.sourceMarked = NO;
    self.fillerButton.title = [NSString stringWithFormat:@"Delete %lu", (unsigned long)fillerCount];
    self.pauseButton.title = [NSString stringWithFormat:@"Delete %lu", (unsigned long)pauseCount];
    self.fillerButton.toolTip = [NSString stringWithFormat:@"Delete %lu filler word%@ (um, uh…) from the timeline", (unsigned long)fillerCount, fillerCount == 1 ? @"" : @"s"];
    self.pauseButton.toolTip = [NSString stringWithFormat:@"Shorten %lu pause%@ to 0.1 s each side", (unsigned long)pauseCount, pauseCount == 1 ? @"" : @"s"];
    [self.textView setNeedsDisplay:YES];
    self.fillerButton.enabled = fillerCount > 0;
    self.pauseButton.enabled = pauseCount > 0;
    [self sk_rebuildSpeakerMenus:speakerNames.array];
    [self sk_updateFind:NO];
    [self sk_updateSourceButtons];
    TLog(@"refresh took %.0f ms (build %.0f, same text=%d identical=%d)", (CFAbsoluteTimeGetCurrent() - tRefresh0) * 1000, (tBuilt - tRefresh0) * 1000, sameText, identical);
    [self sk_tick];
}

- (SKWord *)sk_wordAtIndex:(NSUInteger)idx {
    for (SKWord *w in self.words) if (!w.pause && NSLocationInRange(idx, w.range)) return w;
    return nil;
}

#pragma mark Speakers: menus, detection, assignment

- (void)sk_rebuildSpeakerMenus:(NSArray<NSString *> *)names {
    NSMutableArray *all = [names mutableCopy];
    if (gSpeakerFilter && ![all containsObject:gSpeakerFilter]) [all addObject:gSpeakerFilter];
    [self.speakerPopup removeAllItems];
    [self.speakerPopup addItemWithTitle:@"All Speakers"];
    for (NSString *n in all) { [self.speakerPopup addItemWithTitle:n]; self.speakerPopup.lastItem.representedObject = n; }
    if (gSpeakerFilter) [self.speakerPopup selectItemWithTitle:gSpeakerFilter]; else [self.speakerPopup selectItemAtIndex:0];
    self.speakerPopup.enabled = all.count > 0;

    NSMenu *menu = [[NSMenu alloc] init];
    [menu addItemWithTitle:@"Set speaker" action:NULL keyEquivalent:@""];   // pull-down title
    for (NSString *n in all) {
        NSMenuItem *it = [menu addItemWithTitle:n action:@selector(sk_assignMenu:) keyEquivalent:@""];
        it.target = self; it.representedObject = n;
    }
    if (all.count) [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"New speaker…" action:@selector(sk_assignNew:) keyEquivalent:@""].target = self;
    [menu addItemWithTitle:@"Rename speaker…" action:@selector(sk_renameSpeaker:) keyEquivalent:@""].target = self;
    self.assignPopup.menu = menu;
    self.detectButton.title = gDetecting ? @"Detecting…" : (names.count ? @"Re-detect" : @"Detect");
    self.detectButton.enabled = !gDetecting && self.mediaPaths.count > 0;
}

- (void)sk_setFilter:(NSString *)name { gSpeakerFilter = name.length ? [name copy] : nil; [self sk_refresh]; }
- (void)sk_filterChanged:(NSPopUpButton *)sender { [self sk_setFilter:sender.selectedItem.representedObject]; }

// Run SpliceKit's parakeet-transcriber --speakers on each media file in the transcript and
// keep the per-word speaker labels it returns. Manual assignments are left alone.
// The tool reads audio with AVFoundation, which can't open MXF and other pro camera formats,
// so the audio is first extracted (all channels mixed to mono, 16 kHz WAV) with the ffmpeg
// that ships with SpliceKit. Progress from the tool is shown on the button.
static NSString *SKSpliceKitTool(NSString *name) {
    for (NSString *dir in @[@"Applications/SpliceKit/tools", @"Library/Application Support/SpliceKit/tools"]) {
        NSString *full = [[NSHomeDirectory() stringByAppendingPathComponent:dir] stringByAppendingPathComponent:name];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:full]) return full;
    }
    return nil;
}

// Run a tool to completion; returns stdout. Each stderr line goes to `lineHandler` as it arrives.
static NSData *SKRun(NSString *tool, NSArray *args, int *status, void (^lineHandler)(NSString *)) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:tool];
    task.arguments = args;
    NSPipe *outPipe = [NSPipe pipe], *errPipe = [NSPipe pipe];
    task.standardOutput = outPipe; task.standardError = errPipe;
    NSMutableString *pending = [NSMutableString string];
    errPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSString *chunk = [[NSString alloc] initWithData:h.availableData encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (pending) {
            [pending appendString:chunk];
            NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [pending substringToIndex:nl.location];
                [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                if (lineHandler) lineHandler(line);
            }
        }
    };
    if (![task launchAndReturnError:NULL]) { *status = -1; return nil; }
    NSData *data = [outPipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    errPipe.fileHandleForReading.readabilityHandler = nil;
    *status = task.terminationStatus;
    return data;
}

- (void)sk_setDetectStatus:(NSString *)title tip:(NSString *)tip {
    dispatch_async(dispatch_get_main_queue(), ^{
        SKInspectorModuleTranscript *m = gModule;
        m.detectButton.title = title;
        if (tip) m.detectButton.toolTip = tip;
    });
}

- (void)sk_detectSpeakers:(id)sender {
    if (gDetecting) return;
    NSString *tool = SKSpliceKitTool(@"parakeet-transcriber"), *ffmpeg = SKSpliceKitTool(@"ffmpeg");
    NSArray *paths = [self.mediaPaths copy];
    NSDictionary *proxies = [self.proxyPaths copy];
    if (!tool || paths.count == 0) { TLog(@"detect: tool=%@ files=%lu", tool, (unsigned long)paths.count); NSBeep(); return; }
    gDetecting = YES;
    [self sk_rebuildSpeakerMenus:@[]];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        NSString *failure = nil;
        for (NSUInteger fi = 0; fi < paths.count; fi++) {
            NSString *path = paths[fi];
            NSString *label = paths.count > 1 ? [NSString stringWithFormat:@" (%lu/%lu)", (unsigned long)fi + 1, (unsigned long)paths.count] : @"";
            NSString *wav = nil;
            @try {
                NSDate *t0 = [NSDate date];
                NSString *input = path;
                NSString *audioSource = proxies[path] ?: path;   // labels are still stored under the original
                if (ffmpeg) {
                    [self sk_setDetectStatus:[(audioSource == path ? @"Reading audio…" : @"Reading proxy audio…") stringByAppendingString:label] tip:nil];
                    // How many audio streams? Mix them all, so every mic is heard.
                    int st = 0; __block NSUInteger streams = 0;
                    SKRun(ffmpeg, @[@"-hide_banner", @"-i", audioSource], &st, ^(NSString *line) { if ([line containsString:@"Stream #"] && [line containsString:@"Audio:"]) streams++; });
                    wav = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"sk-speakers-%@.wav", [[NSUUID UUID] UUIDString]]];
                    NSMutableArray *args = [@[@"-hide_banner", @"-loglevel", @"error", @"-y", @"-i", audioSource] mutableCopy];
                    if (streams > 1) {
                        NSMutableString *f = [NSMutableString string];
                        for (NSUInteger i = 0; i < streams; i++) [f appendFormat:@"[0:a:%lu]", (unsigned long)i];
                        [f appendFormat:@"amix=inputs=%lu:duration=longest[a]", (unsigned long)streams];
                        [args addObjectsFromArray:@[@"-filter_complex", f, @"-map", @"[a]"]];
                    } else [args addObjectsFromArray:@[@"-map", @"0:a:0"]];
                    [args addObjectsFromArray:@[@"-ac", @"1", @"-ar", @"16000", @"-c:a", @"pcm_s16le", wav]];
                    SKRun(ffmpeg, args, &st, nil);
                    if (st == 0 && [[NSFileManager defaultManager] fileExistsAtPath:wav]) input = wav;
                    TLog(@"detect: extracted %lu audio stream(s) from %@ %@ in %.1fs (exit %d)", (unsigned long)streams, audioSource == path ? @"original" : @"proxy",
                         audioSource.lastPathComponent, -[t0 timeIntervalSinceNow], st);
                }
                int status = 0;
                __block NSString *toolError = nil;
                [self sk_setDetectStatus:[@"Detecting…" stringByAppendingString:label] tip:nil];
                NSData *data = SKRun(tool, @[input, @"--speakers", @"--progress"], &status, ^(NSString *line) {
                    if ([line hasPrefix:@"PROGRESS:"]) {
                        NSArray *parts = [line componentsSeparatedByString:@":"];
                        if (parts.count >= 3) [self sk_setDetectStatus:[NSString stringWithFormat:@"Detecting %d%%%@", (int)([parts[1] doubleValue] * 100), label]
                                                                  tip:[[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@":"]];
                    } else if ([line hasPrefix:@"ERROR:"]) toolError = [line substringFromIndex:6];
                });
                id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                NSMutableArray *rows = [NSMutableArray array];
                NSString *last = nil;
                for (NSDictionary *w in ([json isKindOfClass:[NSArray class]] ? json : @[])) {
                    if (![w isKindOfClass:[NSDictionary class]] || !w[@"startTime"]) continue;
                    NSString *sp = w[@"speaker"] ?: last;   // the tool leaves boundary words unlabelled: carry the previous speaker
                    if (sp) last = sp;
                    [rows addObject:@[w[@"startTime"], w[@"endTime"] ?: w[@"startTime"], sp ?: [NSNull null]]];
                }
                NSString *firstKnown = nil;
                for (NSArray *r in rows) if (r[2] != [NSNull null]) { firstKnown = r[2]; break; }
                NSMutableArray *filled = [NSMutableArray array];
                if (firstKnown) for (NSArray *r in rows) [filled addObject:@[r[0], r[1], r[2] == [NSNull null] ? firstKnown : r[2]]];
                if (filled.count) found[path] = filled;   // a failed run must not wipe earlier labels
                else failure = toolError ?: [NSString stringWithFormat:@"no speakers found (exit %d)", status];
                NSMutableSet *ids = [NSMutableSet set];
                for (NSArray *r in filled) [ids addObject:r[2]];
                TLog(@"detect: %@ -> %lu words, speakers [%@] in %.1fs (exit %d) %@", path.lastPathComponent, (unsigned long)filled.count,
                     [ids.allObjects componentsJoinedByString:@", "], -[t0 timeIntervalSinceNow], status, toolError ?: @"");
            } @catch (id e) { TLog(@"detect threw %@", e); failure = [e description]; }
            if (wav) [[NSFileManager defaultManager] removeItemAtPath:wav error:NULL];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            for (NSString *path in found) SKSpeakerEntry(path, YES)[@"words"] = found[path];
            SKSaveSpeakers();
            gDetecting = NO;
            [gModule sk_refresh];
            if (failure) {
                gModule.detectButton.title = @"Detection failed";
                gModule.detectButton.toolTip = failure;
                NSBeep();
            }
        });
    });
}

// Label the selected words as `name`, per media file, in source time.
// Spoken words in the text selection, from the timeline or a browser clip.
- (NSArray<SKWord *> *)sk_selectedSpokenWords {
    NSRange sel = self.textView.selectedRange;
    NSMutableArray *hit = [NSMutableArray array];
    if (sel.length == 0) return hit;
    for (SKWord *w in self.words) if (!w.pause && w.mediaPath && NSIntersectionRange(sel, w.range).length > 0) [hit addObject:w];
    return hit;
}

- (BOOL)sk_assignSpeaker:(NSString *)name {
    NSArray<SKWord *> *hit = [self sk_selectedSpokenWords];
    name = [name stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (name.length == 0) return NO;
    NSUInteger n = 0;
    for (SKWord *w in hit) {
        if (w.pause || !w.mediaPath) continue;
        NSMutableDictionary *entry = SKSpeakerEntry(w.mediaPath, YES);
        NSString *sid = SKSpeakerIDForName(entry, name);
        NSMutableArray *overrides = entry[@"overrides"];
        NSArray *prev = overrides.lastObject;
        // Extend the previous override when this word follows straight on from it.
        if (prev && [prev[2] isEqualToString:sid] && w.srcStart >= [prev[0] doubleValue] && w.srcStart - [prev[1] doubleValue] < 0.5)
            overrides[overrides.count - 1] = @[prev[0], @(MAX(w.srcEnd, [prev[1] doubleValue])), sid];
        else [overrides addObject:@[@(w.srcStart), @(w.srcEnd), sid]];
        n++;
    }
    TLog(@"assign '%@' to %lu word(s)", name, (unsigned long)n);
    if (n == 0) return NO;
    SKSaveSpeakers();
    [self sk_refresh];
    return YES;
}

- (BOOL)sk_renameSpeaker:(NSString *)old to:(NSString *)new {
    new = [new stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!old.length || !new.length) return NO;
    NSUInteger n = 0;
    for (NSString *path in self.mediaPaths) {
        NSMutableDictionary *entry = SKSpeakerEntry(path, NO);
        if (!entry) continue;
        NSMutableSet *ids = [NSMutableSet setWithArray:[entry[@"names"] allKeys]];
        for (NSArray *w in entry[@"words"]) [ids addObject:w[2]];
        for (NSArray *o in entry[@"overrides"]) [ids addObject:o[2]];
        for (NSString *sid in ids) {
            if (![SKSpeakerName(entry, sid) isEqualToString:old]) continue;
            if (![entry[@"names"] isKindOfClass:[NSMutableDictionary class]]) entry[@"names"] = [entry[@"names"] mutableCopy] ?: [NSMutableDictionary dictionary];
            entry[@"names"][sid] = new; n++;
        }
    }
    TLog(@"rename '%@' -> '%@' in %lu file(s)", old, new, (unsigned long)n);
    NSDictionary *colors = [[NSUserDefaults standardUserDefaults] dictionaryForKey:kSKSpeakerColorsKey];
    if (n > 0 && colors[old] && !colors[new]) SKSetSpeakerColorIndex(new, [colors[old] integerValue]);   // the color follows the name
    if ([gSpeakerFilter isEqualToString:old]) gSpeakerFilter = [new copy];
    SKSaveSpeakers();
    [self sk_refresh];
    return n > 0;
}

- (NSString *)sk_promptForName:(NSString *)message initial:(NSString *)initial {
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    [alert addButtonWithTitle:@"OK"]; [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 220, 22)];
    field.stringValue = initial ?: @"";
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    return [alert runModal] == NSAlertFirstButtonReturn ? field.stringValue : nil;
}
// Right-click menu. On a speaker name: rename it. On text: if the click isn't inside the current
// selection, select the line (phrase) under the pointer first; then offer every speaker to
// relabel the selected text, "New speaker…", and renaming that line's speaker.
- (NSMenu *)sk_contextMenuAtIndex:(NSUInteger)idx {
    self.menuIndex = idx;
    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Transcript"];
    menu.autoenablesItems = NO;
    NSString *label = [self sk_speakerLabelAtIndex:idx];
    if (label) {
        NSMenuItem *it = [menu addItemWithTitle:[NSString stringWithFormat:@"Rename “%@”…", label] action:@selector(sk_renameLabelMenu:) keyEquivalent:@""];
        it.target = self; it.representedObject = @(idx);
        return menu;
    }
    SKWord *clicked = [self sk_wordAtIndex:idx];
    if (!clicked) return nil;
    if (!NSLocationInRange(idx, self.textView.selectedRange)) {
        // The line: back to the word that opened its paragraph, forward until the next one or a pause.
        NSUInteger i = [self.words indexOfObject:clicked], a = i, b = i;
        while (a > 0 && !self.words[a].paragraphStart && !self.words[a - 1].pause) a--;
        while (b + 1 < self.words.count && !self.words[b + 1].paragraphStart && !self.words[b + 1].pause) b++;
        NSUInteger start = self.words[a].range.location;
        self.textView.selectedRange = NSMakeRange(start, NSMaxRange(self.words[b].range) - start);
        [self.textView.window makeFirstResponder:self.textView];
    }
    NSArray<SKWord *> *hit = [self sk_selectedSpokenWords];
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    for (SKWord *w in self.allItems) if (w.speaker) [names addObject:w.speaker];
    NSSet *current = [NSSet setWithArray:[hit valueForKey:@"speaker"]];
    NSMenuItem *head = [menu addItemWithTitle:(hit.count == 1 ? @"Speaker for this word" : @"Speaker for the selected text") action:NULL keyEquivalent:@""];
    head.enabled = NO;
    for (NSString *n in names) {
        NSMenuItem *it = [menu addItemWithTitle:n action:@selector(sk_assignMenu:) keyEquivalent:@""];
        it.target = self; it.representedObject = n; it.indentationLevel = 1;
        if (current.count == 1 && [current containsObject:n]) it.state = NSControlStateValueOn;
    }
    NSMenuItem *add = [menu addItemWithTitle:@"New speaker…" action:@selector(sk_assignNew:) keyEquivalent:@""];
    add.target = self; add.indentationLevel = 1;
    if (clicked.speaker) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSMenuItem *rn = [menu addItemWithTitle:[NSString stringWithFormat:@"Rename “%@” everywhere…", clicked.speaker] action:@selector(sk_renameSpeakerNamed:) keyEquivalent:@""];
        rn.target = self; rn.representedObject = clicked.speaker;
    }
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@""].target = self.textView;
    TLog(@"context menu at '%@': %lu word(s) selected; items %@", clicked.text, (unsigned long)hit.count, [[menu.itemArray valueForKey:@"title"] componentsJoinedByString:@" | "]);
    return menu;
}
// FCP's role color circle: shown beside a speaker name while the pointer is on that name's line
// (like the Role Editor); clicking it opens the picker pointing at the circle.
- (void)sk_hoverAtViewPoint:(NSPoint)p {
    NSTextView *tv = self.textView;
    NSLayoutManager *lm = tv.layoutManager;
    NSPoint o = tv.textContainerOrigin;
    NSUInteger len = tv.textStorage.length;
    for (NSArray *l in self.labelRanges) {
        NSRange r = [l[0] rangeValue];
        if (r.length == 0 || NSMaxRange(r) > len) continue;
        NSRange g = [lm glyphRangeForCharacterRange:r actualCharacterRange:NULL];
        NSRect line = NSOffsetRect([lm lineFragmentRectForGlyphAtIndex:g.location effectiveRange:NULL], o.x, o.y);
        if (p.y < NSMinY(line) || p.y >= NSMaxY(line)) continue;
        NSRect name = NSOffsetRect([lm boundingRectForGlyphRange:g inTextContainer:tv.textContainer], o.x, o.y);
        NSButton *b = self.colorWheelButton;
        [b setFrameOrigin:NSMakePoint(round(NSMaxX(name) + 6), round(NSMidY(name) - NSHeight(b.frame) / 2))];
        b.hidden = NO;
        self.hoverSpeaker = l[1];
        return;
    }
    if (!self.colorPanel) { self.colorWheelButton.hidden = YES; self.hoverSpeaker = nil; }
}
- (void)sk_colorWheelClicked:(NSButton *)sender {
    if (!self.hoverSpeaker) return;
    [self sk_showColorPickerFor:self.hoverSpeaker anchor:NSMakePoint(NSMinX(sender.frame) - 1, NSMidY(sender.frame))];
}
// `anchor` (text view coordinates) is where the pointer's tip goes; the panel opens to its left.
- (void)sk_showColorPickerFor:(NSString *)name anchor:(NSPoint)anchor {
    BOOL circleShown = !self.colorWheelButton.hidden;
    [self sk_closeColorPicker];   // any picker already open (this also hides the circle…)
    if (circleShown) { self.colorWheelButton.hidden = NO; self.hoverSpeaker = name; }   // …which stays beside the name while its picker is open
    NSTextView *tv = self.textView;
    if (!tv.window) return;
    NSPoint screen = [tv.window convertPointToScreen:[tv convertPoint:anchor toView:nil]];
    CGFloat W = kSKPickerPad * 2 + kSKSwatch * 2 + kSKPickerArrow, H = kSKPickerPad * 2 + kSKSwatchH * 9;
    NSRect fr = NSMakeRect(screen.x - W, screen.y - H / 2, W, H);
    NSRect vis = (tv.window.screen ?: [NSScreen mainScreen]).visibleFrame;
    fr.origin.y = MAX(NSMinY(vis) + 4, MIN(fr.origin.y, NSMaxY(vis) - H - 4));
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:fr styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:NO];
    panel.opaque = NO; panel.backgroundColor = [NSColor clearColor]; panel.hasShadow = NO;   // a shadow read as a thicker frame (v68)
    panel.level = NSPopUpMenuWindowLevel; panel.releasedWhenClosed = NO;
    SKRoleColorPicker *v = [[SKRoleColorPicker alloc] initWithFrame:NSMakeRect(0, 0, W, H)];
    v.selected = SKSpeakerColorIndex(name); v.hover = -1;
    v.arrowY = NSMaxY(fr) - screen.y;
    __weak SKInspectorModuleTranscript *ws = self;
    v.onPick = ^(NSInteger i) {
        SKSetSpeakerColorIndex(name, i);
        TLog(@"speaker color '%@' -> %ld", name, (long)i);
        [ws sk_closeColorPicker];
        [ws sk_refresh];
    };
    panel.contentView = v;
    [panel orderFront:nil];
    self.colorPanel = panel;
    // Escape, or a click anywhere else (in FCP or another app), closes it.
    self.colorLocalMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown | NSEventMaskKeyDown handler:^NSEvent *(NSEvent *e) {
        if (e.type == NSEventTypeKeyDown) { if (e.keyCode == 53) { [ws sk_closeColorPicker]; return nil; } return e; }
        if (e.window != ws.colorPanel) [ws sk_closeColorPicker];
        return e;
    }];
    self.colorGlobalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown handler:^(NSEvent *e) { [ws sk_closeColorPicker]; }];
    TLog(@"color picker for '%@' at %@", name, NSStringFromRect(fr));
}
- (void)sk_closeColorPicker {
    if (self.colorLocalMonitor) { [NSEvent removeMonitor:self.colorLocalMonitor]; self.colorLocalMonitor = nil; }
    if (self.colorGlobalMonitor) { [NSEvent removeMonitor:self.colorGlobalMonitor]; self.colorGlobalMonitor = nil; }
    [self.colorPanel orderOut:nil];
    self.colorPanel = nil;
    self.colorWheelButton.hidden = YES; self.hoverSpeaker = nil;
}
- (void)sk_renameLabelMenu:(NSMenuItem *)item { [self sk_beginEditingSpeakerAtIndex:[item.representedObject unsignedIntegerValue]]; }
// Rename from the text: edit the nearest label for that speaker above the selection, else ask.
- (void)sk_renameSpeakerNamed:(NSMenuItem *)item {
    NSString *name = item.representedObject;
    NSArray *best = nil;
    for (NSArray *l in self.labelRanges)
        if ([l[1] isEqualToString:name] && [l[0] rangeValue].location <= self.textView.selectedRange.location) best = l;
    for (NSArray *l in self.labelRanges) if (!best && [l[1] isEqualToString:name]) best = l;
    if (best) {
        [self.textView scrollRangeToVisible:[best[0] rangeValue]];
        [self sk_beginEditingSpeakerAtIndex:[best[0] rangeValue].location];
    } else {
        NSString *n = [self sk_promptForName:[NSString stringWithFormat:@"Rename “%@”", name] initial:name];
        if (n) [self sk_renameSpeaker:name to:n];
    }
}

- (void)sk_assignMenu:(NSMenuItem *)item { if (![self sk_assignSpeaker:item.representedObject]) NSBeep(); }
- (void)sk_assignNew:(id)sender {
    if ([self sk_selectedSpokenWords].count == 0) { NSBeep(); return; }
    NSRange keep = self.textView.selectedRange;
    NSString *name = [self sk_promptForName:@"Name for the selected speech" initial:nil];
    self.textView.selectedRange = keep;
    if (name) [self sk_assignSpeaker:name];
}
// Menu "Rename speaker…": asks which speaker (preselecting the filtered one or the one under
// the selection) and the new name.
- (void)sk_renameSpeaker:(id)sender {
    NSMutableOrderedSet *names = [NSMutableOrderedSet orderedSet];
    for (SKWord *w in self.allItems) if (w.speaker) [names addObject:w.speaker];
    if (names.count == 0) {
        NSAlert *a = [NSAlert new];
        a.messageText = @"No speakers yet";
        a.informativeText = @"Press “Detect speakers”, or select some words and choose a name from “Set speaker”.";
        [a runModal];
        return;
    }
    NSString *current = gSpeakerFilter ?: [self sk_selectedWords].firstObject.speaker ?: names.firstObject;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Rename speaker";
    alert.informativeText = @"The new name replaces it everywhere in this transcript.";
    [alert addButtonWithTitle:@"Rename"]; [alert addButtonWithTitle:@"Cancel"];
    NSView *box = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 240, 54)];
    NSPopUpButton *which = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 28, 240, 24) pullsDown:NO];
    [which addItemsWithTitles:names.array];
    [which selectItemWithTitle:current];
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 22)];
    field.placeholderString = @"New name";
    [box addSubview:which]; [box addSubview:field];
    alert.accessoryView = box;
    alert.window.initialFirstResponder = field;
    if ([alert runModal] == NSAlertFirstButtonReturn) [self sk_renameSpeaker:which.titleOfSelectedItem to:field.stringValue];
}

// Ask FCP to transcribe, the same way Modify › Analyze and Fix › Transcribe does: background tasks
// whose results FCP stores in the library (so FCP's transcript features see them and they survive a
// restart). Progress shows in FCP's Background Tasks window. We poll FCP's store and redraw.
- (void)sk_requestTranscriptsForClips:(NSArray *)clips missingAssets:(NSArray *)missing {
    NSMutableArray *running = [NSMutableArray array];
    for (id a in missing) {
        NSUInteger audio = [a respondsToSelector:NSSelectorFromString(@"audioSourceCount")]
            ? ((NSUInteger(*)(id,SEL))objc_msgSend)(a, NSSelectorFromString(@"audioSourceCount")) : 1;
        if (audio == 0) { [gTranscribeState setObject:@"no audio" forKey:a]; continue; }
        [gTranscribeState setObject:@"running" forKey:a];
        [running addObject:a];
    }
    NSArray *todo = SKBrowserClipsForAssets(running);
    TLog(@"transcribe: %lu asset(s) missing, %lu with audio, %lu browser clip(s) to analyze (from %lu selected)",
         (unsigned long)missing.count, (unsigned long)running.count, (unsigned long)todo.count, (unsigned long)clips.count);
    void (^fail)(NSString *) = ^(NSString *why) {
        for (id a in running) [gTranscribeState setObject:why forKey:a];
        dispatch_async(dispatch_get_main_queue(), ^{ [gModule sk_refresh]; });
    };
    if (!running.count) { dispatch_async(dispatch_get_main_queue(), ^{ [gModule sk_refresh]; }); return; }
    if (!todo.count) { fail(@"couldn't find the clip in the browser"); return; }
    // Same path as Modify › Analyze and Fix… with only "Transcribe" ticked: FCP's shared
    // FFAnalyzeAndOptimizeViewController and its own default options, with every switch turned off
    // (its defaults include "create proxy media") except analyzeAndOptimizeShouldTranscribe.
    // Language comes from those defaults ("en-US"; v56–58 passed NSLocale's "en_US", which FCP
    // treated as a different language, and the job stalled).
    @try {
        id vc = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFAnalyzeAndOptimizeViewController"), NSSelectorFromString(@"sharedInstance"));
        NSDictionary *defaults = ((id(*)(id,SEL,BOOL))objc_msgSend)(vc, NSSelectorFromString(@"defaultAnalyzeAndOptimizeOptions:"), NO);
        NSMutableDictionary *options = [defaults mutableCopy] ?: [NSMutableDictionary dictionary];
        for (NSString *k in defaults) {
            id v = defaults[k];
            // NSNumber booleans are the switches; leave numeric settings (proxy sizing mode) alone.
            if ([v isKindOfClass:[NSNumber class]] && strcmp([v objCType], @encode(char)) == 0) options[k] = @NO;
            else if ([v isKindOfClass:[NSNumber class]] && ([v isEqual:@0] || [v isEqual:@1]) && ![k containsString:@"Mode"]) options[k] = @NO;
        }
        options[@"analyzeAndOptimizeShouldTranscribe"] = @YES;
        NSString *lang = [defaults[@"analyzeAndOptimizeTranscriptionLanguage"] isKindOfClass:[NSString class]] ? defaults[@"analyzeAndOptimizeTranscriptionLanguage"] : @"en-US";
        options[@"analyzeAndOptimizeTranscriptionLanguage"] = lang;
        ((void(*)(id,SEL,id,id))objc_msgSend)(vc, NSSelectorFromString(@"analyzeAndOptimizeClips:options:"), todo, options);
        TLog(@"transcribe: Analyze and Fix (%@) for %@ options %@", lang, [todo valueForKey:@"displayName"], options);
    } @catch (id e) {
        TLog(@"transcribe threw %@", e);
        fail([NSString stringWithFormat:@"Final Cut Pro refused (%@)", [e respondsToSelector:@selector(reason)] ? [e reason] : e]);
        return;
    }
    SKPollTranscription(running, CFAbsoluteTimeGetCurrent());
}

#pragma mark Click to seek / playhead highlight

// Returns YES when the click landed on a word and moved the playhead.
- (void)sk_transcribeClicked:(id)sender {
    TLog(@"transcribe: button clicked for %lu asset(s)", (unsigned long)gUntranscribedAssets.count);
    if (gUntranscribedAssets.count) [self sk_requestTranscriptsForClips:gUntranscribedClips missingAssets:gUntranscribedAssets];
    [self sk_refresh];
}

- (BOOL)sk_clickedCharacterAtIndex:(NSUInteger)idx {
    for (SKWord *w in self.words) {
        if (!NSLocationInRange(idx, w.range)) continue;
        if (isnan(w.tlStart)) return [self sk_seekSourceWord:w];   // source view: move the browser playhead
        TLog(@"click word src=%.3f -> timeline %.3f", w.srcStart, w.tlStart);
        SKSeek(w.tlStart);
        [self sk_highlight:w.range];
        return YES;
    }
    return NO;
}

- (void)sk_highlight:(NSRange)range {
    if (NSEqualRanges(range, self.highlighted)) return;
    { static int logged; if (logged++ < 30) TLog(@"highlight -> %lu,%lu", (unsigned long)range.location, (unsigned long)range.length); }
    NSTextStorage *ts = self.textView.textStorage;
    if (self.highlighted.location != NSNotFound && NSMaxRange(self.highlighted) <= ts.length)
        [ts removeAttribute:NSBackgroundColorAttributeName range:self.highlighted];
    if (range.location != NSNotFound && NSMaxRange(range) <= ts.length) {
        [ts addAttribute:NSBackgroundColorAttributeName value:[[NSColor colorWithSRGBRed:0.30 green:0.55 blue:1.0 alpha:1] colorWithAlphaComponent:0.32] range:range];
        if (self.textView.selectedRange.length == 0) [self.textView scrollRangeToVisible:range];
    }
    self.highlighted = range;
}

// Cheap fingerprint of the primary storyline: which clips, where, and how they are trimmed.
static NSString *SKTimelineSignature(void) {
    NSMutableString *sig = [NSMutableString string];
    NSArray *primary = SKPrimaryItems();
    for (id clip in primary) {
        double a = 0, b = 0, d = 0;
        SKClipPlacement(clip, &a, &b, &d);
        [sig appendFormat:@"%p:%.3f:%.3f:%.3f;", clip, a, b, d];
    }
    for (NSDictionary *c in SKConnectedOverGaps(primary, SKPrimaryGaps(primary)))
        [sig appendFormat:@"c%p:%.3f:%.3f:%.3f;", c[@"clip"], [c[@"tl"] doubleValue], [c[@"trim"] doubleValue], [c[@"dur"] doubleValue]];
    return sig;
}

// Highlight the last timeline word that starts at or before the playhead, and redraw when
// the timeline was edited outside this tab (blade, trim, undo, appended clips…).
- (void)sk_tick {
    if (self.tickCount % 3 == 0) [self sk_reattachIfNeeded];
    if (![self sk_isShowing]) { self.tickCount++; return; }
    if (self.needsRefresh) { [self sk_refresh]; return; }
    if (++self.tickCount % 5 == 0 && !SKTimelinePlaying()) {   // the timeline can't be edited mid-playback; keep the main thread free
        NSString *sig = SKTimelineSignature();
        if (self.renderedSignature && ![sig isEqualToString:self.renderedSignature]) { TLog(@"timeline changed, redrawing"); [self sk_refresh]; return; }
    }
    if (self.words.count == 0) return;
    SKWord *firstSource = nil;
    for (SKWord *w in self.words) if (w.sourceClip) { firstSource = w; break; }
    if (firstSource) { [self sk_tickSource:firstSource]; return; }
    @try {
        double t = SKPlayheadSeconds();
        if (t < 0) return;
        NSRange hit = NSMakeRange(NSNotFound, 0);
        SKWord *last = nil;
        for (SKWord *w in self.words) {
            if (isnan(w.tlStart)) continue;
            if (w.tlStart <= t + 0.02) { hit = w.range; last = w; } else break;
        }
        if (last && t > last.tlEnd + 1.5) hit = NSMakeRange(NSNotFound, 0);   // long pause or past the end
        [self sk_highlight:hit];
    } @catch (id e) {}
}

// After FCP is deactivated and reactivated (Cmd-Tab away and back) it leaves our tab selected
// but our view detached, so the tab shows blank. If the inspector's selected tab item is ours
// and our view isn't in a window, put it back into that item's view, filling it.
- (void)sk_reattachIfNeeded {
    @try {
        NSTabView *tabView = [gTabModule valueForKey:@"_tabView"];
        NSTabViewItem *item = tabView.selectedTabViewItem;
        if (!item || !tabView.window || item.identifier != self) return;   // only when our tab is the one showing
        if (item.view && (item.view == self.container || [self.container isDescendantOf:item.view])) return;   // already in place
        // Ours if its identifier is our tab, or its view tree is where our content used to live.
        // FCP uses the module object itself as each tab item's identifier.
        BOOL ours = item.identifier == self || [item.identifier isEqual:kTabIdent] || [item.view isEqual:self.container];
        if (!ours) {
            for (NSTabViewItem *it in tabView.tabViewItems)
                if (it.identifier == self || [it.identifier isEqual:kTabIdent]) { ours = (it == item); break; }
        }
        static NSUInteger logged;
        if (logged++ < 5) TLog(@"detached: item view=%@ (%lu subviews), our view's window=%@ visible=%d, superview=%@", [item.view class],
            (unsigned long)item.view.subviews.count, [self.container.window class], self.container.window.isVisible, [self.container.superview class]);
        if (!ours) return;
        NSView *host = item.view;
        if (!host || host == self.container) {
            item.view = self.container;
        } else {
            [self.container removeFromSuperview];
            self.container.frame = host.bounds;
            self.container.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
            [host addSubview:self.container];
        }
        [self sk_applyControlScale];
        TLog(@"reattached transcript view (window=%d)", self.container.window != nil);
    } @catch (id e) { TLog(@"reattach threw %@", e); }
}

// Keyboard focus to the browser when showing a browser clip's transcript, else to the timeline.
// Focusing the timeline from a browser clip would make the inspector switch to the timeline.
- (void)sk_focusPlaybackOwner {
    BOOL source = NO;
    for (SKWord *w in self.words) if (w.sourceClip) { source = YES; break; }
    SKTimelineAction(source ? @"goToOrganizer:" : @"goToTimeline:");
    TLog(@"focus -> %@", source ? @"browser" : @"timeline");
}

// Source view: follow the browser/viewer playhead. The browser's FFContext time is in the
// clip's own time (camera timecode), so subtract the clip's start to get transcript time.
// Binary search, since a long interview is several thousand words.
- (void)sk_tickSource:(SKWord *)sample {
    @try {
        id fs = SKFilmstripModule();
        id ctx = [fs respondsToSelector:@selector(context)] ? ((id(*)(id,SEL))objc_msgSend)(fs, @selector(context)) : nil;
        if (![ctx respondsToSelector:NSSelectorFromString(@"time")]) return;
        CMTime ct = ((CMTime(*)(id,SEL))objc_msgSend)(ctx, NSSelectorFromString(@"time"));
        if (!CMTIME_IS_NUMERIC(ct)) return;
        double t = CMTimeGetSeconds(CMTimeSubtract(ct, sample.clipOrigin));
        NSArray<SKWord *> *ws = self.words;
        NSInteger lo = -1, hi = ws.count;   // last word with srcStart <= t (pauses are not in the source view)
        while (hi - lo > 1) { NSInteger mid = (lo + hi) / 2; if (ws[mid].srcStart <= t + 0.02) lo = mid; else hi = mid; }
        NSRange hit = NSMakeRange(NSNotFound, 0);
        if (lo >= 0 && ws[lo].sourceClip == sample.sourceClip && t <= ws[lo].srcEnd + 1.5) hit = ws[lo].range;
        [self sk_highlight:hit];
    } @catch (id e) {}
}

#pragma mark Source clips: mark a range from the text, then edit it into the timeline
// With a browser clip selected the tab shows that clip's transcript. Selecting words marks
// the same range on the clip in the browser (FCP's own range selection), so FCP's edit
// commands — Append (E), Insert (W), Overwrite (D), Connect (Q), drag to the timeline —
// all work on it. Clicking a word moves the browser playhead there.

static id SKFilmstripModule(void) {
    @try {
        id container = ((id(*)(id,SEL))objc_msgSend)([NSApp delegate], NSSelectorFromString(@"mediaEventOrganizerContainer"));
        id organizer = ((id(*)(id,SEL))objc_msgSend)(container, NSSelectorFromString(@"activeOrganizerModule"));
        SEL fs = NSSelectorFromString(@"filmstripModule");
        return [organizer respondsToSelector:fs] ? ((id(*)(id,SEL))objc_msgSend)(organizer, fs) : nil;
    } @catch (id e) { return nil; }
}

static NSArray *SKBrowserSelection(id fs) {
    SEL sel = NSSelectorFromString(@"selectedRangesOfMedia");
    return [fs respondsToSelector:sel] ? ((id(*)(id,SEL))objc_msgSend)(fs, sel) : nil;
}

// Does the browser selection hold `range` on `clip` (to within a frame)?
static BOOL SKBrowserSelectionIs(id fs, id clip, CMTimeRange range) {
    for (id r in SKBrowserSelection(fs)) {
        CMTimeRange got = kCMTimeRangeZero;
        if (!SKInvokeRange(r, @"CMTimeRange", nil, &got) && !SKInvokeRange(r, @"range", nil, &got)) {
            // FigTimeRangeAndObject keeps its range in the "timeRange"-style ivar; fall back to the description
            return [[r description] containsString:[NSString stringWithFormat:@"%.6f", CMTimeGetSeconds(range.start)]];
        }
        if (fabs(CMTimeGetSeconds(got.start) - CMTimeGetSeconds(range.start)) < 0.05 && fabs(CMTimeGetSeconds(got.duration) - CMTimeGetSeconds(range.duration)) < 0.05) return YES;
    }
    return NO;
}

// Select `range` (clip time) on a browser clip and put the browser playhead at `playhead`.
// Tries FCP's own range-selection call first, then reveal-and-select; logs what worked.
static BOOL SKRevealInBrowser(id clip, CMTimeRange range, CMTime playhead) {
    id fs = SKFilmstripModule();
    if (!fs) { TLog(@"browser module unavailable"); return NO; }
    Class rao = objc_getClass("FigTimeRangeAndObject");
    // The browser's own object for this clip, if it is listed (the inspector may hand us a different wrapper).
    id browserObject = clip;
    for (NSString *listSel in @[@"filteredRanges", @"unfilteredRanges"]) {
        if (![fs respondsToSelector:NSSelectorFromString(listSel)]) continue;
        for (id r in ((id(*)(id,SEL))objc_msgSend)(fs, NSSelectorFromString(listSel))) {
            id o = [r respondsToSelector:@selector(object)] ? [r valueForKey:@"object"] : nil;
            if (o == clip) { browserObject = o; break; }
        }
    }
    id ranged = ((id(*)(id,SEL,CMTimeRange,id))objc_msgSend)(rao, NSSelectorFromString(@"rangeAndObjectWithRange:andObject:"), range, browserObject);
    BOOL ok = NO;
    SEL selectSel = NSSelectorFromString(@"_selectMediaRanges:");
    if (ranged && [fs respondsToSelector:selectSel]) {
        ((void(*)(id,SEL,id))objc_msgSend)(fs, selectSel, @[ranged]);
        ok = SKBrowserSelectionIs(fs, browserObject, range);
        TLog(@"browser _selectMediaRanges: -> %@ (match=%d)", [SKBrowserSelection(fs) description], ok);
    }
    if (!ok) {
        SEL reveal = NSSelectorFromString(@"_revealAndSelectMediaRanges:");
        if (ranged && [fs respondsToSelector:reveal]) {
            ((void(*)(id,SEL,id))objc_msgSend)(fs, reveal, @[ranged]);
            ok = SKBrowserSelectionIs(fs, browserObject, range);
            TLog(@"browser _revealAndSelectMediaRanges: -> %@ (match=%d)", [SKBrowserSelection(fs) description], ok);
        }
    }
    // Browser playhead to the start of the range.
    SEL move = NSSelectorFromString(@"moveToRangeOfMedia:andTime:");
    if (ranged && [fs respondsToSelector:move]) ((void(*)(id,SEL,id,CMTime))objc_msgSend)(fs, move, ranged, playhead);
    TLog(@"browser mark %.3f–%.3f on %@ (%p, browser object %p) -> %d", CMTimeGetSeconds(range.start), CMTimeGetSeconds(CMTimeRangeGetEnd(range)),
         [clip class], clip, browserObject, ok);
    return ok;
}

// Clip time = the clip's own start (its media timecode origin) + the word's time in the media,
// on the clip's own frame grid. direction > 0 rounds up to a frame, < 0 down.
static CMTime SKClipTime(SKWord *w, double mediaSeconds, int direction) {
    CMTime fd = w.clipFrame.timescale > 0 && w.clipFrame.value > 0 ? w.clipFrame : SKFrameDuration();
    double frames = mediaSeconds * fd.timescale / fd.value;
    int64_t n = direction > 0 ? (int64_t)ceil(frames - 1e-6) : (int64_t)floor(frames + 1e-6);
    CMTime t = CMTimeAdd(w.clipOrigin, CMTimeMake(MAX(n, 0) * fd.value, fd.timescale));
    return t;
}

- (BOOL)sk_seekSourceWord:(SKWord *)w {
    if (!w.sourceClip) return NO;
    id fs = SKFilmstripModule();
    CMTimeRange whole = kCMTimeRangeZero;
    SKInvokeRange(w.sourceClip, @"clippedRange", nil, &whole);
    id ranged = ((id(*)(id,SEL,CMTimeRange,id))objc_msgSend)(objc_getClass("FigTimeRangeAndObject"), NSSelectorFromString(@"rangeAndObjectWithRange:andObject:"), whole, w.sourceClip);
    SEL move = NSSelectorFromString(@"moveToRangeOfMedia:andTime:");
    if (!ranged || ![fs respondsToSelector:move]) return NO;
    ((void(*)(id,SEL,id,CMTime))objc_msgSend)(fs, move, ranged, SKClipTime(w, w.srcStart, -1));
    TLog(@"browser playhead -> %.3f", w.srcStart);
    return YES;
}

static id SKClipAtTime(double t);
// Timeline view (v75): mark the selected words as a range on the timeline, like I and O — first
// word's start (frame floor) to last word's end (frame ceiling) — so FCP's edits act on it.
- (BOOL)sk_markTimelineSelection {
    NSRange sel = self.textView.selectedRange;
    SKWord *a = nil, *b = nil;
    for (SKWord *w in self.words) if (!isnan(w.tlStart) && NSIntersectionRange(sel, w.range).length) { if (!a) a = w; b = w; }
    if (!a) return NO;
    CMTime s = SKFrameTime(a.tlStart, -1), e = SKFrameTime(b.tlEnd, 1);
    if (CMTimeCompare(e, s) <= 0) return NO;
    @try {
        id tl = SKTimelineModule();
        SEL selRange = NSSelectorFromString(@"_selectRange:extendRange:selectedItem:");
        if (![tl respondsToSelector:selRange]) { TLog(@"range selection API missing"); return NO; }
        id onItem = a.connectedClip && a.connectedClip == b.connectedClip ? a.connectedClip : SKClipAtTime(CMTimeGetSeconds(s));
        ((void(*)(id,SEL,CMTimeRange,BOOL,id))objc_msgSend)(tl, selRange, CMTimeRangeFromTimeToTime(s, e), NO, onItem);
        BOOL ok = ((BOOL(*)(id,SEL))objc_msgSend)(tl, NSSelectorFromString(@"timelineHasSelectedRange"));
        TLog(@"mark timeline '%@'…'%@' %.3f–%.3f -> %@", a.text ?: @"pause", b.text ?: @"pause", CMTimeGetSeconds(s), CMTimeGetSeconds(e), ok ? @"range set" : @"no range");
        [self.textView.window makeFirstResponder:self.textView];   // keep Delete / key forwarding working on the text selection
        return ok;
    } @catch (id ex) { TLog(@"mark timeline threw %@", ex); return NO; }
}

// Mark the selected words as the clip's range: first word's onset to last word's end.
// In timeline view the range goes on the timeline instead.
- (BOOL)sk_markSourceSelection {
    for (SKWord *w in self.words) if (!isnan(w.tlStart)) return [self sk_markTimelineSelection];
    NSMutableArray<SKWord *> *hit = [NSMutableArray array];
    NSRange sel = self.textView.selectedRange;
    for (SKWord *w in self.words) if (!w.pause && w.sourceClip && NSIntersectionRange(sel, w.range).length) [hit addObject:w];
    if (hit.count == 0) return NO;
    for (SKWord *w in hit) if (w.sourceClip != hit.firstObject.sourceClip) { TLog(@"selection spans clips; not marking"); NSBeep(); return NO; }
    SKWord *a = hit.firstObject, *b = hit.lastObject;
    CMTime s = SKClipTime(a, a.srcStart, -1), e = SKClipTime(b, b.srcEnd, 1);
    TLog(@"mark source '%@'…'%@' media %.3f–%.3f", a.text, b.text, a.srcStart, b.srcEnd);
    self.sourceMarked = SKRevealInBrowser(a.sourceClip, CMTimeRangeFromTimeToTime(s, e), s);
    [self sk_updateSourceButtons];
    return self.sourceMarked;
}

- (void)sk_updateSourceButtons {
    BOOL source = NO;
    for (SKWord *w in self.words) if (w.sourceClip) { source = YES; break; }
    for (NSButton *b in self.sourceButtons) b.enabled = source && self.sourceMarked;
}

// Append / Insert / Overwrite / Connect the marked range, as FCP's E / W / D / Q do.
- (BOOL)sk_editSource:(NSString *)kind {
    NSDictionary *actions = @{@"append": @"appendWithSelectedMedia:", @"insert": @"insertWithSelectedMedia:",
                              @"overwrite": @"overwriteWithSelectedMedia:", @"connect": @"anchorWithSelectedMedia:"};
    NSString *action = actions[kind];
    if (!action || !self.sourceMarked) { NSBeep(); return NO; }
    if (self.textView.selectedRange.length) [self sk_markSourceSelection];   // re-assert the range in case the browser selection moved on
    TLog(@"source edit: %@", action);
    SKTimelineAction(action);
    return YES;
}
- (void)sk_sourceButton:(NSButton *)sender { [self sk_editSource:sender.identifier]; }

#pragma mark Export and captions

static NSString *SKTimecode(double t) {
    CMTime fd = SKFrameDuration();
    int fps = MAX(1, (int)llround((double)fd.timescale / fd.value));
    int64_t frames = (int64_t)llround(t * fd.timescale / fd.value);
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld:%02lld", frames / fps / 3600, frames / fps / 60 % 60, frames / fps % 60, frames % fps];
}

static NSString *SKSRTTime(double t) {
    int64_t ms = (int64_t)llround(t * 1000);
    return [NSString stringWithFormat:@"%02lld:%02lld:%02lld,%03lld", ms / 3600000, ms / 60000 % 60, ms / 1000 % 60, ms % 1000];
}

// Timeline seconds as timecode. Drop-frame projects (29.97/59.94) count in drop frame and
// use ';' like Premiere; everything else is non-drop with ':'.
// Times round to the nearest frame, so a segment's end and the next block's start (the same
// instant) always print the same timecode and blocks never overlap.
static NSString *SKTimecodeDF(double t) {
    CMTime fd = SKFrameDuration();
    int64_t frames = (int64_t)llround(t * fd.timescale / fd.value);
    int fps = MAX(1, (int)llround((double)fd.timescale / fd.value));
    BOOL drop = NO;
    @try {
        id seq = ((id(*)(id,SEL))objc_msgSend)(SKTimelineModule(), @selector(sequence));
        SEL dfSel = NSSelectorFromString(@"timecodeDisplayDropFrame");
        drop = [seq respondsToSelector:dfSel] && ((long(*)(id,SEL))objc_msgSend)(seq, dfSel) != 0 && (fps == 30 || fps == 60) && fd.timescale % fd.value != 0;
    } @catch (id e) {}
    if (drop) {   // standard drop-frame renumbering: skip 2 (or 4) frame numbers each minute except every tenth
        int64_t d = fps == 60 ? 4 : 2, per10 = fps * 600 - d * 9, perMin = fps * 60 - d;
        int64_t tens = frames / per10, rem = frames % per10;
        frames += d * 9 * tens + (rem > d ? d * ((rem - d) / perMin) : 0);
    }
    NSString *sep = drop ? @";" : @":";
    return [NSString stringWithFormat:@"%02lld%@%02lld%@%02lld%@%02lld", frames / fps / 3600, sep, frames / fps / 60 % 60, sep, frames / fps % 60, sep, frames % fps];
}

// Premiere Pro's transcript text format: one block per speech segment —
//   00;00;02;15 - 00;00;04;24
//   Speaker Name
//   Text of the segment.
//   (blank line)
// Segments break at phrase boundaries, speaker changes and pauses; each pause item becomes
// an empty block (blank speaker and text lines), as Premiere writes silences.
- (NSString *)sk_exportPremiere {
    NSMutableString *out = [NSMutableString string];
    NSMutableArray<SKWord *> *seg = [NSMutableArray array];
    void (^flush)(void) = ^{
        if (seg.count == 0) return;
        SKWord *a = seg.firstObject, *b = seg.lastObject;
        double s = isnan(a.tlStart) ? a.srcStart : a.tlStart, e = isnan(b.tlEnd) ? b.srcEnd : b.tlEnd;
        [out appendFormat:@"%@ - %@\n%@\n%@\n\n", SKTimecodeDF(s), SKTimecodeDF(e), a.speaker ?: @"Unknown",
            [[seg valueForKey:@"text"] componentsJoinedByString:@" "]];
        [seg removeAllObjects];
    };
    for (SKWord *w in self.words) {
        if (w.pause) {
            flush();
            [out appendFormat:@"%@ - %@\n\n\n\n", SKTimecodeDF(w.tlStart), SKTimecodeDF(w.tlEnd)];
            continue;
        }
        if (w.text.length == 0) continue;
        if (seg.count && (w.paragraphStart || ![w.speaker ?: @"" isEqualToString:seg.lastObject.speaker ?: @""])) flush();
        [seg addObject:w];
    }
    flush();
    return out;
}

// The transcript as plain text, one paragraph per phrase, with "Name:" when speakers are
// known and "[timecode]" when asked. Follows what the tab shows: corrections, and the speaker
// filter if one is on. Pause markers are left out.
- (NSString *)sk_exportTextWithTimecodes:(BOOL)timecodes {
    NSMutableString *out = [NSMutableString string];
    __block NSMutableString *para = nil;
    NSString *lastSpeaker = nil;
    BOOL anySpeaker = NO;
    for (SKWord *w in self.words) if (w.speaker) { anySpeaker = YES; break; }
    void (^flush)(void) = ^{ if (para.length) [out appendFormat:@"%@\n\n", para]; };
    for (SKWord *w in self.words) {
        if (w.pause) continue;
        if (!para || w.paragraphStart || (w.speaker && ![w.speaker isEqualToString:lastSpeaker])) {
            flush();
            para = [NSMutableString string];
            double t = isnan(w.tlStart) ? w.srcStart : w.tlStart;
            if (timecodes) [para appendFormat:@"[%@] ", SKTimecode(t)];
            if (anySpeaker) [para appendFormat:@"%@: ", w.speaker ?: @"Unknown"];
            lastSpeaker = w.speaker;
        } else [para appendString:@" "];
        [para appendString:w.text];
    }
    flush();
    return out;
}

// Caption cues from the timeline transcript (all speakers, corrected text). A cue breaks at a
// pause, a speaker change, sentence ends once it has some length, ~84 characters or 6 seconds,
// and is wrapped onto two lines past 42 characters. Times are frame-aligned so FCP accepts
// them without retiming.
- (NSArray<NSDictionary *> *)sk_captionCues {
    NSMutableArray *cues = [NSMutableArray array];
    NSMutableArray<SKWord *> *cur = [NSMutableArray array];
    void (^flush)(void) = ^{
        if (cur.count == 0) return;
        NSString *text = [[cur valueForKey:@"text"] componentsJoinedByString:@" "];
        if (text.length > 42) {   // two lines, split at the space nearest the middle
            NSUInteger mid = text.length / 2, best = NSNotFound;
            for (NSUInteger i = 0; i < text.length; i++)
                if ([text characterAtIndex:i] == ' ' && (best == NSNotFound || labs((long)i - (long)mid) < labs((long)best - (long)mid))) best = i;
            if (best != NSNotFound) text = [NSString stringWithFormat:@"%@\n%@", [text substringToIndex:best], [text substringFromIndex:best + 1]];
        }
        [cues addObject:@{@"start": @(cur.firstObject.tlStart), @"end": @(cur.lastObject.tlEnd), @"text": text}];
        [cur removeAllObjects];
    };
    NSString *lastSpeaker = nil;
    for (SKWord *w in self.allItems) {
        if (w.pause) { flush(); continue; }
        if (isnan(w.tlStart) || w.text.length == 0) continue;
        if (w.speaker && lastSpeaker && ![w.speaker isEqualToString:lastSpeaker]) flush();
        lastSpeaker = w.speaker ?: lastSpeaker;
        NSUInteger len = 0; for (SKWord *c in cur) len += c.text.length + 1;
        if (cur.count && (len + w.text.length > 84 || w.tlEnd - cur.firstObject.tlStart > 6.0)) flush();
        [cur addObject:w];
        unichar last = [w.text characterAtIndex:w.text.length - 1];
        if ((last == '.' || last == '?' || last == '!') && len + w.text.length >= 20) flush();
    }
    flush();
    // Hold each cue at least a second (without running into the next), then snap to frames.
    double frame = CMTimeGetSeconds(SKFrameDuration());
    NSMutableArray *snapped = [NSMutableArray array];
    for (NSUInteger i = 0; i < cues.count; i++) {
        double s = [cues[i][@"start"] doubleValue], e = [cues[i][@"end"] doubleValue];
        double limit = i + 1 < cues.count ? [cues[i + 1][@"start"] doubleValue] : e + 1.0;
        e = MIN(MAX(e, s + 1.0), limit);
        s = CMTimeGetSeconds(SKFrameTime(s, -1)); e = CMTimeGetSeconds(SKFrameTime(e, -1));
        if (e - s < frame) e = s + frame;
        [snapped addObject:@{@"start": @(s), @"end": @(e), @"text": cues[i][@"text"]}];
    }
    return snapped;
}

- (NSString *)sk_srt {
    NSMutableString *srt = [NSMutableString string];
    NSArray *cues = [self sk_captionCues];
    for (NSUInteger i = 0; i < cues.count; i++)
        [srt appendFormat:@"%lu\n%@ --> %@\n%@\n\n", (unsigned long)i + 1, SKSRTTime([cues[i][@"start"] doubleValue]), SKSRTTime([cues[i][@"end"] doubleValue]), cues[i][@"text"]];
    return srt;
}

// kind: 0 text, 1 text with timecodes, 2 SRT, 3 Premiere-style transcript. Writes to `path`,
// or asks with a save panel.
- (BOOL)sk_export:(NSInteger)kind toPath:(NSString *)path {
    if (kind == 1) kind = 3;   // "with timecodes" is the Premiere-style layout
    NSString *body = kind == 3 ? [self sk_exportPremiere] : kind == 2 ? [self sk_srt] : [self sk_exportTextWithTimecodes:NO];
    if (body.length == 0) {   // e.g. FCP is still transcribing: don't write an empty file
        TLog(@"export kind=%ld skipped: no transcript yet", (long)kind);
        NSBeep();
        return NO;
    }
    if (!path) {
        NSSavePanel *panel = [NSSavePanel savePanel];
        NSString *base = [[[self.mediaPaths.firstObject lastPathComponent] stringByDeletingPathExtension] ?: @"Transcript" stringByAppendingString:@" transcript"];
        panel.nameFieldStringValue = [base stringByAppendingPathExtension:kind == 2 ? @"srt" : @"txt"];
        if ([panel runModal] != NSModalResponseOK) return NO;
        path = panel.URL.path;
    }
    NSError *err = nil;
    BOOL ok = [body writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&err];
    TLog(@"export kind=%ld -> %@ (%lu chars) ok=%d %@", (long)kind, path, (unsigned long)body.length, ok, err ?: @"");
    return ok;
}
- (void)sk_exportMenu:(NSMenuItem *)item { if (![self sk_export:item.tag toPath:nil]) TLog(@"export cancelled or failed"); }

// Native captions: write the cues as an SRT file and run FCP's own File > Import > Closed
// Captions with it. The import's open panel is answered by SKOpenPanel* hooks below (it never
// appears), so FCP parses, places and adds the captions itself, as one undoable step.
static NSURL *gPendingCaptionURL;
- (BOOL)sk_createCaptions:(id)sender {
    NSString *srt = [self sk_srt];
    if (srt.length == 0) { NSBeep(); return NO; }
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"SpliceKit Transcript Captions.srt"];
    [srt writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    gPendingCaptionURL = [NSURL fileURLWithPath:path];
    TLog(@"create captions: %lu cue(s) via %@", (unsigned long)[self sk_captionCues].count, path);
    SKTimelineAction(@"importCaptions:");
    // FCP may open the panel a beat later; stop answering for it after a few seconds.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ gPendingCaptionURL = nil; });
    return YES;
}

#pragma mark Find, replace and word correction
// Corrections only change what the transcript says; the media is untouched. They are stored
// per media file next to the speaker data, keyed by the word's source start time, so they
// survive re-renders and restarts. An empty correction hides a word (used when a replacement
// merges several words into one, e.g. "sound bite" -> "soundbite").

static NSString *SKCorrectionKey(SKWord *w) { return [NSString stringWithFormat:@"%.3f", w.srcStart]; }

static NSMutableDictionary *SKCorrections(NSString *path, BOOL create) {
    NSMutableDictionary *entry = SKSpeakerEntry(path, create);
    if (!entry) return nil;
    if (![entry[@"corrections"] isKindOfClass:[NSMutableDictionary class]]) {
        if (!create && !entry[@"corrections"]) return nil;
        entry[@"corrections"] = [entry[@"corrections"] mutableCopy] ?: [NSMutableDictionary dictionary];
    }
    return entry[@"corrections"];
}

// Record new text for a word (nil or the original text reverts it). Caller saves and refreshes.
- (void)sk_setText:(NSString *)text forWord:(SKWord *)w {
    if (w.pause || !w.mediaPath) return;
    NSMutableDictionary *c = SKCorrections(w.mediaPath, YES);
    if (!text || [text isEqualToString:w.original]) [c removeObjectForKey:SKCorrectionKey(w)];
    else c[SKCorrectionKey(w)] = text;
}

- (void)sk_commitCorrections { SKSaveSpeakers(); [self sk_refresh]; }

// Inline editor: a text field laid over the word. Return commits, Tab commits and moves to the
// next word, Escape cancels. An empty field reverts the word to FCP's original text.
- (void)sk_beginEditingWord:(SKWord *)w {
    [self sk_endEditing:NO];
    if (!w || w.pause || w.range.location == NSNotFound) return;
    NSLayoutManager *lm = self.textView.layoutManager;
    NSRect rect = [lm boundingRectForGlyphRange:[lm glyphRangeForCharacterRange:w.range actualCharacterRange:NULL] inTextContainer:self.textView.textContainer];
    rect = NSOffsetRect(rect, self.textView.textContainerOrigin.x, self.textView.textContainerOrigin.y);
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(NSMinX(rect) - 3, NSMinY(rect) - 2, MAX(NSWidth(rect) + 60, 90), NSHeight(rect) + 4)];
    field.font = [NSFont systemFontOfSize:SKPt(13)];
    field.stringValue = w.text;
    field.placeholderString = w.original;
    field.delegate = self;
    field.focusRingType = NSFocusRingTypeExterior;
    [self.textView addSubview:field];
    self.editField = field; self.editingWord = w;
    [self.textView.window makeFirstResponder:field];
    [field.currentEditor selectAll:nil];
    TLog(@"editing word '%@' (original '%@')", w.text, w.original);
}

- (NSString *)sk_speakerLabelAtIndex:(NSUInteger)idx {
    for (NSArray *l in self.labelRanges) if (NSLocationInRange(idx, [l[0] rangeValue])) return l[1];
    return nil;
}

// Double-click on a speaker label: edit the name in place; Return renames that speaker everywhere.
- (void)sk_beginEditingSpeakerAtIndex:(NSUInteger)idx {
    [self sk_endEditing:NO];
    NSRange range = NSMakeRange(NSNotFound, 0); NSString *name = nil;
    for (NSArray *l in self.labelRanges) if (NSLocationInRange(idx, [l[0] rangeValue])) { range = [l[0] rangeValue]; name = l[1]; break; }
    if (!name) return;
    NSLayoutManager *lm = self.textView.layoutManager;
    NSRect rect = [lm boundingRectForGlyphRange:[lm glyphRangeForCharacterRange:range actualCharacterRange:NULL] inTextContainer:self.textView.textContainer];
    rect = NSOffsetRect(rect, self.textView.textContainerOrigin.x, self.textView.textContainerOrigin.y);
    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(NSMinX(rect) - 3, NSMinY(rect) - 3, MAX(NSWidth(rect) + 80, 140), NSHeight(rect) + 6)];
    field.font = [NSFont boldSystemFontOfSize:SKPt(11)];
    field.stringValue = name;
    field.placeholderString = name;
    field.toolTip = @"Return renames this speaker everywhere; Escape cancels";
    field.delegate = self;
    field.focusRingType = NSFocusRingTypeExterior;
    [self.textView addSubview:field];
    self.editField = field; self.editingSpeaker = name;
    [self.textView.window makeFirstResponder:field];
    [field.currentEditor selectAll:nil];
    TLog(@"editing speaker '%@'", name);
}

- (void)sk_endEditing:(BOOL)commit {
    NSTextField *field = self.editField; SKWord *w = self.editingWord;
    NSString *speaker = self.editingSpeaker;
    if (!field) return;
    self.editField = nil; self.editingWord = nil; self.editingSpeaker = nil;
    NSString *text = [field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [field removeFromSuperview];
    [self.textView.window makeFirstResponder:self.textView];
    if (speaker) {
        if (commit && text.length && ![text isEqualToString:speaker]) [self sk_renameSpeaker:speaker to:text];
        return;
    }
    if (!commit || [text isEqualToString:w.text]) return;
    TLog(@"correct '%@' -> '%@'", w.text, text.length ? text : w.original);
    [self sk_setText:(text.length ? text : nil) forWord:w];
    [self sk_commitCorrections];
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)tv doCommandBySelector:(SEL)cmd {
    if (control == self.editField) {
        if (cmd == @selector(cancelOperation:)) { [self sk_endEditing:NO]; return YES; }
        if (cmd == @selector(insertNewline:)) { [self sk_endEditing:YES]; return YES; }
        if (cmd == @selector(insertTab:) && self.editingSpeaker) { [self sk_endEditing:YES]; return YES; }
        if (cmd == @selector(insertTab:)) {
            double after = self.editingWord.srcStart; NSString *path = self.editingWord.mediaPath;
            [self sk_endEditing:YES];
            // Re-find the following word after the refresh (the SKWord objects were rebuilt).
            for (SKWord *w in self.words)
                if (!w.pause && [w.mediaPath isEqualToString:path] && w.srcStart > after + 1e-4) { [self sk_beginEditingWord:w]; break; }
            return YES;
        }
    }
    if (control == self.searchField && cmd == @selector(insertNewline:)) { [self sk_findStep:+1]; return YES; }
    if (control == self.replaceField && cmd == @selector(insertNewline:)) { [self sk_replaceAll:NO]; return YES; }
    return NO;
}

- (void)controlTextDidChange:(NSNotification *)n {
    if (n.object == self.searchField) { self.findIndex = 0; [self sk_updateFind:YES]; }
}

- (void)controlTextDidEndEditing:(NSNotification *)n {
    // Clicking away from the inline editor keeps what was typed.
    if (n.object == self.editField && self.editField) [self sk_endEditing:YES];
}

// Matches for the search text, restricted to the transcript words (not timestamps, speaker
// labels or pause markers). A match may span several words.
- (void)sk_updateFind:(BOOL)reveal {
    NSLayoutManager *lm = self.textView.layoutManager;
    NSString *text = self.textView.string;
    [lm removeTemporaryAttribute:NSBackgroundColorAttributeName forCharacterRange:NSMakeRange(0, text.length)];
    NSString *q = self.searchField.stringValue;
    NSMutableArray<NSValue *> *matches = [NSMutableArray array];
    if (q.length) {
        NSMutableIndexSet *wordChars = [NSMutableIndexSet indexSet];
        SKWord *prev = nil;
        for (SKWord *w in self.words) {
            if (w.pause || w.range.location == NSNotFound) { prev = nil; continue; }
            if (prev && w.range.location == NSMaxRange(prev.range) + 1) [wordChars addIndex:NSMaxRange(prev.range)];   // the space between
            [wordChars addIndexesInRange:w.range];
            prev = w;
        }
        NSRange search = NSMakeRange(0, text.length);
        while (search.length) {
            NSRange r = [text rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch range:search];
            if (r.location == NSNotFound) break;
            if ([wordChars containsIndexesInRange:r]) [matches addObject:[NSValue valueWithRange:r]];
            search = NSMakeRange(NSMaxRange(r), text.length - NSMaxRange(r));
        }
    }
    self.findMatches = matches;
    if (self.findIndex >= (NSInteger)matches.count) self.findIndex = matches.count ? matches.count - 1 : 0;
    NSColor *all = [[NSColor systemYellowColor] colorWithAlphaComponent:0.35], *cur = [[NSColor systemOrangeColor] colorWithAlphaComponent:0.7];
    for (NSUInteger i = 0; i < matches.count; i++)
        [lm addTemporaryAttribute:NSBackgroundColorAttributeName value:(i == (NSUInteger)self.findIndex ? cur : all) forCharacterRange:matches[i].rangeValue];
    self.findCount.stringValue = q.length == 0 ? @"" : matches.count == 0 ? @"No matches" : [NSString stringWithFormat:@"%ld of %lu", (long)self.findIndex + 1, (unsigned long)matches.count];
    BOOL any = matches.count > 0;
    self.prevButton.enabled = self.nextButton.enabled = self.replaceButton.enabled = self.replaceAllButton.enabled = any;
    if (reveal && any) [self sk_revealMatch];
}

// Scroll to the current match and park the playhead on its first word.
- (void)sk_revealMatch {
    if (self.findMatches.count == 0) return;
    NSRange r = self.findMatches[self.findIndex].rangeValue;
    [self.textView scrollRangeToVisible:r];
    for (SKWord *w in self.words)
        if (!w.pause && NSIntersectionRange(w.range, r).length && !isnan(w.tlStart)) { SKSeek(w.tlStart); break; }
}

- (void)sk_findStep:(NSInteger)delta {
    NSInteger n = self.findMatches.count;
    if (n == 0) { NSBeep(); return; }
    self.findIndex = ((self.findIndex + delta) % n + n) % n;
    [self sk_updateFind:NO];
    [self sk_revealMatch];
}
- (void)sk_findPrev:(id)sender { [self sk_findStep:-1]; }
- (void)sk_findNext:(id)sender { [self sk_findStep:+1]; }

// Replace the current match (all=NO) or every match. Matches are applied from the end so the
// earlier ones' offsets stay valid; a match spanning words puts the result in the first word
// and hides the rest.
- (NSUInteger)sk_replaceAll:(BOOL)all {
    if (self.findMatches.count == 0) { NSBeep(); return 0; }
    NSString *repl = self.replaceField.stringValue;
    NSArray *targets = all ? self.findMatches : @[self.findMatches[self.findIndex]];
    NSMapTable<SKWord *, NSString *> *working = [NSMapTable strongToStrongObjectsMapTable];
    for (NSValue *v in targets.reverseObjectEnumerator) {
        NSRange r = v.rangeValue;
        NSMutableArray<SKWord *> *hit = [NSMutableArray array];
        for (SKWord *w in self.words) if (!w.pause && NSIntersectionRange(w.range, r).length) [hit addObject:w];
        if (hit.count == 0) continue;
        SKWord *first = hit.firstObject, *last = hit.lastObject;
        NSString *firstText = [working objectForKey:first] ?: first.text, *lastText = [working objectForKey:last] ?: last.text;
        NSUInteger pre = r.location - first.range.location, post = NSMaxRange(r) - last.range.location;
        NSString *merged = [NSString stringWithFormat:@"%@%@%@", [firstText substringToIndex:MIN(pre, firstText.length)], repl,
                            post < lastText.length ? [lastText substringFromIndex:post] : @""];
        [working setObject:merged forKey:first];
        for (NSUInteger k = 1; k < hit.count; k++) [working setObject:@"" forKey:hit[k]];
    }
    NSUInteger n = 0;
    for (SKWord *w in working) {
        NSString *t = [working objectForKey:w];
        // A word replaced down to nothing on its own reverts rather than vanishing.
        [self sk_setText:(t.length || w != [self.words firstObject] ? t : nil) forWord:w]; n++;
    }
    TLog(@"replace %@ '%@' -> '%@': %lu match(es), %lu word(s) changed", all ? @"all" : @"one", self.searchField.stringValue, repl, (unsigned long)targets.count, (unsigned long)n);
    [self sk_commitCorrections];
    return targets.count;
}
- (void)sk_replaceOneClicked:(id)sender { [self sk_replaceAll:NO]; }
- (void)sk_replaceAllClicked:(id)sender { [self sk_replaceAll:YES]; }
- (void)sk_focusSearch {
    if ([SKCollapsedSections() containsObject:@"find"]) [self sk_toggleSection:@"find"];
    [self.textView.window makeFirstResponder:self.searchField];
}

#pragma mark Select and delete

// Timeline items (words and pauses) touched by the current text selection, in order.
- (NSArray<SKWord *> *)sk_selectedWords {
    NSRange sel = self.textView.selectedRange;
    NSMutableArray *hit = [NSMutableArray array];
    if (sel.length == 0) return hit;
    for (SKWord *w in self.words)
        if (!isnan(w.tlStart) && NSIntersectionRange(sel, w.range).length > 0) [hit addObject:w];
    return hit;
}

- (void)sk_snapSelectionToWords {
    NSArray<SKWord *> *hit = [self sk_selectedWords];
    if (hit.count == 0) return;
    NSUInteger start = hit.firstObject.range.location;
    self.textView.selectedRange = NSMakeRange(start, NSMaxRange(hit.lastObject.range) - start);
}

// Frame-aligned timeline range that removes the consecutive items first…last.
//  - A word is cut from the frame containing its onset up to the frame before the next word
//    begins, or to its own end when a pause item (or the end of the timeline) follows.
//  - A pause at either edge of the run keeps kPausePad of air on that side, so removing
//    pauses tightens the edit without butting words together.
static const double kPausePad = 0.1;
- (CMTimeRange)sk_cutRangeFrom:(SKWord *)first to:(SKWord *)last {
    NSUInteger i = [self.allItems indexOfObject:last];   // the full list: a filtered-out word still bounds the cut
    SKWord *next = i != NSNotFound && i + 1 < self.allItems.count ? self.allItems[i + 1] : nil;
    if (next && isnan(next.tlStart)) next = nil;
    CMTime s = first.pause ? SKFrameTime(first.tlStart + (first.tlStart > 0 ? kPausePad : 0), 1) : SKFrameTime(first.tlStart, -1);
    CMTime e;
    if (last.pause) e = SKFrameTime(last.tlEnd - (next ? kPausePad : 0), -1);
    else if (next && !next.pause) e = SKFrameTime(next.tlStart, -1);
    else e = SKFrameTime(last.tlEnd, 1);
    if (CMTimeCompare(e, s) <= 0) return kCMTimeRangeInvalid;
    return CMTimeRangeFromTimeToTime(s, e);
}

// The primary-storyline clip under a timeline time (FCP wants one alongside a range selection).
static id SKClipAtTime(double t) {
    for (id clip in SKPrimaryItems()) {
        double tlStart = 0, trim = 0, dur = 0;
        if (SKClipPlacement(clip, &tlStart, &trim, &dur) && t >= tlStart - 1e-4 && t < tlStart + dur) return clip;
    }
    return nil;
}

// Remove timeline ranges (NSValue-wrapped CMTimeRange, ascending, non-overlapping). Ripple
// delete by default; lift leaves gaps. Tries one multi-range selection so the whole batch is
// a single undo step; otherwise deletes back to front, one undo step per range.
- (BOOL)sk_cutRanges:(NSArray<NSValue *> *)ranges lift:(BOOL)lift {
    return [self sk_cutRanges:ranges lift:lift onItem:nil];
}
// `item`: the clip the range belongs to (a connected clip); nil = the primary clip under it.
- (BOOL)sk_cutRanges:(NSArray<NSValue *> *)ranges lift:(BOOL)lift onItem:(id)item {
    if (ranges.count == 0) return NO;
    NSString *deleteSel = lift ? @"shiftDelete:" : @"delete:";
    CMTimeRange firstRange; [ranges.firstObject getValue:&firstRange];
    double cutAt = CMTimeGetSeconds(firstRange.start);
    @try {
        id tl = SKTimelineModule();
        SEL selRange = NSSelectorFromString(@"_selectRange:extendRange:selectedItem:");
        SEL hasRange = NSSelectorFromString(@"timelineHasSelectedRange");
        SEL rangesSel = NSSelectorFromString(@"selectedRangesOfMedia");
        if (![tl respondsToSelector:selRange] || ![tl respondsToSelector:hasRange]) { TLog(@"range selection API missing"); return NO; }
        void (^select)(CMTimeRange, BOOL) = ^(CMTimeRange r, BOOL extend) {
            ((void(*)(id,SEL,CMTimeRange,BOOL,id))objc_msgSend)(tl, selRange, r, extend, item ?: SKClipAtTime(CMTimeGetSeconds(r.start)));
        };
        BOOL batched = NO;
        if (ranges.count > 1 && [tl respondsToSelector:rangesSel]) {
            for (NSUInteger i = 0; i < ranges.count; i++) { CMTimeRange r; [ranges[i] getValue:&r]; select(r, i > 0); }
            id selected = ((id(*)(id,SEL))objc_msgSend)(tl, rangesSel);
            NSUInteger n = [selected respondsToSelector:@selector(count)] ? [selected count] : 0;
            batched = n == ranges.count;
            TLog(@"multi-range selection: asked %lu, FCP holds %lu -> %@", (unsigned long)ranges.count, (unsigned long)n, batched ? @"one delete" : @"falling back to one delete per range");
            if (batched) SKTimelineAction(deleteSel);
            else SKTimelineAction(@"deselectAll:");
        }
        if (!batched) {
            for (NSValue *v in ranges.reverseObjectEnumerator) {   // back to front keeps earlier times valid
                CMTimeRange r; [v getValue:&r];
                select(r, NO);
                if (!((BOOL(*)(id,SEL))objc_msgSend)(tl, hasRange)) { TLog(@"could not select range at %.3f", CMTimeGetSeconds(r.start)); continue; }
                SKTimelineAction(deleteSel);
            }
        }
    } @catch (id ex) { TLog(@"delete threw %@", ex); return NO; }

    // Park the playhead on the first cut, reselect a clip so the inspector keeps this tab,
    // and give the timeline focus so Cmd-Z and Space act on it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // A cut at the very end leaves the playhead past the last clip, where there is nothing
        // to select; pick up the final clip from one frame earlier, then park on the cut.
        double end = 0, a = 0, b = 0, d = 0;
        for (id clip in SKPrimaryItems()) if (SKClipPlacement(clip, &a, &b, &d)) end = MAX(end, a + d);
        if (cutAt >= end - 1e-4 && end > 0) SKSeek(end - 1.5 * CMTimeGetSeconds(SKFrameDuration()));
        else SKSeek(cutAt);
        SKTimelineAction(@"selectClipAtPlayhead:");
        SKSeek(cutAt);
        SKTimelineAction(@"goToTimeline:");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [gModule sk_refresh]; });
    });
    return YES;
}

// Delete / Shift-Delete on the current text selection. With a speaker filter on, the selected
// items are not all neighbours on the timeline, so each run of neighbours becomes its own cut
// and whatever the other speakers said in between is left alone.
- (BOOL)sk_deleteSelectionLift:(BOOL)lift {
    NSArray<SKWord *> *hit = [self sk_selectedWords];
    if (hit.count == 0) return NO;
    // Connected words (v76): cut that part of the connected clip; the primary storyline doesn't move.
    id conn = nil; BOOL primaryToo = NO, severalConn = NO;
    for (SKWord *w in hit) {
        if (w.connectedClip) { if (conn && conn != w.connectedClip) severalConn = YES; conn = w.connectedClip; }
        else primaryToo = YES;
    }
    if (conn) {
        if (primaryToo || severalConn) { TLog(@"delete: selection mixes %@; select words from one clip", primaryToo ? @"primary and connected words" : @"connected clips"); return NO; }
        CMTime s = SKFrameTime(hit.firstObject.tlStart, -1), e = SKFrameTime(hit.lastObject.tlEnd, 1);
        if (CMTimeCompare(e, s) <= 0) return NO;
        CMTimeRange r = CMTimeRangeFromTimeToTime(s, e);
        TLog(@"delete %lu connected word(s) '%@'…'%@' %.3f–%.3f", (unsigned long)hit.count, hit.firstObject.text, hit.lastObject.text, CMTimeGetSeconds(s), CMTimeGetSeconds(e));
        return [self sk_cutRanges:@[[NSValue valueWithBytes:&r objCType:@encode(CMTimeRange)]] lift:lift onItem:conn];
    }
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSUInteger runStart = 0;
    for (NSUInteger k = 1; k <= hit.count; k++) {
        BOOL adjacent = k < hit.count && [self.allItems indexOfObject:hit[k]] == [self.allItems indexOfObject:hit[k - 1]] + 1;
        if (adjacent) continue;
        CMTimeRange r = [self sk_cutRangeFrom:hit[runStart] to:hit[k - 1]];
        if (CMTIMERANGE_IS_VALID(r)) {
            CMTimeRange prev; if (ranges.count) [ranges.lastObject getValue:&prev];
            if (ranges.count && CMTimeCompare(r.start, CMTimeRangeGetEnd(prev)) <= 0) {   // touching: merge
                r = CMTimeRangeFromTimeToTime(prev.start, CMTimeRangeGetEnd(r));
                [ranges removeLastObject];
            }
            [ranges addObject:[NSValue valueWithBytes:&r objCType:@encode(CMTimeRange)]];
        }
        runStart = k;
    }
    double total = 0;
    for (NSValue *v in ranges) { CMTimeRange r; [v getValue:&r]; total += CMTimeGetSeconds(r.duration); }
    TLog(@"delete %lu item(s) '%@'…'%@' in %lu range(s), %.3fs, lift=%d", (unsigned long)hit.count,
         [self.textView.string substringWithRange:hit.firstObject.range], [self.textView.string substringWithRange:hit.lastObject.range],
         (unsigned long)ranges.count, total, lift);
    return [self sk_cutRanges:ranges lift:lift];
}

// Bulk removal: every filler word, or every pause item currently shown.
- (BOOL)sk_deleteAllFillers:(BOOL)fillers {
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    CMTimeRange prev = kCMTimeRangeInvalid;
    double total = 0;
    for (SKWord *w in self.words) {
        if (isnan(w.tlStart) || w.connectedClip || (fillers ? !w.filler : !w.pause)) continue;   // primary storyline only
        CMTimeRange r = [self sk_cutRangeFrom:w to:w];
        if (!CMTIMERANGE_IS_VALID(r)) continue;
        if (CMTIMERANGE_IS_VALID(prev) && CMTimeCompare(r.start, CMTimeRangeGetEnd(prev)) <= 0) {   // touching: merge
            prev = CMTimeRangeFromTimeToTime(prev.start, CMTimeRangeGetEnd(r));
            [ranges removeLastObject];
        } else prev = r;
        [ranges addObject:[NSValue valueWithBytes:&prev objCType:@encode(CMTimeRange)]];
    }
    for (NSValue *v in ranges) { CMTimeRange r; [v getValue:&r]; total += CMTimeGetSeconds(r.duration); }
    TLog(@"bulk delete %@: %lu range(s), %.3fs", fillers ? @"fillers" : @"pauses", (unsigned long)ranges.count, total);
    return [self sk_cutRanges:ranges lift:NO];
}
- (void)sk_deleteFillersClicked:(id)sender { if (![self sk_deleteAllFillers:YES]) NSBeep(); }
- (void)sk_deletePausesClicked:(id)sender { if (![self sk_deleteAllFillers:NO]) NSBeep(); }
- (void)sk_thresholdChanged:(NSPopUpButton *)sender {
    gPauseThreshold = sender.selectedItem.tag / 10.0;
    [self sk_refresh];
}
@end

// While gPendingCaptionURL is set (only inside -sk_createCaptions:), NSOpenPanel reports that
// file as chosen and returns OK without showing. Added on NSOpenPanel only, so save panels
// and every other open panel behave as normal.
static IMP o_panelRunModal, o_panelURL, o_panelURLs, o_panelSheet;
static NSInteger h_panelRunModal(NSOpenPanel *self, SEL _cmd) {
    if (!gPendingCaptionURL) return ((NSInteger(*)(id,SEL))o_panelRunModal)(self, _cmd);
    id d = self.delegate;
    if ([d respondsToSelector:@selector(panelSelectionDidChange:)]) [d panelSelectionDidChange:self];   // lets FCP sniff format and language
    TLog(@"open panel answered with %@ (delegate %@)", gPendingCaptionURL.lastPathComponent, [d class]);
    return NSModalResponseOK;
}
static void h_panelSheet(NSOpenPanel *self, SEL _cmd, NSWindow *w, void (^handler)(NSModalResponse)) {
    if (!gPendingCaptionURL) { ((void(*)(id,SEL,id,id))o_panelSheet)(self, _cmd, w, handler); return; }
    NSModalResponse r = h_panelRunModal(self, @selector(runModal));
    if (handler) handler(r);
}
static id h_panelURL(NSOpenPanel *self, SEL _cmd) { return gPendingCaptionURL ?: ((id(*)(id,SEL))o_panelURL)(self, _cmd); }
static id h_panelURLs(NSOpenPanel *self, SEL _cmd) { return gPendingCaptionURL ? @[gPendingCaptionURL] : ((id(*)(id,SEL))o_panelURLs)(self, _cmd); }
static IMP SKOverride(Class cls, SEL sel, IMP imp) {
    Method m = class_getInstanceMethod(cls, sel);
    IMP original = method_getImplementation(m);
    if (!class_addMethod(cls, sel, imp, method_getTypeEncoding(m))) method_setImplementation(class_getInstanceMethod(cls, sel), imp);
    return original;
}

static IMP o_ids, o_image, o_alt, o_button;

static BOOL h_ids(id self, SEL _cmd, id items, __autoreleasing id *outIds, __autoreleasing id *outMap) {
    BOOL r = ((BOOL(*)(id,SEL,id,__autoreleasing id*,__autoreleasing id*))o_ids)(self,_cmd,items,outIds,outMap);
    @try {
        gTabModule = self;
        NSArray *snapshot = [items isKindOfClass:[NSArray class]] ? [items copy] : nil;
        if (![snapshot isEqualToArray:gItems]) {
            NSMutableArray *desc = [NSMutableArray array];
            for (id it in snapshot) [desc addObject:[NSString stringWithFormat:@"%@ %p assets=%lu", [it class], it, (unsigned long)SKAssetsForItem(it).count]];
            TLog(@"items changed: %@", [desc componentsJoinedByString:@"; "]);
            gItems = snapshot;
            [gModule sk_requestRefresh];
        }
        if (!r || !outIds || !outMap || !*outIds || !*outMap) return r;
        NSArray *ids = [*outIds isKindOfClass:[NSOrderedSet class]] ? [(NSOrderedSet *)*outIds array] : (NSArray *)*outIds;
        if ([ids containsObject:kTabIdent]) return r;
        if ([ids containsObject:@"FFInspectorTabLibraryPropertiesIdentifier"]) return r;
        // Titles and other effects with their own inspector tab (Title/Text, identifier = the
        // effect class, e.g. FFMotionEffect) lose those tabs, and Color, if a tab is added here, so
        // leave the list alone for them. A title has no transcript anyway.
        for (id k in ids) if ([k isKindOfClass:[NSString class]] && ![k hasPrefix:@"FFInspectorTab"]) {
            static NSString *lastSkip; if (![k isEqual:lastSkip]) { lastSkip = k; TLog(@"no transcript tab for %@ (keeps its own tabs)", k); }
            return r;
        }
        NSMapTable *map = *outMap;
        id sample = [map objectForKey:ids.firstObject];
        id value;
        if ([sample isKindOfClass:[NSArray class]]) value = @[@"SKInspectorModuleTranscript"];
        else if ([sample isKindOfClass:[NSString class]]) value = @"SKInspectorModuleTranscript";
        else value = [SKInspectorModuleTranscript class];
            [map setObject:value forKey:kTabIdent];
        NSArray *newIds = [ids arrayByAddingObject:kTabIdent];
        *outIds = [*outIds isKindOfClass:[NSOrderedSet class]] ? (id)[NSOrderedSet orderedSetWithArray:newIds] : (id)newIds;
    } @catch (id e) { TLog(@"h_ids threw %@", e); }
    return r;
}
// FCP's own tab icons are 18×18 pt template images whose glyphs nearly fill the canvas (the Info
// circle is 18 pt across, the Video glyph about 18×14.6). SF Symbols carry their own padding, so
// render the symbol, crop to its visible pixels, and fit that into a kSKTabGlyphW × kSKTabGlyphH
// box on an 18×18 canvas, nudged kSKTabNudgeX right — measured on screen against Apple's icons
// (glyph ~15 px wide, 9 px gaps and ~24 px centre spacing like Video/Color/Audio/Info).
static const CGFloat kSKTabCanvas = 18, kSKTabGlyphW = 15, kSKTabGlyphH = 13, kSKTabNudgeX = 0.5;
static NSImage *SKTabImage(void) {
    static NSImage *cached;
    if (cached) return cached;
    NSImage *symbol = [[NSImage imageWithSystemSymbolName:@"text.quote" accessibilityDescription:@"Transcript"]
        imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithPointSize:48 weight:NSFontWeightRegular]];
    NSRect full = NSMakeRect(0, 0, symbol.size.width, symbol.size.height);
    CGImageRef cg = [symbol CGImageForProposedRect:&full context:nil hints:nil];
    NSBitmapImageRep *rep = cg ? [[NSBitmapImageRep alloc] initWithCGImage:cg] : nil;
    CGImageRef cropped = NULL;
    if (rep) {   // tight bounds of non-transparent pixels
        NSInteger w = rep.pixelsWide, h = rep.pixelsHigh, minX = w, minY = h, maxX = -1, maxY = -1;
        for (NSInteger y = 0; y < h; y++) for (NSInteger x = 0; x < w; x++) {
            if ([rep colorAtX:x y:y].alphaComponent < 0.1) continue;
            minX = MIN(minX, x); maxX = MAX(maxX, x); minY = MIN(minY, y); maxY = MAX(maxY, y);
        }
        if (maxX >= minX) cropped = CGImageCreateWithImageInRect(cg, CGRectMake(minX, minY, maxX - minX + 1, maxY - minY + 1));
    }
    NSImage *glyph = cropped ? [[NSImage alloc] initWithCGImage:cropped size:NSZeroSize] : symbol;
    if (cropped) CGImageRelease(cropped);
    NSSize sz = glyph.size;
    CGFloat scale = MIN(kSKTabGlyphW / MAX(sz.width, 1), kSKTabGlyphH / MAX(sz.height, 1));
    NSSize fit = NSMakeSize(sz.width * scale, sz.height * scale);
    cached = [NSImage imageWithSize:NSMakeSize(kSKTabCanvas, kSKTabCanvas) flipped:NO drawingHandler:^BOOL(NSRect r) {
        [glyph drawInRect:NSMakeRect((r.size.width - fit.width) / 2 + kSKTabNudgeX, (r.size.height - fit.height) / 2, fit.width, fit.height)];
        return YES;
    }];
    cached.template = YES;
    cached.accessibilityDescription = @"Transcript";
    return cached;
}
static id h_image(id self, SEL _cmd, id tab) {
    if ([tab isKindOfClass:[NSString class]] && [tab isEqualToString:kTabIdent]) return SKTabImage();
    return ((id(*)(id,SEL,id))o_image)(self,_cmd,tab);
}
// Average colour of the opaque pixels of an image (used to read FCP's selected-tab purple).
static NSColor *SKImageInkColor(NSImage *img) {
    NSRect r = NSMakeRect(0, 0, img.size.width, img.size.height);
    CGImageRef cg = [img CGImageForProposedRect:&r context:nil hints:nil];
    NSBitmapImageRep *rep = cg ? [[NSBitmapImageRep alloc] initWithCGImage:cg] : nil;
    double R = 0, G = 0, B = 0, n = 0;
    for (NSInteger y = 0; y < rep.pixelsHigh; y++) for (NSInteger x = 0; x < rep.pixelsWide; x++) {
        NSColor *c = [[rep colorAtX:x y:y] colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
        if (c.alphaComponent < 0.6) continue;
        R += c.redComponent; G += c.greenComponent; B += c.blueComponent; n++;
    }
    return n > 0 ? [NSColor colorWithSRGBRed:R / n green:G / n blue:B / n alpha:1] : nil;
}

// Selected state: FCP's own selected tab icons are tinted (purple); match the Info tab's tint.
static id h_alt(id self, SEL _cmd, id tab) {
    if (!([tab isKindOfClass:[NSString class]] && [tab isEqualToString:kTabIdent])) return ((id(*)(id,SEL,id))o_alt)(self,_cmd,tab);
    static NSImage *tinted; static NSColor *tint;
    NSImage *ref = ((id(*)(id,SEL,id))o_alt)(self,_cmd,@"FFInspectorTabInfoIdentifier");
    NSColor *c = (ref ? SKImageInkColor(ref) : nil) ?: [NSColor controlAccentColor];
    if (!tinted || ![c isEqual:tint]) {
        tint = c;
        NSImage *glyph = SKTabImage();
        tinted = [NSImage imageWithSize:glyph.size flipped:NO drawingHandler:^BOOL(NSRect r) {
            [glyph drawInRect:r];
            [c set];
            NSRectFillUsingOperation(r, NSCompositingOperationSourceAtop);
            return YES;
        }];
        tinted.template = NO;
        TLog(@"selected tab tint %@", c);
    }
    return tinted;
}
static id h_button(id self, SEL _cmd, id title, long tag) {
    return ((id(*)(id,SEL,id,long))o_button)(self,_cmd,title ?: @"Transcript",tag);
}
static IMP hook(Class c, NSString *sel, IMP n) {
    Method m = class_getInstanceMethod(c, NSSelectorFromString(sel));
    if (!m) { TLog(@"missing %@", sel); return NULL; }
    return method_setImplementation(m, n);
}
// Workaround for a SpliceKit 3.3.9 bug: after FCP is switched away from and back to (Cmd-Tab),
// the inspector loses its items and shows "Nothing to Inspect" on every tab, ours and FCP's.
// Remember what the inspector held when FCP went to the background; if it comes back empty,
// hand those same items back to the inspector.
static NSArray *gItemsAtResign;
static __weak NSResponder *gResponderAtResign;
static __weak NSWindow *gWindowAtResign;
// v53: the real cause (found with v52's caller log). When FCP goes to the background, SpliceKit's
// dual-timeline code (SpliceKit_dualTimelineSetFocusedContainer) calls
// -[PEEditorContainerModule _makeEditorActive:], which hands the editor's (empty) selection to
// PESelectionManager. The inspector container then swaps its inspector out, giving "Nothing to
// Inspect". While FCP is inactive the user can't have changed the active editor, so skip that call.
// (v52 refused the inspector's empty setCurrentItems: instead; that left the swapped-out
// inspector half torn down and permanently blank.)
static BOOL gInactive;
static IMP o_makeEditorActive;
static int gSkipLogged;
// Only SpliceKit's call is skipped: FCP itself calls _makeEditorActive: from viewDidLoad at launch,
// possibly while still in the background (v53 skipped that one too).
static BOOL SKCallerIsSpliceKit(void *ret) {
    Dl_info info;
    if (!dladdr(ret, &info) || !info.dli_fname) return NO;
    const char *base = strrchr(info.dli_fname, '/');
    return strcmp(base ? base + 1 : info.dli_fname, "SpliceKit") == 0;
}
static void h_makeEditorActive(id self, SEL _cmd, id editor) {
    if (gInactive && SKCallerIsSpliceKit(__builtin_return_address(0))) {
        TLog(@"skipped SpliceKit's _makeEditorActive: while FCP inactive");
        if (gSkipLogged++ < 1) TLog(@"caller:\n%@", [[NSThread callStackSymbols] componentsJoinedByString:@"\n"]);
        return;
    }
    ((void(*)(id,SEL,id))o_makeEditorActive)(self, _cmd, editor);
}
static void SKInstallInspectorRestore(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    Class ec = objc_getClass("PEEditorContainerModule");
    SEL mea = NSSelectorFromString(@"_makeEditorActive:");
    // `defaults write com.apple.FinalCut SKTranscriptTabNoEditorGuard -bool YES` turns this off
    // (for testing a SpliceKit build that fixes the cause upstream).
    if ([[NSUserDefaults standardUserDefaults] boolForKey:@"SKTranscriptTabNoEditorGuard"]) TLog(@"editor guard off (SKTranscriptTabNoEditorGuard)");
    else if (ec && class_getInstanceMethod(ec, mea)) o_makeEditorActive = SKOverride(ec, mea, (IMP)h_makeEditorActive);
    else TLog(@"no -[PEEditorContainerModule _makeEditorActive:]");
    [nc addObserverForName:NSApplicationWillResignActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        id tm = gTabModule;
        NSArray *cur = [tm respondsToSelector:@selector(currentItems)] ? [[tm valueForKey:@"currentItems"] copy] : nil;
        gItemsAtResign = [cur isKindOfClass:[NSArray class]] && cur.count ? cur : nil;
        gWindowAtResign = NSApp.mainWindow ?: NSApp.keyWindow;
        gResponderAtResign = gWindowAtResign.firstResponder;
        gInactive = YES;
        TLog(@"app resign: inspector held %lu item(s), focus %@", (unsigned long)gItemsAtResign.count, [gResponderAtResign class]);
    }];
    [nc addObserverForName:NSApplicationDidBecomeActiveNotification object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        gInactive = NO;
        NSArray *saved = gItemsAtResign;
        if (!saved) return;
        // Give FCP a moment to finish its own reactivation work, then check.
        for (NSNumber *delay in @[@0.3, @1.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                id tm = gTabModule;
                if (!tm || ![tm respondsToSelector:@selector(setCurrentItems:)]) return;
                NSArray *cur = [tm valueForKey:@"currentItems"];
                if ([cur isKindOfClass:[NSArray class]] && cur.count) return;   // inspector is fine
                // The inspector follows the focused panel; SpliceKit leaves focus elsewhere on return.
                NSWindow *w = gWindowAtResign; NSResponder *r = gResponderAtResign;
                TLog(@"app active: inspector empty after %.1fs; focus now %@, restoring focus to %@", delay.doubleValue, [w.firstResponder class], [r class]);
                // 1. Bounce focus off and back on, so FCP re-reads the focused panel's selection.
                if (w && r) { [w makeFirstResponder:nil]; [w makeFirstResponder:r]; }
                // 2. Still empty and the browser has focus: re-select its own selection so it
                //    sends a fresh selection change (clear, then the same ranges again).
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    NSArray *now = [tm valueForKey:@"currentItems"];
                    if ([now isKindOfClass:[NSArray class]] && now.count) { TLog(@"inspector restored by refocus"); return; }
                    id fs = SKFilmstripModule();
                    NSArray *sel = SKBrowserSelection(fs);
                    SEL selSel = NSSelectorFromString(@"_selectMediaRanges:");
                    if (sel.count && [fs respondsToSelector:selSel] && [NSStringFromClass([w.firstResponder class]) hasPrefix:@"FFOrganizer"]) {
                        NSArray *keep = [sel copy];
                        ((void(*)(id,SEL,id))objc_msgSend)(fs, selSel, @[]);
                        ((void(*)(id,SEL,id))objc_msgSend)(fs, selSel, keep);
                        NSArray *after = [tm valueForKey:@"currentItems"];
                        TLog(@"reselected browser selection; inspector now %lu item(s)", (unsigned long)([after isKindOfClass:[NSArray class]] ? after.count : 0));
                    } else TLog(@"inspector still empty (focus %@)", [w.firstResponder class]);
                });
            });
        }
    }];
}

// SpliceKit's plugin loader (~/Library/Application Support/SpliceKit/plugins/<id>/plugin.json,
// "entry": {"native": "TranscriptTab.dylib"}) requires this symbol and unloads the dylib if it is
// missing, which would leave the hooks below pointing at unmapped code. All setup happens in the
// constructor, which runs when the dylib is opened, so there is nothing more to do here.
// SKTranscriptTestBrowse is installed at load (not with the module) so it can select the first
// clip even before the transcript tab exists.
static void SKInstallBrowseHook(void) {
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    // SKTranscriptTestTranscribe: click the Transcribe / Try again button.
    // SKTranscriptTestTab: "list" logs the inspector's tabs; "N" selects tab N (read-only; for benchmarking).
    [nc addObserverForName:@"SKTranscriptTestTab" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        @try {
            NSTabView *tv = [gTabModule valueForKey:@"_tabView"];
            NSString *cmd = [n.object description];
            if ([cmd isEqualToString:@"list"]) {
                for (NSUInteger i = 0; i < tv.tabViewItems.count; i++) { NSTabViewItem *it = tv.tabViewItems[i]; TLog(@"tab %lu: %@ id=%@%@", (unsigned long)i, it.label, [it.identifier class], it == tv.selectedTabViewItem ? @" (selected)" : @""); }
            } else {
                for (NSTabViewItem *it in tv.tabViewItems)   // by label ("Info"), or "transcript" for ours
                    if ([cmd isEqualToString:@"transcript"] ? (it.identifier == gModule) : [it.label isEqualToString:cmd]) { ((void(*)(id,SEL,NSUInteger))objc_msgSend)(gTabModule, NSSelectorFromString(@"selectInspectorTab:"), [tv.tabViewItems indexOfObject:it]); return; }
                TLog(@"test tab: no tab '%@'", cmd);
            }
        } @catch (id e) { TLog(@"test tab threw %@", e); }
    }];
    [nc addObserverForName:@"SKTranscriptTestTranscribe" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        TLog(@"test transcribe: button %@", gModule.transcribeButton.hidden ? @"hidden" : @"clicked");
        if (!gModule.transcribeButton.hidden) [gModule.transcribeButton performClick:nil];
    }];
    [nc addObserverForName:@"SKTranscriptTestBrowse" object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
        NSString *(^norm)(NSString *) = ^(NSString *x) {
            return [[[x lowercaseString] componentsSeparatedByCharactersInSet:[[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@""];
        };
        NSString *want = norm([n.object description]);
        NSUInteger total = 0;
        id libs = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFLibraryDocument"), NSSelectorFromString(@"copyActiveLibraries"));
        for (id lib in libs) for (id ev in [lib valueForKey:@"events"]) {
            id proj = [ev respondsToSelector:@selector(project)] ? [ev valueForKey:@"project"] : nil;
            id clips = [proj respondsToSelector:NSSelectorFromString(@"ownedClips")] ? [proj valueForKey:@"ownedClips"] : nil;
            TLog(@"browse: %@ / %@: %lu clip(s)", [lib valueForKey:@"displayName"], [proj valueForKey:@"displayName"], (unsigned long)[clips count]);
            for (id clip in clips) {
                total++;
                NSString *name = [clip respondsToSelector:NSSelectorFromString(@"displayName")] ? [clip valueForKey:@"displayName"] : nil;
                if (!name || ![norm(name) isEqualToString:want]) continue;
                CMTimeRange r = kCMTimeRangeZero; SKInvokeRange(clip, @"clippedRange", nil, &r);
                NSMutableArray *info = [NSMutableArray array];
                id retriever = ((id(*)(id,SEL))objc_msgSend)(objc_getClass("FFTranscriptRetriever"), NSSelectorFromString(@"sharedInstance"));
                for (id a in SKAssetsForItem(clip))
                    [info addObject:[NSString stringWithFormat:@"%@ stored=%d", SKMediaPath(a).lastPathComponent,
                        ((BOOL(*)(id,SEL,id))objc_msgSend)(retriever, NSSelectorFromString(@"hasTranscriptForAsset:"), a)]];
                TLog(@"browse '%@' in %@ / %@: %@ range %.3f–%.3f (%@ – %@) assets %@", name, [lib valueForKey:@"displayName"], [proj valueForKey:@"displayName"],
                     [clip class], CMTimeGetSeconds(r.start), CMTimeGetSeconds(CMTimeRangeGetEnd(r)), SKTimecodeDF(CMTimeGetSeconds(r.start)), SKTimecodeDF(CMTimeGetSeconds(CMTimeRangeGetEnd(r))), info);
                id ranged = ((id(*)(id,SEL,CMTimeRange,id))objc_msgSend)(objc_getClass("FigTimeRangeAndObject"), NSSelectorFromString(@"rangeAndObjectWithRange:andObject:"), r, clip);
                id fs = SKFilmstripModule();
                ((void(*)(id,SEL,id))objc_msgSend)(fs, NSSelectorFromString(@"_revealAndSelectMediaRanges:"), @[ranged]);
                TLog(@"browse: browser selection now %@", [SKBrowserSelection(fs) description]);
                SKTimelineAction(@"goToOrganizer:");
                return;
            }
        }
        TLog(@"browse: no clip named '%@' among %lu clip(s)", want, (unsigned long)total);
    }];
}

static void SKRefreshModule(void) { [gModule sk_refresh]; }

__attribute__((visibility("default"))) void SpliceKitPlugin_init(void *api) {
    (void)api;
    TLog(@"loaded as SpliceKit plugin");
}

__attribute__((constructor)) static void tab_init(void) {
    Class c = objc_getClass("FFInspectorTabModule");
    if (!c) { TLog(@"no FFInspectorTabModule"); return; }
    o_ids = hook(c, @"_identifiersAndClassesForItems:outTabIdentifiers:outClassesMap:", (IMP)h_ids);
    o_image = hook(c, @"imageForInspectorTab:", (IMP)h_image);
    o_alt = hook(c, @"altImageForInspectorTab:", (IMP)h_alt);
    o_button = hook(c, @"newTabSelectorButtonWithTitle:tag:", (IMP)h_button);
    Class op = [NSOpenPanel class];
    o_panelRunModal = SKOverride(op, @selector(runModal), (IMP)h_panelRunModal);
    o_panelSheet = SKOverride(op, @selector(beginSheetModalForWindow:completionHandler:), (IMP)h_panelSheet);
    o_panelURL = SKOverride(op, @selector(URL), (IMP)h_panelURL);
    o_panelURLs = SKOverride(op, @selector(URLs), (IMP)h_panelURLs);
    SKInstallInspectorRestore();
    SKInstallBrowseHook();
    TLog(@"Transcript Tab 1.1.1 loaded");
}
