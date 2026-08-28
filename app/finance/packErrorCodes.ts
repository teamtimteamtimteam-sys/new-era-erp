import { getTranslations } from '@/lib/i18n/server'

// GLEXPORT-1:管理报表包与总账导出那一族的错误码(端口自 whtErrorCodes.ts)。
//
// ★【这份名单是从【函数体】逐条数出来的,不是从"撞到过哪几条"数的】★
// 生成它的那条命令留在这里,因为下一个加拒绝的人要用同一条重数一遍:
//
//     grep -rhoE "RAISE EXCEPTION '([A-Z_]+)" \
//       db/functions/gl_control_reconciliation.sql \
//       db/functions/management_pack_data.sql \
//       db/functions/freeze_management_pack.sql \
//       db/tables/management_packs.sql | sed "s/RAISE EXCEPTION '//" | sort -u
//
// ★【下半段是【被调用方】抛的,而它们照样会打到这张屏幕上】★
// management_pack_data 调了六支函数,它们各自的拒绝会原样冒上来。
// 尤其 AGING_AS_OF_FUTURE:账龄对未来的截止日按名拒,而报表包正是最容易
// 撞上它的地方(有人想看下个月)。漏了它,屏幕上就是一串机器码 ——
// 这个仓库为"机器文本打到人脸上"专门有一份文档(docs/machine-text-reaching-humans.md)。
const PACK_ERROR_CODES = new Set([
    // ── freeze_management_pack / management_pack_data / management_packs ──
    'PACK_PERIOD_REQUIRED',
    'PACK_MONTH_NOT_LOCKED',
    'PACK_SUPERSEDE_REASON_REQUIRED',
    'PACK_IMMUTABLE',
    // ── gl_control_reconciliation / balance_sheet ──
    'AS_OF_REQUIRED',
    // ── pnl_statement / cash_flow_statement ──
    'PERIOD_REQUIRED',
    // ── ar_aging_asof / ap_aging_asof(报表包最容易撞上的一条)──
    'AGING_AS_OF_FUTURE',
    // ── require_permission,以及底下过账路径冒上来的期间锁 ──
    'PERMISSION_DENIED',
    'PERIOD_LOCKED',
    // ── FX:重估读不到牌价时,底下那一支会按名拒并带上币种与日期 ──
    'FX_RATE_MISSING',
])

// 宽松解析:从消息里抓 "CODE" 或 "CODE|p0|p1..."(同 localizeWhtError)。
const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizePackError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const match = raw.match(CODE_RE)

    if (!match || !PACK_ERROR_CODES.has(match[1])) {
        return raw // genuine non-coded DB error → surface verbatim
    }

    const code = match[1]
    const params: Record<string, string> = {}
    if (match[2]) {
        match[2].split('|').forEach((v, i) => {
            params[String(i)] = v // '0' -> first param, '1' -> second, ...
        })
    }

    return (await getTranslations())('pack.errors.' + code, params)
}
