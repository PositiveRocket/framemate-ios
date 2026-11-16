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
//                                                         last_result, last_time}      (read/write)
//
// Both files are shared with the app (framemate-core's `pairing` and `prefs` modules); the formats
// here must stay in step with them. Nothing else is persisted and no notification content is logged.

#import "Tweak.h"
#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>

// The FrameMate app itself, never forwarded (its own "test"/status toasts would loop).
static NSString *const kSelfBundleID = @"dev.framemate.app";
// Older than this when seen: a respring replays recent bulletins, and a toast for something from
// minutes ago only confuses. Matches ForwardNotifier's guard.
static const NSTimeInterval kMaxAge = 5.0;
// The app icon, downscaled to this before it is PNG-encoded. The agent accepts up to 64 KB.
static const CGFloat kIconPx = 96.0;
// Per address. A sleeping Frame never answers, so this is what a notification costs then.
static const NSTimeInterval kRequestTimeout = 5.0;

#pragma mark - Shared files

// The app's shared config directory (<container>/Documents/FrameMate), resolved from the app's
// data container. It is inside the app's sandbox container — created when the app first runs — so
// it can't be hard-coded; cached once found. Matches `config_dir` in src-tauri/src/lib.rs.
static NSString *configDir(void) {
    static NSString *cached = nil;
    if (cached) return cached;
    LSApplicationProxy *proxy = [%c(LSApplicationProxy) applicationProxyForIdentifier:kSelfBundleID];
    NSURL *container = proxy.dataContainerURL;
    if (!container.path.length) return nil; // app not installed, or never launched yet
    cached = [[container.path stringByAppendingPathComponent:@"Documents"] stringByAppendingPathComponent:@"FrameMate"];
    return cached;
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

static void recordResult(NSString *dir, NSString *result) {
    updatePrefs(dir, ^(NSMutableDictionary *prefs) {
        prefs[@"last_result"] = result;
        prefs[@"last_time"] = @((unsigned long long)([[NSDate date] timeIntervalSince1970] * 1000.0));
    });
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

// One POST to one address. Blocks (we are on our own queue). Returns the HTTP status, or 0 with
// *failure set.
static NSInteger postOnce(NSString *host, NSNumber *port, NSString *token, NSString *pin, NSData *body,
                          NSData **responseBody, NSString **failure, BOOL *rejected) {
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    components.host = host;
    components.port = port;
    components.path = @"/api/notify";
    NSURL *url = components.URL;
    if (!url) {
        *failure = [NSString stringWithFormat:@"%@: not a usable address", host];
        return 0;
    }

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:kRequestTimeout];
    request.HTTPMethod = @"POST";
    request.HTTPBody = body;
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];

    FMPinnedDelegate *delegate = [FMPinnedDelegate new];
    delegate.pin = pin;
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = kRequestTimeout;
    config.timeoutIntervalForResource = kRequestTimeout * 2;
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
    long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((kRequestTimeout * 2 + 2) * NSEC_PER_SEC)));
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
    *responseBody = received;
    return status;
}

// Tries the mDNS name and the address, starting with whichever worked last. Returns the status
// word the settings page shows: `shown`, `headset_asleep`, `rate_limited`, or `error: …`.
static NSString *sendToast(NSDictionary *pairing, NSData *body) {
    NSString *token = stringOrNil(pairing[@"token"]);
    NSString *pin = stringOrNil(pairing[@"pin"]);
    NSNumber *port = [pairing[@"port"] isKindOfClass:[NSNumber class]] ? pairing[@"port"] : nil;
    NSMutableArray<NSString *> *candidates = [NSMutableArray new];
    if (stringOrNil(pairing[@"host"])) [candidates addObject:pairing[@"host"]];
    if (stringOrNil(pairing[@"ip"])) [candidates addObject:pairing[@"ip"]];
    if (!token || !pin || !port || candidates.count == 0) return @"error: the saved pairing is incomplete, pair again";

    static NSUInteger preferred = 0; // only touched on the send queue
    NSString *failure = @"";
    for (NSUInteger offset = 0; offset < candidates.count; offset++) {
        NSUInteger index = (preferred + offset) % candidates.count;
        NSData *responseBody = nil;
        BOOL rejected = NO;
        NSInteger status = postOnce(candidates[index], port, token, pin, body, &responseBody, &failure, &rejected);
        // Something answered and it isn't ours: don't fall through to the next address, which
        // would turn a pin mismatch into a vague timeout.
        if (rejected) return [NSString stringWithFormat:@"error: this isn't the Frame the app was paired with, pair again (%@)", failure];
        if (status == 0) continue;
        preferred = index;
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
    return [NSString stringWithFormat:@"error: can't reach the Frame (%@)", failure];
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
static NSString *displayName(NSString *bundleID) {
    NSString *name = nil;
    @try {
        name = stringOrNil([[%c(LSApplicationProxy) applicationProxyForIdentifier:bundleID] localizedName]);
    } @catch (__unused NSException *e) {
    }
    return name ?: bundleID;
}

static void handleNotification(NSString *bundleID, NSString *title, NSString *subtitle, NSString *message) {
    NSString *dir = configDir();
    if (!dir) return; // app not installed, or never launched (no container yet)
    NSDictionary *pairing = readPairing(dir);
    if (!pairing) return; // not paired: nowhere to send, nothing to set up

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
    if (![prefs[@"enabled"] isKindOfClass:[NSNumber class]] || ![prefs[@"enabled"] boolValue]) return;
    NSArray *disabled = [prefs[@"disabled_apps"] isKindOfClass:[NSArray class]] ? prefs[@"disabled_apps"] : nil;
    if ([disabled containsObject:bundleID]) return;

    // De-duplicate re-posts of the same content (progress bars, etc.). A genuinely new message
    // has new text and so a new hash, and still goes through.
    static NSMutableDictionary<NSString *, NSNumber *> *lastHash;
    if (!lastHash) lastHash = [NSMutableDictionary new];
    NSUInteger hash = [[NSString stringWithFormat:@"%@\n%@\n%@", title, subtitle, message] hash];
    if (lastHash[bundleID] && [lastHash[bundleID] unsignedIntegerValue] == hash) return;
    if (lastHash.count > 200) [lastHash removeAllObjects];
    lastHash[bundleID] = @(hash);

    NSString *text = subtitle.length ? [NSString stringWithFormat:@"%@\n%@", subtitle, message] : message;
    NSDictionary *payload = @{
        @"app": label,
        @"title": title,
        @"body": text,
        @"icon": iconDataURI(bundleID) ?: (id)[NSNull null],
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    if (!body) return;

    recordResult(dir, sendToast(pairing, body));
}

%hook BBServer
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations {
    %orig;
    // Only copy strings here; never let a forwarding slip-up disturb the real notification pipeline.
    @try {
        NSString *bundleID = [bulletin.sectionID copy];
        if (bundleID.length == 0 || [bundleID isEqualToString:kSelfBundleID]) return;

        // Skip stale bulletins (respring replay).
        NSDate *date = bulletin.date;
        if (date && [date timeIntervalSinceNow] < -kMaxAge) return;

        BBContent *content = bulletin.content;
        NSString *title = [(content.title ?: bulletin.title ?: @"") copy];
        NSString *subtitle = [(content.subtitle ?: @"") copy];
        NSString *message = [(content.message ?: bulletin.message ?: @"") copy];
        if (title.length == 0 && message.length == 0) return;

        dispatch_async(workQueue(), ^{
            @autoreleasepool {
                @try {
                    handleNotification(bundleID, title, subtitle, message);
                } @catch (__unused NSException *e) {
                }
            }
        });
    } @catch (__unused NSException *e) {
    }
}
%end
