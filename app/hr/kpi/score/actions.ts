'use server'

// app/hr/kpi/score/actions.ts
// C-2:KPI 月度录入的写入口。
//
// ★【规则全部长在数据库里,这里一条都不复制】★
//   0–5 的范围、judged/computed 必须二选一、computed 必须说出算的是什么、
//   封顶必须带理由、周期关了不许改 —— 全在 score_kpi_entry 里(KPI-1 建的)。
//   这一层只做两件事:把表单的形状交进去,把机器码翻成人话。
//   界面复制一份规则,就是第二个真相来源,而两份规则一定会漂开。
//
// ★【score_kind 在这一屏恒为 'judged',这是一个【判断】,不是一个偷懒的默认值】★
//   §10.2 要求算出来的分与人判的分在数据里分开,而【本屏的每一分都是人判的】:
//   Sandra 看证据、给分。'computed' 那一支要求 computed_basis 说出它算的是什么
//   (哪几次盘点、哪张账龄、截至哪一天)—— 今天没有任何一条 KPI 接着一个真的计算,
//   所以给她一个 judged/computed 的下拉,只会让她在两个都不真的选项之间挑一个,
//   然后为了过约束去编一句 basis。**那才是把 §10.2 变成一个标签。**
//   ☞ 将来某条 KPI 真的接上盘点数字时,那条路自己带着 basis 进来,这里不必先留坑。
import { revalidatePath } from 'next/cache'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'

export type KpiScoreState = { error?: string; success?: boolean }

/** DB 的错误码 → 人话。看到 KPI_CYCLE_LOCKED 的人要知道的是"这个月被关口锁了"。 */
export async function localizeKpiError(message: string): Promise<string> {
    const t = await getTranslations()
    const m = (message ?? '').trim().match(/([A-Z_]+)(?:\|(.*))?$/)
    if (!m) return message
    const p = (m[2] ?? '').split('|')
    switch (m[1]) {
        case 'KPI_ENTRY_NOT_FOUND':
            return t('kpi.errEntryNotFound')
        case 'KPI_CYCLE_CLOSED':
            return t('kpi.errCycleClosed', { 0: p[0] ?? '' })
        // ★ C-2 新增的那一道:锁 ≠ 关。锁是冻结打分,关是对本人揭晓。
        case 'KPI_CYCLE_LOCKED':
            return t('kpi.errCycleLocked', { 0: p[0] ?? '', 1: p[1] ?? '' })
        case 'KPI_SCORE_OUT_OF_RANGE':
            return t('kpi.errScoreRange', { 0: p[0] ?? '' })
        case 'KPI_SCORE_KIND_INVALID':
            return t('kpi.errScoreKind', { 0: p[0] ?? '' })
        case 'KPI_COMPUTED_NEEDS_BASIS':
            return t('kpi.errComputedNeedsBasis', { 0: p[0] ?? '' })
        case 'KPI_OVERRIDE_NEEDS_REASON':
            return t('kpi.errOverrideNeedsReason', { 0: p[0] ?? '' })
        case 'KPI_CYCLE_NOT_FOUND':
            return t('kpi.errCycleNotFound')
        case 'EMPLOYEE_NOT_FOUND':
            return t('kpi.errEmployeeNotFound')
        case 'EMPLOYEE_HAS_NO_POSITION':
            return t('kpi.errNoPosition', { 0: p[0] ?? '' })
        case 'POSITION_HAS_NO_TEMPLATES':
            return t('kpi.errNoTemplates', { 0: p[0] ?? '' })
        case 'KPI_ENTRIES_ALREADY_GENERATED':
            return t('kpi.errAlreadyGenerated', { 0: p[0] ?? '', 1: p[1] ?? '', 2: p[2] ?? '' })
        case 'KPI_TEMPLATE_WEIGHTS_NOT_100':
            return t('kpi.errWeightsNot100', { 0: p[0] ?? '', 1: p[1] ?? '' })
        case 'PERMISSION_DENIED':
            return t('permissions.errDenied')
        default:
            return message
    }
}

/**
 * 给一条 KPI 打分 —— 分数 / 证据 / 反馈三样,外加可选的安全监管封顶。
 * ★ 加权分【不在参数里】★:它是 分÷5×权重,由 score_kpi_entry 算、由 roll-up 视图算。
 *   手打一个派生数,只是给"算错"开一扇门。
 */
export async function scoreKpiEntry(
    entryId: string,
    patch: {
        score: number | null
        evidenceNote: string | null
        feedbackNote: string | null
        overrideCap: number | null
        overrideReason: string | null
    }
): Promise<KpiScoreState> {
    const t = await getTranslations()
    // 分数是这一屏的必填项 —— 空着按下保存,数据库会抛 OUT_OF_RANGE|null,
    // 那句话是对的但绕了一圈。这里先说人话,理由与上面那条"不复制规则"不冲突:
    // 这不是一条【业务规则】,是把一个必填项在到达数据库之前说清楚。
    if (patch.score === null || Number.isNaN(patch.score)) {
        return { error: t('kpi.errScoreRequired') }
    }

    const supabase = await createClient()
    // 【null → 省略,不是 null → 0】那几个参数的默认值都是 NULL,所以省掉一个键
    // 与显式传 NULL 在数据库那一侧是同一件事;而 PostgREST 的生成类型只收 undefined。
    // ★ 要紧的是它【不是】把清空变成一个值 —— 清掉封顶得到的是 NULL,不是 0。
    const { error } = await supabase.rpc('score_kpi_entry', {
        p_entry_id: entryId,
        p_score: patch.score,
        p_score_kind: 'judged',
        p_evidence_note: patch.evidenceNote ?? undefined,
        p_feedback_note: patch.feedbackNote ?? undefined,
        p_override_cap: patch.overrideCap ?? undefined,
        p_override_reason: patch.overrideReason ?? undefined,
    })
    if (error) return { error: await localizeKpiError(error.message) }

    revalidatePath('/hr/kpi/score')
    revalidatePath('/hr/kpi')
    revalidatePath('/me')
    return { success: true }
}

/**
 * 给一个人在一个月里生成他的五条 —— **复制模板,不是引用**(§8.3)。
 * 九月那一批在迁移里生成过了;这是后面五个月的入口。
 * ★ 显式的动作,不是打开页面的副作用 ★:生成会把那一刻的标准抄下来冻住,
 *   那是一件应当由人按下的事。
 */
export async function generateKpiEntries(employeeId: string, cycleId: string): Promise<KpiScoreState> {
    const supabase = await createClient()
    const { error } = await supabase.rpc('assign_position_kpis', {
        p_employee_id: employeeId,
        p_cycle_id: cycleId,
    })
    if (error) return { error: await localizeKpiError(error.message) }

    revalidatePath('/hr/kpi/score')
    revalidatePath('/me')
    return { success: true }
}
