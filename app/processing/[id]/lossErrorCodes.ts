// PROC-BUILD-1:损耗分类那一族的具名拒绝。
//
// 【为什么单独一个文件】与 licenceErrorCodes / commissionErrorCodes / whtErrorCodes
// 同一条:i18n 体检从这个 Set【现读】后缀集合,于是加一条拒绝而忘了写文案,
// 构建当场红 —— 而不是屏幕上冒出一串 LOSS_CATEGORIES_EXCEED_LOSS_QTY|R-1|110|100。
export const LOSS_ERROR_CODES = new Set([
    'LOSS_CATEGORIES_EXCEED_LOSS_QTY',
])
