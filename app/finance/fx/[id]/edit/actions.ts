'use server'

// 编辑/软删汇率(端口自 metal-prices 编辑 actions)。source 不动。
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { getTranslations } from '@/lib/i18n/server'
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

    const { error } = await supabase
        .from('fx_rates')
        .update({
            currency,
            rate_type,
            rate_sgd_per_unit: rate ?? undefined,
            source,
            rate_date,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        // 唯一约束 (currency, rate_date):同一币种同一天已有汇率
        if (error.code === '23505') {
            return { fieldErrors: { rate_date: t('finance.fxPage.errors.duplicate') } }
        }
        return { error: t('finance.fxPage.form.saveError', { message: error.message }) }
    }

    revalidatePath('/finance/fx')
    revalidatePath(`/finance/fx/${id}/edit`)
    redirect('/finance/fx')
}

// 软删除:置 deleted_at + 记录 updated_by,revalidate 后跳回列表。
export async function softDeleteFxRate(id: string) {
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('fx_rates')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已经删过的不重复删

    if (error) {
        return { error: t('finance.fxPage.deleteError', { message: error.message }) }
    }

    revalidatePath('/finance/fx')
    redirect('/finance/fx')
}
