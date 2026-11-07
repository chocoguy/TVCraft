// TVCraft entry: set up the log and the working directory, then hand over to UIKit (GameViewController.mm runs the game).
// tvOS apps have no Documents to keep: Library/Caches holds the worlds, the options and the log, and the system may purge it while the app is closed
// (TVSaves.m keeps a copy of the worlds; TVPort's dm/ios/Sources/main.m does the same for Switch games).
#import <UIKit/UIKit.h>
#import <AVFAudio/AVFAudio.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>
#import "GameViewController.h"

NSString *tv_data_dir(void) {
    return NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
}

static void boot(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *caches = tv_data_dir();
    [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:nil];
    // The game prints to stdout and the shell to stderr: both go to Caches/log.txt, the previous run's kept as log.prev.txt (tvcraft.py log reads it off the TV)
    NSString *log = [caches stringByAppendingPathComponent:@"log.txt"], *prev = [caches stringByAppendingPathComponent:@"log.prev.txt"];
    [fm removeItemAtPath:prev error:nil];
    [fm moveItemAtPath:log toPath:prev error:nil];
    if (freopen(log.fileSystemRepresentation, "w", stderr)) {
        setvbuf(stderr, NULL, _IOLBF, 0);
        dup2(fileno(stderr), fileno(stdout));
        setvbuf(stdout, NULL, _IOLBF, 0);
    }
    // A game's sounds: mixed with other audio, quiet when the TV's sound is muted for something else. Set before the game opens OpenAL
    NSError *audioError = nil;
    if (![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryAmbient error:&audioError] || ![AVAudioSession.sharedInstance setActive:YES error:&audioError])
        fprintf(stderr, "[RED] boot: the audio session: %s\n", audioError.localizedDescription.UTF8String);
    signal(SIGPIPE, SIG_IGN);   // RakNet's sockets, as the Android build does (NinecraftApp's constructor)
    // The game opens assets/... relative to the working directory, as the SDL build does from its folder
    NSString *resources = NSBundle.mainBundle.resourcePath;
    if (chdir(resources.fileSystemRepresentation)) fprintf(stderr, "[RED] boot: cannot enter %s\n", resources.fileSystemRepresentation);
    if (![fm fileExistsAtPath:[resources stringByAppendingPathComponent:@"assets/images/terrain-atlas.tga"]])
        fprintf(stderr, "[RED] boot: the game's assets are not in the app. Run \"tvcraft.py extract\", then build again\n");
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    fprintf(stderr, "boot: TVCraft %s (%s), tvOS %s, data in %s\n", [info[@"CFBundleShortVersionString"] UTF8String], [info[@"CFBundleVersion"] UTF8String],
            NSProcessInfo.processInfo.operatingSystemVersionString.UTF8String, caches.fileSystemRepresentation);
}

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)app; (void)options;
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [GameViewController new];
    [self.window makeKeyAndVisible];
}
- (void)sceneWillResignActive:(UIScene *)scene { (void)scene; [(GameViewController *)self.window.rootViewController appWillResignActive]; }
- (void)sceneDidBecomeActive:(UIScene *)scene { (void)scene; [(GameViewController *)self.window.rootViewController appDidBecomeActive]; }
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        boot();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class));
    }
}
