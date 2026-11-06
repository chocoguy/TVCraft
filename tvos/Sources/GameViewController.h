// The game's view controller: the OpenGL ES 1.1 view, the frame loop, the Back button and the app's lifecycle.
#import <GameController/GameController.h>

NSString *tv_data_dir(void);   // main.mm: Library/Caches

// A GCEventViewController with controllerUserInteractionEnabled off: a controller's presses reach the game only, so its B does not also act as the
// remote's Back and leave for the Home screen (TVPort's dm/ios/Sources/front_ios.m)
@interface GameViewController : GCEventViewController
- (void)appWillResignActive;
- (void)appDidBecomeActive;
@end

#ifdef __cplusplus
struct NinecraftApp;
struct AppPlatform_tvos;
NinecraftApp *tv_game(void);           // NULL until the first frame has set the game up
AppPlatform_tvos *tv_platform(void);
#endif
