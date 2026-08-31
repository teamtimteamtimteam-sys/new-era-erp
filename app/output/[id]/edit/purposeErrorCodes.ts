// PROC-WIRE-1A:产出批次【用途】(工序投料指定)那一族的具名拒绝。
//
// 【为什么单独一个文件】与 lossErrorCodes / licenceErrorCodes 同一条:
// i18n 体检从这个 Set【现读】后缀集合,于是加一条拒绝而忘了写文案,
// 构建当场红 —— 而不是屏幕上冒出一串 BATCH_PURPOSE_UNKNOWN|feed。
export const PURPOSE_ERROR_CODES = new Set([
    'BATCH_PURPOSE_UNKNOWN',
    'OUTPUT_NOT_FOUND',
    'OUTPUT_DELETED',
    // 【设定与释放要的是【工序】权限,不是销售权限】—— 把一批货许给产线是一个
    // 工序决定。门里那条 require_permission 抛的就是这一条。
    // (注意:本集合里【不要】写别的带引号的串 —— check-i18n 从这个 Set 现读
    //  后缀,连注释里的引号串都会被当成一个后缀。实测撞过一次。)
    'PERMISSION_DENIED',
    // PROC-WIRE-1B-ii(R3):在制品那个指针的两条拒绝。
    'WIP_OPERATION_UNKNOWN',
    'WIP_AWAITING_ON_SALEABLE_BATCH',
])
