#import <Foundation/Foundation.h>
#include <string.h>
#include <stdbool.h>

static inline const char *DXSystemUnqualifiedType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) type++;
    return type;
}

// Validate the runtime ABI instead of trusting historical private headers.
// Only scalar/object returns and explicitly typed arguments are supported.
static inline BOOL DXSystemInvocationRejected(id target, NSString *selector, NSString *stage) {
    NSLog(@"[MUBX][SystemAction] rejected class=%@ selector=%@ stage=%@", target ? NSStringFromClass([target class]) : @"nil", selector, stage);
    return NO;
}
static inline BOOL DXSystemInvokeReportingError(id target, NSString *name, NSArray *arguments, id *result, NSError **error) {
    if (result) *result = nil;
    if (error) *error = nil;
    NSError *__autoreleasing invocationError = nil;
    if (![name isKindOfClass:NSString.class] || !name.length || ![arguments isKindOfClass:NSArray.class]) return NO;
    SEL selector = NSSelectorFromString(name);
    if (!target || ![target respondsToSelector:selector]) return DXSystemInvocationRejected(target, name, @"missing-method");
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature || signature.numberOfArguments != arguments.count + 2) return DXSystemInvocationRejected(target, name, @"argument-count");
    const char *returned = DXSystemUnqualifiedType(signature.methodReturnType);
    if (!*returned || !strchr("v@BcCsSiIlLqQfd", *returned) || returned[1]) return DXSystemInvocationRejected(target, name, @"return-type");
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    for (NSUInteger index = 0; index < arguments.count; index++) {
        id argument = arguments[index];
        const char *type = DXSystemUnqualifiedType([signature getArgumentTypeAtIndex:index + 2]);
        if (!strcmp(type, "@") || !strcmp(type, "@?")) {
            id object = argument == NSNull.null ? nil : argument;
            [invocation setArgument:&object atIndex:index + 2];
        } else if (!strcmp(type, "^@") && argument == NSNull.null) {
            // Keep the autoreleasing out storage alive until invoke returns.
            NSError *__autoreleasing *pointer = error ? &invocationError : NULL;
            [invocation setArgument:&pointer atIndex:index + 2];
        } else {
            if (![argument isKindOfClass:NSNumber.class] || type[1]) return DXSystemInvocationRejected(target, name, @"argument-type");
#define DX_SYSTEM_ARGUMENT(CODE, TYPE, ACCESSOR) case CODE: { TYPE value = [argument ACCESSOR]; [invocation setArgument:&value atIndex:index + 2]; break; }
            switch (*type) {
                DX_SYSTEM_ARGUMENT('B', bool, boolValue)
                DX_SYSTEM_ARGUMENT('c', char, charValue)
                DX_SYSTEM_ARGUMENT('C', unsigned char, unsignedCharValue)
                DX_SYSTEM_ARGUMENT('s', short, shortValue)
                DX_SYSTEM_ARGUMENT('S', unsigned short, unsignedShortValue)
                DX_SYSTEM_ARGUMENT('i', int, intValue)
                DX_SYSTEM_ARGUMENT('I', unsigned int, unsignedIntValue)
                DX_SYSTEM_ARGUMENT('l', long, longValue)
                DX_SYSTEM_ARGUMENT('L', unsigned long, unsignedLongValue)
                DX_SYSTEM_ARGUMENT('q', long long, longLongValue)
                DX_SYSTEM_ARGUMENT('Q', unsigned long long, unsignedLongLongValue)
                DX_SYSTEM_ARGUMENT('f', float, floatValue)
                DX_SYSTEM_ARGUMENT('d', double, doubleValue)
                default: return DXSystemInvocationRejected(target, name, @"unsupported-argument");
            }
#undef DX_SYSTEM_ARGUMENT
        }
    }
    [invocation retainArguments];
    @try { [invocation invoke]; }
    @catch (NSException *exception) { NSLog(@"[MUBX][SystemAction] invocation exception=%@", exception.name); return NO; }
    if (error) *error = invocationError;
    if (*returned == 'v') return YES;
    if (*returned == '@') {
        __unsafe_unretained id object = nil;
        [invocation getReturnValue:&object];
        if (result) *result = object;
        return YES;
    }
#define DX_SYSTEM_RETURN(CODE, TYPE) case CODE: { TYPE value = 0; [invocation getReturnValue:&value]; if (result) *result = @(value); break; }
    switch (*returned) {
        DX_SYSTEM_RETURN('B', bool)
        DX_SYSTEM_RETURN('c', char)
        DX_SYSTEM_RETURN('C', unsigned char)
        DX_SYSTEM_RETURN('s', short)
        DX_SYSTEM_RETURN('S', unsigned short)
        DX_SYSTEM_RETURN('i', int)
        DX_SYSTEM_RETURN('I', unsigned int)
        DX_SYSTEM_RETURN('l', long)
        DX_SYSTEM_RETURN('L', unsigned long)
        DX_SYSTEM_RETURN('q', long long)
        DX_SYSTEM_RETURN('Q', unsigned long long)
        DX_SYSTEM_RETURN('f', float)
        DX_SYSTEM_RETURN('d', double)
        default: return NO;
    }
#undef DX_SYSTEM_RETURN
    return YES;
}

static inline BOOL DXSystemInvoke(id target, NSString *name, NSArray *arguments, id *result) {
    return DXSystemInvokeReportingError(target, name, arguments, result, NULL);
}
