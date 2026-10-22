#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// 在 @try/@catch 裡執行 block,回傳抓到的 NSException(沒有就 nil)。
/// Swift 接不到 ObjC 例外;AVFAudio 的前置條件失敗(installTap 格式不符、0 聲道)是
/// NSException,不包起來就是整個 app abort(AUD-37,#2523,2026-10-22 10:31 真機)。
FOUNDATION_EXPORT NSException * _Nullable MPCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
