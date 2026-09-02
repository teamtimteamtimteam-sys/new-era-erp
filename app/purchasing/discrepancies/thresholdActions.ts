'use server'

// GRN-1b:收货差异的三个阈值 —— 【可见配置,不是常量】
// 形状取自 app/operation/orders/thresholdActions.ts(EXEC-3b),连同它学到的两件事:
//
// 【一 · 三个数一起提交,而且各自独立校验】它们判的是三种不同的坏消息
// (短交是履约、超收是仓储与现金、化验超差是品质),任何一个不合法都不该把
// 另外两个写进去。
//
// 【二 · 要回写下的那一行】RLS 挡住时 UPDATE 不报错,只是【影响 0 行】——
// 不看回来的行,这里会对一个什么都没改的人回一句"已保存"。0 与"你没有权限"
// 在屏幕上一模一样,而这正是 lib/permissions.ts 存在的理由。
//
// 【写的门是 module.purchasing.edit,读的门是 receiving_settings 自己的 RLS】
// 两者【不是同一道】,这是刻意的:表上的 UPDATE 策略写的是 module.inbound.edit
// (收货的设置归收货),而这块面板挂在采购侧。所以这里【不自己判权限】——
// 判据只有一处,就是数据库那条策略,页面靠"回写了几行"读它的答案。
// 手抄一句 can('module.purchasing.edit') 到这里,就是第二份会漂开的判断。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'

export type GrnThresholdState = { error?: string; saved?: boolean }

export async function updateGrnThresholds(
    _prevState: GrnThresholdState,
    formData: FormData
): Promise<GrnThresholdState> {
    const t = await getTranslations()
    const rawShort = String(formData.get('grn_short_pct') ?? '').trim()
    const rawOver = String(formData.get('grn_over_pct') ?? '').trim()
    const rawAssay = String(formData.get('grn_assay_tolerance_pct') ?? '').trim()
    const pctShort = Number(rawShort)
    const pctOver = Number(rawOver)
    const pctAssay = Number(rawAssay)

    // > 0 与三条 CHECK 同口径 —— 页面不比服务端松,也不比它严
    if (!rawShort || Number.isNaN(pctShort) || pctShort <= 0) {
        return { error: t('grn.settings.errShort') }
    }
    if (!rawOver || Number.isNaN(pctOver) || pctOver <= 0) {
        return { error: t('grn.settings.errOver') }
    }
    if (!rawAssay || Number.isNaN(pctAssay) || pctAssay <= 0) {
        return { error: t('grn.settings.errAssay') }
    }

    const supabase = await createClient()
    const { data, error } = await supabase
        .from('receiving_settings')
        .update({
            grn_short_pct: pctShort,
            grn_over_pct: pctOver,
            grn_assay_tolerance_pct: pctAssay,
        })
        .eq('id', true)
        .select('grn_short_pct, grn_over_pct, grn_assay_tolerance_pct')

    if (error) return { error: error.message }
    if (!data || data.length === 0) return { error: t('common.editDenied') }

    // 三个数一动,每一张现读它们的屏都变了 —— 差异清单、每一张采购单详情、
    // 每一个批次详情。列表与采购单列表这两条路径显式刷,详情页按 id 走
    // 动态路由,由它们自己的 revalidate 兜底。
    revalidatePath('/purchasing/discrepancies')
    revalidatePath('/purchasing/orders')
    revalidatePath('/inbound')
    return { saved: true }
}
