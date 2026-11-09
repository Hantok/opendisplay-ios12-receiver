// ODReceiver: an OpenDisplay receiver for jailbroken iOS 12 devices (tested on iPad mini 2).
//
// Speaks the OpenDisplay wire protocol (pv 3,
// https://github.com/peetzweg/opendisplay/blob/main/PROTOCOL.md): listens on
// 127.0.0.1:9000, the Mac sender dials it through usbmuxd over the cable, and
// H.264 Annex B frames are hardware-decoded with VideoToolbox and shown
// immediately through AVSampleBufferDisplayLayer (no timestamps, no buffering).
// The mouse cursor is drawn locally from the control channel, so it moves at
// input rate instead of video rate.
//
// Gestures:  1 finger = click / drag,  2 fingers = scroll,
//            3-finger tap = stats overlay + decode-limit switch.
//
// Copyright (C) 2026 Roman Slysh. Licensed under the GNU GPL v3 (see LICENSE).
// The touch-to-click logic is ported from OpenDisplay's iOS receiver (GPL-3.0).

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <QuartzCore/QuartzCore.h>
#import <VideoToolbox/VideoToolbox.h>
#include <stdatomic.h>
#include <sys/socket.h>
#include <sys/utsname.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <pthread.h>
#include <errno.h>
#include <unistd.h>

static const uint16_t kPort = 9000;
static const int kProtocolVersion = 3;
// H.264 Level 4.2 macroblock rate in pixels/s: what A7/A8 hardware is rated for.
static const long kLevel42PixelsPerSecond = 522240L * 256L;

static double NowMs(void) { return [[NSDate date] timeIntervalSince1970] * 1000.0; }

typedef NS_ENUM(NSInteger, ODDecodeMode) {
    ODDecodeModeAuto = 0,      // Level 4.2 throughput budget: full raster, sender lowers fps
    ODDecodeModeUnlimited = 1, // no limits: native raster at 60 fps
    ODDecodeModeSafe = 2,      // 1600x1200 cap at 60 fps
};

static NSString *DecodeModeName(ODDecodeMode m) {
    switch (m) {
        case ODDecodeModeAuto: return @"Auto (L4.2 budget)";
        case ODDecodeModeUnlimited: return @"Unlimited (native@60)";
        case ODDecodeModeSafe: return @"Safe (1600x1200@60)";
    }
    return @"?";
}

#pragma mark - Connection

@class ODConnection;
@protocol ODConnectionDelegate <NSObject>
- (void)connection:(ODConnection *)c didReceiveFrame:(const uint8_t *)p length:(uint32_t)n;
- (void)connectionDidClose:(ODConnection *)c;
@end

@interface ODConnection : NSObject
@property (nonatomic, readonly) BOOL loopback;
@property (atomic) double lastRx;
@property (atomic) double created;
@property (atomic) BOOL gotBytes;
@property (atomic) uint64_t rxBytes;
@property (nonatomic, weak) id<ODConnectionDelegate> delegate;
- (instancetype)initWithFD:(int)fd loopback:(BOOL)loopback;
- (void)start;
- (void)sendJSON:(NSDictionary *)obj;
- (void)close;
@end

@implementation ODConnection {
    int _fd;
    dispatch_queue_t _writeQueue;
    pthread_mutex_t _lock;
    BOOL _closed;
}

- (instancetype)initWithFD:(int)fd loopback:(BOOL)loopback {
    if ((self = [super init])) {
        _fd = fd;
        _loopback = loopback;
        _writeQueue = dispatch_queue_create("od.write", DISPATCH_QUEUE_SERIAL);
        dispatch_set_target_queue(_writeQueue, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0));
        pthread_mutex_init(&_lock, NULL);
        _lastRx = _created = NowMs();
    }
    return self;
}

- (void)start {
    NSThread *t = [[NSThread alloc] initWithTarget:self selector:@selector(readLoop) object:nil];
    t.qualityOfService = NSQualityOfServiceUserInteractive;
    t.name = @"od.read";
    [t start];
}

- (BOOL)isClosed {
    pthread_mutex_lock(&_lock);
    BOOL c = _closed;
    pthread_mutex_unlock(&_lock);
    return c;
}

- (void)readLoop {
    size_t cap = 1 << 20, len = 0;
    uint8_t *buf = malloc(cap);
    for (;;) {
        if (cap - len < 65536) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
        ssize_t r = recv(_fd, buf + len, cap - len, 0);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        len += (size_t)r;
        self.lastRx = NowMs();
        self.rxBytes += (uint64_t)r;
        self.gotBytes = YES;

        size_t off = 0;
        BOOL bad = NO;
        while (len - off >= 4) {
            const uint8_t *h = buf + off;
            uint32_t n = ((uint32_t)h[0] << 24) | ((uint32_t)h[1] << 16) | ((uint32_t)h[2] << 8) | h[3];
            if (n == 0) { off += 4; continue; }
            if (n > (64u << 20)) { bad = YES; break; }
            if (len - off - 4 < n) {
                if ((size_t)n + 4 > cap) {   // make room for a big keyframe
                    memmove(buf, buf + off, len - off);
                    len -= off; off = 0;
                    cap = (size_t)n + 4 + 65536;
                    buf = realloc(buf, cap);
                }
                break;
            }
            if ([self isClosed]) { bad = YES; break; }
            [self.delegate connection:self didReceiveFrame:h + 4 length:n];
            off += 4 + n;
        }
        if (bad) break;
        if (off) {
            memmove(buf, buf + off, len - off);
            len -= off;
        }
    }
    free(buf);
    [self close];
    int fd = _fd;
    dispatch_async(_writeQueue, ^{ close(fd); });   // after any queued writes fail out
    [self.delegate connectionDidClose:self];
}

- (void)sendJSON:(NSDictionary *)obj {
    NSData *body = [NSJSONSerialization dataWithJSONObject:obj options:0 error:NULL];
    if (!body.length) return;
    uint32_t n = htonl((uint32_t)body.length);
    NSMutableData *pkt = [NSMutableData dataWithCapacity:body.length + 4];
    [pkt appendBytes:&n length:4];
    [pkt appendData:body];
    dispatch_async(_writeQueue, ^{
        if ([self isClosed]) return;
        const uint8_t *p = pkt.bytes;
        size_t left = pkt.length;
        while (left) {
            ssize_t w = send(self->_fd, p, left, 0);
            if (w < 0) {
                if (errno == EINTR) continue;
                [self close];
                return;
            }
            p += w;
            left -= (size_t)w;
        }
    });
}

- (void)close {
    pthread_mutex_lock(&_lock);
    if (!_closed) {
        _closed = YES;
        shutdown(_fd, SHUT_RDWR);   // wakes the blocking recv()
    }
    pthread_mutex_unlock(&_lock);
}

@end

#pragma mark - Receiver

typedef struct { double submit, cap, arrival; } ODFrameInfo;
#define OD_RING 64
static void ODDecodeCallback(void *refcon, void *frameRefCon, OSStatus status, VTDecodeInfoFlags flags,
                             CVImageBufferRef image, CMTime pts, CMTime dur);

@protocol ODReceiverUI <NSObject>
- (void)receiverConnected:(BOOL)connected usb:(BOOL)usb;
- (void)receiverVideoSize:(CGSize)size;
- (void)receiverCursorX:(double)x y:(double)y visible:(BOOL)visible;
- (void)receiverCursorImage:(UIImage *)image nw:(double)nw nh:(double)nh ax:(double)ax ay:(double)ay;
- (void)receiverMessage:(NSString *)message;
@end

@interface ODReceiver : NSObject <ODConnectionDelegate>
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, weak) id<ODReceiverUI> ui;
@property (atomic) ODDecodeMode decodeMode;
@property (atomic, readonly) BOOL offsetKnown;
@property (atomic, readonly) double clockOffset;   // sender clock - receiver clock (ms)
- (void)startListening;
- (void)stopListeningSaying:(NSString *)farewell;
- (void)setPanelPixelsWide:(int)w high:(int)h scale:(double)scale;
- (void)sendTouch:(NSString *)phase x:(double)x y:(double)y;
- (void)sendScrollDX:(double)dx dy:(double)dy;
- (void)requestKeyframe;
- (void)resend;
- (void)layerNeedsRecovery;
- (NSString *)statsText;
@end

@implementation ODReceiver {
    int _listenFD;
    NSNetService *_bonjour;
    dispatch_source_t _acceptSource;
    dispatch_source_t _timer;
    ODConnection *_active;
    ODConnection *_candidate;

    // panel (written on main, read anywhere)
    int _panelW, _panelH;
    double _panelScale;

    // decoder state, guarded by _decLock
    pthread_mutex_t _decLock;
    CMVideoFormatDescriptionRef _format;
    NSData *_sps, *_pps;
    BOOL _waitForIDR;
    double _lastKfRequest;
    CGSize _videoSize;
    VTDecompressionSessionRef _session;
    ODFrameInfo _ring[OD_RING];
    uint64_t _frameSeq;
    atomic_int _inFlight;
    atomic_int _decodeFailed;

    // decoded-output state (VT callback thread), guarded by _outLock
    pthread_mutex_t _outLock;
    CMVideoFormatDescriptionRef _outFormat;

    // stats, guarded by _statLock
    pthread_mutex_t _statLock;
    NSMutableArray<NSArray<NSNumber *> *> *_clockSamples;   // [rtt, offset]
    double _rtt;
    NSMutableArray<NSNumber *> *_e2e;
    NSMutableArray<NSNumber *> *_dec;      // submit -> decoded (ms)
    NSMutableArray<NSNumber *> *_glass;    // capture on Mac -> decoded on iPad (ms)
    uint64_t _decodeErrors, _backlog;
    uint64_t _frames, _framesWindow, _bytesWindow, _kfRequests, _decodeResets;
    double _windowStart, _fps, _mbps;
    long _senderPV;
    NSDictionary *_streamConfig;
    NSDictionary *_senderHealth;
    double _lastStatsSent;
    int64_t _cursorSeq;
}

- (instancetype)init {
    if ((self = [super init])) {
        _listenFD = -1;
        pthread_mutex_init(&_decLock, NULL);
        pthread_mutex_init(&_statLock, NULL);
        pthread_mutex_init(&_outLock, NULL);
        _dec = [NSMutableArray array];
        _glass = [NSMutableArray array];
        _clockSamples = [NSMutableArray array];
        _e2e = [NSMutableArray array];
        _windowStart = NowMs();
        _senderPV = 1;
        _cursorSeq = -1;
        _decodeMode = (ODDecodeMode)[[NSUserDefaults standardUserDefaults] integerForKey:@"decodeMode"];
    }
    return self;
}

+ (NSString *)installID {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    NSString *v = [d stringForKey:@"installID"];
    if (!v) {
        v = [NSUUID UUID].UUIDString;
        [d setObject:v forKey:@"installID"];
    }
    return v;
}

#pragma mark Listening

- (void)startListening {
    @synchronized (self) {
        if (_listenFD >= 0) return;
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in a;
        memset(&a, 0, sizeof a);
        a.sin_len = sizeof a;
        a.sin_family = AF_INET;
        a.sin_port = htons(kPort);
        a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);   // USB (usbmuxd) only, invisible on WiFi
        if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0 || listen(fd, 4) < 0) {
            NSString *err = [NSString stringWithFormat:@"Cannot listen on port %d: %s", kPort, strerror(errno)];
            close(fd);
            dispatch_async(dispatch_get_main_queue(), ^{ [self.ui receiverMessage:err]; });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [self startListening];
            });
            return;
        }
        _listenFD = fd;
        dispatch_queue_t q = dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0);
        _acceptSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, q);
        __weak ODReceiver *weakSelf = self;
        dispatch_source_set_event_handler(_acceptSource, ^{ [weakSelf acceptOn:fd]; });
        dispatch_source_set_cancel_handler(_acceptSource, ^{ close(fd); });
        dispatch_resume(_acceptSource);

        dispatch_async(dispatch_get_main_queue(), ^{ [self publishBonjour]; });

        if (!_timer) {
            _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
            dispatch_source_set_timer(_timer, dispatch_time(DISPATCH_TIME_NOW, 0), 1 * NSEC_PER_SEC, 50 * NSEC_PER_MSEC);
            dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
            dispatch_resume(_timer);
        }
    }
}

// Presence beacon only: the Mac sender (re)dials a cabled device over usbmuxd
// when a receiver with that install id shows up, e.g. after the app reopens.
// main thread
- (void)publishBonjour {
    if (_bonjour) return;
    NSData *(^utf8)(NSString *) = ^(NSString *v) { return [v dataUsingEncoding:NSUTF8StringEncoding]; };
    _bonjour = [[NSNetService alloc] initWithDomain:@"local." type:@"_opensidecar._tcp."
                                               name:[UIDevice currentDevice].name port:kPort];
    [_bonjour setTXTRecordData:[NSNetService dataFromTXTRecordDictionary:@{
        @"id": utf8([ODReceiver installID]),
        @"pv": utf8([NSString stringWithFormat:@"%d", kProtocolVersion]),
    }]];
    [_bonjour publish];
}

- (void)stopListeningSaying:(NSString *)farewell {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_bonjour stop];
        self->_bonjour = nil;
    });
    ODConnection *a, *c;
    @synchronized (self) {
        if (_acceptSource) {
            dispatch_source_cancel(_acceptSource);
            _acceptSource = nil;
        }
        _listenFD = -1;
        a = _active; c = _candidate;
        _active = nil; _candidate = nil;
    }
    if (farewell) [a sendJSON:@{@"type": farewell}];
    // give the farewell a moment to leave before cutting the socket
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_global_queue(0, 0), ^{
        [a close];
        [c close];
    });
    [self resetDecoder];
}

- (void)acceptOn:(int)lfd {
    struct sockaddr_storage ss;
    socklen_t sl = sizeof ss;
    int c = accept(lfd, (struct sockaddr *)&ss, &sl);
    if (c < 0) return;
    int one = 1;
    setsockopt(c, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof one);
    int rcv = 4 << 20;
    setsockopt(c, SOL_SOCKET, SO_RCVBUF, &rcv, sizeof rcv);
    BOOL loopback = NO;
    if (ss.ss_family == AF_INET) {
        loopback = ((struct sockaddr_in *)&ss)->sin_addr.s_addr == htonl(INADDR_LOOPBACK);
    }
    ODConnection *conn = [[ODConnection alloc] initWithFD:c loopback:loopback];
    conn.delegate = self;
    BOOL becameActive = NO;
    ODConnection *dropped = nil;
    @synchronized (self) {
        if (!_active) {
            _active = conn;
            becameActive = YES;
        } else {
            dropped = _candidate;   // only the newest newcomer is kept
            _candidate = conn;
        }
    }
    [dropped close];
    if (becameActive) [self adoptedConnection:conn];
    [conn start];
    [self sendHelloOn:conn];
}

- (void)adoptedConnection:(ODConnection *)conn {
    [self resetDecoder];
    pthread_mutex_lock(&_statLock);
    [_clockSamples removeAllObjects];
    _offsetKnown = NO;
    _cursorSeq = -1;
    _senderPV = 1;
    _streamConfig = nil;
    pthread_mutex_unlock(&_statLock);
    BOOL usb = conn.loopback;
    dispatch_async(dispatch_get_main_queue(), ^{ [self.ui receiverConnected:YES usb:usb]; });
}

#pragma mark ODConnectionDelegate (reader threads)

- (void)connection:(ODConnection *)c didReceiveFrame:(const uint8_t *)p length:(uint32_t)n {
    ODConnection *old = nil;
    BOOL adopted = NO;
    @synchronized (self) {
        if (c != _active) {
            if (c != _candidate) return;
            old = _active;
            _active = c;
            _candidate = nil;
            adopted = YES;
        }
    }
    if (adopted) {
        [old close];
        [self adoptedConnection:c];
    }
    // PROTOCOL.md section 4: JSON iff < 32 KB, starts with '{', has no NUL.
    if (n < 32768 && p[0] == '{' && memchr(p, 0, n) == NULL) {
        [self handleControl:[NSData dataWithBytes:p length:n] on:c];
    } else {
        [self handleVideo:p length:n];
    }
}

- (void)connectionDidClose:(ODConnection *)c {
    BOOL wasActive = NO;
    ODConnection *promoted = nil;
    @synchronized (self) {
        if (c == _active) {
            wasActive = YES;
            _active = nil;
            if (_candidate) {
                promoted = _candidate;
                _active = _candidate;
                _candidate = nil;
            }
        } else if (c == _candidate) {
            _candidate = nil;
        }
    }
    if (promoted) {
        [self adoptedConnection:promoted];
    } else if (wasActive) {
        [self resetDecoder];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.ui receiverConnected:NO usb:NO]; });
    }
}

#pragma mark Control messages

- (void)sendHelloOn:(ODConnection *)conn {
    int w, h;
    double scale;
    @synchronized (self) { w = _panelW; h = _panelH; scale = _panelScale; }
    if (w < 2 || h < 2) return;
    NSMutableDictionary *h264 = [@{@"codec": @"h264", @"maxFrameRate": @60} mutableCopy];
    NSMutableDictionary *hello = [@{
        @"type": @"hello",
        @"pixelsWide": @(w),
        @"pixelsHigh": @(h),
        @"scale": @(scale),
        @"device": @"iPad",
        @"id": [ODReceiver installID],
        @"pv": @(kProtocolVersion),
        @"displayMaxFrameRate": @60,
        @"panel": @{@"pixelsWide": @(w), @"pixelsHigh": @(h), @"scale": @(scale)},
    } mutableCopy];
    switch (self.decodeMode) {
        case ODDecodeModeAuto:
            h264[@"maxPixelsPerSecond"] = @(kLevel42PixelsPerSecond);
            break;
        case ODDecodeModeSafe: {
            int mw = w >= h ? 1600 : 1200, mh = w >= h ? 1200 : 1600;
            h264[@"maxWidth"] = @(mw);
            h264[@"maxHeight"] = @(mh);
            hello[@"maxEncodeWide"] = @(mw);
            hello[@"maxEncodeHigh"] = @(mh);
            break;
        }
        case ODDecodeModeUnlimited:
            break;
    }
    hello[@"videoCaps"] = @[h264];
    [conn sendJSON:hello];
}

- (void)setPanelPixelsWide:(int)w high:(int)h scale:(double)scale {
    BOOL changed;
    ODConnection *a;
    @synchronized (self) {
        changed = (w != _panelW || h != _panelH || scale != _panelScale);
        _panelW = w; _panelH = h; _panelScale = scale;
        a = _active;
    }
    if (changed && a) [self sendHelloOn:a];
}

- (void)resend {
    ODConnection *a;
    @synchronized (self) { a = _active; }
    if (a) [self sendHelloOn:a];
}

- (ODConnection *)activeConnection {
    @synchronized (self) { return _active; }
}

- (void)handleControl:(NSData *)data on:(ODConnection *)c {
    NSDictionary *m = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![m isKindOfClass:[NSDictionary class]]) return;
    NSString *type = m[@"type"];
    if (![type isKindOfClass:[NSString class]]) return;

    if ([type isEqualToString:@"cursor"]) {
        NSNumber *s = m[@"s"];
        if ([s isKindOfClass:[NSNumber class]]) {
            pthread_mutex_lock(&_statLock);
            BOOL stale = s.longLongValue <= _cursorSeq;
            if (!stale) _cursorSeq = s.longLongValue;
            pthread_mutex_unlock(&_statLock);
            if (stale) return;
        }
        BOOL visible = [m[@"v"] intValue] == 1;
        double x = [m[@"x"] doubleValue], y = [m[@"y"] doubleValue];
        dispatch_async(dispatch_get_main_queue(), ^{ [self.ui receiverCursorX:x y:y visible:visible]; });
    } else if ([type isEqualToString:@"cursorImg"]) {
        NSString *b64 = m[@"png"];
        if (![b64 isKindOfClass:[NSString class]]) return;
        NSData *png = [[NSData alloc] initWithBase64EncodedString:b64 options:NSDataBase64DecodingIgnoreUnknownCharacters];
        UIImage *img = png ? [UIImage imageWithData:png] : nil;
        if (!img) return;
        double nw = [m[@"nw"] doubleValue], nh = [m[@"nh"] doubleValue];
        double ax = [m[@"ax"] doubleValue], ay = [m[@"ay"] doubleValue];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.ui receiverCursorImage:img nw:nw nh:nh ax:ax ay:ay];
        });
    } else if ([type isEqualToString:@"pong"]) {
        double t1 = [m[@"t"] doubleValue], mt = [m[@"mt"] doubleValue], t2 = NowMs();
        double rtt = t2 - t1;
        if (rtt < 0 || rtt >= 2000) return;
        pthread_mutex_lock(&_statLock);
        [_clockSamples addObject:@[@(rtt), @(mt - (t1 + t2) / 2.0)]];
        while (_clockSamples.count > 15) [_clockSamples removeObjectAtIndex:0];
        NSArray *best = nil;
        for (NSArray *sample in _clockSamples) {
            if (!best || [sample[0] doubleValue] < [best[0] doubleValue]) best = sample;
        }
        _clockOffset = [best[1] doubleValue];
        _offsetKnown = YES;
        _rtt = rtt;
        pthread_mutex_unlock(&_statLock);
    } else if ([type isEqualToString:@"ping"]) {
        pthread_mutex_lock(&_statLock);
        _senderHealth = m;
        pthread_mutex_unlock(&_statLock);
    } else if ([type isEqualToString:@"welcome"]) {
        pthread_mutex_lock(&_statLock);
        _senderPV = [m[@"pv"] longValue];
        pthread_mutex_unlock(&_statLock);
    } else if ([type isEqualToString:@"streamConfig"]) {
        pthread_mutex_lock(&_statLock);
        _streamConfig = m;
        pthread_mutex_unlock(&_statLock);
        NSString *codec = m[@"codec"];
        if ([codec isKindOfClass:[NSString class]] && ![codec isEqualToString:@"h264"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self.ui receiverMessage:[NSString stringWithFormat:@"Unsupported codec %@", codec]];
            });
        }
    } else if ([type isEqualToString:@"updateRequired"]) {
        NSString *msg = m[@"message"];
        if ([msg isKindOfClass:[NSString class]]) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self.ui receiverMessage:msg]; });
        }
    }
    // everything else (power, cursorAck, unknown types) is ignored
}

- (void)sendTouch:(NSString *)phase x:(double)x y:(double)y {
    ODConnection *a = [self activeConnection];
    if (!a) return;
    NSMutableDictionary *m = [@{@"type": @"touch", @"phase": phase, @"x": @(x), @"y": @(y)} mutableCopy];
    if (self.offsetKnown) m[@"t"] = @(llround(NowMs() + self.clockOffset));
    [a sendJSON:m];
}

- (void)sendScrollDX:(double)dx dy:(double)dy {
    ODConnection *a = [self activeConnection];
    if (!a || (dx == 0 && dy == 0)) return;
    [a sendJSON:@{@"type": @"scroll", @"dx": @(dx), @"dy": @(dy)}];
}

- (void)requestKeyframe {
    double now = NowMs();
    if (now - _lastKfRequest < 300) return;
    _lastKfRequest = now;
    ODConnection *a = [self activeConnection];
    if (!a) return;
    pthread_mutex_lock(&_statLock);
    _kfRequests++;
    pthread_mutex_unlock(&_statLock);
    [a sendJSON:@{@"type": @"kf"}];
}

- (void)tick {
    ODConnection *a, *cand;
    @synchronized (self) { a = _active; cand = _candidate; }
    double now = NowMs();
    if (cand && !cand.gotBytes && now - cand.created > 5000) [cand close];
    if (!a) return;
    if (now - a.lastRx > 5000) {   // PROTOCOL.md 8.2: silence over 5 s is death
        [a close];
        return;
    }
    static int n = 0;
    if (++n % 2 == 0) [a sendJSON:@{@"type": @"ping", @"t": @(llround(now))}];
    if (now - _lastStatsSent > 5000) {
        _lastStatsSent = now;
        pthread_mutex_lock(&_statLock);
        NSDictionary *stats = @{
            @"type": @"stats",
            @"transport": a.loopback ? @"usb" : @"wifi",
            @"fps": @(round(_fps)),
            @"mbps": @(round(_mbps * 10) / 10),
            @"e2e50": @([self percentile:0.5]),
            @"e2e95": @([self percentile:0.95]),
            @"rtt": @(round(_rtt)),
            @"dec50": @([self percentile:0.5 of:_dec]),
            @"dec95": @([self percentile:0.95 of:_dec]),
            @"glass50": @([self percentile:0.5 of:_glass]),
            @"glass95": @([self percentile:0.95 of:_glass]),
            @"decErr": @(_decodeErrors),
            @"backlog": @(_backlog),
            @"mode": @(self.decodeMode),
            @"offsetKnown": @(_offsetKnown),
            @"client": @"ODReceiver-iOS12",
        };
        pthread_mutex_unlock(&_statLock);
        [a sendJSON:stats];
    }
}

// caller holds _statLock
- (double)percentile:(double)p {
    return [self percentile:p of:_e2e];
}

- (double)percentile:(double)p of:(NSArray<NSNumber *> *)values {
    if (!values.count) return -1;
    NSArray *sorted = [values sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger i = MIN(sorted.count - 1, (NSUInteger)(p * sorted.count));
    return round([sorted[i] doubleValue]);
}

#pragma mark Video

static ssize_t FindStartCode(const uint8_t *p, size_t n, size_t from) {
    if (n < 4) return -1;
    for (size_t i = from; i + 3 < n; i++) {
        if (p[i + 2] > 1) { i += 2; continue; }   // fast skip
        if (p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0 && p[i + 3] == 1) return (ssize_t)i;
    }
    return -1;
}

- (void)resetDecoder {
    pthread_mutex_lock(&_decLock);
    if (_format) { CFRelease(_format); _format = NULL; }
    [self destroySession];
    _sps = nil;
    _pps = nil;
    _waitForIDR = YES;
    _videoSize = CGSizeZero;
    [self.displayLayer flush];   // synchronous: must not race the next IDR
    pthread_mutex_unlock(&_decLock);
}

- (void)handleVideo:(const uint8_t *)p length:(uint32_t)n {
    double arrival = NowMs();
    ssize_t first = FindStartCode(p, n, 0);
    if (first < 0) return;

    double cap = 0;
    if (first > 1 && p[0] == '{') {
        NSDictionary *tele = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:(void *)p length:(NSUInteger)first freeWhenDone:NO]
                                                             options:0 error:NULL];
        if ([tele isKindOfClass:[NSDictionary class]]) cap = [tele[@"cap"] doubleValue];
    }

    // Split NAL units on 4-byte start codes (PROTOCOL.md 5.1).
    const uint8_t *nals[64];
    size_t lens[64];
    int count = 0;
    ssize_t s = first;
    while (s >= 0 && count < 64) {
        size_t start = (size_t)s + 4;
        ssize_t next = FindStartCode(p, n, start);
        size_t end = next >= 0 ? (size_t)next : n;
        if (end > start) {
            nals[count] = p + start;
            lens[count] = end - start;
            count++;
        }
        s = next;
    }

    const uint8_t *sps = NULL, *pps = NULL;
    size_t spsLen = 0, ppsLen = 0, payload = 0;
    BOOL idr = NO;
    for (int i = 0; i < count; i++) {
        int t = nals[i][0] & 0x1F;
        if (t == 7) { sps = nals[i]; spsLen = lens[i]; }
        else if (t == 8) { pps = nals[i]; ppsLen = lens[i]; }
        else if (t == 9 || t == 6) { /* AUD / SEI: skip */ }
        else {
            if (t == 5) idr = YES;
            payload += 4 + lens[i];
        }
    }

    pthread_mutex_lock(&_decLock);
    BOOL sizeChanged = NO;
    CGSize newSize = CGSizeZero;
    if (sps && pps) {
        NSData *spsData = [NSData dataWithBytes:sps length:spsLen];
        NSData *ppsData = [NSData dataWithBytes:pps length:ppsLen];
        if (!_format || ![spsData isEqualToData:_sps] || ![ppsData isEqualToData:_pps]) {
            const uint8_t *sets[2] = {sps, pps};
            size_t sizes[2] = {spsLen, ppsLen};
            CMVideoFormatDescriptionRef fmt = NULL;
            OSStatus st = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, sets, sizes, 4, &fmt);
            if (st == noErr && fmt) {
                if (_format) CFRelease(_format);
                _format = fmt;
                [self destroySession];
                _sps = spsData;
                _pps = ppsData;
                CMVideoDimensions d = CMVideoFormatDescriptionGetDimensions(fmt);
                newSize = CGSizeMake(d.width, d.height);
                if (!CGSizeEqualToSize(newSize, _videoSize)) {
                    _videoSize = newSize;
                    sizeChanged = YES;
                }
                [self.displayLayer flush];   // drop frames of the old format
            }
        }
    }
    if (atomic_exchange(&_decodeFailed, 0)) {   // the decoder reported an error
        _waitForIDR = YES;
        pthread_mutex_lock(&_statLock);
        _decodeResets++;
        pthread_mutex_unlock(&_statLock);
    }
    if (idr) _waitForIDR = NO;
    BOOL canDecode = _format && !_waitForIDR && payload > 0;
    if (canDecode && !_session && ![self createSession]) {
        _waitForIDR = YES;
        canDecode = NO;
    }
    if (!canDecode) {
        pthread_mutex_unlock(&_decLock);
        if (sizeChanged) {
            dispatch_async(dispatch_get_main_queue(), ^{ [self.ui receiverVideoSize:newSize]; });
        }
        if (payload > 0 || !_format) [self requestKeyframe];
        [self checkDecoderHealth];
        return;
    }

    // Annex B -> AVCC (4-byte big-endian lengths) in one malloc'd block.
    uint8_t *avcc = malloc(payload);
    size_t o = 0;
    for (int i = 0; i < count; i++) {
        int t = nals[i][0] & 0x1F;
        if (t == 7 || t == 8 || t == 9 || t == 6) continue;
        uint32_t be = htonl((uint32_t)lens[i]);
        memcpy(avcc + o, &be, 4);
        memcpy(avcc + o + 4, nals[i], lens[i]);
        o += 4 + lens[i];
    }
    CMBlockBufferRef block = NULL;
    OSStatus st = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, avcc, payload, kCFAllocatorMalloc,
                                                     NULL, 0, payload, 0, &block);
    if (st != noErr) {
        free(avcc);
        pthread_mutex_unlock(&_decLock);
        return;
    }
    CMSampleBufferRef sample = NULL;
    size_t sampleSize = payload;
    st = CMSampleBufferCreateReady(kCFAllocatorDefault, block, _format, 1, 0, NULL, 1, &sampleSize, &sample);
    CFRelease(block);
    if (st == noErr && sample) {
        uint64_t seq = ++_frameSeq;
        ODFrameInfo *info = &_ring[seq % OD_RING];
        info->submit = NowMs();
        info->cap = cap;
        info->arrival = arrival;
        if (atomic_fetch_add(&_inFlight, 1) >= 2) {
            pthread_mutex_lock(&_statLock);
            _backlog++;
            pthread_mutex_unlock(&_statLock);
        }
        VTDecodeInfoFlags infoFlags = 0;
        st = VTDecompressionSessionDecodeFrame(_session, sample,
                                               kVTDecodeFrame_EnableAsynchronousDecompression,
                                               (void *)(uintptr_t)seq, &infoFlags);
        CFRelease(sample);
        if (st != noErr) {
            atomic_fetch_sub(&_inFlight, 1);
            [self destroySession];   // e.g. kVTInvalidSessionErr after backgrounding
            _waitForIDR = YES;
        }
    }
    pthread_mutex_unlock(&_decLock);
    if (st != noErr) [self requestKeyframe];

    if (sizeChanged) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self.ui receiverVideoSize:newSize]; });
    }

    pthread_mutex_lock(&_statLock);
    _frames++;
    _framesWindow++;
    _bytesWindow += n;
    if (cap > 0 && _offsetKnown) {
        double lat = arrival + _clockOffset - cap;
        if (lat > -50 && lat < 5000) {
            [_e2e addObject:@(lat)];
            while (_e2e.count > 120) [_e2e removeObjectAtIndex:0];
        }
    }
    double el = arrival - _windowStart;
    if (el >= 1000) {
        _fps = _framesWindow * 1000.0 / el;
        _mbps = _bytesWindow * 8.0 / el / 1000.0;
        _framesWindow = 0;
        _bytesWindow = 0;
        _windowStart = arrival;
    }
    pthread_mutex_unlock(&_statLock);
}

// caller holds _decLock
- (BOOL)createSession {
    if (!_format) return NO;
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    VTDecompressionOutputCallbackRecord cb = {ODDecodeCallback, (__bridge void *)self};
    VTDecompressionSessionRef session = NULL;
    OSStatus st = VTDecompressionSessionCreate(kCFAllocatorDefault, _format, NULL,
                                               (__bridge CFDictionaryRef)attrs, &cb, &session);
    if (st != noErr || !session) {
        pthread_mutex_lock(&_statLock);
        _decodeErrors++;
        pthread_mutex_unlock(&_statLock);
        return NO;
    }
    VTSessionSetProperty(session, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
    _session = session;
    atomic_store(&_inFlight, 0);
    return YES;
}

// caller holds _decLock
- (void)destroySession {
    if (!_session) return;
    VTDecompressionSessionInvalidate(_session);
    CFRelease(_session);
    _session = NULL;
    atomic_store(&_inFlight, 0);
}

// VideoToolbox callback thread. Must not take _decLock (the submitting thread
// holds it while VT may wait for this callback to free a slot).
- (void)decoded:(CVImageBufferRef)image status:(OSStatus)status seq:(uint64_t)seq {
    if (atomic_fetch_sub(&_inFlight, 1) <= 0) atomic_store(&_inFlight, 0);
    double done = NowMs();
    if (status != noErr || !image) {
        atomic_store(&_decodeFailed, 1);
        pthread_mutex_lock(&_statLock);
        _decodeErrors++;
        pthread_mutex_unlock(&_statLock);
        [self requestKeyframe];
        return;
    }
    ODFrameInfo info = _ring[seq % OD_RING];

    pthread_mutex_lock(&_outLock);
    if (!_outFormat || !CMVideoFormatDescriptionMatchesImageBuffer(_outFormat, image)) {
        if (_outFormat) CFRelease(_outFormat);
        _outFormat = NULL;
        CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, image, &_outFormat);
    }
    CMVideoFormatDescriptionRef fmt = _outFormat ? (CMVideoFormatDescriptionRef)CFRetain(_outFormat) : NULL;
    pthread_mutex_unlock(&_outLock);
    if (!fmt) return;

    CMSampleTimingInfo timing = {kCMTimeInvalid, CMTimeMakeWithSeconds(CACurrentMediaTime(), 1000000), kCMTimeInvalid};
    CMSampleBufferRef sb = NULL;
    OSStatus st = CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, fmt, &timing, &sb);
    CFRelease(fmt);
    if (st != noErr || !sb) return;
    CFArrayRef atts = CMSampleBufferGetSampleAttachmentsArray(sb, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(atts, 0);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
    AVSampleBufferDisplayLayer *layer = self.displayLayer;
    if (layer.status == AVQueuedSampleBufferRenderingStatusFailed) [layer flush];
    [layer enqueueSampleBuffer:sb];
    CFRelease(sb);

    pthread_mutex_lock(&_statLock);
    if (info.submit > 0) {
        [_dec addObject:@(done - info.submit)];
        while (_dec.count > 120) [_dec removeObjectAtIndex:0];
    }
    if (info.cap > 0 && _offsetKnown) {
        double g = done + _clockOffset - info.cap;
        if (g > -50 && g < 5000) {
            [_glass addObject:@(g)];
            while (_glass.count > 120) [_glass removeObjectAtIndex:0];
        }
    }
    pthread_mutex_unlock(&_statLock);
}

// The hardware decoder keeps failing (stream too big for this chip?): step
// down to the safe 1600x1200 cap once instead of looping on keyframes.
- (void)checkDecoderHealth {
    static double windowStart = 0;
    static uint64_t resetsAtStart = 0;
    pthread_mutex_lock(&_statLock);
    uint64_t resets = _decodeResets;
    pthread_mutex_unlock(&_statLock);
    double now = NowMs();
    if (now - windowStart > 15000) { windowStart = now; resetsAtStart = resets; return; }
    if (resets - resetsAtStart >= 3 && self.decodeMode != ODDecodeModeSafe) {
        windowStart = now;
        resetsAtStart = resets;
        self.decodeMode = ODDecodeModeSafe;
        [[NSUserDefaults standardUserDefaults] setInteger:ODDecodeModeSafe forKey:@"decodeMode"];
        [self resend];
    }
}

- (void)layerNeedsRecovery {
    pthread_mutex_lock(&_decLock);
    [self.displayLayer flush];
    [self destroySession];
    _waitForIDR = YES;
    pthread_mutex_unlock(&_decLock);
    [self requestKeyframe];
}

- (NSString *)statsText {
    ODConnection *a = [self activeConnection];
    pthread_mutex_lock(&_statLock);
    double fps = _fps, mbps = _mbps, rtt = _rtt;
    if (NowMs() - _windowStart > 1500) fps = 0;   // static screen: no frames
    NSString *cfg = _streamConfig ? [NSString stringWithFormat:@"%@ %@x%@ @%@",
                                     _streamConfig[@"codec"], _streamConfig[@"width"],
                                     _streamConfig[@"height"], _streamConfig[@"framesPerSecond"]] : @"-";
    NSString *s = [NSString stringWithFormat:
        @"link      %@\n"
        @"stream    %@  (decoded %.0fx%.0f)\n"
        @"fps       %.0f    %.1f Mbit/s\n"
        @"latency   p50 %.0f ms  p95 %.0f ms  (capture->arrival)\n"
        @"decoded   p50 %.0f ms  p95 %.0f ms  (capture->decoded)   decode p50 %.1f ms\n"
        @"rtt       %.1f ms   clock %@\n"
        @"frames    %llu   kf req %llu   decoder resets %llu  errors %llu  backlog %llu\n"
        @"sender    pv %ld   drops enc %@ net %@   input p50 %@ ms\n"
        @"decode    %@",
        a ? (a.loopback ? @"USB (usbmux)" : @"network") : @"waiting",
        cfg, _videoSize.width, _videoSize.height,
        fps, mbps,
        [self percentile:0.5], [self percentile:0.95],
        [self percentile:0.5 of:_glass], [self percentile:0.95 of:_glass], [self percentile:0.5 of:_dec],
        rtt, _offsetKnown ? @"synced" : @"-",
        _frames, _kfRequests, _decodeResets, _decodeErrors, _backlog,
        _senderPV, _senderHealth[@"encDrops"] ?: @"-", _senderHealth[@"netDrops"] ?: @"-",
        _senderHealth[@"inp50"] ?: @"-",
        DecodeModeName(self.decodeMode)];
    pthread_mutex_unlock(&_statLock);
    return s;
}

@end

static void ODDecodeCallback(void *refcon, void *frameRefCon, OSStatus status, VTDecodeInfoFlags flags,
                             CVImageBufferRef image, CMTime pts, CMTime dur) {
    [(__bridge ODReceiver *)refcon decoded:image status:status seq:(uint64_t)(uintptr_t)frameRefCon];
}

#pragma mark - View

@interface ODView : UIView <ODReceiverUI, UIGestureRecognizerDelegate>
@property (nonatomic, strong) ODReceiver *receiver;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *videoLayer;
@end

@implementation ODView {
    CALayer *_cursorLayer;
    UILabel *_status;
    UILabel *_hud;
    UIButton *_modeButton;
    NSTimer *_hudTimer;
    CGSize _videoSize;
    CGPoint _cursorNorm;
    CGSize _cursorNormSize;
    BOOL _cursorVisible;
    BOOL _streaming;
    BOOL _connected;
    NSString *_message;

    // touch state (port of the official receiver's logic)
    BOOL _twoFingerActive;
    CGPoint _lastPan;
    CGPoint _lastNorm;
    BOOL _hasPendingDown;
    CGPoint _pendingDown;
    CGPoint _pendingDownPoint;
    BOOL _downSent;
    NSUInteger _holdToken;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor blackColor];
        self.multipleTouchEnabled = YES;

        _videoLayer = [AVSampleBufferDisplayLayer layer];
        _videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
        _videoLayer.backgroundColor = [UIColor blackColor].CGColor;
        [self.layer addSublayer:_videoLayer];

        _cursorLayer = [CALayer layer];
        _cursorLayer.hidden = YES;
        _cursorLayer.zPosition = 10;
        _cursorLayer.contentsGravity = kCAGravityResize;
        _cursorLayer.actions = @{@"position": [NSNull null], @"bounds": [NSNull null],
                                 @"contents": [NSNull null], @"hidden": [NSNull null],
                                 @"anchorPoint": [NSNull null]};
        [self.layer addSublayer:_cursorLayer];

        _status = [[UILabel alloc] init];
        _status.numberOfLines = 0;
        _status.textAlignment = NSTextAlignmentCenter;
        _status.textColor = [UIColor colorWithWhite:0.75 alpha:1];
        _status.font = [UIFont systemFontOfSize:20 weight:UIFontWeightMedium];
        [self addSubview:_status];

        _hud = [[UILabel alloc] init];
        _hud.numberOfLines = 0;
        _hud.textColor = [UIColor colorWithRed:0.6 green:1 blue:0.6 alpha:1];
        _hud.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        _hud.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont systemFontOfSize:13];
        _hud.hidden = YES;
        _hud.layer.zPosition = 20;
        [self addSubview:_hud];

        _modeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _modeButton.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
        _modeButton.layer.cornerRadius = 8;
        _modeButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _modeButton.hidden = YES;
        _modeButton.layer.zPosition = 20;
        [_modeButton addTarget:self action:@selector(cycleMode) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_modeButton];

        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(twoFingerPan:)];
        pan.minimumNumberOfTouches = 2;
        pan.maximumNumberOfTouches = 2;
        [self addGestureRecognizer:pan];

        UITapGestureRecognizer *three = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleHUD)];
        three.numberOfTouchesRequired = 3;
        [self addGestureRecognizer:three];

        [self refreshStatus];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _videoLayer.frame = self.bounds;
    [CATransaction commit];
    CGRect b = self.bounds;
    _status.frame = CGRectInset(b, 40, 40);
    CGSize hs = [_hud sizeThatFits:CGSizeMake(b.size.width - 40, CGFLOAT_MAX)];
    _hud.frame = CGRectMake(20, 20, MIN(b.size.width - 40, hs.width + 16), hs.height + 12);
    _modeButton.frame = CGRectMake(20, CGRectGetMaxY(_hud.frame) + 10, 320, 40);
    [self layoutCursor];

    UIScreen *screen = self.window.screen ?: [UIScreen mainScreen];
    double scale = screen.scale;
    int pw = (int)lround(b.size.width * scale), ph = (int)lround(b.size.height * scale);
    if (pw > 0 && ph > 0) [self.receiver setPanelPixelsWide:pw high:ph scale:scale];
}

- (CGRect)videoRect {
    if (_videoSize.width <= 0 || _videoSize.height <= 0) return self.bounds;
    return AVMakeRectWithAspectRatioInsideRect(_videoSize, self.bounds);
}

- (void)layoutCursor {
    if (CGSizeEqualToSize(_cursorNormSize, CGSizeZero)) return;
    CGRect r = [self videoRect];
    _cursorLayer.bounds = CGRectMake(0, 0, _cursorNormSize.width * r.size.width, _cursorNormSize.height * r.size.height);
    _cursorLayer.position = CGPointMake(r.origin.x + _cursorNorm.x * r.size.width,
                                        r.origin.y + _cursorNorm.y * r.size.height);
}

- (void)refreshStatus {
    if (_message) {
        _status.text = _message;
        _status.hidden = NO;
        return;
    }
    if (_streaming) {
        _status.hidden = YES;
        return;
    }
    _status.hidden = NO;
    _status.text = _connected
        ? @"Connected — waiting for the first frame…"
        : @"iPad Display\n\nWaiting for the Mac over USB.\nOpen OpenDisplay on the Mac and pick this iPad.\n\n3-finger tap: stats";
}

#pragma mark ODReceiverUI (main thread)

- (void)receiverConnected:(BOOL)connected usb:(BOOL)usb {
    _connected = connected;
    _message = nil;
    if (!connected) {
        _streaming = NO;
        _cursorLayer.hidden = YES;
        _videoSize = CGSizeZero;
    }
    [self refreshStatus];
}

- (void)receiverVideoSize:(CGSize)size {
    _videoSize = size;
    _streaming = YES;
    [self refreshStatus];
    [self layoutCursor];
}

- (void)receiverCursorX:(double)x y:(double)y visible:(BOOL)visible {
    _cursorVisible = visible;
    if (visible) _cursorNorm = CGPointMake(x, y);
    _cursorLayer.hidden = !visible || _cursorLayer.contents == nil;
    if (visible) [self layoutCursor];
}

- (void)receiverCursorImage:(UIImage *)image nw:(double)nw nh:(double)nh ax:(double)ax ay:(double)ay {
    _cursorLayer.contents = (__bridge id)image.CGImage;
    _cursorLayer.anchorPoint = CGPointMake(ax, ay);
    _cursorNormSize = CGSizeMake(nw, nh);
    _cursorLayer.hidden = !_cursorVisible;
    [self layoutCursor];
}

- (void)receiverMessage:(NSString *)message {
    _message = message;
    [self refreshStatus];
}

#pragma mark HUD

- (void)toggleHUD {
    BOOL show = _hud.hidden;
    _hud.hidden = !show;
    _modeButton.hidden = !show;
    [_hudTimer invalidate];
    _hudTimer = nil;
    if (show) {
        [self updateHUD];
        _hudTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self selector:@selector(updateHUD) userInfo:nil repeats:YES];
    }
}

- (void)updateHUD {
    _hud.text = [self.receiver statsText];
    [_modeButton setTitle:[NSString stringWithFormat:@"Decode limit: %@", DecodeModeName(self.receiver.decodeMode)]
                 forState:UIControlStateNormal];
    [self setNeedsLayout];
}

- (void)cycleMode {
    ODDecodeMode next = (ODDecodeMode)((self.receiver.decodeMode + 1) % 3);
    self.receiver.decodeMode = next;
    [[NSUserDefaults standardUserDefaults] setInteger:next forKey:@"decodeMode"];
    [self.receiver resend];
    [self updateHUD];
}

#pragma mark Input

- (BOOL)normalize:(CGPoint)pt into:(CGPoint *)out {
    CGRect r = [self videoRect];
    if (r.size.width <= 0 || r.size.height <= 0) return NO;
    double x = (pt.x - r.origin.x) / r.size.width;
    double y = (pt.y - r.origin.y) / r.size.height;
    *out = CGPointMake(MIN(MAX(x, 0), 1), MIN(MAX(y, 0), 1));
    return YES;
}

- (void)twoFingerPan:(UIPanGestureRecognizer *)g {
    if (_videoSize.width <= 0) return;
    switch (g.state) {
        case UIGestureRecognizerStateBegan: {
            _twoFingerActive = YES;
            _lastPan = CGPointZero;
            CGPoint n;
            // Put the cursor under the fingers once so the scroll hits that window.
            if ([self normalize:[g locationInView:self] into:&n]) {
                _lastNorm = n;
                [self.receiver sendTouch:@"moved" x:n.x y:n.y];
            }
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint t = [g translationInView:self];
            double scale = [self videoRect].size.width / _videoSize.width;   // points per video pixel
            [self.receiver sendScrollDX:(t.x - _lastPan.x) / scale dy:(t.y - _lastPan.y) / scale];
            _lastPan = t;
            break;
        }
        default:
            _twoFingerActive = NO;
            break;
    }
}

- (void)commitPendingDown {
    if (!_hasPendingDown || _downSent) return;
    _downSent = YES;
    _holdToken++;
    [self.receiver sendTouch:@"began" x:_pendingDown.x y:_pendingDown.y];
}

- (void)discardPendingDown {
    _hasPendingDown = NO;
    _downSent = NO;
    _holdToken++;
}

- (void)route:(NSString *)phase touches:(NSSet<UITouch *> *)touches event:(UIEvent *)event {
    UITouch *touch = touches.anyObject;
    if (!touch || _videoSize.width <= 0) return;
    // A second finger turns this into a scroll: withdraw the press.
    if (_twoFingerActive || event.allTouches.count > 1) {
        if (_downSent) [self.receiver sendTouch:@"cancelled" x:_lastNorm.x y:_lastNorm.y];
        [self discardPendingDown];
        return;
    }
    CGPoint loc = [touch locationInView:self];
    CGPoint norm;
    if (![self normalize:loc into:&norm]) return;
    _lastNorm = norm;

    if ([phase isEqualToString:@"began"]) {
        _hasPendingDown = YES;
        _pendingDown = norm;
        _pendingDownPoint = loc;
        _downSent = NO;
        NSUInteger token = ++_holdToken;
        // A press held 120 ms with no second finger is a deliberate hold: commit it.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (self->_holdToken == token) [self commitPendingDown];
        });
        return;
    }
    if ([phase isEqualToString:@"ended"]) {
        if (_hasPendingDown && !_downSent) [self commitPendingDown];   // a tap: whole click now
        if (_downSent) [self.receiver sendTouch:@"ended" x:norm.x y:norm.y];
        [self discardPendingDown];
        return;
    }
    if ([phase isEqualToString:@"cancelled"]) {
        if (_downSent) [self.receiver sendTouch:@"cancelled" x:norm.x y:norm.y];
        [self discardPendingDown];
        return;
    }
    // moved
    if (_hasPendingDown && !_downSent) {
        if (hypot(loc.x - _pendingDownPoint.x, loc.y - _pendingDownPoint.y) > 10) [self commitPendingDown];
    }
    NSArray<UITouch *> *samples = [event coalescedTouchesForTouch:touch] ?: @[touch];
    for (UITouch *t in samples) {
        CGPoint n;
        if ([self normalize:[t locationInView:self] into:&n]) {
            _lastNorm = n;
            [self.receiver sendTouch:@"moved" x:n.x y:n.y];
        }
    }
    UITouch *predicted = [event predictedTouchesForTouch:touch].lastObject;
    CGPoint pn;
    if (predicted && [self normalize:[predicted locationInView:self] into:&pn]) {
        [self.receiver sendTouch:@"moved" x:pn.x y:pn.y];
    }
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self route:@"began" touches:touches event:event]; }
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self route:@"moved" touches:touches event:event]; }
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self route:@"ended" touches:touches event:event]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event { [self route:@"cancelled" touches:touches event:event]; }

@end

#pragma mark - View controller / app

@interface ODViewController : UIViewController
@property (nonatomic, strong) ODReceiver *receiver;
@end

@implementation ODViewController

- (void)loadView {
    ODView *v = [[ODView alloc] initWithFrame:[UIScreen mainScreen].bounds];
    v.receiver = self.receiver;
    self.receiver.displayLayer = v.videoLayer;
    self.receiver.ui = v;
    self.view = v;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

@end

@interface ODAppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) ODReceiver *receiver;
@end

@implementation ODAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
    self.receiver = [[ODReceiver alloc] init];
    ODViewController *vc = [[ODViewController alloc] init];
    vc.receiver = self.receiver;
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    self.window.rootViewController = vc;
    [self.window makeKeyAndVisible];
    app.idleTimerDisabled = YES;   // it's a monitor: never auto-lock while open
    [self.receiver startListening];
    return YES;
}

- (void)applicationDidEnterBackground:(UIApplication *)app {
    // Tell the Mac we'll be back (locked / home button), then free the port.
    [self.receiver stopListeningSaying:@"sleeping"];
}

- (void)applicationWillEnterForeground:(UIApplication *)app {
    app.idleTimerDisabled = YES;
    [self.receiver startListening];
}

- (void)applicationDidBecomeActive:(UIApplication *)app {
    if (self.receiver.displayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        [self.receiver layerNeedsRecovery];
    }
}

- (void)applicationWillTerminate:(UIApplication *)app {
    [self.receiver stopListeningSaying:@"closing"];
}

@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([ODAppDelegate class]));
    }
}
