#import <Foundation/Foundation.h>
#include <math.h>
#include <stdint.h>

static NSString * const DXFloatInputSessionName = @"com.lindo.mubx.floating-input.session-v1";
static inline NSString *DXFloatInputName(uint32_t pid) {
    return [NSString stringWithFormat:@"com.lindo.mubx.floating-input.pinch-v1.%u", pid];
}
static inline NSString *DXFloatInputSceneName(uint32_t pid) {
    return [NSString stringWithFormat:@"com.lindo.mubx.floating-input.scene-v1.%u", pid];
}
static inline uint64_t DXFloatInputSceneHash(NSString *identifier) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return 0;
    const char *bytes = identifier.UTF8String;
    if (!bytes) return 0;
    uint64_t hash = 14695981039346656037ULL;
    for (const unsigned char *p = (const unsigned char *)bytes; *p; p++) {
        hash ^= *p; hash *= 1099511628211ULL;
    }
    return hash ?: 1;
}
typedef NS_ENUM(uint32_t, DXFloatPinchPhase) {
    DXFloatPinchBegan, DXFloatPinchChanged, DXFloatPinchEnded, DXFloatPinchCancelled
};
static inline uint64_t DXFloatInputSessionWord(uint32_t pid, uint32_t nonce) {
    return ((uint64_t)nonce << 32) | pid;
}
static inline uint64_t DXFloatPinchWord(uint32_t nonce, uint8_t gesture, DXFloatPinchPhase phase, double scale) {
    if (!nonce || !gesture || phase > DXFloatPinchCancelled || !isfinite(scale) || scale <= 0) return 0;
    uint32_t quantized = (uint32_t)lround(fmin(16, fmax(.001, scale)) * 1000);
    return ((uint64_t)nonce << 32) | ((uint32_t)phase << 24) | ((uint32_t)gesture << 16) | quantized;
}
static inline BOOL DXFloatDecodePinch(uint64_t word, uint32_t nonce, uint8_t *gesture,
                                     DXFloatPinchPhase *phase, double *scale) {
    uint32_t quantized = word & 0xffff;
    uint8_t serial = (word >> 16) & 0xff;
    if (!nonce || (uint32_t)(word >> 32) != nonce || (word & 0xfc000000ULL) ||
        !serial || !quantized || quantized > 16000) return NO;
    *gesture = serial; *phase = (DXFloatPinchPhase)((word >> 24) & 3); *scale = quantized / 1000.0;
    return YES;
}
FOUNDATION_EXPORT void DXStartFloatingAppInputClient(void);
