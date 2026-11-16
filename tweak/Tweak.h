// Private-API stubs for the classes the tweak touches. Only the members the tweak uses are declared.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

// --- BulletinBoard (the notification pipeline inside SpringBoard) ---

@interface BBContent : NSObject
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *message;
@end

@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *sectionID;   // the posting app's bundle id
@property (nonatomic, copy) NSString *recordID;    // this notification, stable across re-posts
@property (nonatomic, copy) NSString *publisherBulletinID;
@property (nonatomic, retain) BBContent *content;
@property (nonatomic, copy) NSDate *date;
@property (nonatomic, copy) NSString *title;        // older path; falls back to content.title
@property (nonatomic, copy) NSString *message;
@end

@interface BBServer : NSObject
- (void)publishBulletin:(BBBulletin *)bulletin destinations:(unsigned long long)destinations;
@end

// --- UIKit private: the app's icon as a UIImage, usable from inside SpringBoard ---

@interface UIImage (FrameMatePrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier
                                               format:(int)format
                                                scale:(CGFloat)scale;
@end

// --- MobileCoreServices private: an installed app's container and display name ---

@interface LSApplicationProxy : NSObject
+ (instancetype)applicationProxyForIdentifier:(NSString *)identifier;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@property (nonatomic, readonly) NSString *localizedName;
@end
