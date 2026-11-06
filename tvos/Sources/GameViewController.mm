// The game's view controller: an OpenGL ES 1.1 view (the API the game was written for), a 60 fps frame loop on the main thread as the SDL build's
// AppPlatform_sdl::init loop does, Back handling and the app's lifecycle. Input from controllers and the remote is TVInput.mm.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <OpenGLES/EAGL.h>
#import <OpenGLES/EAGLDrawable.h>
#import "GameViewController.h"
#include <NinecraftApp.hpp>
#include <tvos/AppPlatform_tvos.hpp>
#include <unigl.hpp>

static NinecraftApp *g_mc;
static AppPlatform_tvos *g_platform;
NinecraftApp *tv_game(void) { return g_mc; }
AppPlatform_tvos *tv_platform(void) { return g_platform; }

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
    if (g_mc) g_mc->handleBack(0);
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
    g_mc->init();
    g_mc->setSize(_width, _height);

    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)frame:(CADisplayLink *)link {
    (void)link;
    [EAGLContext setCurrentContext:_context];
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, _framebuffer);
    g_mc->update();
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, _colorBuffer);
    [_context presentRenderbuffer:GL_RENDERBUFFER_OES];
}

- (void)appWillResignActive {
    // The game pauses itself when it loses focus with no screen open, as the SDL build does; tvOS does not allow GL work in the background
    if (g_mc && g_mc->level && !g_mc->currentScreen) g_mc->pauseGame(1);
    _link.paused = YES;
    if (_context) { [EAGLContext setCurrentContext:_context]; glFinish(); }
}

- (void)appDidBecomeActive {
    _link.paused = NO;
}
@end
