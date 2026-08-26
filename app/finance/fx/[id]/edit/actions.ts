'use server'

// 编辑/软删汇率(端口自 metal-prices 编辑 actions)。source 不动。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { localizeFxError } from '../../../fxErrorCodes'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type UpdateFxRateState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateFxRate(
    id: string,
    _prevState: UpdateFxRateState,
    formData: FormData
): Promise<UpdateFxRateState> {
    const t = await getTranslations()

    const currency = (formData.get('currency') as string)?.trim() || ''
    const rate_raw = (formData.get('rate_sgd_per_unit') as string) || ''
    const rate_type = (formData.get('rate_type') as string)?.trim() || ''
    const source = (formData.get('source') as string)?.trim() || 'DBS'
    const rate_date = (formData.get('rate_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || null
    // FX-RATES-1:改一条已在册的牌价【必须说为什么】—— 一条被悄悄换掉的牌价,
    // 日后没有人答得出"我们那天到底用的哪个数"。
    const reason = (formData.get('reason') as string)?.trim() || ''

    const fieldErrors: Record<string, string> = {}
    if (!currency || currency === await getBaseCurrency()) fieldErrors.currency = t('finance.fxPage.form.errCurrency')
    if (!['tt_buy', 'tt_sell', 'mid'].includes(rate_type)) fieldErrors.rate_type = t('finance.fxPage.form.errRateType')

    let rate: number | null = null
    if (!rate_raw) {
        fieldErrors.rate_sgd_per_unit = t('finance.fxPage.form.errRate')
    } else {
        const n = Number(rate_raw)
        if (Number.isNaN(n) || n <= 0) {
            fieldErrors.rate_sgd_per_unit = t('finance.fxPage.form.errRate')
        } else {
            rate = n
        }
    }

    if (!rate_date || Number.isNaN(Date.parse(rate_date))) {
        fieldErrors.rate_date = t('finance.fxPage.form.errRateDate')
    }

    if (!reason) fieldErrors.reason = t('finance.fxPage.form.errReason')

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    const supabase = await createClient()

    // 【同一个写入口】—— 直接 UPDATE 已被 trg_fx_rates_write_guard 拦下
    // (FX_RATE_VIA_FUNCTION|UPDATE)。带上理由走 record_fx_rate,它会留下一行
    // 'corrected' 史,连【改之前是什么】一起记着。
    const { error } = await supabase.rpc('record_fx_rate', {
        p_currency: currency,
        p_rate_date: rate_date,
        p_rate_type: rate_type,
        p_rate: rate as number,
        p_source: source,
        p_notes: notes ?? undefined,
        p_reason: reason,
    })

    if (error) {
        return { error: await localizeFxError(error.message) }
    }

    revalidatePath('/finance/fx')
    revalidatePath(`/finance/fx/${id}/edit`)
    redirect('/finance/fx')
}

// 撤销 = 软删 + 留痕 + 必填理由(withdraw_fx_rate)。直接改 deleted_at 仍然可行,
// 但那条路不留史 —— 所以界面这一侧只走函数,理由是必填的。
export async function softDeleteFxRate(id: string, reason: string) {
    const supabase = await createClient()

    const { error } = await supabase.rpc('withdraw_fx_rate', {
        p_id: id,
        p_reason: reason,
    })

    if (error) {
        return { error: await localizeFxError(error.message) }
    }

    revalidatePath('/finance/fx')
    redirect('/finance/fx')
}
