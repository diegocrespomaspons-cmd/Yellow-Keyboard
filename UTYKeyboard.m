// UTYKeyboard.m  (v2: diagnóstico de lecturas del runner + notificación de conexión)
// LiveContainer tweak: hace que el teclado físico del iPad se vea como un
// mando (GCController) para el runner de GameMaker de Undertale Yellow.
//
// Mapeo (igual que en PC):
//   Flechas / WASD   -> D-pad + stick izquierdo
//   Z / Enter / Space -> A   (Confirmar)
//   X / Shift         -> B   (Cancelar)
//   C / Ctrl          -> Y   (Menú)
//   Esc               -> Menu/Start
//
// Diagnóstico: escribe Documents/UTYKeyboard.log dentro del contenedor del juego.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <objc/message.h>

#pragma mark - Estado de teclas

static BOOL kUp, kDown, kLeft, kRight;
static BOOL kA, kB, kX, kY, kMenu;

#pragma mark - Log

static NSString *UTYLogPath(void) {
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (!docs) docs = NSHomeDirectory();
    return [docs stringByAppendingPathComponent:@"UTYKeyboard.log"];
}

static void UTYLog(NSString *fmt, ...) {
    static NSUInteger lines = 0;
    if (lines > 400) return; // no llenar el disco
    lines++;
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [NSDate date], msg];
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:UTYLogPath()];
    if (!h) {
        [line writeToFile:UTYLogPath() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        return;
    }
    [h seekToEndOfFile];
    [h writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}

static void UTYLogOnce(NSString *msg) {
    static NSMutableSet *seen;
    if (!seen) seen = [NSMutableSet new];
    if ([seen containsObject:msg]) return;
    [seen addObject:msg];
    UTYLog(@"%@", msg);
}

#pragma mark - Objeto "agujero negro": responde a todo devolviendo nil/0

@interface UTYNilObject : NSObject
@end
@implementation UTYNilObject
- (BOOL)respondsToSelector:(SEL)sel { return YES; }
- (NSMethodSignature *)methodSignatureForSelector:(SEL)sel {
    NSMethodSignature *sig = [super methodSignatureForSelector:sel];
    if (sig) return sig;
    return [NSMethodSignature signatureWithObjCTypes:"@@:"];
}
- (void)forwardInvocation:(NSInvocation *)inv {
    UTYLogOnce([NSString stringWithFormat:@"selector desconocido en %@: %@", NSStringFromClass([self class]), NSStringFromSelector(inv.selector)]);
    id nilObj = nil;
    if (strcmp(inv.methodSignature.methodReturnType, "v") != 0) {
        [inv setReturnValue:&nilObj];
    }
}
@end

#pragma mark - Elementos falsos del mando

@interface UTYButton : UTYNilObject
@property (nonatomic, assign) BOOL *flag;
@end
@implementation UTYButton
- (float)value { UTYLogOnce(@"runner lee button.value"); return (self.flag && *self.flag) ? 1.0f : 0.0f; }
- (BOOL)isPressed { UTYLogOnce(@"runner lee button.isPressed"); return self.flag && *self.flag; }
- (BOOL)pressed { return [self isPressed]; }
- (BOOL)isTouched { return [self isPressed]; }
- (BOOL)touched { return [self isPressed]; }
- (BOOL)isAnalog { return NO; }
- (BOOL)isKindOfClass:(Class)c { return c == [GCControllerButtonInput class] || [super isKindOfClass:c]; }
@end

@interface UTYAxis : UTYNilObject
@property (nonatomic, assign) BOOL *neg;
@property (nonatomic, assign) BOOL *pos;
@end
@implementation UTYAxis
- (float)value {
    UTYLogOnce(@"runner lee axis.value");
    float v = 0;
    if (self.pos && *self.pos) v += 1.0f;
    if (self.neg && *self.neg) v -= 1.0f;
    return v;
}
- (BOOL)isAnalog { return NO; }
- (BOOL)isKindOfClass:(Class)c { return c == [GCControllerAxisInput class] || [super isKindOfClass:c]; }
@end

@interface UTYDpad : UTYNilObject
@property (nonatomic, strong) UTYAxis *xAxis;
@property (nonatomic, strong) UTYAxis *yAxis;
@property (nonatomic, strong) UTYButton *up, *down, *left, *right;
@end
@implementation UTYDpad
- (instancetype)init {
    if ((self = [super init])) {
        _xAxis = [UTYAxis new]; _xAxis.neg = &kLeft; _xAxis.pos = &kRight;
        _yAxis = [UTYAxis new]; _yAxis.neg = &kDown; _yAxis.pos = &kUp; // GC: +y = arriba
        _up = [UTYButton new];    _up.flag = &kUp;
        _down = [UTYButton new];  _down.flag = &kDown;
        _left = [UTYButton new];  _left.flag = &kLeft;
        _right = [UTYButton new]; _right.flag = &kRight;
    }
    return self;
}
- (BOOL)isKindOfClass:(Class)c { return c == [GCControllerDirectionPad class] || [super isKindOfClass:c]; }
@end

@interface UTYZeroDpad : UTYDpad
@end
@implementation UTYZeroDpad
- (instancetype)init {
    if ((self = [super init])) {
        static BOOL never = NO;
        self.xAxis.neg = &never; self.xAxis.pos = &never;
        self.yAxis.neg = &never; self.yAxis.pos = &never;
        self.up.flag = &never; self.down.flag = &never;
        self.left.flag = &never; self.right.flag = &never;
    }
    return self;
}
@end

@interface UTYGamepad : UTYNilObject
@property (nonatomic, strong) UTYButton *buttonA, *buttonB, *buttonX, *buttonY;
@property (nonatomic, strong) UTYButton *buttonMenu, *buttonOptions, *buttonHome;
@property (nonatomic, strong) UTYButton *leftShoulder, *rightShoulder, *leftTrigger, *rightTrigger;
@property (nonatomic, strong) UTYButton *leftThumbstickButton, *rightThumbstickButton;
@property (nonatomic, strong) UTYDpad *dpad;
@property (nonatomic, strong) UTYDpad *leftThumbstick;
@property (nonatomic, strong) UTYDpad *rightThumbstick;
@end
@implementation UTYGamepad
- (UTYButton *)buttonA { UTYLogOnce(@"runner lee gamepad.buttonA"); return _buttonA; }
- (UTYDpad *)dpad { UTYLogOnce(@"runner lee gamepad.dpad"); return _dpad; }
- (UTYDpad *)leftThumbstick { UTYLogOnce(@"runner lee gamepad.leftThumbstick"); return _leftThumbstick; }
- (instancetype)init {
    if ((self = [super init])) {
        static BOOL never = NO;
        UTYButton *(^btn)(BOOL *) = ^UTYButton *(BOOL *f) { UTYButton *b = [UTYButton new]; b.flag = f; return b; };
        _buttonA = btn(&kA);
        _buttonB = btn(&kB);
        _buttonX = btn(&kX);
        _buttonY = btn(&kY);
        _buttonMenu = btn(&kMenu);
        _buttonOptions = btn(&never);
        _buttonHome = btn(&never);
        _leftShoulder = btn(&never);
        _rightShoulder = btn(&never);
        _leftTrigger = btn(&never);
        _rightTrigger = btn(&never);
        _leftThumbstickButton = btn(&never);
        _rightThumbstickButton = btn(&never);
        _dpad = [UTYDpad new];
        _leftThumbstick = [UTYDpad new];
        _rightThumbstick = [UTYZeroDpad new];
    }
    return self;
}
- (BOOL)isKindOfClass:(Class)c { return c == [GCExtendedGamepad class] || [super isKindOfClass:c]; }
@end

@interface UTYController : UTYNilObject
@property (nonatomic, strong) UTYGamepad *pad;
@property (nonatomic, assign) NSInteger playerIndex;
@property (nonatomic, copy) void (^controllerPausedHandler)(id);
+ (instancetype)shared;
@end
@implementation UTYController
- (void)setPlayerIndex:(NSInteger)idx { UTYLogOnce([NSString stringWithFormat:@"runner asignó playerIndex=%ld", (long)idx]); _playerIndex = idx; }
+ (instancetype)shared {
    static UTYController *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [UTYController new]; s.pad = [UTYGamepad new]; s.playerIndex = 0; });
    return s;
}
- (id)extendedGamepad { UTYLogOnce(@"runner lee controller.extendedGamepad"); return self.pad; }
- (id)gamepad { UTYLogOnce(@"runner lee controller.gamepad"); return self.pad; }
- (id)microGamepad { return nil; }
- (id)physicalInputProfile { return self.pad; }
- (NSString *)vendorName { return @"UTY Keyboard"; }
- (NSString *)productCategory { return @"Extended Gamepad"; }
- (BOOL)isAttachedToDevice { return YES; }
- (BOOL)attachedToDevice { return YES; }
- (BOOL)isSnapshot { return NO; }
- (dispatch_queue_t)handlerQueue { return dispatch_get_main_queue(); }
- (BOOL)isKindOfClass:(Class)c { return c == [GCController class] || [super isKindOfClass:c]; }
@end

#pragma mark - Hook: +[GCController controllers]

static NSArray *(*orig_controllers)(id, SEL);
static NSUInteger gControllersCalls = 0;

static NSArray *uty_controllers(id self, SEL _cmd) {
    NSArray *real = orig_controllers ? orig_controllers(self, _cmd) : @[];
    if (!real) real = @[];
    gControllersCalls++;
    if (gControllersCalls == 1) UTYLog(@"El runner consultó [GCController controllers] por primera vez (reales: %lu)", (unsigned long)real.count);
    if (gControllersCalls % 3600 == 0) UTYLog(@"controllers consultado %lu veces", (unsigned long)gControllersCalls);
    return [real arrayByAddingObject:[UTYController shared]];
}

#pragma mark - Teclas -> estado

static void uty_handleKeyCode(long code, BOOL down, NSString *source) {
    static NSMutableSet *loggedSources;
    if (!loggedSources) loggedSources = [NSMutableSet new];
    if (![loggedSources containsObject:source]) {
        [loggedSources addObject:source];
        UTYLog(@"Primer evento de teclado recibido por vía: %@ (keyCode=%ld)", source, code);
    }
    static int logged = 0;
    if (logged < 40) { logged++; UTYLog(@"key %ld %@ (%@)", code, down ? @"DOWN" : @"UP", source); }

    switch (code) {
        case UIKeyboardHIDUsageKeyboardUpArrow:    case UIKeyboardHIDUsageKeyboardW: kUp = down; break;
        case UIKeyboardHIDUsageKeyboardDownArrow:  case UIKeyboardHIDUsageKeyboardS: kDown = down; break;
        case UIKeyboardHIDUsageKeyboardLeftArrow:  case UIKeyboardHIDUsageKeyboardA: kLeft = down; break;
        case UIKeyboardHIDUsageKeyboardRightArrow: case UIKeyboardHIDUsageKeyboardD: kRight = down; break;

        case UIKeyboardHIDUsageKeyboardZ:
        case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        case UIKeyboardHIDUsageKeypadEnter:
        case UIKeyboardHIDUsageKeyboardSpacebar:
            kA = down; break;

        case UIKeyboardHIDUsageKeyboardX:
        case UIKeyboardHIDUsageKeyboardLeftShift:
        case UIKeyboardHIDUsageKeyboardRightShift:
            kB = down; break;

        case UIKeyboardHIDUsageKeyboardC:
        case UIKeyboardHIDUsageKeyboardLeftControl:
        case UIKeyboardHIDUsageKeyboardRightControl:
            kY = down; break;

        case UIKeyboardHIDUsageKeyboardEscape:
            kMenu = down; break;
        default: break;
    }
}

static void uty_handlePresses(NSSet<UIPress *> *presses, NSString *source) {
    for (UIPress *p in presses) {
        UIKey *key = nil;
        if (@available(iOS 13.4, *)) key = p.key;
        if (!key) continue;
        if (p.phase == UIPressPhaseBegan) uty_handleKeyCode((long)key.keyCode, YES, source);
        else if (p.phase == UIPressPhaseEnded || p.phase == UIPressPhaseCancelled) uty_handleKeyCode((long)key.keyCode, NO, source);
    }
}

#pragma mark - Hook: -[UIApplication sendEvent:]

static void (*orig_sendEvent)(id, SEL, UIEvent *);
static void uty_sendEvent(id self, SEL _cmd, UIEvent *event) {
    if (event.type == UIEventTypePresses && [event isKindOfClass:[UIPressesEvent class]]) {
        uty_handlePresses(((UIPressesEvent *)event).allPresses, @"sendEvent");
    }
    if (orig_sendEvent) orig_sendEvent(self, _cmd, event);
}

#pragma mark - Hook: pressesBegan/Ended/Cancelled en UIWindow y UIApplication

typedef void (*PressesIMP)(id, SEL, NSSet *, UIPressesEvent *);

#define UTY_PRESSES_HOOK(NAME, SELNAME, SRC)                                          \
    static PressesIMP orig_##NAME;                                                    \
    static void uty_##NAME(id self, SEL _cmd, NSSet *presses, UIPressesEvent *event) { \
        uty_handlePresses(presses, SRC);                                              \
        if (orig_##NAME) orig_##NAME(self, _cmd, presses, event);                     \
    }

UTY_PRESSES_HOOK(winBegan,  pressesBegan:withEvent:,     @"UIWindow.pressesBegan")
UTY_PRESSES_HOOK(winEnded,  pressesEnded:withEvent:,     @"UIWindow.pressesEnded")
UTY_PRESSES_HOOK(winCancel, pressesCancelled:withEvent:, @"UIWindow.pressesCancelled")
UTY_PRESSES_HOOK(appBegan,  pressesBegan:withEvent:,     @"UIApplication.pressesBegan")
UTY_PRESSES_HOOK(appEnded,  pressesEnded:withEvent:,     @"UIApplication.pressesEnded")
UTY_PRESSES_HOOK(appCancel, pressesCancelled:withEvent:, @"UIApplication.pressesCancelled")

static void uty_swizzleInstance(Class cls, SEL sel, IMP newImp, IMP *origOut) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { UTYLog(@"No existe -%@ en %@", NSStringFromSelector(sel), cls); return; }
    IMP orig = method_getImplementation(m);
    // Si el método viene heredado, agregarlo a la clase para no tocar la superclase
    if (class_addMethod(cls, sel, newImp, method_getTypeEncoding(m))) {
        *origOut = orig;
    } else {
        *origOut = method_setImplementation(m, newImp);
    }
}

#pragma mark - Hook privado de respaldo: -[UIApplication handleKeyUIEvent:]

static void (*orig_handleKeyUIEvent)(id, SEL, id);
static void uty_handleKeyUIEvent(id self, SEL _cmd, id event) {
    @try {
        SEL selCode = NSSelectorFromString(@"_keyCode");
        SEL selDown = NSSelectorFromString(@"_isKeyDown");
        if ([event respondsToSelector:selCode] && [event respondsToSelector:selDown]) {
            long code = ((long (*)(id, SEL))objc_msgSend)(event, selCode);
            BOOL down = ((BOOL (*)(id, SEL))objc_msgSend)(event, selDown);
            uty_handleKeyCode(code, down, @"handleKeyUIEvent");
        }
    } @catch (NSException *e) {
        UTYLog(@"handleKeyUIEvent excepción: %@", e);
    }
    if (orig_handleKeyUIEvent) orig_handleKeyUIEvent(self, _cmd, event);
}

#pragma mark - Instalación

__attribute__((constructor))
static void uty_init(void) {
    UTYLog(@"==== UTYKeyboard cargado (proceso: %@) ====", [NSProcessInfo processInfo].processName);

    // 1) Mando falso
    Method m = class_getClassMethod([GCController class], @selector(controllers));
    if (m) {
        orig_controllers = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)uty_controllers);
        UTYLog(@"Hook +[GCController controllers] instalado");
    } else {
        UTYLog(@"ERROR: no se encontró +[GCController controllers]");
    }

    // 2) Captura de teclado (varias vías; setear un BOOL es idempotente, así que no importa si se duplican)
    uty_swizzleInstance([UIApplication class], @selector(sendEvent:), (IMP)uty_sendEvent, (IMP *)&orig_sendEvent);
    uty_swizzleInstance([UIWindow class], @selector(pressesBegan:withEvent:),     (IMP)uty_winBegan,  (IMP *)&orig_winBegan);
    uty_swizzleInstance([UIWindow class], @selector(pressesEnded:withEvent:),     (IMP)uty_winEnded,  (IMP *)&orig_winEnded);
    uty_swizzleInstance([UIWindow class], @selector(pressesCancelled:withEvent:), (IMP)uty_winCancel, (IMP *)&orig_winCancel);
    uty_swizzleInstance([UIApplication class], @selector(pressesBegan:withEvent:),     (IMP)uty_appBegan,  (IMP *)&orig_appBegan);
    uty_swizzleInstance([UIApplication class], @selector(pressesEnded:withEvent:),     (IMP)uty_appEnded,  (IMP *)&orig_appEnded);
    uty_swizzleInstance([UIApplication class], @selector(pressesCancelled:withEvent:), (IMP)uty_appCancel, (IMP *)&orig_appCancel);

    SEL hk = NSSelectorFromString(@"handleKeyUIEvent:");
    if (class_getInstanceMethod([UIApplication class], hk)) {
        uty_swizzleInstance([UIApplication class], hk, (IMP)uty_handleKeyUIEvent, (IMP *)&orig_handleKeyUIEvent);
    }
    UTYLog(@"Hooks de teclado instalados");

    // 3) Avisar al runner que "se conectó" un mando (siempre; el sondeo por sí solo no basta si
    //    el runner solo asigna slots al recibir la notificación)
    for (NSNumber *delay in @[@3.0, @8.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GCControllerDidConnectNotification
                                                                object:[UTYController shared]];
            UTYLog(@"Notificación GCControllerDidConnect enviada a los %@s (controllers sondeado %lu veces)", delay, (unsigned long)gControllersCalls);
        });
    }
}
    });
}
