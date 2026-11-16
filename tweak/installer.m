// framemate-installer: installs and removes the FrameMate app for the FrameMate package.
//
// The app can't just be copied into /var/jb/Applications (WKWebView needs a normal app container,
// which only iOS's installer, installd, sets up). So the package carries FrameMate.ipa and its
// postinst/prerm call this, which asks installd through LaunchServices — the same way AppSync
// Unified's appinst does (github.com/akemin-dayo/AppSync, appinst/appinst.m), without depending on
// appinst's package. AppSync Unified itself is still needed, so that installd accepts a
// fakesigned app; it can come from any repo.
//
//   framemate-installer install <path.ipa> <bundle-id>
//   framemate-installer uninstall <bundle-id>
//
// Exit 0 on success (uninstalling an app that isn't installed counts), 1 on failure, 2 on bad usage.

#import <Foundation/Foundation.h>

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)installApplication:(NSURL *)path withOptions:(NSDictionary *)options error:(NSError **)error;
- (BOOL)uninstallApplication:(NSString *)identifier withOptions:(NSDictionary *)options;
@end

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *bundleURL;
@end

static LSApplicationWorkspace *workspace(void) {
    Class cls = NSClassFromString(@"LSApplicationWorkspace");
    return cls ? [cls defaultWorkspace] : nil;
}

static BOOL isInstalled(NSString *bundleID) {
    Class cls = NSClassFromString(@"LSApplicationProxy");
    LSApplicationProxy *proxy = cls ? [cls applicationProxyForIdentifier:bundleID] : nil;
    return proxy.bundleURL != nil;
}

static int install(NSString *ipa, NSString *bundleID) {
    NSFileManager *files = [NSFileManager defaultManager];
    if (![files fileExistsAtPath:ipa]) {
        fprintf(stderr, "No such file: %s\n", ipa.UTF8String);
        return 1;
    }
    // installd deletes the IPA once it has unpacked it, so it gets a copy. The directory is
    // world-writable because installd doesn't run as root (this is called from a root postinst).
    NSString *work = [NSTemporaryDirectory() stringByAppendingPathComponent:@"framemate-installer"];
    [files removeItemAtPath:work error:nil];
    if (![files createDirectoryAtPath:work withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions: @0777} error:nil]) {
        fprintf(stderr, "Couldn't create %s\n", work.UTF8String);
        return 1;
    }
    NSString *copy = [work stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.ipa", NSUUID.UUID.UUIDString]];
    NSError *error = nil;
    if (![files copyItemAtPath:ipa toPath:copy error:&error]) {
        fprintf(stderr, "Couldn't copy the IPA: %s\n", error.localizedDescription.UTF8String);
        return 1;
    }
    [files setAttributes:@{NSFilePosixPermissions: @0644} ofItemAtPath:copy error:nil];

    LSApplicationWorkspace *ws = workspace();
    BOOL ok = NO;
    error = nil;
    @try {
        ok = [ws installApplication:[NSURL fileURLWithPath:copy] withOptions:@{@"CFBundleIdentifier": bundleID} error:&error];
    } @catch (NSException *exception) {
        fprintf(stderr, "Installing threw: %s\n", exception.description.UTF8String);
    }
    [files removeItemAtPath:work error:nil];
    if (ok) {
        printf("Installed %s\n", bundleID.UTF8String);
        return 0;
    }
    fprintf(stderr, "Couldn't install %s: %s\n", bundleID.UTF8String,
            error ? error.description.UTF8String : (ws ? "installd refused it" : "LaunchServices is not available"));
    return 1;
}

static int uninstall(NSString *bundleID) {
    if (!isInstalled(bundleID)) {
        printf("%s is not installed\n", bundleID.UTF8String);
        return 0;
    }
    if ([workspace() uninstallApplication:bundleID withOptions:nil]) {
        printf("Removed %s\n", bundleID.UTF8String);
        return 0;
    }
    fprintf(stderr, "Couldn't remove %s\n", bundleID.UTF8String);
    return 1;
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        if (argc == 4 && strcmp(argv[1], "install") == 0) return install(@(argv[2]), @(argv[3]));
        if (argc == 3 && strcmp(argv[1], "uninstall") == 0) return uninstall(@(argv[2]));
        fprintf(stderr, "usage: %s install <path.ipa> <bundle-id>\n       %s uninstall <bundle-id>\n", argv[0], argv[0]);
        return 2;
    }
}
