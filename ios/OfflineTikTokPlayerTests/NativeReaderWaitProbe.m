#import "NativeReaderWaitProbe.h"
#include <TargetConditionals.h>
#include <mach/mach.h>
#include <mach/thread_status.h>
#include <mach/thread_info.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <dlfcn.h>
#include <stdint.h>
#include <string.h>
#if __has_feature(ptrauth_calls)
#include <ptrauth.h>
#endif

typedef struct {
    thread_t thread;
    uint64_t sequence;
    uintptr_t bottom, top;
} OPReaderContext;

// All mutation and port-reference duplication use this small lock. Never hold
// it across thread_get_state, VM reads, dladdr or a native media operation.
@implementation OPNativeReaderWaitProbe {
    pthread_mutex_t _lock;
    OPReaderContext _lanes[3];
    BOOL _closed;
}
- (instancetype)init {
    if ((self = [super init])) { pthread_mutex_init(&_lock, NULL); }
    return self;
}
- (void)noteOwnThreadForLane:(NSInteger)lane copySequence:(uint64_t)sequence {
#if TARGET_OS_SIMULATOR
    if (lane < 0 || lane >= 3 || sequence == 0) { return; }
    pthread_t own = pthread_self();
    thread_t borrowed = pthread_mach_thread_np(own);
    pthread_mutex_lock(&_lock);
    OPReaderContext *context = &_lanes[lane];
    if (!_closed && context->thread != borrowed) {
        // The owning thread is running this call, so its borrowed port is live.
        // Retain BEFORE replacing; a sampler duplicates this reference under lock.
        kern_return_t retained = mach_port_mod_refs(mach_task_self(), borrowed, MACH_PORT_RIGHT_SEND, 1);
        if (retained == KERN_SUCCESS) {
            thread_t previous = context->thread;
            uintptr_t top = (uintptr_t)pthread_get_stackaddr_np(own);
            size_t size = pthread_get_stacksize_np(own);
            *context = (OPReaderContext){borrowed, sequence, size <= top ? top - size : 0, top};
            if (previous != MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(), previous); }
        }
    }
    if (!_closed && context->thread == borrowed) { context->sequence = sequence; }
    pthread_mutex_unlock(&_lock);
#endif
}

static uintptr_t OPStripCode(uintptr_t value) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_return_address);
#else
    return value;
#endif
}
static uintptr_t OPStripData(uintptr_t value) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip((void *)value, ptrauth_key_process_independent_data);
#else
    return value;
#endif
}
static NSString *OPHex(uintptr_t value) { return [NSString stringWithFormat:@"0x%llx", (unsigned long long)value]; }
static NSString *OPBoundedName(const char *value, size_t capacity) {
    if (!value) { return @"unavailable"; }
    size_t length = strnlen(value, capacity);
    NSString *text = [[NSString alloc] initWithBytes:value length:length encoding:NSUTF8StringEncoding];
    return text ?: @"invalid-utf8";
}
static NSDictionary *OPAddress(uintptr_t address) {
    Dl_info image = {0};
    BOOL located = address && dladdr((const void *)address, &image) != 0;
    NSString *name = located ? OPBoundedName(image.dli_fname, 1024).lastPathComponent : @"unavailable";
    // Own generated-fixture app addresses only, for later exact-image symbolication.
    // Never retain stack contents, strings, URLs or arbitrary object data.
    return @{@"address": OPHex(address), @"image": name,
        @"imageBase": OPHex(located ? (uintptr_t)image.dli_fbase : 0),
        @"symbol": located ? OPBoundedName(image.dli_sname, 384) : @"unavailable",
        @"symbolOffset": @(located && image.dli_saddr && address >= (uintptr_t)image.dli_saddr
            ? address - (uintptr_t)image.dli_saddr : 0), @"located": @(located)};
}
typedef struct { uintptr_t pc, lr, sp, fp; kern_return_t result; } OPRegisters;
static OPRegisters OPRegistersFor(thread_t thread) {
    OPRegisters value = {0, 0, 0, 0, KERN_NOT_SUPPORTED};
#if defined(__arm64__)
    arm_thread_state64_t state = {0}; mach_msg_type_number_t count = ARM_THREAD_STATE64_COUNT;
    value.result = thread_get_state(thread, ARM_THREAD_STATE64, (thread_state_t)&state, &count);
    if (value.result == KERN_SUCCESS && count == ARM_THREAD_STATE64_COUNT) {
        value.pc = arm_thread_state64_get_pc(state); value.lr = arm_thread_state64_get_lr(state);
        value.sp = arm_thread_state64_get_sp(state); value.fp = arm_thread_state64_get_fp(state);
    } else if (value.result == KERN_SUCCESS) { value.result = KERN_FAILURE; }
#elif defined(__x86_64__)
    x86_thread_state64_t state = {0}; mach_msg_type_number_t count = x86_THREAD_STATE64_COUNT;
    value.result = thread_get_state(thread, x86_THREAD_STATE64, (thread_state_t)&state, &count);
    if (value.result == KERN_SUCCESS && count == x86_THREAD_STATE64_COUNT) {
        value.pc = state.__rip; value.sp = state.__rsp; value.fp = state.__rbp;
    } else if (value.result == KERN_SUCCESS) { value.result = KERN_FAILURE; }
#endif
    if (value.result == KERN_SUCCESS && value.pc == 0) { value.result = KERN_FAILURE; }
    return value;
}
- (NSDictionary<NSString *,id> *)sampleLane:(NSInteger)lane copySequence:(uint64_t)sequence {
    uint64_t begin = mach_absolute_time();
    NSMutableDictionary *result = [@{@"schema": @1, @"lane": @(lane), @"copySequence": @(sequence),
        @"available": @NO, @"frameLimit": @16, @"stackCoherent": @NO,
        @"explicitSuspend": @NO, @"kernelGetStateMayBrieflyStopThread": @YES,
        @"scope": @"recorded-own-thread-only", @"sdkInternalCause": @"unestablished"} mutableCopy];
    OPReaderContext context = {0};
    pthread_mutex_lock(&_lock);
    if (!_closed && lane >= 0 && lane < 3 && _lanes[lane].sequence == sequence) {
        context = _lanes[lane];
        if (context.thread == MACH_PORT_NULL || mach_port_mod_refs(mach_task_self(), context.thread,
            MACH_PORT_RIGHT_SEND, 1) != KERN_SUCCESS) { context.thread = MACH_PORT_NULL; }
    }
    pthread_mutex_unlock(&_lock);
    if (context.thread == MACH_PORT_NULL) { result[@"reason"] = @"no-exact-retained-context"; }
    else {
        thread_basic_info_data_t basic = {0}; mach_msg_type_number_t count = THREAD_BASIC_INFO_COUNT;
        kern_return_t basicResult = thread_info(context.thread, THREAD_BASIC_INFO, (thread_info_t)&basic, &count);
        BOOL basicValid = basicResult == KERN_SUCCESS && count == THREAD_BASIC_INFO_COUNT;
        result[@"basicReturn"] = @(basicResult); result[@"basicValid"] = @(basicValid);
        result[@"runState"] = @(basicValid ? basic.run_state : -1);
        result[@"userMicroseconds"] = @(basicValid ? (int64_t)basic.user_time.seconds * 1000000 + basic.user_time.microseconds : -1);
        result[@"systemMicroseconds"] = @(basicValid ? (int64_t)basic.system_time.seconds * 1000000 + basic.system_time.microseconds : -1);
        // get_state captures registers together, but returns before stack reads.
        // The bounded walk below is explicitly BEST EFFORT, never a coherent stack claim.
        OPRegisters registers = OPRegistersFor(context.thread);
        result[@"registerReturn"] = @(registers.result);
        uintptr_t addresses[16] = {0}; NSUInteger frameCount = 0;
        if (registers.result == KERN_SUCCESS) {
            addresses[frameCount++] = OPStripCode(registers.pc);
            if (registers.lr && frameCount < 16) { addresses[frameCount++] = OPStripCode(registers.lr); }
            uintptr_t fp = OPStripData(registers.fp);
            while (frameCount < 16 && context.bottom > 0 && fp >= context.bottom && fp >= registers.sp
                && context.top >= 2 * sizeof(uintptr_t) && fp <= context.top - 2 * sizeof(uintptr_t)
                && fp % (2 * sizeof(uintptr_t)) == 0) {
                // iOS exports the native-width vm_* interface; mach_vm.h is
                // explicitly unsupported by its SDK. Refuse a narrower ABI.
                _Static_assert(sizeof(vm_address_t) >= sizeof(uintptr_t), "Own stack address must not truncate");
                uintptr_t pair[2] = {0}; vm_size_t bytes = 0;
                kern_return_t read = vm_read_overwrite(mach_task_self(), (vm_address_t)fp,
                    (vm_size_t)sizeof(pair), (vm_address_t)pair, &bytes);
                if (read != KERN_SUCCESS || bytes != sizeof(pair)) { break; }
                uintptr_t next = OPStripData(pair[0]), caller = OPStripCode(pair[1]);
                if (!caller) { break; }
                addresses[frameCount++] = caller;
                if (next <= fp) { break; }
                fp = next;
            }
        }
        OPRegisters after = OPRegistersFor(context.thread);
        result[@"afterRegisterReturn"] = @(after.result);
        result[@"registerPCAndFPUnchanged"] = @(registers.result == KERN_SUCCESS && after.result == KERN_SUCCESS
            && registers.pc == after.pc && registers.fp == after.fp && registers.sp == after.sp);
        pthread_mutex_lock(&_lock);
        BOOL same = !_closed && lane >= 0 && lane < 3 && _lanes[lane].thread == context.thread
            && _lanes[lane].sequence == sequence;
        pthread_mutex_unlock(&_lock);
        mach_port_deallocate(mach_task_self(), context.thread);
        // Symbolication is after the native-thread sampling envelope.
        result[@"sampleBeginTicks"] = @(begin); result[@"sampleEndTicks"] = @(mach_absolute_time());
        NSMutableArray *frames = [NSMutableArray arrayWithCapacity:16];
        for (NSUInteger index = 0; index < frameCount; index++) { [frames addObject:OPAddress(addresses[index])]; }
        result[@"frames"] = frames; result[@"contextUnchanged"] = @(same);
        result[@"available"] = @(same && registers.result == KERN_SUCCESS && frameCount > 0);
    }
    result[@"returnTicks"] = @(mach_absolute_time());
    return result;
}
- (void)close {
    pthread_mutex_lock(&_lock); _closed = YES;
    for (NSInteger index = 0; index < 3; index++) {
        if (_lanes[index].thread != MACH_PORT_NULL) { mach_port_deallocate(mach_task_self(), _lanes[index].thread); }
        _lanes[index] = (OPReaderContext){0};
    }
    pthread_mutex_unlock(&_lock);
}
- (void)dealloc { [self close]; pthread_mutex_destroy(&_lock); }
@end
