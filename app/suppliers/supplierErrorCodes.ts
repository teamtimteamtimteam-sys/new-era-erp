import { getTranslations } from '@/lib/i18n/server'

// SILENT-1(2026-09-08):供应商状态跳转的拒绝 → 人话。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这一支现在才有,而它接的只有一条】
//
// validate_supplier_status_transition 从建库起抛的就是一句【中文散文】:
//     RAISE EXCEPTION '非法状态跳转: % → %'
// 六个 *ErrorCodes.ts 的契约都是"认不出来就把原文原样还回去",而散文永远认不出来。
// 于是它落进 statusActions.ts 的 refuseFromDriver,再被拼进 statusPanel.changeError,
// **英文界面上印出来的是**:「Status change failed: 非法状态跳转: active → draft」。
//
// 本刀把库里那一句换成 `INVALID_STATUS_TRANSITION|<from>|<to>` —— 与
// PERMISSION_DENIED|<码> 逐字同一个形状,所以下面这个正则与其余五支完全一致。
//
// ★【两个状态不原样印出去】★ 库里给的是 'active' / 'draft' 这样的【存储值】。
//   直接插进句子就是"cannot go from active to draft" —— 屏幕上别处写的是
//   「Active」「Draft」,同一个东西两套说法就是下一次漂移(AGENTS.md 记过这一条)。
//   所以这里先经 suppliers.status.* 换成标签再插进去,与状态面板用的是同一份词。
//
// 加一条拒绝 = 来这里加一个名字。check-i18n 的 suppliers.errors.* 后缀集合
// 现读下面这个 Set,漏了句子 npm run build 当场红。
// ════════════════════════════════════════════════════════════════════════════
const SUPPLIER_ERROR_CODES = new Set([
    'INVALID_STATUS_TRANSITION',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

/** 存储值 → 屏幕上那个标签。认不出的原样用,不编造。 */
const SUPPLIER_STATUSES = new Set([
    'draft', 'pending_review', 'approved', 'rejected',
    'active', 'suspended', 'blacklisted', 'archived',
])

export async function localizeSupplierError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    const match = raw.match(CODE_RE)
    if (match && SUPPLIER_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) {
            match[2].split('|').forEach((v, i) => {
                // 状态值换成标签;不是状态值的照原样(下一条码的参数未必是状态)。
                params[String(i)] = SUPPLIER_STATUSES.has(v)
                    ? t('suppliers.status.' + v)
                    : v
            })
        }
        return t('suppliers.errors.' + match[1], params)
    }

    // 认不出的原样返回 —— 六支本地化器共用的那条契约,refuseFromCoded 靠它分界。
    return raw
}
