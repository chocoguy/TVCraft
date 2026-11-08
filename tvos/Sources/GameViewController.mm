// The game's view controller: an OpenGL ES 1.1 view (the API the game was written for), a 60 fps frame loop on the main thread as the SDL build's
// AppPlatform_sdl::init loop does, Back handling and the app's lifecycle. Input from controllers and the remote is TVInput.mm.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import "GameViewController.h"
#import "TVInput.h"
#import "TVSaves.h"
#include <NinecraftApp.hpp>
#include <tvos/AppPlatform_tvos.hpp>
#include <unigl.hpp>
#include <input/Keyboard.hpp>
#include <util/Util.hpp>
#include <level/Level.hpp>
#include <level/gen/ChunkSource.hpp>
#include <sound/SoundEngine.hpp>
#include <OpenAL/alc.h>

static NinecraftApp *g_mc;
static AppPlatform_tvos *g_platform;
NinecraftApp *tv_game(void) { return g_mc; }
AppPlatform_tvos *tv_platform(void) { return g_platform; }

// OpenAL keeps running in the background unless told; tvOS wants the app silent and idle there
static void audio_active(BOOL on) {
    ALCcontext *c = g_mc && g_mc->soundEngine ? g_mc->soundEngine->soundSystem.context : NULL;
    if (!c) return;
    if (on) { alcMakeContextCurrent(c); alcProcessContext(c); }
    else { alcSuspendContext(c); alcMakeContextCurrent(NULL); }
}

@interface TVGLView : UIView
@end
@implementation TVGLView
+ (Class)layerClass { return CAEAGLLayer.class; }
@end

@implementation GameViewController {
    EAGLContext *_context;
    GLuint _framebuffer, _colorBuffer, _depthStencilBuffer;
    GLint _width, _height;
    CADisplayLink *_link;
    UITapGestureRecognizer *_backPress;
    CFTimeInterval _lastFrame, _lastSync;
    BOOL _hadLevel;
    CFTimeInterval _statsStart, _slowest;   // frame statistics, logged every 600 frames
    int _statsFrames, _slowFrames;
    BOOL _atRoot, _alertUp;
    UIAlertController *_keyboardAlert;
}

- (void)loadView {
    TVGLView *view = [[TVGLView alloc] initWithFrame:CGRectZero];
    view.contentScaleFactor = 1.0;   // draw at 1920x1080 points; tvOS scales it up for a 4K TV
    view.backgroundColor = UIColor.blackColor;
    self.view = view;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.controllerUserInteractionEnabled = NO;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // tvOS leaves for the Home screen when nothing takes a Back press (the remote's Back, a controller's B or Menu). This view holds nothing focusable,
    // so this controller stays first responder and a recognizer on the window takes what arrives there (TVPort's front_ios.m)
    [self becomeFirstResponder];
    if (!_backPress) {
        _backPress = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backPressed:)];
        _backPress.allowedPressTypes = @[@(UIPressTypeMenu)];
        [self.view.window addGestureRecognizer:_backPress];
    }
}

- (BOOL)canBecomeFirstResponder { return YES; }

- (void)backPressed:(UITapGestureRecognizer *)recognizer {
    (void)recognizer;
    if (g_mc && !_alertUp) g_mc->handleBack(0);
}

// The remote's arrows, select and play/pause, and a keyboard's keys (a Bluetooth keyboard, the simulator's). Back (Menu) goes on up the chain: on the title
// screen nothing takes it and tvOS goes to the Home screen; elsewhere the recognizer above has it. A keyboard's Escape is Back too
static UIPressType press_type(UIPress *p) {
    if (!p.key) return p.type;
    switch (p.key.keyCode) {
        case UIKeyboardHIDUsageKeyboardUpArrow: case UIKeyboardHIDUsageKeyboardW: return UIPressTypeUpArrow;
        case UIKeyboardHIDUsageKeyboardDownArrow: case UIKeyboardHIDUsageKeyboardS: return UIPressTypeDownArrow;
        case UIKeyboardHIDUsageKeyboardLeftArrow: case UIKeyboardHIDUsageKeyboardA: return UIPressTypeLeftArrow;
        case UIKeyboardHIDUsageKeyboardRightArrow: case UIKeyboardHIDUsageKeyboardD: return UIPressTypeRightArrow;
        case UIKeyboardHIDUsageKeyboardReturnOrEnter: case UIKeyboardHIDUsageKeyboardSpacebar: return UIPressTypeSelect;
        case UIKeyboardHIDUsageKeyboardEscape: return UIPressTypeMenu;
        case UIKeyboardHIDUsageKeyboardP: return UIPressTypePlayPause;
        default: return (UIPressType)-1;
    }
}
- (BOOL)take:(UIPress *)p down:(BOOL)down {
    UIPressType type = press_type(p);
    if (_alertUp) return NO;
    if (type == UIPressTypeMenu) {
        if (!p.key) return NO;                     // the remote's: the recognizer, or tvOS on the title screen
        if (down && g_mc && !_atRoot) g_mc->handleBack(0);
        return !_atRoot;
    }
    if ((long)type == -1) return NO;
    tv_input_press(type, down);
    return YES;
}
- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSMutableSet *rest = [NSMutableSet set];
    for (UIPress *p in presses) if (![self take:p down:YES]) [rest addObject:p];
    if (rest.count) [super pressesBegan:rest withEvent:event];
}
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSMutableSet *rest = [NSMutableSet set];
    for (UIPress *p in presses) if (![self take:p down:NO]) [rest addObject:p];
    if (rest.count) [super pressesEnded:rest withEvent:event];
}
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {
    NSMutableSet *rest = [NSMutableSet set];
    for (UIPress *p in presses) if (![self take:p down:NO]) [rest addObject:p];
    if (rest.count) [super pressesCancelled:rest withEvent:event];
}

// Back leaves the game only from the title screen: there the recognizer stands aside and nothing takes the remote's Back, so tvOS goes to the Home screen.
// Controller input stays with the game (controllerUserInteractionEnabled off) except while a system alert is up, whose focus engine needs it: with it on,
// tvOS gives a controller's A, B, sticks and D-pad to UIKit's focus navigation and the game no longer sees them (found on an Apple TV with a Pro Controller)
- (void)updateRouting {
    BOOL root = tv_input_at_root();
    if (root == _atRoot && self.controllerUserInteractionEnabled == _alertUp) return;
    _atRoot = root;
    self.controllerUserInteractionEnabled = _alertUp;
    _backPress.enabled = !root && !_alertUp;
}

#pragma mark - Text: the game's dialogs and text boxes, as system alerts with tvOS's keyboard

- (void)presentAlert:(UIAlertController *)alert {
    _alertUp = YES;
    tv_input_suspend(YES);
    [self updateRouting];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)alertDone {
    _alertUp = NO;
    _keyboardAlert = nil;
    tv_input_suspend(NO);
    [self updateRouting];
    [self becomeFirstResponder];
}

static std::string utf8(NSString *s) { return s ? std::string(s.UTF8String) : std::string(); }

// AppPlatform_tvos::createUserInput: 1 creates a world {name, seed, game mode} (Touch::SelectWorldScreen::tick reads it), 4 renames one {name}
- (void)presentDialog:(int32_t)dialog {
    AppPlatform_tvos *platform = g_platform;
    __weak GameViewController *weakSelf = self;
    UIAlertController *alert;
    if (dialog == AppPlatform_tvos::DIALOG_CREATE_WORLD) {
        alert = [UIAlertController alertControllerWithTitle:@"Create New World" message:@"Leave the seed empty for a random world." preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"World name"; f.text = @"My World"; }];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"Seed (optional)"; }];
        __weak UIAlertController *weakAlert = alert;
        for (NSString *mode in @[@"Survival", @"Creative"]) {
            [alert addAction:[UIAlertAction actionWithTitle:mode style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
                (void)a;
                platform->finishUserInput(1, {utf8(weakAlert.textFields[0].text), utf8(weakAlert.textFields[1].text), utf8(mode.lowercaseString)});
                [weakSelf alertDone];
            }]];
        }
    } else {
        alert = [UIAlertController alertControllerWithTitle:@"Rename World" message:nil preferredStyle:UIAlertControllerStyleAlert];
        [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.placeholder = @"World name"; }];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:@"Rename" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a;
            platform->finishUserInput(1, {utf8(weakAlert.textFields[0].text)});
            [weakSelf alertDone];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        (void)a;
        platform->finishUserInput(0, {});
        [weakSelf alertDone];
    }]];
    [self presentAlert:alert];
}

// A text box took focus (AppPlatform_tvos::showKeyboard): edit its text in an alert, then type the result into the game the way a keyboard does:
// backspaces for the old text, each character, then Enter a frame later (TextBox::keyPressed, ChatScreen)
- (void)presentKeyboard:(const std::string &)text maxLength:(int32_t)maxLength {
    if (_alertUp) return;
    NSString *old = @(text.c_str()) ?: @"";
    __weak GameViewController *weakSelf = self;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil message:nil preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = old; }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:@"Done" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        NSString *typed = weakAlert.textFields[0].text ?: @"";
        if (maxLength > 0 && (int32_t)typed.length > maxLength) typed = [typed substringToIndex:maxLength];
        for (int i = 0; i < Util::utf8len(text); i++) { Keyboard::feed(8, 1); Keyboard::feed(8, 0); }
        [typed enumerateSubstringsInRange:NSMakeRange(0, typed.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
            (void)r; (void)er; (void)stop;
            Keyboard::feedText(utf8(ch), 0);
        }];
        tv_input_tap_later(13);   // Enter once the text is in
        [weakSelf alertDone];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        (void)a;
        [weakSelf alertDone];
        if (g_mc) g_mc->handleBack(0);   // the text box loses focus without a change
    }]];
    _keyboardAlert = alert;
    [self presentAlert:alert];
}
- (void)dismissKeyboard {
    if (!_keyboardAlert) return;
    [_keyboardAlert dismissViewControllerAnimated:YES completion:nil];
    [self alertDone];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    if (!_context && self.view.bounds.size.width > 0) [self startGame];
}

- (BOOL)makeFramebuffer {
    CAEAGLLayer *layer = (CAEAGLLayer *)self.view.layer;
    layer.opaque = YES;
    layer.contentsScale = 1.0;
    layer.drawableProperties = @{kEAGLDrawablePropertyRetainedBacking: @NO, kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8};
    glGenFramebuffersOES(1, &_framebuffer);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    glGenRenderbuffersOES(1, &_colorBuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _colorBuffer);
    [_context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:layer];
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, GL_RENDERBUFFER_OES, _colorBuffer);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &_width);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &_height);
    // depth and an 8-bit stencil, as the SDL build asks for (AppPlatform_sdl::sdlCtxInit)
    glGenRenderbuffersOES(1, &_depthStencilBuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _depthStencilBuffer);
    glRenderbufferStorageOES(GL_RENDERBUFFER_OES, GL_DEPTH24_STENCIL8_OES, _width, _height);
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_DEPTH_ATTACHMENT_OES, GL_RENDERBUFFER_OES, _depthStencilBuffer);
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_STENCIL_ATTACHMENT_OES, GL_RENDERBUFFER_OES, _depthStencilBuffer);
    GLenum status = glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES);
    if (status != GL_FRAMEBUFFER_COMPLETE_OES) {
        fprintf(stderr, "[RED] gl: the framebuffer is incomplete (0x%x)\n", status);
        return NO;
    }
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _colorBuffer);
    return YES;
}

- (void)startGame {
    _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
    if (!_context || ![EAGLContext setCurrentContext:_context]) {
        fprintf(stderr, "[RED] gl: this device would not create an OpenGL ES 1.1 context\n");
        return;
    }
    fprintf(stderr, "gl: GL_VERSION: %s\ngl: GL_RENDERER: %s\n", (const char *)glGetString(GL_VERSION), (const char *)glGetString(GL_RENDERER));
    if (![self makeFramebuffer]) return;
    fprintf(stderr, "gl: drawing %dx%d\n", _width, _height);

    // As AppPlatform_sdl::init: the platform needs the GL context current (AppPlatform's constructor reads GL_EXTENSIONS)
    g_platform = new AppPlatform_tvos(_width, _height);
    g_mc = new NinecraftApp();
    AppContext ctx{};
    ctx.platform = g_platform;
    g_mc->context = ctx;
    g_mc->dataPathMaybe = tv_data_dir().fileSystemRepresentation;
    tv_saves_restore();   // worlds tvOS purged come back before the game lists them
    __weak GameViewController *weakSelf = self;
    g_platform->onCreateUserInput = [weakSelf](int32_t dialog) { [weakSelf presentDialog:dialog]; };
    g_platform->onShowKeyboard = [weakSelf](const std::string &text, int32_t maxLength) { [weakSelf presentKeyboard:text maxLength:maxLength]; };
    g_platform->onHideKeyboard = [weakSelf]() { [weakSelf dismissKeyboard]; };
    g_mc->init();
    g_mc->setSize(_width, _height);
    tv_input_attach(self.view);

    // The Apple TV has no fan: when tvOS reports serious it lowers the clocks itself (TVPort, tvport/README.md). Log each change with the time since launch
    static const char *thermal[] = {"nominal", "fair", "serious", "critical"};
    CFTimeInterval launched = CACurrentMediaTime();
    fprintf(stderr, "power: thermal state %s\n", thermal[NSProcessInfo.processInfo.thermalState & 3]);
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n;
        fprintf(stderr, "power: thermal state %s (%.0f s after launch)\n", thermal[NSProcessInfo.processInfo.thermalState & 3], CACurrentMediaTime() - launched);
    }];

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)frame:(CADisplayLink *)link {
    double dt = _lastFrame ? fmin(link.timestamp - _lastFrame, 0.1) : 1.0 / 60;
    if (_lastFrame) {   // frames: the rate, the slowest, and how many missed a refresh (over 1.5 frames at 60 Hz)
        double gap = link.timestamp - _lastFrame;
        if (!_statsStart) _statsStart = _lastFrame;
        _statsFrames++; _slowest = fmax(_slowest, gap); if (gap > 0.025) _slowFrames++;
        if (_statsFrames == 600) {
            fprintf(stderr, "frames: %.1f fps over %.0f s, slowest %.0f ms, %d slow, %s\n", _statsFrames / (link.timestamp - _statsStart), link.timestamp - _statsStart,
                    _slowest * 1000, _slowFrames, g_mc->level ? "in a world" : "in menus");
            _statsStart = link.timestamp; _statsFrames = _slowFrames = 0; _slowest = 0;
        }
    }
    _lastFrame = link.timestamp;
    [EAGLContext setCurrentContext:_context];
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    tv_input_frame(dt);
    g_mc->update();
    [self updateRouting];
    // The game writes its chunks every 50 ticks and the level when a menu opens: copy what changed once a minute, and when a world is left
    BOOL hasLevel = g_mc->level != NULL;
    if ((hasLevel && link.timestamp - _lastSync > 60) || (_hadLevel && !hasLevel)) { tv_saves_sync(NO); _lastSync = link.timestamp; }
    _hadLevel = hasLevel;
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _colorBuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER_OES];
}

- (void)appWillResignActive {
    // The game pauses itself when it loses focus with no screen open, as the SDL build does; tvOS does not allow GL work in the background
    if (g_mc && g_mc->level && !g_mc->currentScreen) g_mc->pauseGame(1);
    _link.paused = YES;
    if (_context) { [EAGLContext setCurrentContext:_context]; glFinish(); }
    if (g_mc && g_mc->level) {   // write everything now, as leaving a world does (Minecraft::prepareLevel), then copy it: tvOS may end the app from here
        g_mc->level->saveGame();
        if (g_mc->level->getChunkSource()) g_mc->level->getChunkSource()->saveAll(0);
    }
    tv_saves_sync(YES);
    audio_active(NO);
}

- (void)appDidBecomeActive {
    _lastFrame = 0;
    _statsStart = 0; _statsFrames = _slowFrames = 0; _slowest = 0;
    audio_active(YES);
    _link.paused = NO;
}
@end
