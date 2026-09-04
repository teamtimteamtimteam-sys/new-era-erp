'use server'

import { parseSourceFields } from '../sourceParse'
import { createClient } from '@/lib/supabase/server'
import type { InsertRow } from '@/lib/db-helpers'
import { getTranslations } from '@/lib/i18n/server'
import { redirect } from 'next/navigation'
import { revalidatePath } from 'next/cache'
import { loadSubstances } from '../substanceQuery'
import { ACK_FIELD, ackSignature, outsideOnly, type AnomalyVerdict } from '../anomaly'
import { parseIndexField } from '../indexOptions'

export type CreateMetalPriceState = {
    error?: string
    fieldErrors?: Record<string, string>
    // METAL-1:异常提示。有值 = 这一次【没有保存】,等人看过两个数字再确认。
    warnings?: AnomalyVerdict[]
}

export async function createMetalPrice(
    _prevState: CreateMetalPriceState,
    formData: FormData
): Promise<CreateMetalPriceState> {
    const t = await getTranslations()

    // 1. 取字段。LME-1b:出处现在【在表单里】—— 1a 之后它必填,
    //    而这条路此前直插、不给 source,于是撞的是裸的 NOT NULL 约束原文。
    const metal = (formData.get('metal') as string)?.trim() || ''
    const price_raw = (formData.get('price_usd_per_tonne') as string) || ''
    const price_date = (formData.get('price_date') as string)?.trim() || ''
    const notes = (formData.get('notes') as string)?.trim() || null
    // METAL-2:哪个市场的报价。未声明是一个明写的选项,不是"没填"。
    const price_index = parseIndexField(formData.get('price_index'))
    const { source, sourceReference, quoteDelayed } = parseSourceFields(formData)

    // 2. 校验
    const fieldErrors: Record<string, string> = {}
    // 【表单先说人话,库仍然是权威】两条都要:漏了出处,库会拒(NOT NULL),
    // 但那是约束原文;这里先按名拦下来。配对那条同理。
    if (!source) fieldErrors.quote_source = t('pricing.errors.QUOTE_SOURCE_REQUIRED')
    else if (source === 'published_index' && !price_index) {
        fieldErrors.quote_source = t('pricing.errors.QUOTE_SOURCE_INDEX_REQUIRED')
    }
// PROC-4:合法值现读 substances 那张字典(外键才是权威;这里只把话说成人话)。
    const allowedMetals = new Set(
        (await loadSubstances(await createClient())).map((r) => r.code)
    )
    if (!allowedMetals.has(metal)) fieldErrors.metal = t('metalPrices.form.errMetal')

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

    // 3. METAL-1:异常判据 —— 【问数据库,不自己算】(一份实现,预览与写入共用)。
    //    第一次提交先把两个数字摆出来;人确认【这一组数字】之后才继续。
    //    【服务端在这里不拒绝任何东西】—— 确认位只决定要不要先画提示,不是闸门:
    //    3 倍的真实行情是可能的,而系统分不出哪一种是哪一种。
    const { data: verdict, error: checkError } = await supabase.rpc('metal_price_anomaly', {
        p_metal: metal,
        p_price: price,
        p_price_date: price_date,
        p_price_index: price_index ?? undefined,
    })
    // 判据本身失败要说出来,不能当作"没有异常"放过去 ——
    // 失败不是空集(与 mustRows 同一条规矩)
    if (checkError) {
        return { error: t('metalPrices.form.saveError', { message: checkError.message }) }
    }
    const outside = outsideOnly([verdict as unknown as AnomalyVerdict].filter(Boolean))
    if (outside.length > 0 && formData.get(ACK_FIELD) !== ackSignature(outside)) {
        return { warnings: outside }
    }

    // 4. 写入
    const {
        data: { user },
    } = await supabase.auth.getUser()

    const { error } = await supabase.from('metal_prices').insert({
        metal,
        price_usd_per_tonne: price,
        price_date,
        price_index,
        notes,
        created_by: user?.id ?? null,
        updated_by: user?.id ?? null,
        // LME-1b:出处三件套。source 必填(库里没有默认值了);
        // 凭据空 → NULL;延迟三态 → true/false/null。
        source,
        source_reference: sourceReference,
        quote_delayed: quoteDelayed,
        // id/created_at/updated_at 用默认值
    } as InsertRow<'metal_prices'>)

    if (error) {
        // 唯一约束 (metal, price_date):同一金属同一天已有价格
        if (error.code === '23505') {
            return { fieldErrors: { price_date: t('metalPrices.errors.duplicate') } }
        }
        return { error: t('metalPrices.form.saveError', { message: error.message }) }
    }

    revalidatePath('/tools/pricing/metal-prices')
    redirect('/tools/pricing/metal-prices')
}
