// app/metal-prices/bulk/page.tsx
// 每日行情批量录入(服务端壳):按 ?date=(默认今天)取两组数据 ——
//   * 该日期已录入的价格(预填,于是本页也能当"改今天的价"用)
//   * 该日期之前(含当日)每个金属最近一次的价格(录入时的参照)
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { loadSubstances, toOptions } from '../substanceQuery'
import BulkPricesForm, { type MetalRowData } from './BulkPricesForm'
import { requireEditPermission } from '@/app/components/moduleGuard'
import { getMetalPriceIndices } from '../indexQuery'
import { INDEX_UNSTATED } from '../indexOptions'
import { getLocale } from '@/lib/i18n/server'

function todayIso(): string {
    return new Date().toISOString().slice(0, 10)
}

export default async function BulkPricesPage({
    searchParams,
}: {
    searchParams: Promise<{ date?: string; index?: string }>
}) {
    // 【本页把关用 module.pricing.edit,不是 module.pricing.view。这是那条规矩的「写」那一半】
    // 规矩只有一条:【守卫跟着数据自己的 RLS 走,不跟模块目录走】。
    // 而一张表的 RLS 本来就有读、写两个答案,metal_prices 的这两个答案【不一样】——
    // 所以 app/metal-prices/ 底下四页带着两种守卫,那是【同一条规则的两半,不是例外】:
    //
    //   读(列表页 /metal-prices)  SELECT ... USING (true)
    //                             → 不设守卫
    //   写(new / bulk / [id]/edit) INSERT|UPDATE|DELETE ... has_permission('module.pricing.edit')
    //                             → requireEditPermission('module.pricing.edit', ...)
    //
    // (策略原文见 db/tables/metal_prices.sql;完整理由见 lib/modules.ts 的 /pricing 那一条。)
    //
    // 改行情不是人人可以,而本页【只做】这件事。用 module.pricing.view 把关会同时错两头:
    // 挡下有 edit 而无 view 的人,又放进有 view 而无 edit 的人 —— 让后者填完整张表单,
    // 再被数据库以 42501 拒收。不设守卫则只错后一头。边界仍然是那几条 WITH CHECK 策略;
    // 这里只是不要把一张注定被拒收的表单摆到人面前。

    const denied = await requireEditPermission('module.pricing.edit', 'nav.metalPrices')
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    // PROC-4:物质清单从 substances 那张字典读(清单与顺序都由它定)。
    const substanceOptions = toOptions(await loadSubstances(supabase))
    const t = await getTranslations()

    const raw = (sp.date ?? '').trim()
    const priceDate = raw && !Number.isNaN(Date.parse(raw)) ? raw : todayIso()

    // METAL-2:一张批量录入表属于【一个指数】—— 一天的行情单来自一个市场。
    // 参照价("上次多少")也必须按同一个指数取,否则拿 LME 的上一条去比 SMM 的
    // 今天,屏幕上那句"上次 X"就是错的。
    const indices = await getMetalPriceIndices()
    const locale = await getLocale()
    const rawIndex = (sp.index ?? '').trim()
    const priceIndex =
        rawIndex === INDEX_UNSTATED || rawIndex === ''
            ? null
            : indices.some((i) => i.code === rawIndex)
              ? rawIndex
              : null

    // 该日期之前(含)的全部在册行情,按金属+日期倒序 —— 首条即"最近一次"。
    let historyQuery = supabase
        .from('metal_prices')
        .select('metal, price_usd_per_tonne, price_date')
        .is('deleted_at', null)
        .lte('price_date', priceDate)
    // 未声明指数是一个【取值】,不是"不过滤" —— .is() 与 .eq() 是两个问题
    historyQuery = priceIndex === null
        ? historyQuery.is('price_index', null)
        : historyQuery.eq('price_index', priceIndex)
    const { data: history } = await historyQuery
        .order('metal')
        .order('price_date', { ascending: false })

    const rows: MetalRowData[] = substanceOptions.map((opt) => {
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

            <BulkPricesForm
                substanceOptions={substanceOptions}
                priceDate={priceDate}
                priceIndex={priceIndex}
                indices={indices}
                locale={locale}
                rows={rows}
            />
        </div>
    )
}
