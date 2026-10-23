import 'server-only'

// TABLE-EXPORT-2b-1(Tim 2026-10-22 TABLE-EXPORT-1 Q2 · Q8):金属行情列表的【一份】读取 —— 页面与导出路由共用。
// 页面一次画 METAL_PRICES_PAGE_SIZE 行(服务端分页、服务端排序);导出路由按同一条读取、同一个映射翻页取全(上限 50,000)。
// 排序在页面那一套之后补 id —— 翻页要一个【唯一】的次序(price_date + metal 可以并列:同一天两个指数各一条)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { formatDate } from '@/lib/dates'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { applyMetalPricesFilters, type MetalPricesListParams } from './metalPricesQuery'
import { sourceLabelKey } from './sourceOptions'
import { metalLabelKey } from './options'
import type { AnomalyVerdict } from './anomaly'
import type { MetalPriceRow as MetalPricesTableRow } from './MetalPricesTable'

type Client = SupabaseClient<Database>

export type MetalPriceDbRow = {
    id: string
    metal: string
    price_usd_per_tonne: number
    price_date: string
    source: string
    price_index: string | null
    notes: string | null
    // METAL-1:录入那一刻的判词(记录,不事后重算 —— 后来的报价会改变"上一条")
    anomaly_check: AnomalyVerdict | null
    // METAL-3:这一行是【哪个币种】报的 —— SMM 是 CNY/吨,不是 USD/吨。
    metal_price_indices: { quote_currency: string | null } | null
}

export function metalPricesCount(supabase: Client, p: MetalPricesListParams) {
    return applyMetalPricesFilters(supabase.from('metal_prices').select('id', { count: 'exact', head: true }), p)
}

export function metalPricesPage(supabase: Client, p: MetalPricesListParams, from: number, to: number) {
    return applyMetalPricesFilters(
        supabase
            .from('metal_prices')
            .select('id, metal, price_usd_per_tonne, price_date, source, price_index, notes, anomaly_check, metal_price_indices ( quote_currency )'),
        p,
    )
        .order('id', { ascending: true })
        .range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as MetalPriceDbRow[] | null }))
}

export async function shapeMetalPriceRows(rows: MetalPriceDbRow[]): Promise<MetalPricesTableRow[]> {
    const [t, locale] = await Promise.all([getTranslations(), getLocale()])
    // metal 存储值反查成本地化文案;未知值原样显示
    const metalLabel = (value: string) => {
        const key = metalLabelKey(value)
        return key ? t(key) : value
    }
    return rows.map((r) => ({
        id: r.id,
        metalLabel: metalLabel(r.metal),
        pricePerTonne: r.price_usd_per_tonne,
        quoteCurrency: r.metal_price_indices?.quote_currency ?? null,
        priceDate: formatDate(r.price_date, locale),
        priceDateRaw: r.price_date,
        priceIndex: r.price_index ?? null,
        sourceLabel: t(sourceLabelKey(r.source)),
        notes: r.notes ?? '—',
        notesRaw: r.notes,
        // 判词为空 = 这一行录入时还没有这项检查(见 MetalPricesTable 抬头第三种)
        anomalyVerdict: (r.anomaly_check?.verdict as 'outside' | 'no_reference' | 'inside' | undefined) ?? null,
        anomalyChangePct: r.anomaly_check?.change_pct ?? 0,
        anomalyRefPrice: r.anomaly_check?.reference_price ?? 0,
        anomalyRefDate: r.anomaly_check?.reference_date ?? '',
    }))
}

/** 导出路由的地址,带上当前的筛选与排序(不带 page)。 */
export function metalPricesExportHref(p: MetalPricesListParams): string {
    const params = new URLSearchParams()
    if (p.metal) params.set('metal', p.metal)
    params.set('sort', p.sort)
    params.set('dir', p.dir)
    return `/tools/pricing/metal-prices/export?${params.toString()}`
}
