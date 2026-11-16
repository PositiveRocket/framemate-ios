// FrameMate notification tweak.
//
// Injected into SpringBoard. Every notification passes through -[BBServer publishBulletin:
// destinations:]; we let it publish as normal (%orig), copy the few strings we need, and do
// everything else on our own serial queue: check the user's settings and, if the app is enabled,
// send a toast to the paired Frame (`POST /api/notify`) over TLS pinned to the Frame's key.
//
// This is the iOS counterpart of FrameNotificationListener.kt. It is deliberately plain
// Objective-C with system frameworks only. An earlier version linked the app's Rust core here, but
// SpringBoard is an arm64e process and Rust's arm64e output does not sign pointers the way the
// platform expects (thread-locals, callbacks), which crashed SpringBoard into safe mode on the
// first send. So the pin check, the request and the settings file are re-implemented natively:
//
//   <container>/Documents/FrameMate/pairing.json        {host, ip, port, token, pin}   (read)
//   <container>/Documents/FrameMate/notifications.json  {enabled, disabled_apps, seen,
//                                                         last_result, last_time, paused_since,
//                                                         pause_next_check, pause_step}  (read/write)
//
// Both files are shared with the app (framemate-core's `pairing` and `prefs` modules); the formats
// here must stay in step with them. Nothing else is persisted, and no notification content is
// logged (the log lines stay in memory, see FMLog).

#import "Tweak.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <os/log.h>
#import <Network/Network.h>

// What the tweak decided, in the system log (category "FrameMate"): read it live with
// `idevicesyslog -m "FrameMate: "`. Only the step and the outcome are logged, never any
// notification content; app identifiers are marked private, so iOS redacts them by default.
// Nothing is written to disk: iOS keeps "info" and "debug" messages in memory only (unlike the
// default level). FMLog is for the per-notification steps, FMNote for changes of state.
static os_log_t fmLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ log = os_log_create("dev.framemate.tweak", "FrameMate"); });
    return log;
}
#define FMLog(fmt, ...) os_log_debug(fmLog(), "FrameMate: " fmt, ##__VA_ARGS__)
#define FMNote(fmt, ...) os_log_info(fmLog(), "FrameMate: " fmt, ##__VA_ARGS__)

// The FrameMate app itself, never forwarded (its own "test"/status toasts would loop).
static NSString *const kSelfBundleID = @"dev.framemate.app";
// A respring replays the notifications already on the lock screen, dated hours back. Anything
// dated older than this when it arrives is such a replay. Generous on purpose: some apps date a
// notification by when its message was sent, so a real one can arrive a little late.
static const NSTimeInterval kReplayAge = 120.0;
// Like the Android listener (FrameNotificationListener.kt): a notification that waited longer than
// this for its turn is dropped (a toast about something from minutes ago would only confuse), and
// at most kMaxQueued wait at once, the oldest giving way.
static const NSTimeInterval kMaxWait = 30.0;
static const NSUInteger kMaxQueued = 10;
// The app icon, downscaled to this before it is PNG-encoded. The agent accepts up to 64 KB.
static const CGFloat kIconPx = 96.0;
// Per address. A sleeping Frame never answers, so this is what a notification costs then.
static const NSTimeInterval kRequestTimeout = 5.0;
// The quick reachability check made while paused (see "Pausing" below), per address.
static const NSTimeInterval kProbeTimeout = 1.5;

#pragma mark - Shared files

// The app's shared config directory: Documents/FrameMate in the app's home. It lives inside the
// app's data container, which is created when the app is installed, so it can't be hard-coded.
// Matches `config_dir` in src-tauri/src/lib.rs.
//
// The container LaunchServices reports for the app isn't always the one the app runs in: after
// installing the app through installd, the app kept its pairing in a container that was neither
// the reported one nor labelled with its bundle id. So rather than trust either, every app data
// container is checked for Documents/FrameMate/pairing.json (plus /var/mobile, the home of an app
// running without a container), and the newest pairing wins. That's a hundred or so lookups,
// done only when the remembered directory has lost its pairing.

static NSString *const kConfigDirName = @"FrameMate";
static NSString *const kContainersRoot = @"/var/mobile/Containers/Data/Application";

static NSString *configDirIn(NSString *home) {
    return [[home stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:kConfigDirName];
}

static NSString *pairingPath(NSString *dir) {
    return [dir stringByAppendingPathComponent:@"pairing.json"];
}

static NSArray<NSString *> *candidateConfigDirs(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray new];
    for (NSString *uuid in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kContainersRoot error:nil]) {
        [dirs addObject:configDirIn([kContainersRoot stringByAppendingPathComponent:uuid])];
    }
    [dirs addObject:configDirIn(@"/var/mobile")];
    return dirs;
}

// The label MobileContainerManager put on a data container (normally the app's bundle id), for
// the log.
static NSString *containerLabel(NSString *dir) {
    NSString *home = [[dir stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
        [home stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
    id label = meta[@"MCMMetadataIdentifier"];
    return [label isKindOfClass:[NSString class]] ? label : @"(no label)";
}

static NSString *configDir(void) {
    static NSString *cached = nil;
    // When nothing was found (not paired yet), don't search again on every notification.
    static CFAbsoluteTime lastFruitlessSearch = 0;
    static const CFTimeInterval kSearchAgainAfter = 30;
    NSFileManager *files = [NSFileManager defaultManager];
    if (cached && [files fileExistsAtPath:pairingPath(cached)]) return cached;
    if (!cached && CFAbsoluteTimeGetCurrent() - lastFruitlessSearch < kSearchAgainAfter) return nil;

    NSArray<NSString *> *dirs = candidateConfigDirs();
    NSString *best = nil;
    NSDate *bestDate = nil;
    for (NSString *dir in dirs) {
        NSDate *date = [files attributesOfItemAtPath:pairingPath(dir) error:nil].fileModificationDate;
        if (date && (!bestDate || [date compare:bestDate] == NSOrderedDescending)) {
            best = dir;
            bestDate = date;
        }
    }
    if (best) {
        if (![best isEqualToString:cached]) {
            FMNote("using the pairing in %{public}@ (container labelled %{public}@)", best, containerLabel(best));
        }
        cached = best;
        return best;
    }
    FMNote("no pairing found in any of %lu app containers (or /var/mobile); looking again in %.0f s",
          (unsigned long)dirs.count - 1, kSearchAgainAfter);
    cached = nil;
    lastFruitlessSearch = CFAbsoluteTimeGetCurrent();
    return nil;
}

static NSString *prefsPath(NSString *dir) {
    return [dir stringByAppendingPathComponent:@"notifications.json"];
}

static NSDictionary *readPairing(NSString *dir) {
    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"pairing.json"]];
    if (!data) return nil;
    id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

// Absent or unreadable means the defaults: everything off, nothing seen.
static NSMutableDictionary *loadPrefs(NSString *dir) {
    NSData *data = [NSData dataWithContentsOfFile:prefsPath(dir)];
    id obj = data ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil] : nil;
    return [obj isKindOfClass:[NSMutableDictionary class]] ? obj : [NSMutableDictionary new];
}

// Reload, mutate, save atomically. The app writes the same file; a lost update between the two
// would at worst drop one "app seen" or one "last result", never corrupt the file.
static void updatePrefs(NSString *dir, void (^mutate)(NSMutableDictionary *prefs)) {
    NSMutableDictionary *prefs = loadPrefs(dir);
    mutate(prefs);
    NSData *data = [NSJSONSerialization dataWithJSONObject:prefs options:0 error:nil];
    // Readable while the phone is locked: notifications arrive then too.
    [data writeToFile:prefsPath(dir)
              options:NSDataWritingAtomic | NSDataWritingFileProtectionCompleteUntilFirstUserAuthentication
                error:nil];
}

static NSString *stringOrNil(id value) {
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}

#pragma mark - Pinned TLS

// One DER element at *pos: its tag and content range; advances *pos past it.
static BOOL derNext(const uint8_t *p, size_t len, size_t *pos, uint8_t *tag, size_t *start, size_t *contentLen) {
    size_t i = *pos;
    if (len < 2 || i > len - 2) return NO;
    *tag = p[i++];
    size_t l = p[i++];
    if (l & 0x80) {
        size_t n = l & 0x7f;
        if (n == 0 || n > 4 || n > len - i) return NO;
        l = 0;
        while (n--) l = (l << 8) | p[i++];
    }
    if (l > len - i) return NO;
    *start = i;
    *contentLen = l;
    *pos = i + l;
    return YES;
}

// The SubjectPublicKeyInfo of an X.509 certificate, header included — what the agent hashes.
//   Certificate ::= SEQUENCE { tbsCertificate SEQUENCE { [0] version OPTIONAL, serialNumber,
//                   signature, issuer, validity, subject, subjectPublicKeyInfo, ... }, ... }
static NSData *spkiOfCertificate(NSData *der) {
    const uint8_t *p = (const uint8_t *)der.bytes;
    size_t len = der.length, pos = 0, start, clen;
    uint8_t tag;
    if (!derNext(p, len, &pos, &tag, &start, &clen) || tag != 0x30) return nil; // Certificate
    size_t end = start + clen;
    pos = start;
    if (!derNext(p, end, &pos, &tag, &start, &clen) || tag != 0x30) return nil; // tbsCertificate
    end = start + clen;
    pos = start;
    size_t probe = pos;
    if (!derNext(p, end, &probe, &tag, &start, &clen)) return nil;
    if (tag == 0xA0) pos = probe;                                               // explicit version
    for (int skipped = 0; skipped < 5; skipped++) {                             // serial … subject
        if (!derNext(p, end, &pos, &tag, &start, &clen)) return nil;
    }
    size_t spkiStart = pos;
    if (!derNext(p, end, &pos, &tag, &start, &clen) || tag != 0x30) return nil;
    return [der subdataWithRange:NSMakeRange(spkiStart, pos - spkiStart)];
}

// Must match `pin_of` in framemate-core's proxy.rs and `Identity::pin` in the agent:
// the first 128 bits of SHA-256(SPKI), in Crockford base32.
static NSString *pinOfSPKI(NSData *spki) {
    static const char alphabet[] = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(spki.bytes, (CC_LONG)spki.length, digest);
    NSMutableString *out = [NSMutableString stringWithCapacity:26];
    uint32_t acc = 0, bits = 0;
    for (int i = 0; i < 16; i++) {
        acc = (acc << 8) | digest[i];
        bits += 8;
        while (bits >= 5) {
            bits -= 5;
            [out appendFormat:@"%c", alphabet[(acc >> bits) & 31]];
        }
    }
    if (bits > 0) [out appendFormat:@"%c", alphabet[(acc << (5 - bits)) & 31]];
    return out;
}

// Trusts exactly one server: the one whose public key hashes to the pin from the pairing code.
// The certificate's name, issuer and validity are ignored, as in the app (the agent's certificate
// is self-signed and rebuilt at every start; only its key is stable).
@interface FMPinnedDelegate : NSObject <NSURLSessionDelegate>
@property (nonatomic, copy) NSString *pin;
@property (atomic, assign) BOOL mismatch;
@end

@implementation FMPinnedDelegate
- (void)URLSession:(NSURLSession *)session
    didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
      completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))completionHandler {
    if (![challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    NSData *der = nil;
    if (trust) {
        if (@available(iOS 15.0, *)) {
            NSArray *chain = CFBridgingRelease(SecTrustCopyCertificateChain(trust));
            if (chain.count) der = CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)chain[0]));
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            SecCertificateRef leaf = SecTrustGetCertificateCount(trust) > 0 ? SecTrustGetCertificateAtIndex(trust, 0) : NULL;
#pragma clang diagnostic pop
            if (leaf) der = CFBridgingRelease(SecCertificateCopyData(leaf));
        }
    }
    NSData *spki = der ? spkiOfCertificate(der) : nil;
    if (spki && self.pin.length && [pinOfSPKI(spki) isEqualToString:self.pin]) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:trust]);
    } else {
        self.mismatch = YES;
        completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    }
}
@end

#pragma mark - Sending

// One request to one address: a POST of `body` to /api/notify, or (no body) a GET of /healthz, the
// agent's unauthenticated liveness route. Blocks (we are on our own queue). Returns the HTTP
// status, or 0 with *failure set.
static NSInteger requestOnce(NSString *host, NSNumber *port, NSString *token, NSString *pin, NSData *body,
                             NSTimeInterval timeout, NSData **responseBody, NSString **failure, BOOL *rejected) {
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = host;
    components.port = port;
    components.path = body ? @"/api/notify" : @"/healthz";
    NSURL *url = components.URL;
    if (!url) {
        *failure = [NSString stringWithFormat:@"%@: not a usable address", host];
        return 0;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:timeout];
    if (body) {
        request.HTTPMethod = @"POST";
        request.HTTPBody = body;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
    }

    FMPinnedDelegate *delegate = [FMPinnedDelegate new];
    delegate.pin = pin;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = timeout;
    config.timeoutIntervalForResource = timeout * 2;
    config.waitsForConnectivity = NO;
    config.HTTPCookieStorage = nil;
    config.URLCache = nil;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:config delegate:delegate delegateQueue:nil];

    __block NSInteger status = 0;
    __block NSData *received = nil;
    __block NSError *error = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[session dataTaskWithRequest:request
                completionHandler:^(NSData *data, NSURLResponse *response, NSError *err) {
        if ([response isKindOfClass:[NSHTTPURLResponse class]]) status = ((NSHTTPURLResponse *)response).statusCode;
        received = data;
        error = err;
        dispatch_semaphore_signal(done);
    }] resume];
    // The session enforces the timeouts above; the extra margin only guards against a stuck task.
    long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout * 2 + 2) * NSEC_PER_SEC)));
    [session invalidateAndCancel]; // also breaks the session → delegate retain cycle

    if (timedOut) {
        *failure = [NSString stringWithFormat:@"%@: no answer", host];
        return 0;
    }
    if (delegate.mismatch) {
        *rejected = YES;
        *failure = [NSString stringWithFormat:@"%@: its key doesn't match the pairing code", host];
        return 0;
    }
    if (error || status == 0) {
        *failure = [NSString stringWithFormat:@"%@: %@", host, error.localizedDescription ?: @"no response"];
        return 0;
    }
    if (responseBody) *responseBody = received;
    return status;
}

// The Frame's addresses from the pairing: its mDNS name, then its IP.
static NSArray<NSString *> *pairingAddresses(NSDictionary *pairing) {
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    if (stringOrNil(pairing[@"host"])) [candidates addObject:pairing[@"host"]];
    if (stringOrNil(pairing[@"ip"])) [candidates addObject:pairing[@"ip"]];
    return candidates;
}

static NSUInteger preferredAddress = 0; // the address that worked last; only touched on the work queue

// Tries the mDNS name and the address, starting with whichever worked last. Returns the status
// word the settings page shows: `shown`, `headset_asleep`, `rate_limited`, or `error: …`.
// *unreachable is set when no address answered at all (as opposed to an answer that was an error).
static NSString *sendToast(NSDictionary *pairing, NSData *body, BOOL *unreachable) {
    *unreachable = NO;
    NSString *token = stringOrNil(pairing[@"token"]);
    NSString *pin = stringOrNil(pairing[@"pin"]);
    NSNumber *port = [pairing[@"port"] isKindOfClass:[NSNumber class]] ? pairing[@"port"] : nil;
    NSArray<NSString *> *candidates = pairingAddresses(pairing);
    if (!token || !pin || !port || candidates.count == 0) return @"error: the saved pairing is incomplete, pair again";

    NSString *failure = @"";
    for (NSUInteger offset = 0; offset < candidates.count; offset++) {
        NSUInteger index = (preferredAddress + offset) % candidates.count;
        NSData *responseBody = nil;
        BOOL rejected = NO;
        NSInteger status = requestOnce(candidates[index], port, token, pin, body, kRequestTimeout, &responseBody, &failure, &rejected);
        // Something answered and it isn't ours: don't fall through to the next address, which
        // would turn a pin mismatch into a vague timeout.
        if (rejected) return [NSString stringWithFormat:@"error: this isn't the Frame the app was paired with, pair again (%@)", failure];
        if (status == 0) continue;
        preferredAddress = index;
        switch (status) {
            case 200: {
                id obj = responseBody ? [NSJSONSerialization JSONObjectWithData:responseBody options:0 error:nil] : nil;
                NSString *result = [obj isKindOfClass:[NSDictionary class]] ? stringOrNil(obj[@"result"]) : nil;
                return result ?: @"error: unexpected answer from the Frame";
            }
            case 401: return @"error: the Frame rejected the token, pair again";
            case 429: return @"rate_limited";
            // Agents before v0.3.0 have no /api/notify.
            case 404: return @"error: the FrameMate agent on the Frame is too old for notifications, update it";
            default: {
                NSString *text = responseBody ? [[NSString alloc] initWithData:responseBody encoding:NSUTF8StringEncoding] : nil;
                return [NSString stringWithFormat:@"error: %ld %@", (long)status, text ?: @""];
            }
        }
    }
    *unreachable = YES;
    return [NSString stringWithFormat:@"error: can't reach the Frame (%@)", failure];
}

// The quick check made while paused: does anything answer at the Frame's address within
// kProbeTimeout? (A wrong key still counts as an answer; the real send then reports it.)
static BOOL frameAnswers(NSDictionary *pairing) {
    NSString *pin = stringOrNil(pairing[@"pin"]);
    NSNumber *port = [pairing[@"port"] isKindOfClass:[NSNumber class]] ? pairing[@"port"] : nil;
    NSArray<NSString *> *candidates = pairingAddresses(pairing);
    if (!pin || !port) return NO;
    for (NSUInteger offset = 0; offset < candidates.count; offset++) {
        NSUInteger index = (preferredAddress + offset) % candidates.count;
        NSString *failure = nil;
        BOOL rejected = NO;
        if (requestOnce(candidates[index], port, nil, pin, nil, kProbeTimeout, NULL, &failure, &rejected) > 0 || rejected) {
            preferredAddress = index;
            return YES;
        }
    }
    return NO;
}

#pragma mark - Pausing
//
// When the Frame can't be reached (asleep, off, or on another network), every send would wait
// kRequestTimeout per address, one notification after another. So the first unreachable send
// pauses forwarding: notifications are skipped without touching the network, and a quick check
// (frameAnswers) is made at most every 1, then 2, then 5 minutes, on the next notification after
// that. The pause ends when the check succeeds, when the phone joins a Wi-Fi network (watchWiFi),
// or when the app clears it (on opening, and on "Send a test notification").
//
// It is kept in the shared settings file, so the app can show it and clear it:
//   paused_since      ms since 1970 when the Frame stopped answering (absent: not paused)
//   pause_next_check  ms since 1970 before which no check is made
//   pause_step        how many checks have failed (picks the next interval)
// These names are shared with framemate-core's prefs.rs.

static uint64_t nowMs(void) {
    return (uint64_t)([[NSDate date] timeIntervalSince1970] * 1000.0);
}

static NSTimeInterval pauseInterval(NSInteger failedChecks) {
    static const NSTimeInterval steps[] = {60, 120, 300};
    return steps[MIN(MAX(failedChecks, 0), 2)];
}

static BOOL isPaused(NSDictionary *prefs) {
    return [prefs[@"paused_since"] isKindOfClass:[NSNumber class]];
}

static void clearPause(NSMutableDictionary *prefs) {
    [prefs removeObjectsForKeys:@[@"paused_since", @"pause_next_check", @"pause_step"]];
}

#pragma mark - Per notification

// Everything after the hook runs here, one notification at a time, off SpringBoard's own threads:
// file access, the icon, and a send that blocks for seconds while the Frame is unreachable.
static dispatch_queue_t workQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("dev.framemate.notify", dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    });
    return q;
}

// The waiting notifications, oldest first, at most kMaxQueued: when the Frame is slow to answer and
// more arrive, the oldest give way (Android: ThreadPoolExecutor.DiscardOldestPolicy). Each enqueue
// schedules one run on workQueue, which takes the oldest waiting job; runs that find the list
// empty (their job gave way) do nothing.
static NSMutableArray *pendingJobs(void) {
    static NSMutableArray *jobs;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ jobs = [NSMutableArray new]; });
    return jobs;
}

static void enqueue(void (^job)(void)) {
    NSMutableArray *jobs = pendingJobs();
    @synchronized (jobs) {
        [jobs addObject:[job copy]];
        if (jobs.count > kMaxQueued) {
            [jobs removeObjectAtIndex:0];
            FMLog("skipped: too many notifications waiting, dropped the oldest");
        }
    }
    dispatch_async(workQueue(), ^{
        void (^next)(void) = nil;
        @synchronized (jobs) {
            if (jobs.count) {
                next = jobs.firstObject;
                [jobs removeObjectAtIndex:0];
            }
        }
        if (!next) return;
        @autoreleasepool {
            @try {
                next();
            } @catch (__unused NSException *e) {
            }
        }
    });
}

// The app's launcher icon as a small PNG data URI, or nil. Best-effort: a missing icon just means
// the toast has no image. Cached per app; only used on the work queue.
static NSString *iconDataURI(NSString *bundleID) {
    static NSMutableDictionary<NSString *, id> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    id hit = cache[bundleID];
    if (hit) return [hit isKindOfClass:[NSString class]] ? hit : nil;

    NSString *uri = nil;
    @try {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:2.0];
        if (icon) {
            CGRect rect = CGRectMake(0, 0, kIconPx, kIconPx);
            UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
            format.scale = 1.0;
            UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:rect.size format:format];
            UIImage *small = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
                [icon drawInRect:rect];
            }];
            NSData *png = UIImagePNGRepresentation(small);
            if (png) uri = [@"data:image/png;base64," stringByAppendingString:[png base64EncodedStringWithOptions:0]];
        }
    } @catch (__unused NSException *e) {
    }
    if (cache.count > 100) [cache removeAllObjects];
    cache[bundleID] = uri ?: (id)[NSNull null];
    return uri;
}

// The posting app's display name (fallback: the bundle id).
// Cached per app, like the icons; only used on the work queue.
static NSString *displayName(NSString *bundleID) {
    static NSMutableDictionary<NSString *, NSString *> *cache;
    if (!cache) cache = [NSMutableDictionary new];
    NSString *name = cache[bundleID];
    if (name) return name;
    @try {
        name = stringOrNil([[%c(LSApplicationProxy) applicationProxyForIdentifier:bundleID] localizedName]);
    } @catch (__unused NSException *e) {
    }
    name = name ?: bundleID;
    if (cache.count > 200) [cache removeAllObjects];
    cache[bundleID] = name;
    return name;
}

static void handleNotification(NSString *bundleID, NSString *key, NSTimeInterval posted,
                               NSString *title, NSString *subtitle, NSString *message) {
    NSString *dir = configDir();
    if (!dir) {
        FMLog("skipped: not paired (open FrameMate and scan the pairing code)");
        return;
    }
    NSDictionary *pairing = readPairing(dir);
    if (!pairing) {
        FMLog("skipped: the pairing in %{public}@ can't be read", dir);
        return;
    }

    // Record the app so it shows up in the settings list, whether or not it is forwarded now.
    // Skipped when unchanged: notifications are frequent.
    NSString *label = displayName(bundleID);
    NSDictionary *prefs = loadPrefs(dir);
    NSDictionary *seen = [prefs[@"seen"] isKindOfClass:[NSDictionary class]] ? prefs[@"seen"] : nil;
    if (![seen[bundleID] isEqual:label]) {
        updatePrefs(dir, ^(NSMutableDictionary *p) {
            NSMutableDictionary *s = [p[@"seen"] isKindOfClass:[NSDictionary class]] ? [p[@"seen"] mutableCopy] : [NSMutableDictionary new];
            s[bundleID] = label;
            p[@"seen"] = s;
        });
    }

    // The bell is on and this app isn't switched off.
    if (![prefs[@"enabled"] isKindOfClass:[NSNumber class]] || ![prefs[@"enabled"] boolValue]) {
        FMLog("skipped: the bell is off (settings %{public}s)", prefs.count ? "found" : "missing or unreadable");
        return;
    }
    NSArray *disabled = [prefs[@"disabled_apps"] isKindOfClass:[NSArray class]] ? prefs[@"disabled_apps"] : nil;
    if ([disabled containsObject:bundleID]) {
        FMLog("skipped: %{private}@ is switched off", bundleID);
        return;
    }

    // Apps re-post the same notification with the same text (progress, updates); only the first
    // goes through. Remembered per notification and including when it was posted, like the
    // Android listener (FrameNotificationListener.kt), so a new message with the same text as an
    // earlier one (a second "ok") still goes through.
    static NSMutableDictionary<NSString *, NSNumber *> *lastHash;
    if (!lastHash) lastHash = [NSMutableDictionary new];
    NSUInteger hash = [[NSString stringWithFormat:@"%@\n%@\n%@\n%.3f", title, subtitle, message, posted] hash];
    if (lastHash[key] && [lastHash[key] unsignedIntegerValue] == hash) {
        FMLog("skipped: a re-post of the same notification");
        return;
    }
    if (lastHash.count > 200) [lastHash removeAllObjects];
    lastHash[key] = @(hash);

    // Paused because the Frame wasn't reachable: skip, or make the quick check when it's due.
    if (isPaused(prefs)) {
        uint64_t nextCheck = [prefs[@"pause_next_check"] isKindOfClass:[NSNumber class]] ? [prefs[@"pause_next_check"] unsignedLongLongValue] : 0;
        uint64_t now = nowMs();
        if (now < nextCheck) {
            FMLog("skipped: paused, the Frame wasn't reachable (next check in %llu s)", (nextCheck - now) / 1000);
            return;
        }
        if (!frameAnswers(pairing)) {
            NSInteger failed = ([prefs[@"pause_step"] isKindOfClass:[NSNumber class]] ? [prefs[@"pause_step"] integerValue] : 0) + 1;
            NSTimeInterval wait = pauseInterval(failed);
            updatePrefs(dir, ^(NSMutableDictionary *p) {
                p[@"pause_step"] = @(failed);
                p[@"pause_next_check"] = @(nowMs() + (uint64_t)(wait * 1000));
            });
            FMNote("skipped: still paused, the Frame doesn't answer (next check in %.0f s)", wait);
            return;
        }
        FMNote("the Frame answers again; resuming");
        updatePrefs(dir, ^(NSMutableDictionary *p) { clearPause(p); });
    }

    NSString *text = subtitle.length ? [NSString stringWithFormat:@"%@\n%@", subtitle, message] : message;
    NSDictionary *payload = @{
        @"app": label,
        @"title": title,
        @"body": text,
        @"icon": iconDataURI(bundleID) ?: (id)[NSNull null],
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) return;

    FMLog("sending a notification from %{private}@", bundleID);
    BOOL unreachable = NO;
    NSString *result = sendToast(pairing, body, &unreachable);
    FMLog("result: %{public}@", result);
    // Most sends end the same way as the one before ("shown"); don't rewrite the settings file
    // for that. It is written when the result changes, when a pause starts or ends, and
    // otherwise at most every few minutes to keep the time of the last send roughly current.
    // Compared with the settings read at the start: these fields only change here.
    uint64_t storedTime = [prefs[@"last_time"] isKindOfClass:[NSNumber class]] ? [prefs[@"last_time"] unsignedLongLongValue] : 0;
    if (!unreachable && !isPaused(prefs) && [prefs[@"last_result"] isEqual:result] && nowMs() - storedTime < 5 * 60 * 1000) {
        return;
    }
    updatePrefs(dir, ^(NSMutableDictionary *p) {
        p[@"last_result"] = result;
        p[@"last_time"] = @(nowMs());
        if (unreachable) {
            p[@"paused_since"] = @(nowMs());
            p[@"pause_step"] = @0;
            p[@"pause_next_check"] = @(nowMs() + (uint64_t)(pauseInterval(0) * 1000));
        } else {
            clearPause(p);
        }
    });
    if (unreachable) FMNote("pausing: the Frame isn't reachable (next check in %.0f s)", pauseInterval(0));
}

%hook BBServer
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations {
    %orig;
    // Only copy strings here; never let a forwarding slip-up disturb the real notification pipeline.
    @try {
        NSString *bundleID = [bulletin.sectionID copy];
        if (bundleID.length == 0 || [bundleID isEqualToString:kSelfBundleID]) return;

        NSDate *date = bulletin.date;
        // Private API: only used where this iOS version has it (else every app's notifications
        // share one entry, which still lets new messages through thanks to the post time).
        NSString *record = nil;
        if ([bulletin respondsToSelector:@selector(recordID)]) record = stringOrNil(bulletin.recordID);
        if (!record && [bulletin respondsToSelector:@selector(publisherBulletinID)]) record = stringOrNil(bulletin.publisherBulletinID);
        NSString *key = [NSString stringWithFormat:@"%@\n%@", bundleID, record ?: @""];
        NSTimeInterval posted = date ? date.timeIntervalSince1970 : 0;
        // A respring replaying old notifications.
        if (date && [date timeIntervalSinceNow] < -kReplayAge) return;

        BBContent *content = bulletin.content;
        NSString *title = [(content.title ?: bulletin.title ?: @"") copy];
        NSString *subtitle = [(content.subtitle ?: @"") copy];
        NSString *message = [(content.message ?: bulletin.message ?: @"") copy];
        if (title.length == 0 && message.length == 0) {
            FMLog("skipped: no title or text");
            return;
        }

        CFAbsoluteTime queued = CFAbsoluteTimeGetCurrent();
        enqueue(^{
            if (CFAbsoluteTimeGetCurrent() - queued > kMaxWait) {
                FMLog("skipped: waited more than %.0f s for its turn", kMaxWait);
                return;
            }
            handleNotification(bundleID, key, posted, title, subtitle, message);
        });
    } @catch (__unused NSException *e) {
    }
}
%end

// Joining a Wi-Fi network (e.g. coming home, where the Frame is) ends a pause at once. iOS reports
// path changes as events, so this costs nothing in between.
static void watchWiFi(void) {
    static nw_path_monitor_t monitor;
    monitor = nw_path_monitor_create_with_type(nw_interface_type_wifi);
    nw_path_monitor_set_queue(monitor, workQueue());
    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        if (nw_path_get_status(path) != nw_path_status_satisfied) return;
        @try {
            NSString *dir = configDir();
            if (!dir || !isPaused(loadPrefs(dir))) return;
            updatePrefs(dir, ^(NSMutableDictionary *p) { clearPause(p); });
            FMNote("Wi-Fi connected; resuming");
        } @catch (__unused NSException *e) {
        }
    });
    nw_path_monitor_start(monitor);
}

%ctor {
    FMNote("loaded into SpringBoard");
    watchWiFi();
}
