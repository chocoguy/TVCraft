// Game controllers and the Siri Remote, fed into the game's own input paths once a frame, before Minecraft::update:
//   - keys through Keyboard::feed, with the key codes the game already uses on Android (Options::initDefaultValues): the D-pad codes for movement and
//     menus, 102 / 103 destroy / use, 99 / 4 the hotbar, 100 the inventory, 255 pause (Minecraft::tickInput, Gui::handleKeyPressed, Screen::keyPressed);
//   - the left stick into Controller's first stick (XperiaPlayInput::tick moves the player by it with TVTWEAKS), the right stick into its second,
//     which ControllerTurnInput turns the camera by (its joystick mode with TVTWEAKS);
//   - in menus, a cursor: Mouse::feed moves and clicks as the SDL build's mouse does, and the D-pad steps through a screen's buttons as on the Xperia Play.
// Controllers map by position, as on an Xbox pad (bottom A, right B, left X, top Y); a Nintendo pad's labels are turned to match (TVPort's dm/host/pad_apple.h).
// The remote is for menus: its touch surface moves the cursor, a click clicks, Back goes back. Its presses arrive through UIKit (tv_input_press).
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import "TVInput.h"
#import "GameViewController.h"
#include <NinecraftApp.hpp>
#include <Options.hpp>
#include <input/Mouse.hpp>
#include <input/Keyboard.hpp>
#include <input/Controller.hpp>
#include <gui/screens/Touch_StartMenuScreen.hpp>
#include <gui/screens/StartMenuScreen.hpp>
#include <entity/LocalPlayer.hpp>
#include <math.h>
#include <string>
#include <vector>
#include <sstream>
#include <typeinfo>

enum { KEY_NEXT_SLOT = 4, KEY_PREV_SLOT = 99, KEY_INVENTORY = 100, KEY_PAUSE = 255 };
static const float DEAD = 0.15f;           // stick dead zone
static const float CURSOR_SPEED = 1500.f;  // pixels a second at full tilt
static const float TURN_GAIN = 1.5f;       // right stick to ControllerTurnInput
enum Mode { MODE_NONE, MODE_GAME, MODE_MENU };

struct Pad {
    bool a, b, x, y, lb, rb, lt, rt, menu, options, l3, r3, up, down, left, right;
    float lx, ly, rx, ry;
};

static Mode g_mode = MODE_NONE;
static Pad g_prev;                 // last frame's controller state, for presses
static bool g_held[256];           // keys this file holds down in the game
static bool g_suspended;
static UIView *g_view;
static CAShapeLayer *g_cursor;
static CGPoint g_pos;              // the cursor, in the game's pixels (the drawable)
static bool g_cursorShown;         // the cursor is in use; after a D-pad step it hides and A presses the selected button instead
static bool g_mouseDown;
static int g_lateKey = -1, g_lateFrames;   // a key to press a frame later (tv_input_tap_later)
static double g_remoteSelectAt;    // when the remote's GameController click last changed: its UIKit press within 0.1 s is the same click

static NinecraftApp *game(void) { return tv_game(); }
static double now(void) { return CACurrentMediaTime(); }

static void key(int code, bool down) {
    if (code < 0 || code > 255 || g_held[code] == down) return;
    g_held[code] = down;
    Keyboard::feed((uint8_t)code, down ? 1 : 0);
}
static void tap(int code) {
    Keyboard::feed((uint8_t)code, 1);
    Keyboard::feed((uint8_t)code, 0);
}
static void release_all(void) {
    for (int i = 0; i < 256; i++) if (g_held[i]) key(i, false);
    Controller::stickValuesX[0] = Controller::stickValuesY[0] = 0;
    Controller::stickValuesX[1] = Controller::stickValuesY[1] = 0;
    Controller::isTouchedValues[0] = Controller::isTouchedValues[1] = 0;
    if (g_mouseDown) { Mouse::feed(1, 0, (int16_t)g_pos.x, (int16_t)g_pos.y); g_mouseDown = false; }
}

static float axis(float v) { return fabsf(v) < DEAD ? 0.f : v; }

static bool labelled(GCController *c) {   // TVPort's dm_pad_labelled
    NSString *k = c.productCategory;
    return [k isEqualToString:@"Switch Pro Controller"] || [k containsString:@"Joy-Con"];
}

static GCExtendedGamepad *pad(void) {
    GCController *current = GCController.current;
    if (current.extendedGamepad) return current.extendedGamepad;
    for (GCController *c in GCController.controllers) if (c.extendedGamepad) return c.extendedGamepad;
    return nil;
}
static GCMicroGamepad *remote(void) {
    for (GCController *c in GCController.controllers) if (!c.extendedGamepad && c.microGamepad) return c.microGamepad;
    return nil;
}

static Pad read_pad(GCExtendedGamepad *g) {
    Pad p = {};
    if (!g) return p;
    GCControllerButtonInput *a = g.buttonA, *b = g.buttonB, *x = g.buttonX, *y = g.buttonY;
    if (labelled(g.controller)) { GCControllerButtonInput *t = a; a = b; b = t; t = x; x = y; y = t; }   // Nintendo labels to positions
    p.a = a.isPressed; p.b = b.isPressed; p.x = x.isPressed; p.y = y.isPressed;
    p.lb = g.leftShoulder.isPressed; p.rb = g.rightShoulder.isPressed;
    p.lt = g.leftTrigger.value > 0.3f; p.rt = g.rightTrigger.value > 0.3f;
    p.menu = g.buttonMenu.isPressed; p.options = g.buttonOptions.isPressed;
    p.l3 = g.leftThumbstickButton.isPressed; p.r3 = g.rightThumbstickButton.isPressed;
    p.up = g.dpad.up.isPressed; p.down = g.dpad.down.isPressed; p.left = g.dpad.left.isPressed; p.right = g.dpad.right.isPressed;
    p.lx = axis(g.leftThumbstick.xAxis.value); p.ly = axis(g.leftThumbstick.yAxis.value);
    p.rx = axis(g.rightThumbstick.xAxis.value); p.ry = axis(g.rightThumbstick.yAxis.value);
    return p;
}

#define PRESSED(field) (now.field && !g_prev.field)
#define RELEASED(field) (!now.field && g_prev.field)

static void show_cursor(bool shown) {
    if (g_cursorShown == shown) return;
    g_cursorShown = shown;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    g_cursor.hidden = !shown || g_mode != MODE_MENU;
    [CATransaction commit];
}

static void move_cursor(float vx, float vy, double dt) {
    if (vx == 0 && vy == 0) return;
    NinecraftApp *mc = game();
    show_cursor(true);
    float speed = CURSOR_SPEED * powf(fminf(1.f, sqrtf(vx * vx + vy * vy)), 0.5f);   // fine control near the centre, quick at full tilt
    float len = sqrtf(vx * vx + vy * vy);
    CGPoint old = g_pos;
    g_pos.x = fmax(0, fmin(mc->width - 1, g_pos.x + vx / len * speed * dt));
    g_pos.y = fmax(0, fmin(mc->height - 1, g_pos.y - vy / len * speed * dt));   // stick up is +y, the screen's y grows downward
    int16_t dx = (int16_t)(g_pos.x - old.x), dy = (int16_t)(g_pos.y - old.y);
    Mouse::feed(0, 0, (int16_t)g_pos.x, (int16_t)g_pos.y, dx, dy);   // a move: hover and drags (holding A) follow it
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    g_cursor.position = g_pos;   // the view is 1920x1080 points at scale 1, the same as the game's pixels
    [CATransaction commit];
}

static void click(bool down) {
    if (down == g_mouseDown) return;
    g_mouseDown = down;
    Mouse::feed(1, down ? 1 : 0, (int16_t)g_pos.x, (int16_t)g_pos.y);
}

// A in a menu: a click at the cursor, or, after the D-pad chose a button, that button (Screen::keyPressed's keyMenuOk)
static void menu_accept(bool down, bool up) {
    NinecraftApp *mc = game();
    if (g_cursorShown) { if (down) click(true); if (up) click(false); }
    else if (down) tap(mc->options.keyMenuOk.keyCode);
}

static void game_frame(const Pad &now) {
    NinecraftApp *mc = game();
    Options &o = mc->options;
    Controller::stickValuesX[0] = now.lx;
    Controller::stickValuesY[0] = now.ly;
    // ControllerTurnInput's joystick mode turns by the value past a 0.1 dead zone: squared for fine aim near the centre, and up to about 200 degrees a
    // second at full tilt (measured: 0.9 unscaled gave 100 a second). Its y is the Xperia touchpad's, which grows downward, so stick up (+y) looks up as it is
    Controller::stickValuesX[1] = TURN_GAIN * now.rx * fabsf(now.rx);
    Controller::stickValuesY[1] = TURN_GAIN * now.ry * fabsf(now.ry);
    Controller::isTouchedValues[1] = now.rx != 0 || now.ry != 0;
    key(o.keyForward.keyCode, now.up);
    key(o.keyBack.keyCode, now.down);
    key(o.keyLeft.keyCode, now.left);
    key(o.keyRight.keyCode, now.right);
    key(o.keyJump.keyCode, now.a);
    key(o.keyDestroy.keyCode, now.rt);
    key(o.keyUse.keyCode, now.lt);
    if (PRESSED(b) || PRESSED(l3)) Controller::isTouchedValues[0] = 1;   // XperiaPlayInput toggles sneaking when its left touchpad is touched
    if (RELEASED(b) || RELEASED(l3)) Controller::isTouchedValues[0] = 0;
    if (PRESSED(x)) tap(KEY_INVENTORY);
    if (PRESSED(y)) tap(o.keyCrafting.keyCode);
    if (PRESSED(lb)) tap(KEY_PREV_SLOT);
    if (PRESSED(rb)) tap(KEY_NEXT_SLOT);
    if (PRESSED(menu)) tap(KEY_PAUSE);
    if (PRESSED(options)) o.toggle(&Options::Option::THIRD_PERSON, 0);
}

static void menu_frame(const Pad &now, double dt) {
    NinecraftApp *mc = game();
    Options &o = mc->options;
    move_cursor(now.lx, now.ly, dt);
    GCMicroGamepad *r = remote();
    if (r) move_cursor(axis(r.dpad.xAxis.value), axis(r.dpad.yAxis.value), dt);   // the touch surface, as a stick (reportsAbsoluteDpadValues is off)
    if (PRESSED(up) || PRESSED(left)) { show_cursor(false); tap(o.keyMenuPrevious.keyCode); }
    if (PRESSED(down) || PRESSED(right)) { show_cursor(false); tap(o.keyMenuNext.keyCode); }
    menu_accept(PRESSED(a), RELEASED(a));
    if (PRESSED(b) || PRESSED(menu)) { release_all(); mc->handleBack(0); }
}

// A test script (TVCRAFT_SCRIPT, set at launch) plays controller and cursor input through the same paths as a real controller, for the simulator,
// which has no controller to drive: "<seconds> <action> [args]" steps separated by ';'. Actions: pad <button or axis> <value> (a b x y lb rb lt rt menu
// options l3 r3 up down left right lx ly rx ry), cursor <x> <y> (game pixels), mouse <1|0> (A in a menu), back, log (the mode and screen to the log)
struct Step { double t; std::string op, field; float a, b; };
static std::vector<Step> g_script;
static size_t g_step;
static double g_scriptTime;
static Pad g_virtual;

static void script_parse(const char *text) {
    std::stringstream all(text);
    std::string item;
    while (std::getline(all, item, ';')) {
        std::stringstream in(item);
        Step s = {0, "", "", 0, 0};
        if (!(in >> s.t >> s.op)) continue;
        if (s.op == "pad") in >> s.field >> s.a;
        else in >> s.a >> s.b;
        g_script.push_back(s);
    }
    fprintf(stderr, "input: test script with %zu steps\n", g_script.size());
}

static bool *pad_button(Pad &p, const std::string &f) {
    if (f == "a") return &p.a; if (f == "b") return &p.b; if (f == "x") return &p.x; if (f == "y") return &p.y;
    if (f == "lb") return &p.lb; if (f == "rb") return &p.rb; if (f == "lt") return &p.lt; if (f == "rt") return &p.rt;
    if (f == "menu") return &p.menu; if (f == "options") return &p.options; if (f == "l3") return &p.l3; if (f == "r3") return &p.r3;
    if (f == "up") return &p.up; if (f == "down") return &p.down; if (f == "left") return &p.left; if (f == "right") return &p.right;
    return nullptr;
}
static float *pad_axis(Pad &p, const std::string &f) {
    if (f == "lx") return &p.lx; if (f == "ly") return &p.ly; if (f == "rx") return &p.rx; if (f == "ry") return &p.ry;
    return nullptr;
}

static void script_run(double dt) {
    if (g_step >= g_script.size()) return;
    g_scriptTime += dt;
    while (g_step < g_script.size() && g_script[g_step].t <= g_scriptTime) {
        const Step &s = g_script[g_step++];
        NinecraftApp *mc = game();
        if (s.op == "pad") {
            if (bool *b = pad_button(g_virtual, s.field)) *b = s.a != 0;
            else if (float *a = pad_axis(g_virtual, s.field)) *a = s.a;
        } else if (s.op == "cursor") {
            show_cursor(true);
            g_pos = CGPointMake(s.a, s.b);
            Mouse::feed(0, 0, (int16_t)s.a, (int16_t)s.b, 0, 0);
            g_cursor.position = g_pos;
        } else if (s.op == "mouse") {
            click(s.a != 0);
        } else if (s.op == "back") {
            mc->handleBack(0);
        } else if (s.op == "log") {
            Screen *screen = mc->currentScreen.get();
            fprintf(stderr, "input: script log at %.1f s: mode %d, screen %s, level %s", g_scriptTime, g_mode, screen ? typeid(*screen).name() : "none", mc->level ? "yes" : "no");
            if (mc->player) fprintf(stderr, ", player at %.1f %.1f %.1f, yaw %.1f, pitch %.1f", mc->player->posX, mc->player->posY, mc->player->posZ, mc->player->yaw, mc->player->pitch);
            fprintf(stderr, "\n");
        }
    }
}

static Pad merged(Pad p) {   // the script's virtual pad on top of the real one
    const char *buttons[] = {"a", "b", "x", "y", "lb", "rb", "lt", "rt", "menu", "options", "l3", "r3", "up", "down", "left", "right"};
    for (const char *f : buttons) *pad_button(p, f) = *pad_button(p, f) || *pad_button(g_virtual, f);
    for (const char *f : {"lx", "ly", "rx", "ry"}) if (*pad_axis(g_virtual, f) != 0) *pad_axis(p, f) = *pad_axis(g_virtual, f);
    return p;
}

static void configure(GCController *c) {
    fprintf(stderr, "input: %s connected (%s)\n", c.vendorName.UTF8String ?: "a controller", c.extendedGamepad ? "gamepad" : c.microGamepad ? "remote" : "other");
    if (c.microGamepad) { c.microGamepad.reportsAbsoluteDpadValues = NO; c.microGamepad.allowsRotation = YES; }
    if (!c.extendedGamepad && c.microGamepad) c.microGamepad.buttonA.valueChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL pressed) {
        (void)b; (void)v;
        g_remoteSelectAt = now();
        if (getenv("TVCRAFT_INPUT_LOG")) fprintf(stderr, "input: remote click %s (mode %d)\n", pressed ? "down" : "up", g_mode);
        if (g_suspended || g_mode != MODE_MENU) return;
        menu_accept(pressed, !pressed);
    };
    for (NSString *b in @[GCInputButtonHome, GCInputButtonShare]) c.physicalInputProfile.buttons[b].preferredSystemGestureState = GCSystemGestureStateDisabled;
    if (getenv("TVCRAFT_INPUT_LOG")) {   // every raw element the controller reports, to see what a press really sends
        fprintf(stderr, "input: %s: category %s, extended %d, micro %d, elements %lu\n", c.vendorName.UTF8String ?: "?", c.productCategory.UTF8String ?: "?",
                c.extendedGamepad != nil, c.microGamepad != nil, (unsigned long)c.physicalInputProfile.allElements.count);
        NSString *name = c.vendorName ?: @"?";
        c.physicalInputProfile.valueDidChangeHandler = ^(GCPhysicalInputProfile *profile, GCControllerElement *element) {
            (void)profile;
            NSString *what = element.localizedName ?: element.aliases.anyObject ?: @"?";
            if ([element isKindOfClass:GCControllerButtonInput.class])
                fprintf(stderr, "input: raw %s: button %s %.2f\n", name.UTF8String, what.UTF8String, ((GCControllerButtonInput *)element).value);
            else if ([element isKindOfClass:GCControllerDirectionPad.class])
                fprintf(stderr, "input: raw %s: pad %s %.2f %.2f\n", name.UTF8String, what.UTF8String, ((GCControllerDirectionPad *)element).xAxis.value, ((GCControllerDirectionPad *)element).yAxis.value);
            else fprintf(stderr, "input: raw %s: %s\n", name.UTF8String, what.UTF8String);
        };
    }
}

void tv_input_attach(UIView *view) {
    g_view = view;
    g_cursor = [CAShapeLayer layer];
    g_cursor.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(-14, -14, 28, 28)].CGPath;
    g_cursor.fillColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
    g_cursor.strokeColor = UIColor.blackColor.CGColor;
    g_cursor.lineWidth = 3;
    g_cursor.hidden = YES;
    g_cursor.zPosition = 10;
    [view.layer addSublayer:g_cursor];
    g_pos = CGPointMake(view.bounds.size.width / 2, view.bounds.size.height / 2);
    g_cursor.position = g_pos;
    if (const char *script = getenv("TVCRAFT_SCRIPT")) script_parse(script);
    for (GCController *c in GCController.controllers) configure(c);   // those already connected at launch
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        configure(n.object);
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidDisconnectNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        GCController *c = n.object;
        fprintf(stderr, "input: %s disconnected\n", c.vendorName.UTF8String ?: "a controller");
        release_all();
        g_prev = Pad{};
    }];
}

void tv_input_tap_later(int code) {
    g_lateKey = code;
    g_lateFrames = 2;   // the game handles a frame's keys before its text (Screen::updateEvents): typed text needs a frame of its own first
}

void tv_input_frame(double dt) {
    NinecraftApp *mc = game();
    if (!mc) return;
    if (g_lateKey >= 0 && --g_lateFrames <= 0) { tap(g_lateKey); g_lateKey = -1; }
    script_run(dt);
    Pad now = merged(read_pad(pad()));
    if (g_suspended) { g_prev = now; return; }
    Mode mode = (mc->currentScreen || !mc->level || !mc->player) ? MODE_MENU : MODE_GAME;
    if (mode != g_mode) {
        release_all();
        g_mode = mode;
        g_prev = now;   // a button held across the switch (A on "Play", Menu to pause) does not act again on the other side
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        g_cursor.hidden = mode != MODE_MENU || !g_cursorShown;
        [CATransaction commit];
        return;
    }
    if (getenv("TVCRAFT_INPUT_LOG") && memcmp(&now, &g_prev, sizeof now)) fprintf(stderr, "input: [%s, mode %d] pad a%d b%d x%d y%d up%d down%d menu%d l(%.2f %.2f) r(%.2f %.2f)\n",
        pad() ? pad().controller.vendorName.UTF8String : "no pad", mode, now.a, now.b, now.x, now.y, now.up, now.down, now.menu, now.lx, now.ly, now.rx, now.ry);
    if (mode == MODE_GAME) game_frame(now);
    else menu_frame(now, dt);
    g_prev = now;
}

void tv_input_press(UIPressType type, BOOL down) {
    NinecraftApp *mc = game();
    if (getenv("TVCRAFT_INPUT_LOG")) fprintf(stderr, "input: UIKit press %ld %s (mode %d)\n", (long)type, down ? "down" : "up", g_mode);
    if (!mc || g_suspended) return;
    Options &o = mc->options;
    if (g_mode == MODE_GAME) {   // the simulator's keyboard (arrows, return) and a remote's clicks walk and jump; Play/Pause pauses
        switch (type) {
            case UIPressTypeUpArrow: key(o.keyForward.keyCode, down); break;
            case UIPressTypeDownArrow: key(o.keyBack.keyCode, down); break;
            case UIPressTypeLeftArrow: key(o.keyLeft.keyCode, down); break;
            case UIPressTypeRightArrow: key(o.keyRight.keyCode, down); break;
            case UIPressTypeSelect: key(o.keyJump.keyCode, down); break;
            case UIPressTypePlayPause: if (down) tap(KEY_PAUSE); break;
            default: break;
        }
        return;
    }
    switch (type) {
        case UIPressTypeUpArrow: case UIPressTypeLeftArrow: if (down) { show_cursor(false); tap(o.keyMenuPrevious.keyCode); } break;
        case UIPressTypeDownArrow: case UIPressTypeRightArrow: if (down) { show_cursor(false); tap(o.keyMenuNext.keyCode); } break;
        case UIPressTypeSelect: if (now() - g_remoteSelectAt > 0.1) menu_accept(down, !down); break;   // not the remote's click GameController already took
        case UIPressTypePlayPause: if (down) { release_all(); mc->handleBack(0); } break;
        default: break;
    }
}

void tv_input_suspend(BOOL suspended) {
    if (suspended) release_all();
    g_suspended = suspended;
}

BOOL tv_input_at_root(void) {
    NinecraftApp *mc = game();
    if (!mc || mc->level) return NO;
    Screen *s = mc->currentScreen.get();
    return dynamic_cast<Touch::StartMenuScreen *>(s) != nullptr || dynamic_cast<StartMenuScreen *>(s) != nullptr;
}
