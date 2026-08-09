// app/metal-prices/bulk/page.tsx
// 每日行情批量录入(服务端壳):按 ?date=(默认今天)取两组数据 ——
//   * 该日期已录入的价格(预填,于是本页也能当"改今天的价"用)
//   * 该日期之前(含当日)每个金属最近一次的价格(录入时的参照)
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { METAL_OPTIONS } from '../options'
import BulkPricesForm, { type MetalRowData } from './BulkPricesForm'

function todayIso(): string {
    return new Date().toISOString().slice(0, 10)
}

export default async function BulkPricesPage({
    searchParams,
}: {
    searchParams: Promise<{ date?: string }>
}) {
    // 【本页没有 requireModule,是有意的,不是漏了 —— 不要"补"回来】
    // metal_prices 的 SELECT 策略写的是 `USING (true)`(db/tables/metal_prices.sql):
    // 数据自己声明它是公开的。挂上 module.pricing.view 会让 UI 比数据库还严 ——
    // 对一个数据库愿意完整回答的人显示"你没有权限",而那道门数据库里根本不存在。
    // 【把关跟着数据自己的 RLS 走,不跟模块目录走】;完整理由在 lib/modules.ts
    // 的 /pricing 那一条(/pricing 本身仍然受管:公式与商务条款不是公开数据)。
    // 写入这一侧由 RLS 自己管:insert/update/delete 策略都是
    // `has_permission('module.pricing.edit')`,所以本页打得开、存不下 ——
    // 与 OPS-15 之前的行为一致(这四页在 OPS-15 之前本来就没有任何页面级把关)。

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const raw = (sp.date ?? '').trim()
    const priceDate = raw && !Number.isNaN(Date.parse(raw)) ? raw : todayIso()

    // 该日期之前(含)的全部在册行情,按金属+日期倒序 —— 首条即"最近一次"。
    const { data: history } = await supabase
        .from('metal_prices')
        .select('metal, price_usd_per_tonne, price_date')
        .is('deleted_at', null)
        .lte('price_date', priceDate)
        .order('metal')
        .order('price_date', { ascending: false })

    const rows: MetalRowData[] = METAL_OPTIONS.map((opt) => {
        const forMetal = (history ?? []).filter((h) => h.metal === opt.value)
        const exact = forMetal.find((h) => h.price_date === priceDate)
        // 参照价:排除当日那条(否则"上次"就是自己),取更早的最近一条
        const prior = forMetal.find((h) => h.price_date !== priceDate)
        return {
            metal: opt.value,
            current: exact ? String(exact.price_usd_per_tonne) : '',
            lastPrice: prior ? Number(prior.price_usd_per_tonne) : null,
            lastDate: prior ? prior.price_date : null,
        }
    })

    return (
        <div className="p-8">
            <div className="mb-6">
                <Link href="/metal-prices" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <h1 className="text-2xl font-bold mb-4">{t('metalPrices.bulk.title')}</h1>

            <BulkPricesForm priceDate={priceDate} rows={rows} />
        </div>
    )
}
