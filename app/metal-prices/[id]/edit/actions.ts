'use server'

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { METAL_VALUES } from '../../options'

export type UpdateMetalPriceState = {
    error?: string
    fieldErrors?: Record<string, string>
}

export async function updateMetalPrice(
    id: string,
    _prevState: UpdateMetalPriceState,
    formData: FormData
): Promise<UpdateMetalPriceState> {
    const t = await getTranslations()

    // 1. 取字段(source 不在表单里,不改动)
    const metal = (formData.get('metal') as string)?.trim() || ''
    const price_raw = (formData.get('price_usd_per_tonne') as string) || ''
    const price_date = (formData.get('price_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || null

    // 2. 校验(与 create 一致)
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

    // 3. 更新(不动 source、code)
    const supabase = await createClient()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('metal_prices')
        .update({
            metal,
            price_usd_per_tonne: price ?? undefined,
            price_date,
            notes,
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已软删除的不能改

    if (error) {
        // 唯一约束 (metal, price_date):同一金属同一天已有价格
        if (error.code === '23505') {
            return { fieldErrors: { price_date: t('metalPrices.errors.duplicate') } }
        }
        return { error: t('metalPrices.form.saveError', { message: error.message }) }
    }

    revalidatePath('/metal-prices')
    revalidatePath(`/metal-prices/${id}/edit`)
    redirect('/metal-prices')
}

// 软删除:置 deleted_at + 记录 updated_by,revalidate 后跳回列表。
export async function softDeleteMetalPrice(id: string) {
    const supabase = await createClient()
    const t = await getTranslations()
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('metal_prices')
        .update({
            deleted_at: new Date().toISOString(),
            updated_by: user?.id ?? null,
        })
        .eq('id', id)
        .is('deleted_at', null) // 已经删过的不重复删

    if (error) {
        return { error: t('metalPrices.deleteError', { message: error.message }) }
    }

    revalidatePath('/metal-prices')
    redirect('/metal-prices')
}
