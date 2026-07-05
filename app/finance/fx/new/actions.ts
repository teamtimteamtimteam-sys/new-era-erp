'use server'

// 新增汇率(端口自 metal-prices/new/actions):source 用 DB 默认 'manual';
// 唯一约束 (currency, rate_date) 冲突 → 友好的字段错误。
import { createClient } from '@/lib/supabase/server'
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
    const rate_raw = (formData.get('rate_to_usd') as string) || ''
    const rate_date = (formData.get('rate_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || null

    const fieldErrors: Record<string, string> = {}
    if (!currency || currency === 'USD') fieldErrors.currency = t('finance.fxPage.form.errCurrency')

    let rate: number | null = null
    if (!rate_raw) {
        fieldErrors.rate_to_usd = t('finance.fxPage.form.errRate')
    } else {
        const n = Number(rate_raw)
        if (Number.isNaN(n) || n <= 0) {
            fieldErrors.rate_to_usd = t('finance.fxPage.form.errRate')
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
        rate_to_usd: rate,
        rate_date,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // source 不传,用数据库默认值 'manual'
    } as InsertRow<'fx_rates'>)

    if (error) {
        // 唯一约束 (currency, rate_date):同一币种同一天已有汇率
        if (error.code === '23505') {
            return { fieldErrors: { rate_date: t('finance.fxPage.errors.duplicate') } }
        }
        return { error: t('finance.fxPage.form.saveError', { message: error.message }) }
    }

    revalidatePath('/finance/fx')
    redirect('/finance/fx')
}
