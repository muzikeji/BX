#import "DXJavaScriptEngine.h"
#import <JavaScriptCore/JavaScriptCore.h>
#import <dlfcn.h>

static const NSUInteger DXJSMaxBytes = 1024 * 1024;
static NSError *DXJSError(NSString *message) {
    return [NSError errorWithDomain:@"MUBX.JavaScript" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message ?: @"Script failed"}];
}

// Incremental response limit: do not buffer an unbounded download in a host App.
@interface DXJSDownload : NSObject <NSURLSessionDataDelegate>
@property (atomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableData *data;
@property (nonatomic, copy) void (^completion)(NSString *, NSError *);
- (void)start:(NSURLRequest *)request;
- (void)cancel;
@end
@implementation DXJSDownload
- (void)start:(NSURLRequest *)request {
    self.data = [NSMutableData data];
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.timeoutIntervalForRequest = 15;
    config.timeoutIntervalForResource = 25;
    config.HTTPCookieStorage = nil;
    config.URLCredentialStorage = nil;
    config.URLCache = nil;
    NSOperationQueue *queue = [NSOperationQueue new];
    queue.maxConcurrentOperationCount = 1;
    self.session = [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:queue];
    [[self.session dataTaskWithRequest:request] resume];
}
- (void)finish:(NSError *)error {
    void (^callback)(NSString *, NSError *) = self.completion;
    self.completion = nil;
    NSString *text = error ? nil : [[NSString alloc] initWithData:self.data encoding:NSUTF8StringEncoding];
    if (!error && !text) error = DXJSError(@"Only UTF-8 text/JSON responses are supported");
    [self.session invalidateAndCancel];
    self.session = nil;
    self.data = nil;
    if (callback) callback(text, error);
}
- (void)cancel {
    // Use the delegate queue to serialize with data/completion callbacks.
    NSURLSession *session = self.session;
    [session.delegateQueue addOperationWithBlock:^{ [self finish:DXJSError(@"Cancelled")]; }];
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
 didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    (void)session; (void)task;
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? [(NSHTTPURLResponse *)response statusCode] : 0;
    if (status < 200 || status >= 300 || response.expectedContentLength > (int64_t)DXJSMaxBytes) {
        handler(NSURLSessionResponseCancel);
        [self finish:DXJSError(status < 200 || status >= 300
            ? [NSString stringWithFormat:@"HTTP %ld", (long)status] : @"Response exceeds 1 MiB")];
        return;
    }
    handler(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    (void)session; (void)task;
    if (!self.completion) return;
    if (self.data.length + data.length > DXJSMaxBytes) { [self finish:DXJSError(@"Response exceeds 1 MiB")]; return; }
    [self.data appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    (void)session; (void)task;
    if (self.completion) [self finish:error];
}
@end

@interface DXJavaScriptEngine ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) JSContext *context;
@property (nonatomic, strong) JSValue *invoke;
@property (nonatomic, strong) NSMutableSet<DXJSDownload *> *downloads;
@property (atomic, assign) BOOL cancelled;
@property (atomic, assign) BOOL executionLimitReached;
@property (nonatomic, assign) BOOL evaluating;
@property (nonatomic, assign) NSUInteger invocation;
@property (nonatomic, assign) NSUInteger calls;
@property (nonatomic, assign) NSUInteger requests;
@property (nonatomic, assign) NSUInteger logBytes;
@property (nonatomic, assign) NSUInteger directActions;
@end

@implementation DXJavaScriptEngine
+ (NSArray<NSDictionary *> *)actionsForResult:(id)result error:(NSError **)error {
    if (!result || result == NSNull.null) return @[];
    NSArray *values = [result isKindOfClass:NSArray.class] ? result : @[result];
    if (values.count > 100) { if (error) *error = DXJSError(@"At most 100 choices are supported"); return nil; }
    NSMutableArray *actions = [NSMutableArray array];
    NSUInteger size = 0;
    for (id value in values) {
        NSDictionary *item = [value isKindOfClass:NSString.class] ? @{@"type": @"txt", @"content": value} : value;
        if (![item isKindOfClass:NSDictionary.class]) goto invalid;
        NSString *type = item[@"type"], *content = item[@"content"], *title = item[@"title"];
        if (![type isKindOfClass:NSString.class] || ![@[@"txt", @"url", @"urlInApp", @"app", @"function"] containsObject:type] ||
            ![content isKindOfClass:NSString.class] || (title && ![title isKindOfClass:NSString.class])) goto invalid;
        if (![type isEqual:@"txt"] && !content.length) goto invalid;
        id args = item[@"args"] ?: @[];
        if (![args isKindOfClass:NSArray.class] || ![NSJSONSerialization isValidJSONObject:args]) goto invalid;
        NSData *argsData = [NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
        size += [content lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + [title lengthOfBytesUsingEncoding:NSUTF8StringEncoding] + argsData.length;
        if (size > DXJSMaxBytes) goto invalid;
        [actions addObject:@{@"type": type, @"content": content, @"title": title ?: content, @"args": args}];
    }
    return actions;
invalid:
    if (error) *error = DXJSError(@"Unsupported result. Use text or {type, content, title?, args?}; legacy type 'js' is not supported");
    return nil;
}
- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.lindo.mubx.javascript", DISPATCH_QUEUE_SERIAL);
        _downloads = [NSMutableSet set];
    }
    return self;
}
- (void)cancel {
    if (self.cancelled) return;
    self.cancelled = YES;
    dispatch_async(self.queue, ^{
        for (DXJSDownload *download in self.downloads) [download cancel];
        [self.downloads removeAllObjects];
        self.context.exceptionHandler = nil;
        self.invoke = nil;
        self.context = nil;
        self.evaluating = NO;
    });
}
- (void)deliver:(NSArray *)actions error:(NSError *)error {
    if (!self.evaluating || self.cancelled) return;
    self.evaluating = NO;
    for (DXJSDownload *download in self.downloads) [download cancel];
    [self.downloads removeAllObjects];
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.cancelled && self.resultHandler) self.resultHandler(actions, error);
    });
}
- (void)log:(NSString *)message {
    if (self.cancelled || !self.evaluating || self.logBytes >= 16384) return;
    NSString *bounded = message.length > 2048 ? [message substringToIndex:2048] : message;
    self.logBytes += [bounded lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
    dispatch_async(dispatch_get_main_queue(), ^{ if (!self.cancelled && self.logHandler) self.logHandler(bounded); });
}
- (void)request:(NSString *)method options:(NSDictionary *)options resolve:(JSValue *)resolve reject:(JSValue *)reject {
    if (self.cancelled || !self.evaluating) return;
    NSString *failure = nil;
    if (![options isKindOfClass:NSDictionary.class]) failure = @"HTTP options must be an object";
    NSString *address = failure ? nil : options[@"url"];
    NSURL *url = [address isKindOfClass:NSString.class] ? [NSURL URLWithString:address] : nil;
    if (!url.host.length || ![@[@"https", @"http"] containsObject:url.scheme.lowercaseString] || url.user || url.password) failure = @"Invalid HTTP(S) URL";
    if (self.downloads.count >= 8 || ++self.requests > 32) failure = @"Too many HTTP requests";
    NSMutableURLRequest *request = url ? [NSMutableURLRequest requestWithURL:url] : nil;
    request.HTTPMethod = method;
    id headers = failure ? nil : options[@"headers"];
    if (headers && ![headers isKindOfClass:NSDictionary.class]) failure = @"headers must be an object";
    if (!failure) {
        for (id key in headers) {
            id value = headers[key];
            if (![key isKindOfClass:NSString.class] || ![value isKindOfClass:NSString.class] ||
                [key rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound ||
                [value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location != NSNotFound) {
                failure = @"Invalid HTTP header"; break;
            }
            [request setValue:value forHTTPHeaderField:key];
        }
    }
    id body = failure ? nil : options[@"body"];
    if (body && body != NSNull.null) {
        if (![body isKindOfClass:NSString.class]) failure = @"body must be a string; use JSON.stringify for JSON";
        else request.HTTPBody = [body dataUsingEncoding:NSUTF8StringEncoding];
    }
    if (request.HTTPBody.length > DXJSMaxBytes) failure = @"Request exceeds 1 MiB";
    if (failure) { [reject callWithArguments:@[failure]]; return; }
    NSUInteger invocation = self.invocation;
    DXJSDownload *download = [DXJSDownload new];
    __weak typeof(self) weakSelf = self;
    __weak DXJSDownload *weakDownload = download;
    download.completion = ^(NSString *text, NSError *error) {
        typeof(self) engine = weakSelf;
        if (!engine) return;
        dispatch_async(engine.queue, ^{
            DXJSDownload *finished = weakDownload;
            if (finished) [engine.downloads removeObject:finished];
            if (engine.cancelled || !engine.evaluating || invocation != engine.invocation) return;
            [(error ? reject : resolve) callWithArguments:@[error ? error.localizedDescription : (text ?: @"")]];
            if (engine.executionLimitReached) [engine deliver:nil error:DXJSError(@"Script exceeded the CPU time limit")];
            if (engine.context.exception) [engine deliver:nil error:DXJSError([engine.context.exception toString])];
        });
    };
    [self.downloads addObject:download];
    [download start:request];
}
static bool DXJSTerminate(JSContextRef context, void *data) {
    (void)context;
    ((__bridge DXJavaScriptEngine *)data).executionLimitReached = YES;
    return true;
}
- (BOOL)prepare {
    // A dispatch timer cannot interrupt JS. Require the VM watchdog before
    // executing any user code, including top-level code and JSON conversion.
    typedef void (*SetLimit)(JSContextGroupRef, double, bool (*)(JSContextRef, void *), void *);
    SetLimit limit = (SetLimit)dlsym(RTLD_DEFAULT, "JSContextGroupSetExecutionTimeLimit");
    if (!limit) { [self deliver:nil error:DXJSError(@"JavaScript execution limit is unavailable on this system")]; return NO; }
    self.context = [[JSContext alloc] initWithVirtualMachine:[JSVirtualMachine new]];
    limit(JSContextGetGroup(self.context.JSGlobalContextRef), 0.5, DXJSTerminate, (__bridge void *)self);
    __weak typeof(self) weakSelf = self;
    self.context.exceptionHandler = ^(JSContext *context, JSValue *exception) {
        context.exception = exception;
        [weakSelf deliver:nil error:DXJSError([exception toString])];
    };
    self.context[@"__txDone"] = ^(NSString *json, NSString *failure) {
        typeof(self) engine = weakSelf;
        if (!engine || engine.cancelled || !engine.evaluating) return;
        if (failure.length) { [engine deliver:nil error:DXJSError(failure)]; return; }
        NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
        NSError *error = nil;
        id result = data.length <= DXJSMaxBytes ? [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingFragmentsAllowed error:&error] : nil;
        if (!data || data.length > DXJSMaxBytes) error = DXJSError(@"Result exceeds 1 MiB");
        NSArray *actions = error ? nil : [DXJavaScriptEngine actionsForResult:result error:&error];
        [engine deliver:actions error:error];
    };
    self.context[@"__txLog"] = ^(NSString *message) { [weakSelf log:message ?: @""]; };
    self.context[@"__txAction"] = ^(NSString *type, NSString *content) {
        typeof(self) engine = weakSelf;
        if (!engine || engine.cancelled || !engine.evaluating) return;
        if (++engine.directActions > 8 || content.length > 16384) {
            [engine deliver:nil error:DXJSError(@"Too many or oversized direct actions")]; return;
        }
        NSDictionary *action = @{@"type": type ?: @"", @"content": content ?: @""};
        dispatch_async(dispatch_get_main_queue(), ^{ if (!engine.cancelled && engine.actionHandler) engine.actionHandler(action); });
    };
    self.context[@"__txHTTP"] = ^(NSString *method, JSValue *options, JSValue *resolve, JSValue *reject) {
        @try { [weakSelf request:method options:[options toDictionary] resolve:resolve reject:reject]; }
        @catch (__unused NSException *exception) { [reject callWithArguments:@[@"Invalid HTTP request"]]; }
    };
    // Capture callbacks before evaluating user code. Keep invocation and its
    // Promise bookkeeping outside the script's global namespace.
    self.invoke = [self.context evaluateScript:
        @"(function(done,log,action,http){ 'use strict';"
         "const P=Promise, stringify=JSON.stringify;"
         "globalThis.console={log:(...v)=>log(v.map(String).join(' ')),error:(...v)=>log(v.map(String).join(' '))};"
         "globalThis.$url={open:u=>action('url',String(u)),openInApp:u=>action('urlInApp',String(u))};"
         "globalThis.$app={open:u=>action('app',String(u))};"
         "globalThis.$http={};"
         "for(const m of ['get','post','put','patch','delete']) $http[m]=o=>new P((yes,no)=>http(m.toUpperCase(),o,yes,e=>no(new Error(e))));"
         "delete globalThis.__txDone;delete globalThis.__txLog;delete globalThis.__txAction;delete globalThis.__txHTTP;"
         "return function(fn,args){ P.resolve().then(()=>{if(typeof fn!=='function')throw new Error('Missing function');return fn(...args);})"
         ".then(value=>{const json=stringify(value===undefined?null:value);if(json===undefined)throw new Error('Unsupported result');done(json,'');})"
         ".catch(error=>done('',String(error))); };"
         "})(__txDone,__txLog,__txAction,__txHTTP)"];
    return self.invoke && !self.context.exception;
}
- (void)beginInvocation {
    self.evaluating = YES;
    self.invocation++;
    NSUInteger invocation = self.invocation;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), self.queue, ^{
        typeof(self) engine = weakSelf;
        if (engine && engine.invocation == invocation && engine.evaluating && !engine.cancelled) {
            [engine deliver:nil error:DXJSError(@"Script timed out (30 seconds)")];
        }
    });
}
- (void)runSource:(NSString *)source input:(NSString *)input {
    dispatch_async(self.queue, ^{
        if (self.cancelled || self.context) return;
        [self beginInvocation];
        if (source.length == 0 || source.length > 131072 || input.length > DXJSMaxBytes) {
            [self deliver:nil error:DXJSError(@"Empty or oversized script/input")]; return;
        }
        if (![self prepare]) return;
        [self.context evaluateScript:source withSourceURL:[NSURL URLWithString:@"mubx-script:///action.js"]];
        if (self.executionLimitReached) [self deliver:nil error:DXJSError(@"Script exceeded the CPU time limit")];
        if (!self.evaluating || self.context.exception) return;
        [self.invoke callWithArguments:@[self.context[@"main"], @[input ?: @""]]];
        if (self.executionLimitReached) [self deliver:nil error:DXJSError(@"Script exceeded the CPU time limit")];
    });
}
- (void)callFunction:(NSString *)name arguments:(NSArray *)arguments {
    dispatch_async(self.queue, ^{
        if (self.cancelled || !self.context || self.evaluating) return;
        [self beginInvocation];
        if (++self.calls > 16) { [self deliver:nil error:DXJSError(@"Function chain exceeds 16 calls")]; return; }
        self.context.exception = nil;
        [self.invoke callWithArguments:@[self.context[name], arguments ?: @[]]];
        if (self.executionLimitReached) [self deliver:nil error:DXJSError(@"Script exceeded the CPU time limit")];
    });
}
@end
