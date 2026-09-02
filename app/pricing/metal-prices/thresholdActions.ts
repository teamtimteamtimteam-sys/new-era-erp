'use server'

// METAL-1:异常提示的阈值 —— 【可见配置,不是常量】
//
// 与 certificate_types.warn_lead_days、finance_settings.default_allocation_basis
// 同一条(FIN-35/FIN-36):看得见、改得动的默认值不是假设。引导里那个 50 是
// 【默认值,不是决定】—— 改它不需要改代码,也不需要一次迁移。
//
// 闸门在数据库:pricing_settings 的 UPDATE 策略要 module.pricing.edit
// (改阈值与录行情是同一件工作,同一个码)。这里不复述那条判断,只是不把一张
// 注定被 42501 拒收的表单摆到人面前。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'

export type ThresholdState = { error?: string; saved?: boolean }

export async function updateAnomalyThreshold(
    _prevState: ThresholdState,
    formData: FormData
): Promise<ThresholdState> {
    const t = await getTranslations()
    const raw = String(formData.get('metal_price_change_warn_pct') ?? '').trim()
    const pct = Number(raw)

    // > 0 与 CHECK 同口径 —— 页面不比服务端松,也不比它严
    if (!raw || Number.isNaN(pct) || pct <= 0) {
        return { error: t('metalPrices.settings.errThreshold') }
    }

    const supabase = await createClient()
    // 【要回写下的那一行】RLS 挡住时 UPDATE 不报错,只是【影响 0 行】(实测确认)——
    // 不看回来的行,这里会对一个什么都没改的人回一句"已保存"。那是同一种病的另一件
    // 衣服:0 与"你没有权限"在屏幕上一模一样。页面本来就不给无权者画这个钮,
    // 但一次伪造的提交不该拿到一句谎话。
    const { data, error } = await supabase
        .from('pricing_settings')
        .update({ metal_price_change_warn_pct: pct })
        .eq('id', true)
        .select('metal_price_change_warn_pct')

    if (error) {
        return { error: t('metalPrices.form.saveError', { message: error.message }) }
    }
    if (!data || data.length === 0) {
        return { error: t('common.editDenied') }
    }

    revalidatePath('/pricing/metal-prices')
    revalidatePath('/pricing/metal-prices/bulk')
    return { saved: true }
}
