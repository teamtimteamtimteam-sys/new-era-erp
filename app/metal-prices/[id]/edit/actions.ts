'use server'

import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { METAL_VALUES } from '../../options'
import { ACK_FIELD, ackSignature, outsideOnly, type AnomalyVerdict } from '../../anomaly'
import { parseIndexField } from '../../indexOptions'

export type UpdateMetalPriceState = {
    error?: string
    fieldErrors?: Record<string, string>
    // METAL-1:异常提示。有值 = 这一次【没有保存】,等人看过两个数字再确认。
    warnings?: AnomalyVerdict[]
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
    const price_index = parseIndexField(formData.get('price_index'))

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

    // price === null 与 fieldErrors 非空是同一件事(上面的校验保证),写在一起
    // 是为了让类型也知道 —— 下面的判据要一个 number,不是 number | null
    if (Object.keys(fieldErrors).length > 0 || price === null) {
        return { fieldErrors }
    }

    const supabase = await createClient()

    // 2b. METAL-1:改价与新录一样要过判据 —— 【三条写入路径都盖到】,否则只长在
    //     一条路径上的检查会被另外两条绕过。这一行自己不能当参照(p_exclude_id)。
    const { data: verdict, error: checkError } = await supabase.rpc('metal_price_anomaly', {
        p_metal: metal,
        p_price: price,
        p_price_date: price_date,
        p_price_index: price_index ?? undefined,
        p_exclude_id: id,
    })
    if (checkError) {
        return { error: t('metalPrices.form.saveError', { message: checkError.message }) }
    }
    const outside = outsideOnly([verdict as unknown as AnomalyVerdict].filter(Boolean))
    if (outside.length > 0 && formData.get(ACK_FIELD) !== ackSignature(outside)) {
        return { warnings: outside }
    }

    // 3. 更新(不动 source、code)
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase
        .from('metal_prices')
        .update({
            metal,
            price_usd_per_tonne: price ?? undefined,
            price_date,
            price_index,
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
