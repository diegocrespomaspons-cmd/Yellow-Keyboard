// UTYKeyboard.m  (v6: v5 + un solo evento por tecla por frame, sincronizado con la cola del runner)
//
// v5 encolaba ~2 press por frame (ticker a 60 Hz, juego a 30 fps). El runner solo procesa un
// evento por tecla por frame y difiere el resto, así que se acumulaba un backlog y la tecla
// "seguía presionada" después de soltarla. v6 mira la cola del runner y solo encola cuando
// está vacía (es decir, una vez por frame, justo después de que el runner la drenó).
//
// El runner de GameMaker en iOS trata cada evento de tecla como "presionada por un step"
// (diseñado para el teclado virtual, que nunca manda key-up). Por eso v4 solo avanzaba un
// pasito por pulsación. v5 reenvía el press en cada refresco de pantalla mientras la tecla
// siga sostenida, que es lo mismo que hace el overlay táctil del port.
//
// Estrategia v4: el runner de GameMaker expone keyboard_key_press() a GML; internamente
// esa función encola un evento en la cola de IO del motor. Llamamos a esa función interna
// con los códigos de tecla de GameMaker (vk_left=37, ord("Z")=90...), así el juego recibe
// exactamente lo mismo que en PC cuando se presiona una tecla.
// El mando falso de v1-v3 queda desactivado (UTY_FAKE_GAMEPAD 0).
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
#import <QuartzCore/QuartzCore.h>
#import <GameController/GameController.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

#define UTY_FAKE_GAMEPAD 0

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

// Contadores de lecturas (diagnóstico v3)
static NSUInteger gReadsButtonA = 0, gReadsButtonAHigh = 0, gReadsIsPressed = 0, gReadsIsPressedTrue = 0, gReadsAxis = 0, gReadsAxisNonZero = 0;

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
- (float)value {
    UTYLogOnce(@"runner lee button.value");
    BOOL on = self.flag && *self.flag;
    if (self.flag == &kA) { gReadsButtonA++; if (on) gReadsButtonAHigh++; }
    return on ? 1.0f : 0.0f;
}
- (BOOL)isPressed {
    UTYLogOnce(@"runner lee button.isPressed");
    BOOL on = self.flag && *self.flag;
    gReadsIsPressed++; if (on) gReadsIsPressedTrue++;
    return on;
}
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
    gReadsAxis++; if (v != 0) gReadsAxisNonZero++;
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

#pragma mark - Runner: función interna de eventos de teclado

// Direcciones estáticas en el binario AlmoraDarkosen_1_2_33 (port UTY 1.2). Se validan en runtime.
static const uintptr_t kTextVMAddr        = 0x100000000ULL;
static const uintptr_t kKeyEventFnAddr    = 0x1001f2658ULL;   // cola de eventos de teclado (tail-call de F_KeyboardKeyPress)
static const uint32_t  kKeyEventFnInsn0   = 0xa9bc5ff8;       // stp x24, x23, [sp, #-0x40]!
static const uintptr_t kCheckStrAddr      = 0x1004e51e8ULL;   // "keyboard_key_press"
static const uintptr_t kQueueTailAddr     = 0x10073f618ULL;   // puntero a la cola del último evento pendiente
static const uintptr_t kQueueHeadAddr     = 0x10073f620ULL;   // puntero a la cabeza de la cola (0 = vacía)
static volatile uintptr_t *gQueueTail = NULL;
static volatile uintptr_t *gQueueHead = NULL;

typedef void (*UTYKeyEventFn)(int type, long key, long keyRaw, int flags); // type 0 = press, 1 = release
static UTYKeyEventFn gKeyEventFn = NULL;
static BOOL gRunnerLookupDone = NO;

static void uty_locateRunner(void) {
    if (gRunnerLookupDone) return;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "AlmoraDarkosen")) continue;
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!hdr || hdr->magic != MH_MAGIC_64) continue;
        // Buscar __TEXT para calcular el slide real y validar rangos
        const struct load_command *lc = (const struct load_command *)(hdr + 1);
        uintptr_t textVM = 0, textSize = 0, dataVM = 0, dataSize = 0;
        for (uint32_t c = 0; c < hdr->ncmds; c++) {
            if (lc->cmd == LC_SEGMENT_64) {
                const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
                if (strcmp(seg->segname, "__TEXT") == 0) { textVM = seg->vmaddr; textSize = seg->vmsize; }
                if (strcmp(seg->segname, "__DATA") == 0) { dataVM = seg->vmaddr; dataSize = seg->vmsize; }
            }
            lc = (const struct load_command *)((const char *)lc + lc->cmdsize);
        }
        gRunnerLookupDone = YES;
        if (textVM != kTextVMAddr) { UTYLog(@"Runner encontrado pero __TEXT vmaddr=%lx (esperado %lx); no inyecto", (unsigned long)textVM, (unsigned long)kTextVMAddr); return; }
        if (kKeyEventFnAddr >= textVM + textSize || kCheckStrAddr >= textVM + textSize) { UTYLog(@"Direcciones fuera de __TEXT; no inyecto"); return; }
        intptr_t slide = (intptr_t)hdr - (intptr_t)textVM;
        const char *chk = (const char *)(kCheckStrAddr + slide);
        uint32_t insn0 = *(const uint32_t *)(kKeyEventFnAddr + slide);
        if (strncmp(chk, "keyboard_key_press", 18) != 0 || insn0 != kKeyEventFnInsn0) {
            UTYLog(@"Validación falló: str='%.20s' insn0=%08x (esperado %08x). Binario distinto; no inyecto", chk, insn0, kKeyEventFnInsn0);
            return;
        }
        if (kQueueHeadAddr < dataVM || kQueueHeadAddr + 8 > dataVM + dataSize || kQueueTailAddr < dataVM) {
            UTYLog(@"Cola fuera de __DATA (%lx..%lx); no inyecto", (unsigned long)dataVM, (unsigned long)(dataVM + dataSize));
            return;
        }
        gQueueTail = (volatile uintptr_t *)(kQueueTailAddr + slide);
        gQueueHead = (volatile uintptr_t *)(kQueueHeadAddr + slide);
        gKeyEventFn = (UTYKeyEventFn)(kKeyEventFnAddr + slide);
        UTYLog(@"Runner localizado (%s), slide=%lx, KeyEventFn=%p, cola head=%p", name, (long)slide, gKeyEventFn, gQueueHead);
        return;
    }
    // no marcar done: puede que el runner aún no esté cargado
}

// HID usage -> código de tecla GameMaker (vk_*). -1 = sin mapeo
static long uty_gmKeyForHID(long code) {
    switch (code) {
        case UIKeyboardHIDUsageKeyboardUpArrow:    case UIKeyboardHIDUsageKeyboardW: return 38; // vk_up
        case UIKeyboardHIDUsageKeyboardDownArrow:  case UIKeyboardHIDUsageKeyboardS: return 40; // vk_down
        case UIKeyboardHIDUsageKeyboardLeftArrow:  case UIKeyboardHIDUsageKeyboardA: return 37; // vk_left
        case UIKeyboardHIDUsageKeyboardRightArrow: case UIKeyboardHIDUsageKeyboardD: return 39; // vk_right
        case UIKeyboardHIDUsageKeyboardZ:          return 90; // Z
        case UIKeyboardHIDUsageKeyboardY:          return 89; // Y (por teclados QWERTZ)
        case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        case UIKeyboardHIDUsageKeypadEnter:        return 13; // vk_enter
        case UIKeyboardHIDUsageKeyboardSpacebar:   return 32; // vk_space
        case UIKeyboardHIDUsageKeyboardX:          return 88; // X
        case UIKeyboardHIDUsageKeyboardLeftShift:
        case UIKeyboardHIDUsageKeyboardRightShift: return 16; // vk_shift
        case UIKeyboardHIDUsageKeyboardC:          return 67; // C
        case UIKeyboardHIDUsageKeyboardLeftControl:
        case UIKeyboardHIDUsageKeyboardRightControl: return 17; // vk_control
        case UIKeyboardHIDUsageKeyboardF4:         return 115; // vk_f4
        // Esc no se mapea a propósito: "Hold ESC" cierra el juego
        default: return -1;
    }
}

static BOOL gHidDown[256];
static int gPendingRelease[256];   // ticks restantes en los que se reenvía RELEASE tras soltar
static NSUInteger gInjected = 0;

static void uty_injectKey(long code, BOOL down) {
    if (code < 0 || code > 255) return;
    if (gHidDown[code] == down) return;   // deduplicar (llegan por 3 vías)
    gHidDown[code] = down;
    long gm = uty_gmKeyForHID(code);
    if (gm < 0) return;
    uty_locateRunner();
    if (!gKeyEventFn) { UTYLogOnce(@"Tecla recibida pero KeyEventFn no disponible"); return; }
    if (!down) gPendingRelease[code] = 2;   // el ticker enviará el release (2 frames, por seguridad)
    gInjected++;
    if (gInjected <= 20) UTYLog(@"  estado GM key %ld -> %@", gm, down ? @"DOWN" : @"UP");
}

#pragma mark - Repetición por frame (CADisplayLink)

@interface UTYTicker : NSObject
@end
@implementation UTYTicker
- (void)tick:(CADisplayLink *)link {
    if (!gKeyEventFn || !gQueueHead || !gQueueTail) return;
    // Solo encolar cuando el runner ya drenó la cola: así va exactamente un evento por tecla por frame
    if (*gQueueHead != 0 || *gQueueTail != 0) return;
    for (int code = 0; code < 256; code++) {
        if (gHidDown[code]) {
            long gm = uty_gmKeyForHID(code);
            if (gm >= 0) gKeyEventFn(0, gm, gm, 0);
        } else if (gPendingRelease[code] > 0) {
            gPendingRelease[code]--;
            long gm = uty_gmKeyForHID(code);
            if (gm >= 0) gKeyEventFn(1, gm, gm, 0);
        }
    }
}
@end

static CADisplayLink *gLink = nil;
static UTYTicker *gTicker = nil;

static void uty_startTicker(void) {
    if (gLink) return;
    gTicker = [UTYTicker new];
    gLink = [CADisplayLink displayLinkWithTarget:gTicker selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) {
        gLink.preferredFrameRateRange = CAFrameRateRangeMake(60, 120, 60);
    } else {
        gLink.preferredFramesPerSecond = 60;
    }
    [gLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    UTYLog(@"Ticker de repetición iniciado");
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
    static int upLogged = 0;
    if (UTY_FAKE_GAMEPAD && !down && upLogged < 12) {
        upLogged++;
        UTYLog(@"  lecturas acumuladas: buttonA.value=%lu (con 1.0: %lu) | isPressed=%lu (true: %lu) | axis=%lu (≠0: %lu)",
               (unsigned long)gReadsButtonA, (unsigned long)gReadsButtonAHigh,
               (unsigned long)gReadsIsPressed, (unsigned long)gReadsIsPressedTrue,
               (unsigned long)gReadsAxis, (unsigned long)gReadsAxisNonZero);
    }

    uty_injectKey(code, down);

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

#if UTY_FAKE_GAMEPAD
    // 1) Mando falso
    Method m = class_getClassMethod([GCController class], @selector(controllers));
    if (m) {
        orig_controllers = (void *)method_getImplementation(m);
        method_setImplementation(m, (IMP)uty_controllers);
        UTYLog(@"Hook +[GCController controllers] instalado");
    } else {
        UTYLog(@"ERROR: no se encontró +[GCController controllers]");
    }
#else
    UTYLog(@"Mando falso desactivado (v4)");
#endif

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
    dispatch_async(dispatch_get_main_queue(), ^{ uty_startTicker(); });

    // Intentar localizar el runner (puede cargar después del tweak): reintentos
    for (NSNumber *t in @[@0.5, @2.0, @5.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            uty_locateRunner();
            if (!gRunnerLookupDone) UTYLog(@"t=%@s: runner aún no localizado (%u imágenes cargadas)", t, _dyld_image_count());
        });
    }
#if UTY_FAKE_GAMEPAD
    // Resumen periódico de lecturas para ver si el runner lee cada frame o solo una vez
    for (NSNumber *t in @[@2.0, @6.0, @12.0, @20.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(t.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            UTYLog(@"t=%@s: controllers=%lu, buttonA.value=%lu, isPressed=%lu, axis=%lu",
                   t, (unsigned long)gControllersCalls, (unsigned long)gReadsButtonA,
                   (unsigned long)gReadsIsPressed, (unsigned long)gReadsAxis);
        });
    }

    for (NSNumber *delay in @[@3.0, @8.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:GCControllerDidConnectNotification
                                                                object:[UTYController shared]];
            UTYLog(@"Notificación GCControllerDidConnect enviada a los %@s (controllers sondeado %lu veces)", delay, (unsigned long)gControllersCalls);
        });
    }
#endif
}
