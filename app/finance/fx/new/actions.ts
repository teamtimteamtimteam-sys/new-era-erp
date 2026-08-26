'use server'

// 新增牌价(端口自 metal-prices/new/actions):FIN-0 起一条 = 一币种一天一侧;
// source 默认 'DBS'。唯一约束 (currency, rate_date, rate_type) 冲突 → 友好的字段错误。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
import { localizeFxError } from '../../fxErrorCodes'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'

export type CreateFxRateState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createFxRate(
    _prevState: CreateFxRateState,
    formData: FormData
): Promise<CreateFxRateState> {
    const t = await getTranslations()

    const currency = (formData.get('currency') as string)?.trim() || ''
    const rate_raw = (formData.get('rate_sgd_per_unit') as string) || ''
    const rate_type = (formData.get('rate_type') as string)?.trim() || ''
    const source = (formData.get('source') as string)?.trim() || 'DBS'
    const rate_date = (formData.get('rate_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || null

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

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    const supabase = await createClient()

    // FX-RATES-1:【只有一个写入口】—— 不再直接 INSERT。表单与批量表格调的是
    // 同一个 record_fx_rate,所以表格【不可能】比表单校验得松:没有第二个地方
    // 可以放松。校验、留痕、未来日期的拒绝,全在函数里,两条路共用。
    const { error } = await supabase.rpc('record_fx_rate', {
        p_currency: currency,
        p_rate_date: rate_date,
        p_rate_type: rate_type,
        // rate 在上面的字段校验里已经确定非空(否则早已 return fieldErrors)
        p_rate: rate as number,
        p_source: source,
        p_notes: notes ?? undefined,
        p_reason: undefined,
    })

    if (error) {
        return { error: await localizeFxError(error.message) }
    }

    revalidatePath('/finance/fx')
    redirect('/finance/fx')
}
