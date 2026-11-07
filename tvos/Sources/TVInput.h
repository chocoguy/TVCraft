// Game controllers and the Siri Remote, fed into the game's own input paths each frame (TVInput.mm).
#import <UIKit/UIKit.h>

void tv_input_attach(UIView *view);              // adds the menu cursor to the game's view
void tv_input_frame(double dt);                  // before each game update: poll the controllers and feed the game
void tv_input_press(UIPressType type, BOOL down); // a press UIKit delivered (the remote's arrows, select and play/pause; the simulator's keyboard)
void tv_input_tap_later(int code);              // press and release a key two frames from now (Enter after typed text)
void tv_input_suspend(BOOL suspended);           // while a system alert is up: release everything and feed nothing
BOOL tv_input_at_root(void);                     // the title screen with no world: Back should leave for the Home screen, as tvOS apps do
