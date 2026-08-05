'use server'

// 新增牌价(端口自 metal-prices/new/actions):FIN-0 起一条 = 一币种一天一侧;
// source 默认 'DBS'。唯一约束 (currency, rate_date, rate_type) 冲突 → 友好的字段错误。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
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
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('fx_rates').insert({
        currency,
        rate_type,
        rate_sgd_per_unit: rate,
        rate_date,
        source,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
    } as InsertRow<'fx_rates'>)

    if (error) {
        // 唯一约束 (currency, rate_date, rate_type):同一币种同一天同一侧已有牌价
        if (error.code === '23505') {
            return { fieldErrors: { rate_date: t('finance.fxPage.errors.duplicate') } }
        }
        return { error: t('finance.fxPage.form.saveError', { message: error.message }) }
    }

    revalidatePath('/finance/fx')
    redirect('/finance/fx')
}
