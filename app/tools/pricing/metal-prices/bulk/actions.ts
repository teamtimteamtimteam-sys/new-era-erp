'use server'

import { parseSourceFields } from '../sourceParse'
// 每日行情批量录入:并列数组(metal[]/price[])组装 prices jsonb → rpc upsert_metal_prices。
// 空价格由 DB 侧跳过(表单常常只填其中几个金属),金属集合/价格正负由 DB 校验。
// 不重定向 —— 每日录入是重复动作,停在原页并回报 {inserted, updated, skipped}。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { localizePricingError } from '../../pricingErrorCodes'
import { ACK_FIELD, ackSignature, outsideOnly, type AnomalyVerdict } from '../anomaly'
import { parseIndexField } from '../indexOptions'

export type BulkPricesState = {
    error?: string
    result?: { inserted: number; updated: number; skipped: number }
    // METAL-1:异常提示。有值 = 这一次【一行都没写】,等人看过再确认整组。
    warnings?: AnomalyVerdict[]
}

export async function saveBulkPrices(
    _prevState: BulkPricesState,
    formData: FormData
): Promise<BulkPricesState> {
    const t = await getTranslations()

    const priceDate = String(formData.get('price_date') ?? '').trim()
    if (!priceDate || Number.isNaN(Date.parse(priceDate))) {
        return { error: t('metalPrices.form.errPriceDate') }
    }

    // METAL-2:一次批量录入属于【一个指数】—— 一天的行情单来自一个市场。
    const priceIndex = parseIndexField(formData.get('price_index'))

    const metals = formData.getAll('metal').map(String)
    const prices = formData.getAll('price').map(String)

    const payload = metals.map((metal, i) => ({
        metal,
        // 空串原样送出:DB 侧把 null/空当作"这个金属今天没填",计入 skipped
        price_usd_per_tonne: (prices[i] ?? '').trim() || null,
    }))

    const supabase = await createClient()

    // METAL-1:一次问一整天 —— 与写入共用同一份判据(preview_metal_price_anomalies
    // 内部就是逐个调 metal_price_anomaly)。【页面不自己算】,理由与
    // preview_revalue_foreign_balances 同一条:两份算术迟早各自漂移,而屏幕上
    // 那份是人相信的那份。
    const { data: verdicts, error: checkError } = await supabase.rpc(
        'preview_metal_price_anomalies',
        { p_price_date: priceDate, p_prices: payload, p_price_index: priceIndex ?? undefined }
    )
    // 判据失败要说出来,不能当作"没有异常"放过去(失败不是空集)
    if (checkError) {
        return { error: await localizePricingError(checkError.message) }
    }
    const outside = outsideOnly((verdicts ?? []) as unknown as AnomalyVerdict[])
    if (outside.length > 0 && formData.get(ACK_FIELD) !== ackSignature(outside)) {
        return { warnings: outside }
    }

    // LME-1b:出处随批次一起走 —— 一次批量录入是【同一个来源】的一批数,
    // 所以三个字段挂在批次上而不是每个金属一份。
    const { source, sourceReference, quoteDelayed } = parseSourceFields(formData)
    const { data, error } = await supabase.rpc('upsert_metal_prices', {
        p_price_date: priceDate,
        p_prices: payload,
        p_price_index: priceIndex ?? undefined,
        p_source: source || undefined,
        p_source_reference: sourceReference ?? undefined,
        p_quote_delayed: quoteDelayed ?? undefined,
    })

    if (error) {
        return { error: await localizePricingError(error.message) }
    }

    revalidatePath('/tools/pricing/metal-prices')
    revalidatePath('/tools/pricing/metal-prices/bulk')

    const res = data as { inserted?: number; updated?: number; skipped?: number } | null
    return {
        result: {
            inserted: res?.inserted ?? 0,
            updated: res?.updated ?? 0,
            skipped: res?.skipped ?? 0,
        },
    }
}
