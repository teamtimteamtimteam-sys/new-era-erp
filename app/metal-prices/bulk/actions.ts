'use server'

// 每日行情批量录入:并列数组(metal[]/price[])组装 prices jsonb → rpc upsert_metal_prices。
// 空价格由 DB 侧跳过(表单常常只填其中几个金属),金属集合/价格正负由 DB 校验。
// 不重定向 —— 每日录入是重复动作,停在原页并回报 {inserted, updated, skipped}。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { localizePricingError } from '../../pricing/pricingErrorCodes'

export type BulkPricesState = {
    error?: string
    result?: { inserted: number; updated: number; skipped: number }
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

    const metals = formData.getAll('metal').map(String)
    const prices = formData.getAll('price').map(String)

    const payload = metals.map((metal, i) => ({
        metal,
        // 空串原样送出:DB 侧把 null/空当作"这个金属今天没填",计入 skipped
        price_usd_per_tonne: (prices[i] ?? '').trim() || null,
    }))

    const supabase = await createClient()
    const { data, error } = await supabase.rpc('upsert_metal_prices', {
        p_price_date: priceDate,
        p_prices: payload,
    })

    if (error) {
        return { error: await localizePricingError(error.message) }
    }

    revalidatePath('/metal-prices')
    revalidatePath('/metal-prices/bulk')

    const res = data as { inserted?: number; updated?: number; skipped?: number } | null
    return {
        result: {
            inserted: res?.inserted ?? 0,
            updated: res?.updated ?? 0,
            skipped: res?.skipped ?? 0,
        },
    }
}
