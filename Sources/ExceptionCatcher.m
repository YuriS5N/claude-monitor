#import "ExceptionCatcher.h"

NSException * _Nullable AGTryBlock(void (^_Nonnull block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
