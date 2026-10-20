// MROffline — Minion Rush 离线网络层
//
// 思路完全照搬安卓版 libmroffline.so：
//   游戏以为自己连上了 Gameloft 服务器，其实所有请求都在本进程内被截下，
//   直接返回一个「让游戏继续跑」的 JSON。不联网、不加密、不用证书。
//
// 安卓靠 hook connect() + 内置假 CA + 本地 HTTP 服务器实现；
// iOS 有 NSURLProtocol 这个官方扩展点，等价于「本地 HTTP 服务器」，
// 而且因为根本不出进程，连 TLS 都不需要。
//
// 行为：
//   1. 拦截发往 gameloft / eve / manhattan 等域名的请求
//   2. 按路径返回最简 JSON（下表照搬安卓那 13 个模板）
//   3. hestia_config.json 动态生成，房间排期永远不过期
//   4. 全部请求写日志到 /var/mobile/Documents/MROffline.log
//   5. 遇到不认识的路径返回 {"status":"ok"} —— 绝不报错、绝不卡住
//
// 卸载：删掉
//   /Library/MobileSubstrate/DynamicLibraries/MROffline.dylib
//   /Library/MobileSubstrate/DynamicLibraries/MROffline.plist
// （无根环境在 /var/jb/... 下）

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>

// ═══════════════════════════════════════════════════════════
//  日志
// ═══════════════════════════════════════════════════════════
static NSString *gLogPath = nil;
static NSUInteger gSeq = 0;
static BOOL gVerbose = YES;        // 关掉可减少开销

// 多个候选路径，全部试一遍；同时写 2 份互备，防止某一路径不可写
static NSMutableArray<NSString *> *gLogPaths = nil;

static NSArray<NSString *> *MRCandidateDirs(void) {
    NSMutableArray *a = [NSMutableArray array];
    // 1) 沙盒内 Documents —— 越狱环境下一定可写，且 Filza 能直接看到
    @try {
        NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        if (paths.count) [a addObject:paths.firstObject];
    } @catch (__unused NSException *e) {}
    // 2) App 容器路径（TrollFools/巨魔注入后容器在 /var/mobile/Containers/Data/Application/<UUID>/）
    @try {
        NSString *home = NSHomeDirectory();
        if (home.length) [a addObject:[home stringByAppendingPathComponent:@"Documents"]];
    } @catch (__unused NSException *e) {}
    // 3) 越狱常用可写目录
    [a addObject:@"/var/mobile/Documents"];
    [a addObject:@"/var/mobile/Media/MROffline"];
    [a addObject:@"/var/tmp"];
    [a addObject:@"/tmp"];
    [a addObject:@"/private/var/tmp"];
    return a;
}

static void MRLogOpen(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    gLogPaths = [NSMutableArray array];

    for (NSString *c in MRCandidateDirs()) {
        if (!c.length) continue;
        [fm createDirectoryAtPath:c withIntermediateDirectories:YES attributes:nil error:NULL];
        NSString *p = [c stringByAppendingPathComponent:@"MROffline.log"];

        // 已存在就直接用（不覆盖），不存在则创建
        if (![fm fileExistsAtPath:p]) {
            if (![fm createFileAtPath:p contents:[NSData data] attributes:nil]) continue;
        }
        if (![fm isWritableFileAtPath:p]) continue;

        // 去重
        BOOL dup = NO;
        for (NSString *x in gLogPaths) if ([x isEqualToString:p]) { dup = YES; break; }
        if (!dup) [gLogPaths addObject:p];

        // 最多留 3 个不同路径
        if (gLogPaths.count >= 3) break;
    }

    gLogPath = gLogPaths.count ? gLogPaths.firstObject : nil;
    NSLog(@"[MROFFLINE] log paths = %@", gLogPaths);
}

// 无条件落盘：即使 gLogPaths 为空也尝试一次
static void MRWriteRaw(NSString *line) {
    if (gLogPaths.count == 0) {
        // 最后的兜底：直接 fopen 试试
        NSString *p = @"/var/tmp/MROffline.log";
        FILE *f = fopen([p fileSystemRepresentation], "a");
        if (f) { fputs([line UTF8String], f); fclose(f); }
        return;
    }
    NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *p in gLogPaths) {
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) continue;
        @try {
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        } @catch (__unused NSException *e) {
            @try { [fh closeFile]; } @catch (__unused NSException *e2) {}
        }
    }
}

static void MRL(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSLog(@"[MROFFLINE] %@", msg);

    @synchronized ([NSProcessInfo processInfo]) {
        NSUInteger n = ++gSeq;
        NSString *line = [NSString stringWithFormat:@"%07lu %@\n", (unsigned long)n, msg];
        MRWriteRaw(line);
    }
}

// ═══════════════════════════════════════════════════════════
//  拦截判定
// ═══════════════════════════════════════════════════════════
// 只拦这些域名的请求。广告 SDK 一律放行（不拦、不改、不记录）。
static BOOL MRShouldHandle(NSURL *url) {
    if (!url) return NO;
    NSString *h = url.host.lowercaseString;
    if (h.length == 0) return NO;

    // 只认 gameloft 系
    if ([h containsString:@"gameloft"]) return YES;

    // manhattan 内容域名（安卓那边也走同一套）
    if ([h containsString:@"manhattan"]) return YES;

    // 本地测试
    if ([h isEqualToString:@"127.0.0.1"] || [h isEqualToString:@"localhost"]) return YES;

    return NO;
}

// ═══════════════════════════════════════════════════════════
//  hestia_config.json —— 房间排期（照搬安卓 sub_69534）
// ═══════════════════════════════════════════════════════════
// 安卓的做法：按「今天」动态拼出 _Slots，incoming 是今天，
// 于是永远不会「还没开始」；end 给到很远的将来，于是永远不会过期。
static NSData *MRMakeHestia(void) {
    NSDate *now = [NSDate date];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd";
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.timeZone = [NSTimeZone timeZoneWithName:@"UTC"];

    // 昨天开始，10 年后结束
    NSDate *past = [now dateByAddingTimeInterval:-86400 * 2];
    NSDate *far  = [now dateByAddingTimeInterval:86400.0 * 3650];
    NSString *dStart = [fmt stringFromDate:past];
    NSString *dEnd   = [fmt stringFromDate:far];

    NSMutableString *slots = [NSMutableString string];

    void (^addSlot)(NSString *, NSString *) = ^(NSString *key, NSString *roomName) {
        if (slots.length) [slots appendString:@","];
        [slots appendFormat:
            @"\"%@\":{"
             "\"incoming_date\":\"%@ 00:00:00\","
             "\"start_date\":\"%@ 00:00:00\","
             "\"end_date\":\"%@ 23:59:59\","
             "\"outgoing_date\":\"%@ 23:59:59\""
             "}",
            key, dStart, dStart, dEnd, dEnd];
        (void)roomName;
    };

    // 安卓原版那 6 个固定槽
    addSlot(@"STORY_Slot",       @"STORY_ROOM");
    addSlot(@"STORY1_Slot",      @"INVENTING_LAB");
    addSlot(@"STORY2_Slot",      @"ARMORY_BEACH");
    addSlot(@"STORY3_Slot",      @"STATION_RES");
    addSlot(@"STORY4_Slot",      @"OMNI_PRISON");
    addSlot(@"TOP_BANANA_Slot",  @"TOP_BANANA_ROOM");

    // 我们额外加的：SE 与每日挑战
    addSlot(@"SEASONAL_Slot",    @"SEASONAL_ROOM");
    addSlot(@"SEASONAL1_Slot",   @"SEASONAL_ROOM_1");
    addSlot(@"SEASONAL2_Slot",   @"SEASONAL_ROOM_2");
    addSlot(@"SEASONAL3_Slot",   @"SEASONAL_ROOM_3");
    addSlot(@"DAYCHALLENGE_Slot",@"DAILY");

    NSString *json = [NSString stringWithFormat:@"{\"_Slots\":{%@}}", slots];
    return [json dataUsingEncoding:NSUTF8StringEncoding];
}

// ═══════════════════════════════════════════════════════════
//  响应规则（照搬安卓 libmroffline.so 的 13 个模板）
// ═══════════════════════════════════════════════════════════
static NSData *MRRespond(NSString *path, NSInteger *statusOut, NSString **ctypeOut) {
    NSString *low = path.lowercaseString;

    *statusOut = 200;
    *ctypeOut = @"application/json";

    // ── 房间排期（最关键）
    if ([low containsString:@"hestia"] || [low containsString:@"/configs/"]) {
        return MRMakeHestia();
    }

    // ── 资源下载：返回 404，让游戏用本地 DLC 包
    if ([low containsString:@"/lfile/"] || [low containsString:@"/rfile/"]) {
        *statusOut = 404;
        return [@"{\"status\":\"not_found\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 登录 / 凭据
    if ([low containsString:@"/portal"]) {
        return [@"{\"status\":\"ok\",\"gdid\":\"local\",\"glid\":\"local\","
                 "\"country\":\"US\",\"token_type\":\"Bearer\","
                 "\"access_token\":\"local\",\"client_id\":\"local\"}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([low containsString:@"/gdid"] || [low containsString:@"/sink"]) {
        return [@"{\"response\": \"OK\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 存档
    if ([low containsString:@"savegame"]) {
        return [@"{\"status\": \"ok\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 内购
    if ([low containsString:@"/iap"] || [low containsString:@"inapp_crm"] ||
        [low containsString:@"ecomm"]) {
        return [@"{\"status\": \"ok\"}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 排行榜：返回空数组
    if ([low containsString:@"leaderboard"]) {
        return [@"[]" dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 活动 / 事件 / TopBanana / 无尽跑
    if ([low containsString:@"endless_run"] || [low containsString:@"top_banana"] ||
        [low containsString:@"topbanana"] || [low containsString:@"events"] ||
        [low containsString:@"/consumed_events"] || [low containsString:@"festival"]) {
        return [@"{\"status\":\"ok\",\"events\":[],\"consumed_events\":[],"
                 "\"participations\":[]}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 玩家资料
    if ([low containsString:@"myprofile"] || [low containsString:@"/profiles"]) {
        return [@"{\"profiles\": [], \"status\": \"ok\"}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([low containsString:@"/accounts"]) {
        return [@"{\"accounts\": [], \"status\": \"ok\"}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 清单 / 背包
    if ([low containsString:@"inventory"]) {
        return [@"{\"status\": \"ok\", \"inventory\": {}}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([low containsString:@"alerts"]) {
        return [@"{\"alerts\": []}" dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([low containsString:@"datacenter"]) {
        return [@"[{\"name\":\"mdc\",\"status\":\"active\",\"preferred\":true,"
                 "\"country_code\":\"US\",\"_datacenter_id\":\"local\"}]"
                dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 在线状态：直接说「关掉」，让游戏走本地逻辑
    if ([low containsString:@"connectivity"]) {
        return [@"{\"enabled\": false}" dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 游戏模式
    if ([low containsString:@"identify_game_mode"]) {
        return [@"{\"body\": {\"game_mode\": \"adventure\"}}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }
    if ([low containsString:@"transfer_profile_exists"]) {
        return [@"{\"body\": {\"has_old_profile\": false}}"
                dataUsingEncoding:NSUTF8StringEncoding];
    }

    // ── 文本资源
    if ([low hasSuffix:@".txt"]) {
        *ctypeOut = @"text/plain";
        return [NSData data];
    }

    // ── 默认：什么都别说，就说 OK
    return [@"{\"status\":\"ok\"}" dataUsingEncoding:NSUTF8StringEncoding];
}

// ═══════════════════════════════════════════════════════════
//  NSURLProtocol —— 核心
// ═══════════════════════════════════════════════════════════
@interface MROfflineProtocol : NSURLProtocol
@end

@implementation MROfflineProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    // 记录所有请求（不只 gameloft），方便判断游戏到底走不走 NSURLProtocol
    static BOOL countedSelf = NO;
    if (!countedSelf) {
        countedSelf = YES;
    }

    if ([self propertyForKey:@"MROfflineHandled" inRequest:request]) return NO;

    NSURL *u = request.URL;
    NSString *h = u.host.lowercaseString ?: @"";
    BOOL handle = MRShouldHandle(u);

    // 首次出现不同 host 时记录一行「看过但没拦」
    static NSMutableSet *seenHosts = nil;
    if (!seenHosts) seenHosts = [NSMutableSet set];
    @synchronized (seenHosts) {
        if (h.length && ![seenHosts containsObject:h]) {
            [seenHosts addObject:h];
            MRL(@"SEEN host=%@ scheme=%@ handle=%d", h, u.scheme ?: @"?", handle ? 1 : 0);
        }
    }

    if (handle) {
        NSString *body = request.HTTPBody
            ? [[NSString alloc] initWithData:request.HTTPBody encoding:NSUTF8StringEncoding]
            : nil;
        MRL(@"REQ  %@ %@", request.HTTPMethod ?: @"?", u.absoluteString);
        if (body.length) MRL(@"     body: %@", body.length > 2000 ? [body substringToIndex:2000] : body);
        return YES;
    }
    return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSString *path = self.request.URL.path ?: @"/";
    NSInteger status = 200;
    NSString *ctype = @"application/json";
    NSData *data = MRRespond(path, &status, &ctype);

    MRL(@"RESP %@ -> %ld (%luB)", path, (long)status, (unsigned long)data.length);

    NSHTTPURLResponse *resp = [[NSHTTPURLResponse alloc]
        initWithURL:self.request.URL
         statusCode:status
        HTTPVersion:@"HTTP/1.1"
       headerFields:@{@"Content-Type": ctype,
                      @"Content-Length": [NSString stringWithFormat:@"%lu", (unsigned long)data.length],
                      @"Cache-Control": @"no-store"}];

    id<NSURLProtocolClient> client = self.client;
    [client URLProtocol:self didReceiveResponse:resp
      cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    if (data.length) [client URLProtocol:self didLoadData:data];
    [client URLProtocolDidFinishLoading:self];
}

- (void)stopLoading {
    // 同步返回，无需处理
}

@end

// ═══════════════════════════════════════════════════════════
//  入口
// ═══════════════════════════════════════════════════════════
%ctor {
    @autoreleasepool {
        MRLogOpen();

        // 无条件先把「我加载了」写下去，哪怕路径全废
        MRL(@"=== MROffline loaded (pid=%d) ===", getpid());
        MRL(@"bundle  = %@", [[NSBundle mainBundle] bundleIdentifier]);
        MRL(@"home    = %@", NSHomeDirectory());
        MRL(@"logs    = %@", gLogPaths);
        MRL(@"sysver  = %@", [[NSProcessInfo processInfo] operatingSystemVersionString]);

        BOOL ok = [NSURLProtocol registerClass:[MROfflineProtocol class]];
        MRL(@"registerClass = %d", ok);

        // ── 心跳：每 10 秒写一行，证明插件活着。
        //    如果只看到 loaded 没有后续心跳（也没 REQ），说明插件确实没跑起来。
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
            static NSUInteger beat = 0;
            @try {
                while (YES) {
                    beat++;
                    MRL(@"HEARTBEAT #%lu", (unsigned long)beat);
                    if (beat == 18) MRL(@"HEARTBEAT: 3分钟后停止心跳，避免日志过大");
                    if (beat >= 18) break;
                    [NSThread sleepForTimeInterval:10.0];
                }
            } @catch (__unused NSException *e) {}
        });
    }
}
