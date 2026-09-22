'use server'

// ════════════════════════════════════════════════════════════════════════════
// APR-1(2026-09-22)· 审批策略的写路径 —— 这一页此前【只读】
// ════════════════════════════════════════════════════════════════════════════
//
// 【为什么是一支 RPC,而不是一条 .from('finance_settings').update()】
// 那张表的表级写闸是 enforce_write_permission('module.finance.edit'),
// 而持有那个码的是 admin · finance · gm —— ★ finance 正是被裁定的一级审批角色。
// 一条直连 UPDATE 只在 UI 这一侧按 action.manage_permissions 把关,
// 分离就【只存在于屏幕上】(docs/known-issues.md APR0-APPROVALS-SWITCH-WRITE-GATE)。
// 所以判据落在库里:set_approvals_policy 查 action.manage_permissions,
// 而 guard_approvals_policy_write 把那四列的直连写按名拒掉。
//
// ★【这里【不】翻译 guard_approvals_switch 的那九条拒绝】它们由数据库抛出、
//   经 refuseFromCoded → localizeFinanceError 变成人话。在这里接住再判一遍,
//   就是"审批能不能开"的第二份实现。
//
// ⚠【APR-1 顺手修掉的一件事,记在这里因为它正是这条路会撞上的】
//   localizeFinanceError 的码正则此前是 /([A-Z_]+)…/ —— **没有数字**,
//   于是每一条带级别的拒绝(APPROVALS_LEVEL1_…)都抓不出来,
//   屏幕上显示的是那句最泛的兜底。见 app/finance/financeErrorCodes.ts 的抬头。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { localizeFinanceError } from '../../finance/financeErrorCodes'
import { refuseFromCoded } from '@/lib/action-refusal'

export type PolicyState = {
    error?: string
    detail?: string
    field?: string
    success?: boolean
    /** true = 真的写了库并落了一行史;false = 四个值一个都没变,什么都没发生。 */
    changed?: boolean
}

export async function setApprovalsPolicy(input: {
    enabled: boolean
    level1RoleCode: string | null
    level2RoleCode: string | null
    thresholdBase: string | null
}): Promise<PolicyState> {
    const t = await getTranslations()

    // ★ ALERT-1 甲类:这两条说的是【某一个框】,所以带 field,界面把它贴在框旁边。
    const rawThreshold = (input.thresholdBase ?? '').trim()
    let threshold: number | null = null
    if (rawThreshold !== '') {
        const n = Number(rawThreshold)
        if (!Number.isFinite(n) || n <= 0) {
            return { error: t('finance.approvals.thresholdInvalid'), field: 'thresholdBase' }
        }
        threshold = n
    }

    // 【开着就必须配齐 —— 但判定不在这里】数据库那道闸才是判据
    // (guard_approvals_switch,它同时还要问"这个角色有没有真的登得进来的持有人"、
    //  "这个角色看不看得见金额",而那两件事这一层答不了)。
    // 这里只挡住一种【在这一层就知道是错的】情形:开着,却连一级角色都没选。
    if (input.enabled && !input.level1RoleCode) {
        return { error: t('finance.approvals.level1Missing'), field: 'level1RoleCode' }
    }

    const supabase = await createClient()
    // 可空参数在 DB 签名里没有默认值,生成的类型因此标成 required —— 运行时传 null
    // 完全合法(四列都可空,而 NULL 的意思是【没有人决定过】),此处仅为通过类型
    // 检查而窄化断言。与 app/purchasing/orders/new/actions.ts 同一个写法、同一个理由。
    const { data, error } = await supabase.rpc('set_approvals_policy', {
        p_enabled: input.enabled,
        p_level1_role_code: input.level1RoleCode as unknown as string,
        p_level2_role_code: input.level2RoleCode as unknown as string,
        p_threshold_base: threshold as unknown as number,
    })

    if (error) {
        // 已编码的 DB 拒绝 → 人话;其余 → 一句写好的兜底 + 原文降级进 detail。
        return await refuseFromCoded(error.message, localizeFinanceError)
    }

    revalidatePath('/settings/approvals')
    // 【"什么都没改"不是一次成功,也不是一次失败 —— 它是第三种结果】
    //   报成成功,操作员会以为自己刚刚改了什么;报成失败,他会再试一次。
    return { success: true, changed: (data as { changed?: boolean } | null)?.changed === true }
}
