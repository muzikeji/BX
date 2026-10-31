#import "DXAIEngine.h"
#import "common.h"
#import "DXShared.h"

// SSE 流式客户端。所有引擎统一 OpenAI 兼容协议：
//   请求  POST {endpoint}/chat/completions  {model, messages, stream}
//   流式  data: {choices:[{delta:{content}}]} 行，data: [DONE] 结束
//   非流式 响应体 {choices:[{message:{content}}]}
// Gemini 走其 OpenAI 兼容端点，协议同上。
@interface DXAIStreamSink : NSObject <NSURLSessionDataDelegate>
@property (nonatomic, copy) void (^onDelta)(NSString *piece);
@property (nonatomic, copy) void (^onFinish)(NSString *fullText, NSError *error);
@property (nonatomic, assign) BOOL wantsStream;
@property (nonatomic, strong) NSMutableData *lineBuffer;   // SSE 跨 chunk 行缓冲
@property (nonatomic, strong) NSMutableData *rawBody;      // 非流式响应 / 错误体
@property (nonatomic, strong) NSMutableString *fullText;
@property (nonatomic, assign) NSInteger httpStatus;
@property (nonatomic, assign) BOOL streamBroken;           // 流中途出现 [DONE]/错误
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSURLSessionDataTask *task;
- (void)consumeData:(NSData *)data;
- (void)finishWithError:(NSError *)error;
@end

@implementation DXAIEngineInfo
@end

@implementation DXAIStreamSink

- (instancetype)init {
    if ((self = [super init])) {
        self.lineBuffer = [NSMutableData data];
        self.rawBody = [NSMutableData data];
        self.fullText = [NSMutableString string];
    }
    return self;
}

- (void)appendText:(NSString *)piece {
    if (piece.length == 0) return;
    [self.fullText appendString:piece];
    if (self.onDelta) self.onDelta(piece);
}

// 解析一条 SSE data 载荷；返回 YES 表示会话应结束（[DONE] 或已报错）。
- (BOOL)consumeSSEPayload:(NSString *)payload {
    NSString *trimmed = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return NO;
    if ([trimmed isEqualToString:@"[DONE]"]) return YES;

    NSData *json = [trimmed dataUsingEncoding:NSUTF8StringEncoding];
    id object = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
    if (![object isKindOfClass:[NSDictionary class]]) return NO;

    // HTTP 层成功但业务报错（部分端点在流里吐 {"error":...}）。
    NSDictionary *errorBody = [object[@"error"] isKindOfClass:[NSDictionary class]] ? object[@"error"] : nil;
    if (errorBody) {
        NSString *message = [errorBody[@"message"] isKindOfClass:[NSString class]] ? errorBody[@"message"] : @"server error";
        if (!self.streamBroken) {
            self.streamBroken = YES;
            [self finishWithError:[NSError errorWithDomain:@"DXAIChat" code:-3
                                                  userInfo:@{NSLocalizedDescriptionKey: message}]];
        }
        return YES;
    }

    NSArray *choices = [object[@"choices"] isKindOfClass:[NSArray class]] ? object[@"choices"] : nil;
    NSDictionary *first = [choices.firstObject isKindOfClass:[NSDictionary class]] ? choices.firstObject : nil;
    NSDictionary *delta = [first[@"delta"] isKindOfClass:[NSDictionary class]] ? first[@"delta"] : nil;
    id piece = delta[@"content"] ?: first[@"text"]; // text: 老 completions 形态兜底
    if ([piece isKindOfClass:[NSString class]]) [self appendText:piece];
    return NO;
}

- (void)consumeData:(NSData *)data {
    if (!data.length) return;
    if (self.wantsStream && self.httpStatus >= 200 && self.httpStatus < 300 && !self.streamBroken) {
        [self.lineBuffer appendData:data];
        // SSE 事件以单个 \n 分行；缓冲区尾可能留半行，只消费完整行。
        static NSData *newline;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{ newline = [@"\n" dataUsingEncoding:NSUTF8StringEncoding]; });
        NSRange range;
        while ((range = [self.lineBuffer rangeOfData:newline options:0 range:NSMakeRange(0, self.lineBuffer.length)]).location != NSNotFound) {
            NSData *lineData = [self.lineBuffer subdataWithRange:NSMakeRange(0, range.location)];
            [self.lineBuffer replaceBytesInRange:NSMakeRange(0, range.location + newline.length) withBytes:"" length:0];
            NSString *line = [[NSString alloc] initWithData:lineData encoding:NSUTF8StringEncoding];
            if (!line) continue;
            line = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (line.length == 0 || [line hasPrefix:@":"]) continue;         // 注释/心跳
            if ([line hasPrefix:@"data:"]) {
                if ([self consumeSSEPayload:[line substringFromIndex:5]]) return;
            }
        }
        return;
    }
    [self.rawBody appendData:data];
}

- (void)finishWithError:(NSError *)error {
    if (self.onFinish) {
        void (^onFinish)(NSString *, NSError *) = self.onFinish;
        self.onFinish = nil; // 恰好一次
        onFinish(self.fullText, error);
    }
}

// 响应体终判：流式已产出内容则成功收尾；否则解析非流式 JSON 或错误体。
- (void)finalizeAfterStatus {
    if (self.httpStatus < 200 || self.httpStatus >= 300) {
        NSString *body = [[NSString alloc] initWithData:self.rawBody encoding:NSUTF8StringEncoding];
        NSString *message = nil;
        id object = body ? [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        if ([object isKindOfClass:[NSDictionary class]]) {
            id err = object[@"error"];
            if ([err isKindOfClass:[NSString class]]) message = err;
            else if ([err isKindOfClass:[NSDictionary class]] && [err[@"message"] isKindOfClass:[NSString class]]) message = err[@"message"];
        }
        if (message.length == 0) message = [body length] > 0 ? [body substringToIndex:MIN(200, body.length)] : [NSString stringWithFormat:@"HTTP %ld", (long)self.httpStatus];
        [self finishWithError:[NSError errorWithDomain:@"DXAIChat" code:self.httpStatus
                                              userInfo:@{NSLocalizedDescriptionKey: message}]];
        return;
    }
    if (self.fullText.length > 0) {
        [self finishWithError:nil];
        return;
    }
    // 非流式：整包解析 message.content。
    id object = [NSJSONSerialization JSONObjectWithData:self.rawBody options:0 error:nil];
    if ([object isKindOfClass:[NSDictionary class]]) {
        NSArray *choices = [object[@"choices"] isKindOfClass:[NSArray class]] ? object[@"choices"] : nil;
        NSDictionary *first = [choices.firstObject isKindOfClass:[NSDictionary class]] ? choices.firstObject : nil;
        NSDictionary *message = [first[@"message"] isKindOfClass:[NSDictionary class]] ? first[@"message"] : nil;
        id content = message[@"content"] ?: first[@"text"];
        if ([content isKindOfClass:[NSString class]]) [self appendText:content];
    }
    if (self.fullText.length == 0) {
        [self finishWithError:[NSError errorWithDomain:@"DXAIChat" code:-2
                                              userInfo:@{NSLocalizedDescriptionKey: @"empty response"}]];
        return;
    }
    [self finishWithError:nil];
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    self.httpStatus = [(NSHTTPURLResponse *)response statusCode];
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask
        didReceiveData:(NSData *)data {
    [self consumeData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
    if (error && error.code != NSURLErrorCancelled) {
        [self finishWithError:error];
        return;
    }
    [self finalizeAfterStatus];
}

@end

@interface DXAIChatRequest ()
@property (nonatomic, strong) DXAIStreamSink *sink;
@end

@implementation DXAIChatRequest
- (void)cancel {
    [self.sink.task cancel];
    // 立即收尾：didCompleteWithError 仍会到，但 finish 恰好一次的守卫保证
    // onDone 只被调用一次（cancel 的错误码 -999）。
    [self.sink finishWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil]];
}
@end

@implementation DXAIEngine

#pragma mark - 引擎预设

+ (NSArray<DXAIEngineInfo *> *)allEngines {
    static NSArray *engines;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        engines = @[[self engineWithID:@"qwen" name:@"通义千问"
                              baseURL:@"https://dashscope.aliyuncs.com/compatible-mode/v1"
                              models:@"qwen3.8-flash\nqwen3-vl-flash"
                             keysURL:@"https://bailian.console.aliyun.com/?apiKey=1#/api-key"],
                    [self engineWithID:@"deepseek" name:@"DeepSeek"
                              baseURL:@"https://api.deepseek.com/v1"
                              models:@"deepseek-chat\ndeepseek-reasoner"
                             keysURL:@"https://platform.deepseek.com/api_keys"],
                    [self engineWithID:@"openai" name:@"OpenAI"
                              baseURL:@"https://api.openai.com/v1"
                              models:@"gpt-4o-mini\ngpt-4o"
                             keysURL:@"https://platform.openai.com/api-keys"],
                    [self engineWithID:@"siliconflow" name:@"硅基流动"
                              baseURL:@"https://api.siliconflow.cn/v1"
                              models:@"deepseek-ai/DeepSeek-V3\nQwen/Qwen2.5-7B-Instruct"
                             keysURL:@"https://cloud.siliconflow.cn/account/ak"],
                    [self engineWithID:@"doubao" name:@"豆包"
                              baseURL:@"https://ark.cn-beijing.volces.com/api/v3"
                              models:@""
                             keysURL:@"https://console.volcengine.com/ark/region:ark-cn-beijing/apiKey"],
                    [self engineWithID:@"zhipu" name:@"智谱"
                              baseURL:@"https://open.bigmodel.cn/api/paas/v4"
                              models:@"glm-4-flash\nglm-4-plus"
                             keysURL:@"https://open.bigmodel.cn/usercenter/apikeys"],
                    [self engineWithID:@"gemini" name:@"Gemini"
                              baseURL:@"https://generativelanguage.googleapis.com/v1beta/openai"
                              models:@"gemini-2.0-flash\ngemini-1.5-flash"
                             keysURL:@"https://aistudio.google.com/apikey"]];
    });
    return engines;
}

+ (DXAIEngineInfo *)engineWithID:(NSString *)identifier name:(NSString *)name
                         baseURL:(NSString *)baseURL models:(NSString *)models keysURL:(NSString *)keysURL {
    DXAIEngineInfo *engine = [[DXAIEngineInfo alloc] init];
    engine.identifier = identifier;
    engine.displayName = name;
    engine.baseURL = baseURL;
    engine.defaultModels = models;
    engine.keysURL = keysURL;
    return engine;
}

+ (DXAIEngineInfo *)engineForIdentifier:(NSString *)identifier {
    for (DXAIEngineInfo *engine in [self allEngines]) {
        if ([engine.identifier isEqualToString:identifier]) return engine;
    }
    for (DXAIEngineInfo *engine in [self customEngines]) {
        if ([engine.identifier isEqualToString:identifier]) return engine;
    }
    return [self allEngines].firstObject;
}

+ (DXAIEngineInfo *)currentEngine {
    // 面板打开时偏好快照可能刚被 Settings 改过而 Darwin 通知尚未派发；打开
    // 路径先 reload 一次再读。
    [[DXPrefsManager sharedInstance] reload];
    NSString *identifier = [self prefStringForKey:DXAIPrefEngine] ?: @"qwen";
    return [self engineForIdentifier:identifier];
}

+ (NSString *)prefStringForKey:(NSString *)key {
    id value = [DXPrefsManager sharedInstance].prefs[key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

#pragma mark - 自定义引擎列表

// aiCustomEngines 列表元素：{id, name, endpoint, key, models, selected}。
// 首次读取时迁移旧的单条自定义引擎（aiCustomEndpoint/aiCustomName/aiKey_custom…）。
+ (NSMutableArray<NSMutableDictionary *> *)customEngineDicts {
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    id value = manager.prefs[DXAIPrefCustomEngines];
    if ([value isKindOfClass:[NSArray class]]) {
        NSMutableArray<NSMutableDictionary *> *dicts = [NSMutableArray array];
        for (id entry in value) {
            if ([entry isKindOfClass:[NSDictionary class]]) [dicts addObject:[entry mutableCopy]];
        }
        return dicts;
    }

    NSMutableArray<NSMutableDictionary *> *dicts = [NSMutableArray array];
    NSString *legacyEndpoint = [self prefStringForKey:DXAIPrefCustomEndpoint];
    if (legacyEndpoint.length > 0) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"id"] = @"c1";
        dict[@"name"] = [self prefStringForKey:DXAIPrefCustomName] ?: @"自定义";
        dict[@"endpoint"] = legacyEndpoint;
        dict[@"key"] = [self prefStringForKey:[DXAIPrefKeyPrefix stringByAppendingString:@"custom"]] ?: @"";
        dict[@"models"] = [self prefStringForKey:[DXAIPrefModelsPrefix stringByAppendingString:@"custom"]] ?: @"";
        dict[@"selected"] = [self prefStringForKey:[DXAIPrefSelectedPrefix stringByAppendingString:@"custom"]] ?: @"";
        [dicts addObject:dict];
    }
    if (manager.preferencesAvailable) {
        [manager setValue:dicts forKey:DXAIPrefCustomEngines];
        // 旧 aiEngine=custom 指到迁移产物；没有迁移产物则回退通义。
        if ([[self prefStringForKey:DXAIPrefEngine] isEqualToString:@"custom"]) {
            [manager setValue:dicts.count > 0 ? @"c1" : @"qwen" forKey:DXAIPrefEngine];
        }
    }
    return dicts;
}

+ (id)customEngineValueForID:(NSString *)engineID key:(NSString *)field {
    for (NSMutableDictionary *dict in [self customEngineDicts]) {
        if ([dict[@"id"] isKindOfClass:[NSString class]] && [dict[@"id"] isEqualToString:engineID]) {
            id value = dict[field];
            return [value isKindOfClass:[NSString class]] || [value isKindOfClass:[NSNumber class]] ? value : nil;
        }
    }
    return nil;
}

+ (NSArray<DXAIEngineInfo *> *)customEngines {
    NSMutableArray<DXAIEngineInfo *> *engines = [NSMutableArray array];
    for (NSMutableDictionary *dict in [self customEngineDicts]) {
        DXAIEngineInfo *engine = [[DXAIEngineInfo alloc] init];
        engine.custom = YES;
        engine.identifier = [dict[@"id"] isKindOfClass:[NSString class]] ? dict[@"id"] : @"";
        engine.displayName = ([dict[@"name"] isKindOfClass:[NSString class]] && ((NSString *)dict[@"name"]).length > 0)
            ? dict[@"name"] : @"自定义";
        engine.baseURL = [dict[@"endpoint"] isKindOfClass:[NSString class]] ? dict[@"endpoint"] : @"";
        engine.defaultModels = [dict[@"models"] isKindOfClass:[NSString class]] ? dict[@"models"] : @"";
        engine.keysURL = @"";
        [engines addObject:engine];
    }
    return engines;
}

+ (NSString *)addCustomEngineWithName:(NSString *)name
                             endpoint:(NSString *)endpoint
                               apiKey:(NSString *)apiKey
                                models:(NSString *)models {
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    NSString *engineID = [NSString stringWithFormat:@"c%.0f", [NSDate date].timeIntervalSince1970 * 1000.0];
    NSMutableArray<NSMutableDictionary *> *dicts = [self customEngineDicts];
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"id"] = engineID;
    dict[@"name"] = name.length > 0 ? name : @"自定义";
    dict[@"endpoint"] = endpoint ?: @"";
    dict[@"key"] = apiKey ?: @"";
    dict[@"models"] = models ?: @"";
    dict[@"selected"] = @"";
    [dicts addObject:dict];
    [manager setValue:dicts forKey:DXAIPrefCustomEngines];
    return engineID;
}

+ (void)updateCustomEngineWithID:(NSString *)engineID key:(NSString *)field value:(id)value {
    if (engineID.length == 0 || field.length == 0 || !value) return;
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    NSMutableArray<NSMutableDictionary *> *dicts = [self customEngineDicts];
    for (NSMutableDictionary *dict in dicts) {
        if ([dict[@"id"] isKindOfClass:[NSString class]] && [dict[@"id"] isEqualToString:engineID]) {
            dict[field] = value;
            [manager setValue:dicts forKey:DXAIPrefCustomEngines];
            return;
        }
    }
}

+ (void)removeCustomEngineWithID:(NSString *)engineID {
    if (engineID.length == 0) return;
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    NSMutableArray<NSMutableDictionary *> *dicts = [self customEngineDicts];
    NSMutableArray<NSMutableDictionary *> *kept = [NSMutableArray array];
    for (NSMutableDictionary *dict in dicts) {
        if ([dict[@"id"] isKindOfClass:[NSString class]] && [dict[@"id"] isEqualToString:engineID]) continue;
        [kept addObject:dict];
    }
    [manager setValue:kept forKey:DXAIPrefCustomEngines];
    if ([[self prefStringForKey:DXAIPrefEngine] isEqualToString:engineID]) {
        [manager setValue:@"qwen" forKey:DXAIPrefEngine];
    }
}

#pragma mark - 人设库

// 人设元素：{id, name, content, role, enabled}。role 是历史字段仅随旧数据保留，
// 不再参与默认人设选择；列表第一项即默认人设，全部可删可改，删空后请求回退
// 面板内建的兜底提示词。
+ (NSDictionary *)personaDictWithID:(NSString *)personaID
                               name:(NSString *)name
                               role:(NSString *)role
                            content:(NSString *)content {
    return @{@"id": personaID,
             @"name": name,
             @"content": content ?: @"",
             @"role": role ?: @"",
             @"enabled": @(YES)};
}

// 出厂人设种子顺序即默认排序：AI问答助手在首位，保证全新安装的默认人设
// 与旧版（role=chat）行为一致。
+ (NSArray<NSDictionary *> *)defaultPersonas {
    return @[[self personaDictWithID:@"p-chat"
                                name:@"AI问答助手"
                                role:@"chat"
                             content:@"你是AI问答助手。请用简洁中文回答用户的问题：先给结论，再补细节；准确、不编造。"],
             [self personaDictWithID:@"p-image"
                                name:@"截图分析助手"
                                role:@"image"
                             content:@"你是截图分析助手。请根据用户发来的截图与问题，用简洁中文回答。先给结论，再补关键细节。不要编造截图中不存在的内容。"],
             [self personaDictWithID:@"p-text"
                                name:@"文字助手"
                                role:@"text"
                             content:@"你是文字助手。请根据用户提供的文字与问题，用简洁中文回答。先给结论，再补关键细节。"]];
}

+ (NSArray<NSDictionary *> *)personas {
    DXPrefsManager *manager = [DXPrefsManager sharedInstance];
    [manager reload];
    id value = manager.prefs[DXAIPrefPersonas];
    if ([value isKindOfClass:[NSArray class]]) return value;

    NSMutableArray<NSDictionary *> *seeded = [[self defaultPersonas] mutableCopy];
    // 旧的单条人设文本迁入 AI问答助手（种子首位），用户写过的提示词不丢。
    NSString *legacy = [self prefStringForKey:DXAIPrefPersona];
    if (legacy.length > 0) {
        NSMutableDictionary *chat = [seeded[0] mutableCopy];
        chat[@"content"] = legacy;
        seeded[0] = chat;
    }
    if (manager.preferencesAvailable) [self setPersonas:seeded];
    return seeded;
}

+ (void)setPersonas:(NSArray<NSDictionary *> *)personas {
    NSMutableArray<NSDictionary *> *sanitized = [NSMutableArray array];
    for (NSDictionary *persona in personas) {
        if ([persona isKindOfClass:[NSDictionary class]]) [sanitized addObject:persona];
    }
    [[DXPrefsManager sharedInstance] setValue:sanitized forKey:DXAIPrefPersonas];
}

+ (NSDictionary *)personaForID:(NSString *)personaID {
    if (personaID.length == 0) return nil;
    for (NSDictionary *persona in [self personas]) {
        if ([persona[@"id"] isKindOfClass:[NSString class]] && [persona[@"id"] isEqualToString:personaID]) return persona;
    }
    return nil;
}

+ (NSDictionary *)defaultPersona {
    id first = [self personas].firstObject;
    return [first isKindOfClass:[NSDictionary class]] ? first : nil;
}

#pragma mark - 配置读取

+ (NSString *)apiKeyForEngine:(DXAIEngineInfo *)engine {
    if (engine.overrideAPIKey.length > 0) return engine.overrideAPIKey;
    if (engine.custom) return [self customEngineValueForID:engine.identifier key:@"key"] ?: @"";
    return [self prefStringForKey:[DXAIPrefKeyPrefix stringByAppendingString:engine.identifier]] ?: @"";
}

+ (NSString *)endpointForEngine:(DXAIEngineInfo *)engine {
    // 内置引擎用预设端点；自定义引擎的端点在 info.baseURL 里（编辑页临时
    // info 则带着未保存的输入值）。快速添加允许直接粘完整对话端点，剥掉
    // /chat/completions 还原 Base URL——聊天与模型抓取都从这里拼路径。
    NSString *endpoint = engine.baseURL ?: @"";
    endpoint = [endpoint stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    while ([endpoint hasSuffix:@"/"]) endpoint = [endpoint substringToIndex:endpoint.length - 1];
    if ([endpoint.lowercaseString hasSuffix:@"/chat/completions"]) {
        endpoint = [endpoint substringToIndex:endpoint.length - @"/chat/completions".length];
        while ([endpoint hasSuffix:@"/"]) endpoint = [endpoint substringToIndex:endpoint.length - 1];
    }
    // 同理兼容直接粘模型列表 URL（…/models 结尾），否则会拼出 /models/models。
    if ([endpoint.lowercaseString hasSuffix:@"/models"]) {
        endpoint = [endpoint substringToIndex:endpoint.length - @"/models".length];
        while ([endpoint hasSuffix:@"/"]) endpoint = [endpoint substringToIndex:endpoint.length - 1];
    }
    return endpoint;
}

+ (NSArray<NSString *> *)modelsForEngine:(DXAIEngineInfo *)engine {
    // 列表存储约定：每行一个模型；兼容旧数据的逗号分隔（模型 ID 实际不含逗号，
    // 硅基流动等含 / 的 ID 不受影响）。
    NSString *stored = engine.custom
        ? engine.defaultModels
        : ([self prefStringForKey:[DXAIPrefModelsPrefix stringByAppendingString:engine.identifier]] ?: engine.defaultModels);
    NSMutableArray *models = [NSMutableArray array];
    NSCharacterSet *separators = [NSCharacterSet characterSetWithCharactersInString:@",\n\r"];
    for (NSString *piece in [stored componentsSeparatedByCharactersInSet:separators]) {
        NSString *model = [piece stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (model.length > 0) [models addObject:model];
    }
    return models;
}

+ (NSString *)selectedModelForEngine:(DXAIEngineInfo *)engine {
    NSString *selected = engine.custom
        ? [self customEngineValueForID:engine.identifier key:@"selected"]
        : [self prefStringForKey:[DXAIPrefSelectedPrefix stringByAppendingString:engine.identifier]];
    if (![selected isKindOfClass:[NSString class]]) selected = nil;
    if (selected.length > 0 && [[self modelsForEngine:engine] containsObject:selected]) return selected;
    return [self modelsForEngine:engine].firstObject ?: @"";
}

+ (void)setSelectedModelForEngine:(DXAIEngineInfo *)engine model:(NSString *)model {
    if (engine.custom) {
        [self updateCustomEngineWithID:engine.identifier key:@"selected" value:model ?: @""];
        return;
    }
    [[DXPrefsManager sharedInstance] setValue:model
                                       forKey:[DXAIPrefSelectedPrefix stringByAppendingString:engine.identifier]];
}

#pragma mark - 面板行为偏好

+ (BOOL)streamEnabled {
    id value = [DXPrefsManager sharedInstance].prefs[DXAIPrefStream];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : YES;
}

+ (NSString *)personaPrompt {
    return [self prefStringForKey:DXAIPrefPersona] ?: @"";
}

#pragma mark - 请求

+ (NSURLSession *)ephemeralSession {
    return [self ephemeralSessionWithDelegate:nil];
}

// delegate 必须在 session 创建时传入——[NSURLSession sessionWithConfiguration:]
// 单参形式的 delegate 恒为 nil，事后无法补挂。聊天路径把流式 sink 传进来，
// didReceiveData/didCompleteWithError 才有归宿；session 会强持有 delegate
// 直到 invalidate，sink 的生命周期由会话保证。
+ (NSURLSession *)ephemeralSessionWithDelegate:(id)delegate {
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 90.0;
    configuration.timeoutIntervalForResource = 300.0;
    configuration.URLCache = nil;
    return [NSURLSession sessionWithConfiguration:configuration
                                         delegate:delegate
                                    delegateQueue:nil];
}

+ (DXAIChatRequest *)sendChatWithMessages:(NSArray<NSDictionary *> *)messages
                      engine:(DXAIEngineInfo *)engine
                       onDelta:(void (^)(NSString *piece))onDelta
                      onDone:(void (^)(NSString *fullText, NSError *error))onDone {
    NSString *endpoint = [self endpointForEngine:engine];
    NSString *apiKey = [self apiKeyForEngine:engine];
    NSString *model = [self selectedModelForEngine:engine];
    if (endpoint.length == 0 || model.length == 0) {
        onDone(@"", [NSError errorWithDomain:@"DXAIChat" code:-10
                                    userInfo:@{NSLocalizedDescriptionKey: @"engine endpoint or model missing"}]);
        return nil;
    }

    BOOL stream = [self streamEnabled];
    NSDictionary *payload = @{@"model": model,
                              @"messages": messages ?: @[],
                              @"stream": @(stream)};

    // 自定义接口地址可能带空格/中文/漏 scheme，URLWithString 返回 nil 时直接
    // 走失败回调——承载进程是 SpringBoard，这里抛异常会带走整个桌面。
    NSURL *chatURL = [NSURL URLWithString:[endpoint stringByAppendingString:@"/chat/completions"]];
    if (!chatURL) {
        onDone(@"", [NSError errorWithDomain:@"DXAIChat" code:-10
                                    userInfo:@{NSLocalizedDescriptionKey: @"接口地址无效，无法构造请求"}]);
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:chatURL];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    if (apiKey.length > 0) [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
    request.HTTPBody = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];

    DXAIStreamSink *sink = [[DXAIStreamSink alloc] init];
    sink.wantsStream = stream;
    __weak DXAIStreamSink *weakSink = sink;
    sink.onDelta = onDelta;
    sink.onFinish = ^(NSString *fullText, NSError *error) {
        onDone(fullText ?: @"", error);
        // NSURLSession 强持有 delegate 直到 invalidate；显式断开避免每次
        // 对话泄漏一条会话。
        [weakSink.session finishTasksAndInvalidate];
    };
    sink.session = [self ephemeralSessionWithDelegate:sink];
    NSURLSessionDataTask *task = [sink.session dataTaskWithRequest:request];
    sink.task = task;
    [task resume];

    DXAIChatRequest *chatRequest = [[DXAIChatRequest alloc] init];
    chatRequest.sink = sink;
    return chatRequest;
}

#pragma mark - 模型列表抓取（多厂商）

// 模型获取的厂商适配按接口地址识别，OpenAI 兼容形态为兜底：
//   OpenAI 兼容   GET {base}/models        Authorization: Bearer <key>            → {data:[{id}]}
//   Gemini 原生   GET {base}/models        x-goog-api-key: <key>                  → {models:[{name:"models/x", supportedGenerationMethods:[...]}]}
//   Anthropic     GET {base}/v1/models     x-api-key: <key> + anthropic-version   → {data:[{id}]}
//   Ollama 本地   GET {base}/api/tags      无鉴权                                  → {models:[{name}]}
// 聊天请求仍统一 OpenAI 兼容协议（Gemini 预设走其 /v1beta/openai 兼容端点）。
typedef NS_ENUM(NSInteger, DXAIModelsVendor) {
    DXAIModelsVendorOpenAI = 0,
    DXAIModelsVendorGeminiNative,
    DXAIModelsVendorAnthropic,
    DXAIModelsVendorOllama,
};

static DXAIModelsVendor DXAIModelsVendorForEndpoint(NSString *endpoint) {
    NSURL *url = [NSURL URLWithString:endpoint];
    NSString *host = url.host.lowercaseString ?: @"";
    // generativelanguage.googleapis.com 一律走原生模型列表：实测其 OpenAI 兼容层
    // 的 /openai/models 在鉴权异常时只回 404/400，原生 v1beta/models +
    // x-goog-api-key 才是稳定的列表源（聊天仍走兼容端点，互不影响）。
    if ([host containsString:@"generativelanguage.googleapis.com"]) {
        return DXAIModelsVendorGeminiNative;
    }
    if ([host containsString:@"anthropic"]) return DXAIModelsVendorAnthropic;
    if (url.port.integerValue == 11434) return DXAIModelsVendorOllama; // Ollama 默认端口
    return DXAIModelsVendorOpenAI;
}

// 用户常只填 api.anthropic.com / http://127.0.0.1:11434，按已带路径补齐余下段。
static NSString *DXAIModelsPathForVendor(DXAIModelsVendor vendor, NSString *endpoint) {
    NSString *path = ([NSURL URLWithString:endpoint].path ?: @"").lowercaseString;
    switch (vendor) {
        case DXAIModelsVendorAnthropic:
            return [path containsString:@"/v1"] ? @"/models" : @"/v1/models";
        case DXAIModelsVendorOllama:
            return [path hasSuffix:@"/api"] ? @"/tags" : @"/api/tags";
        case DXAIModelsVendorGeminiNative:
        case DXAIModelsVendorOpenAI:
            return @"/models";
    }
}

// token 编写：各厂商鉴权头不同，识别错了会 401。
static void DXAIApplyModelsAuthHeaders(NSMutableURLRequest *request, DXAIModelsVendor vendor, NSString *apiKey) {
    if (apiKey.length == 0) return;
    switch (vendor) {
        case DXAIModelsVendorOpenAI:
            [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKey] forHTTPHeaderField:@"Authorization"];
            break;
        case DXAIModelsVendorGeminiNative:
            [request setValue:apiKey forHTTPHeaderField:@"x-goog-api-key"];
            break;
        case DXAIModelsVendorAnthropic:
            [request setValue:apiKey forHTTPHeaderField:@"x-api-key"];
            [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
            break;
        case DXAIModelsVendorOllama:
            break;
    }
}

// 单条模型记录 → 模型名。字段名与形态各厂商不一：字符串直接用；字典取
// id/name/model；Gemini 原生 name 带 "models/" 前缀，剥掉后与兼容端点一致。
static NSString *DXAIModelsNameFromEntry(id entry) {
    if ([entry isKindOfClass:[NSString class]]) return entry;
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;
    NSString *name = nil;
    for (NSString *field in @[@"id", @"name", @"model"]) {
        id value = entry[field];
        if ([value isKindOfClass:[NSString class]] && ((NSString *)value).length > 0) {
            name = value;
            break;
        }
    }
    if (name.length == 0) return nil;
    if ([name hasPrefix:@"models/"]) name = [name substringFromIndex:7];
    return name;
}

// Gemini 原生响应带 supportedGenerationMethods：embedding/tts/audio 等不能
// 对话，从列表剔除；其余厂商无此字段，原样放行。
static BOOL DXAIModelsEntrySupportsChat(id entry) {
    if (![entry isKindOfClass:[NSDictionary class]]) return YES;
    NSArray *methods = nil;
    id value = ((NSDictionary *)entry)[@"supportedGenerationMethods"];
    if ([value isKindOfClass:[NSArray class]]) methods = value;
    if (methods.count == 0) return YES;
    for (id method in methods) {
        if ([method isKindOfClass:[NSString class]] && [method isEqualToString:@"generateContent"]) return YES;
    }
    return NO;
}

+ (void)fetchModelsForEngine:(DXAIEngineInfo *)engine
                  completion:(void (^)(NSArray<NSString *> *models, NSError *error))completion {
    NSString *endpoint = [self endpointForEngine:engine];
    if (endpoint.length == 0) {
        completion(@[], [NSError errorWithDomain:@"DXAIChat" code:-10
                                        userInfo:@{NSLocalizedDescriptionKey: @"endpoint missing"}]);
        return;
    }
    DXAIModelsVendor vendor = DXAIModelsVendorForEndpoint(endpoint);
    // 预设/用户输入可能是 Gemini 兼容路径（…/v1beta/openai）；模型列表走原生
    // 端点，剥掉兼容后缀再拼 /models。
    if (vendor == DXAIModelsVendorGeminiNative && [endpoint.lowercaseString hasSuffix:@"/openai"]) {
        endpoint = [endpoint substringToIndex:endpoint.length - @"/openai".length];
    }
    NSURL *modelsURL = [NSURL URLWithString:[endpoint stringByAppendingString:DXAIModelsPathForVendor(vendor, endpoint)]];
    if (!modelsURL) {
        completion(@[], [NSError errorWithDomain:@"DXAIChat" code:-10
                                        userInfo:@{NSLocalizedDescriptionKey: @"接口地址无效，无法构造请求"}]);
        return;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:modelsURL];
    request.HTTPMethod = @"GET";
    request.timeoutInterval = 30.0;
    DXAIApplyModelsAuthHeaders(request, vendor, [self apiKeyForEngine:engine]);
    NSLog(@"[MUBX] ai: models fetch GET %@ (vendor %ld, key %@)",
          modelsURL.absoluteString, (long)vendor,
          [self apiKeyForEngine:engine].length > 0 ? @"configured" : @"EMPTY");

    NSURLSession *session = [self ephemeralSession];
    // NSURLSession 任务创建后是挂起态，必须显式 resume 才会发出——此前返回值
    // 被丢弃且从不 resume，请求根本没离开设备，completion 永不回调（抓取按钮
    // 永远停在"抓取中…"且无任何报错），这正是全部引擎都抓不到模型的根因。
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
               completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *body = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        NSString *bodyHead = body.length > 0 ? [body substringToIndex:MIN(200, body.length)] : @"";
        if (error || status < 200 || status >= 300) {
            NSString *message = [NSString stringWithFormat:@"HTTP %ld%@",
                                 (long)status,
                                 bodyHead.length > 0 ? [NSString stringWithFormat:@" %@", bodyHead] : @""];
            NSLog(@"[MUBX] ai: models fetch failed: %@ (%@)", message, error.localizedDescription ?: @"");
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@[], error ?: [NSError errorWithDomain:@"DXAIChat" code:status userInfo:@{NSLocalizedDescriptionKey: message}]);
            });
            // NSURLSession 强持有 completionHandler 直至 invalidate，失败路径同样要断。
            [session finishTasksAndInvalidate];
            return;
        }
        id object = body ? [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil] : nil;
        NSArray *items = nil;
        if ([object isKindOfClass:[NSDictionary class]]) {
            if ([object[@"data"] isKindOfClass:[NSArray class]]) items = object[@"data"];             // OpenAI/Anthropic
            else if ([object[@"models"] isKindOfClass:[NSArray class]]) items = object[@"models"];    // Gemini 原生/Ollama
        } else if ([object isKindOfClass:[NSArray class]]) {
            items = object; // 兼容直接返回 [{"id":...}] 的端点
        }
        NSMutableArray<NSString *> *models = [NSMutableArray array];
        NSMutableSet<NSString *> *seen = [NSMutableSet set];
        for (id entry in items) {
            if (!DXAIModelsEntrySupportsChat(entry)) continue;
            NSString *name = DXAIModelsNameFromEntry(entry);
            if (name.length == 0 || [seen containsObject:name]) continue;
            [seen addObject:name];
            [models addObject:name];
        }
        if (models.count == 0) {
            // HTTP 200 但解析不出任何模型：大概率端点/响应形态不符。绝不静默
            // 返回空列表——那正是“抓取成功却一个模型都没有”的体验。
            NSLog(@"[MUBX] ai: models fetch got HTTP %ld with unparseable/empty body from %@: %@",
                  (long)status, modelsURL.absoluteString, bodyHead);
            NSString *message = [NSString stringWithFormat:@"响应无法解析为模型列表（HTTP %ld）\n%@\n%@",
                                 (long)status, modelsURL.absoluteString, bodyHead];
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(@[], [NSError errorWithDomain:@"DXAIChat" code:status userInfo:@{NSLocalizedDescriptionKey: message}]);
            });
            [session finishTasksAndInvalidate];
            return;
        }
        NSLog(@"[MUBX] ai: models fetch OK: %lu models from %@", (unsigned long)models.count, modelsURL.absoluteString);
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(models, nil);
        });
        // NSURLSession 强持有 completionHandler 直至 invalidate，用完即断。
        [session finishTasksAndInvalidate];
    }];
    [task resume];
}

@end
