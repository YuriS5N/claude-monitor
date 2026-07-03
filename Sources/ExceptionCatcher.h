#import <Foundation/Foundation.h>

// Executa o bloco capturando NSException (Swift não captura exceções ObjC).
// Retorna a exceção capturada, ou nil se o bloco rodou sem erro.
NSException * _Nullable AGTryBlock(void (^_Nonnull block)(void));
