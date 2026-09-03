'use server'

// EXEC-3b:工单差异的两个阈值 —— 【可见配置,不是常量】
// 形状取自 app/pricing/metal-prices/thresholdActions.ts(METAL-1),连同它学到的两件事:
//
// 【一 · 两个数一起提交,而且各自独立校验】它们是两种不同的坏消息(投入超耗是
// 成本问题,产出短交是收率问题),所以任何一个不合法都不该把另一个写进去。
//
// 【二 · 要回写下的那一行】RLS 挡住时 UPDATE 不报错,只是【影响 0 行】——
// 不看回来的行,这里会对一个什么都没改的人回一句"已保存"。0 与"你没有权限"
// 在屏幕上一模一样,而这正是 lib/permissions.ts 存在的理由。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'

export type WoThresholdState = { error?: string; saved?: boolean }

export async function updateWoThresholds(
    _prevState: WoThresholdState,
    formData: FormData
): Promise<WoThresholdState> {
    const t = await getTranslations()
    const rawIn = String(formData.get('wo_input_overrun_pct') ?? '').trim()
    const rawOut = String(formData.get('wo_output_shortfall_pct') ?? '').trim()
    const pctIn = Number(rawIn)
    const pctOut = Number(rawOut)

    // > 0 与两条 CHECK 同口径 —— 页面不比服务端松,也不比它严
    if (!rawIn || Number.isNaN(pctIn) || pctIn <= 0) {
        return { error: t('processing.wo.settings.errInput') }
    }
    if (!rawOut || Number.isNaN(pctOut) || pctOut <= 0) {
        return { error: t('processing.wo.settings.errOutput') }
    }

    const supabase = await createClient()
    const { data, error } = await supabase
        .from('processing_settings')
        .update({ wo_input_overrun_pct: pctIn, wo_output_shortfall_pct: pctOut })
        .eq('id', true)
        .select('wo_input_overrun_pct, wo_output_shortfall_pct')

    if (error) return { error: error.message }
    if (!data || data.length === 0) return { error: t('common.editDenied') }

    revalidatePath('/operation/orders')
    // CONV-7 ①:那两块牌子【不在首页了】—— 它们和其余 32 支一起住在 /tools/reminders。
    // 【为什么把 '/' 换掉而不是两个都写】首页在 CONV-7 之后【不再读 operations_now】,
    // 所以刷新它对这两支一点作用都没有 —— 留着它就是一句不会有人去核对的谎。
    revalidatePath('/tools/reminders')   // 提醒页那两块牌子现读这两个数
    return { saved: true }
}
