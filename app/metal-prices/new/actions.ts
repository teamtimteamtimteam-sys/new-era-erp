'use server'

import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { METAL_VALUES } from '../options'

export type CreateMetalPriceState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function createMetalPrice(
    _prevState: CreateMetalPriceState,
    formData: FormData
): Promise<CreateMetalPriceState> {
    const t = await getTranslations()

    // 1. 取字段(source 不在表单里 —— 用数据库默认值 'manual')
    const metal = (formData.get('metal') as string)?.trim() || ''
    const price_raw = (formData.get('price_usd_per_tonne') as string) || ''
    const price_date = (formData.get('price_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    if (!METAL_VALUES.includes(metal)) fieldErrors.metal = t('metalPrices.form.errMetal')

    let price: number | null = null
    if (!price_raw) {
        fieldErrors.price_usd_per_tonne = t('metalPrices.form.errPrice')
    } else {
        const n = Number(price_raw)
        if (Number.isNaN(n) || n <= 0) {
            fieldErrors.price_usd_per_tonne = t('metalPrices.form.errPrice')
        } else {
            price = n
        }
    }

    if (!price_date || Number.isNaN(Date.parse(price_date))) {
        fieldErrors.price_date = t('metalPrices.form.errPriceDate')
    }

    if (Object.keys(fieldErrors).length > 0) {
        return { fieldErrors }
    }

    // 3. 写入
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('metal_prices').insert({
        metal,
        price_usd_per_tonne: price,
        price_date,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // source 不传,用数据库默认值 'manual'
        // id/created_at/updated_at 用默认值
    } as InsertRow<'metal_prices'>)

    if (error) {
        // 唯一约束 (metal, price_date):同一金属同一天已有价格
        if (error.code === '23505') {
            return { fieldErrors: { price_date: t('metalPrices.errors.duplicate') } }
        }
        return { error: t('metalPrices.form.saveError', { message: error.message }) }
    }

    revalidatePath('/metal-prices')
    redirect('/metal-prices')
}
