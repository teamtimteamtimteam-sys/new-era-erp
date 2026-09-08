import 'server-only'
import { getTranslations } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'

// ════════════════════════════════════════════════════════════════════════════
// ALERT-1(2026-09-08)· 一次拒绝【回给界面的形状】
// ════════════════════════════════════════════════════════════════════════════
// 【为什么多一个 detail 字段】旧形状只有 `{ error: string }`,于是数据库原文
// 只能拼进那句话里 —— `删除失败:new row violates row-level security policy...`。
// Tim 在 ALERT-1 闸上裁定:原文降级成【可以展开的细节】,标题必须是人话。
// 一个字段的距离,而它把"标题是机器字"这件事从结构上变成不可能。
//
// ★【旧调用点一个字都不用改】`error` 仍然是那句要显示的话;`detail` 是可选的。
// ════════════════════════════════════════════════════════════════════════════
/**
 * 一个动作【回给界面】的全部形状:要么拒绝(error 那几格),要么成功。
 *
 * 【为什么要显式写出来,而不是让 TS 去推】推出来的是一个联合
 * `ActionRefusal | { success: boolean }`,而调用点写的是 `result?.error` ——
 * 在成功那一支上没有 error 这一格,于是类型检查当场红。
 * 一个【两支形状不同】的返回值,会把"读哪一格"的判断推给每一个调用点;
 * 显式一格,十八处调用点读法一致。
 */
export type ActionOutcome = {
    error?: string
    detail?: string
    field?: string
    success?: boolean
}

export type ActionRefusal = {
    error: string
    /** 降级后的数据库原文 —— 永远不做标题。 */
    detail?: string
    /**
     * ★【甲类的判据 —— 而它是【服务端说出来的】,不是界面猜的】★
     * 有值 = 这一条说的是【某一个输入框】,界面要把它贴在那个框旁边(<FieldMessage>);
     * 没值 = 这一条说的是整条记录,走页级横幅。
     *
     * 【为什么不让界面按文字猜】那需要在客户端认字符串,而字符串是会被翻译的。
     * 判据必须来自【知道自己在拒绝什么】的那一层,也就是动作本身。
     */
    field?: string
}

/**
 * 【权限被拒】—— require_permission 抛的 `PERMISSION_DENIED|<码>`,以及
 * 十处零行落地里查证为"确实没有这项权限"的那一支,共用这一句。
 *
 * ★ 全库只此一句。六个 *ErrorCodes.ts 都路由到这里,而不是各写各的 ——
 *   「同一个问题的第二份实现」正是本仓库反复付账的那件事。
 */
export async function refusePermission(permissionCode: string): Promise<ActionRefusal> {
    const t = await getTranslations()
    return { error: t('common.actionMessage.permissionDenied', { 0: permissionCode }) }
}

/**
 * 【连本地化器都不认识的那条数据库消息】。
 * 原文【不做标题】,进 detail;标题是一句说得出下一步的话。
 */
export async function refuseFromDriver(rawMessage: string): Promise<ActionRefusal> {
    const t = await getTranslations()
    const raw = (rawMessage ?? '').trim()
    return {
        error: t('common.actionMessage.driverFallback'),
        detail: raw === '' ? undefined : raw,
    }
}

/**
 * ★★【零行落地 —— ALERT-1 的主发现】★★
 *
 * 受影响的每一张表,UPDATE 策略都是 `USING (p) WITH CHECK (p)`,两侧【同一个谓词】。
 * 一个不满足 p 的人先卡在 USING 上:那一行【根本没有被匹配到】——
 * 于是 PostgREST 返回零行、**不抛异常**,`error` 是 null。
 * 调用点因此返回 `{ success: true }`,revalidate 照跑,记录纹丝不动,
 * 而屏幕上【一个字都没有】。ALERT-1 在活库上用一个真账号(无编辑权)量过这十张表,
 * 十张全是 `rows=0 raised=NONE`(见提交信息与 scripts/probe-action-message.mjs)。
 *
 * 【这一层是"把话说出来",不是"把闸补上"】数据库那一侧改成 RAISE 是另一刀
 * (ALERT-1 闸上登记)。这里做的是:零行落地时【不再报告成功】。
 *
 * 【判据不另写一份】"这个人有没有这项权限"直接问 lib/permissions.ts 的 can() ——
 * 与页面判断能不能进、能不能编辑走的是同一个答案(而它自己已经分得开
 * 「查询失败」与「真的没有权限」,见那个文件的抬头)。
 *
 * @param permissionCode 这次写入所受管辖的权限码 —— 与该表 RLS 策略上写的那个逐字相同。
 */
export async function refuseNothingChanged(permissionCode: string): Promise<ActionRefusal> {
    const t = await getTranslations()

    // 【can() 失败时不许改口】它查不到不等于"这个人没有权限"(那是 lib/permissions.ts
    // 抬头记的那次爆炸)。查不到就退回中性那一句,而不是断言权限不足。
    let lacksPermission = false
    try {
        lacksPermission = !(await can(permissionCode))
    } catch {
        lacksPermission = false
    }

    if (lacksPermission) return refusePermission(permissionCode)
    return { error: t('common.actionMessage.nothingChanged') }
}

/**
 * ★★【已编码的拒绝 —— 一层包装,而它【不动】那六个本地化器】★★
 *
 * 每个 *ErrorCodes.ts 的契约都写在它自己那一行注释里:
 *     `return raw // genuine non-coded DB error → surface verbatim`
 * 也就是说 **"认出来了"与"没认出来"的分界,就是它返回的是不是原样那一串**。
 * 本函数用的正是这条契约,所以它:
 *   ① 不需要各本地化器把码集合暴露出来;
 *   ② 不需要改它们的签名 —— localizeFinanceError 全库有几十个调用点,
 *      为了 ALERT-1 的 8 处去动那个签名,是把一刀的代价摊到整个模块上。
 *
 * 三条分支,而顺序有意义:
 *   ① PERMISSION_DENIED 先接 —— 六个本地化器都没有这一支(采购模块在
 *      MANUAL-FIX-1 补过,这里是剩下的六个),不先接就会掉进 ③。
 *   ② 本地化器认出来了 → 原样用它的话。
 *   ③ 没认出来 → **绝不把那串机器字做标题**:换成一句说得出下一步的话,
 *      原文降级进 detail。
 */
export async function refuseFromCoded(
    rawMessage: string,
    localize: (message: string) => Promise<string>
): Promise<ActionRefusal> {
    const raw = (rawMessage ?? '').trim()

    // 与各本地化器【逐字同源】的解析(它们各自都写着这一行)。
    const match = raw.match(/([A-Z_]+)(?:\|(.*))?$/)
    if (match && match[1] === 'PERMISSION_DENIED') {
        // require_permission 抛的是 `PERMISSION_DENIED|<权限码>`,第二段就是那个码。
        return refusePermission(match[2] ?? '')
    }

    const localized = await localize(raw)
    if (localized !== raw) return { error: localized }

    // 走到这里 = 本地化器【没认出来】,照它自己的契约把原文还了回来。
    return refuseFromDriver(raw)
}
