// app/tools/pricing/metal-prices/page.tsx
// 金属价格列表页:URL 驱动的金属筛选 / 排序 / 分页。
// 端口自 inbound 列表,精简为单表参考表:无搜索、无导出、无关联方下拉。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { sourceLabelKey } from './sourceOptions'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import MetalPricesToolbar from './MetalPricesToolbar'
import { ListPage } from '@/app/components/ui/list-page'
import MetalPricesTable, { type MetalPriceRow as MetalPricesTableRow } from './MetalPricesTable'
import { metalLabelKey } from './options'
import {
    parseMetalPricesListParams,
    parseMetalPricesPage,
    applyMetalPricesFilters,
    METAL_PRICES_PAGE_SIZE,
    type MetalPricesSortCol,
} from './metalPricesQuery'
import { formatMoneyBare } from '@/lib/format'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { can } from '@/lib/permissions'
import { mustOne } from '@/lib/db-helpers'
import ThresholdPanel from './ThresholdPanel'
import type { AnomalyVerdict } from './anomaly'
import { loadSubstances, toOptions } from './substanceQuery'

type MetalPriceRow = {
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
    // FK 嵌入运行时是对象;显式类型 + cast 锁住(与其他页同一惯例)。
    metal_price_indices: { quote_currency: string | null } | null
}

export default async function MetalPricesPage({
    searchParams,
}: {
    searchParams: Promise<{
        metal?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // ★★【TOOLS-1 ①b(2026-09-03):本页【现在有】守卫了 —— 这是一次刻意的收窄】★★
    //
    // 【它此前为什么没有守卫 —— 那条理由留着,因为它当时是对的】
    //   规矩是:【守卫跟着数据自己的 RLS 走,不跟模块目录走】。
    //   metal_prices 的读策略是 `USING (true)`,所以列表页不设守卫;
    //   写那三页(new / bulk / [id]/edit)由 requireEditPermission 把关。
    //   那是同一条规则的两半 —— **在它是一条【一级路由】的时候。**
    //
    // 【位置变了,结论跟着变】本刀把它搬到 /tools/pricing 之下,而 /tools/pricing 由
    //   module.pricing.view 把门。**只收窄菜单、不收窄这一页,会造出一个
    //   【半开】的状态:菜单里看不见,URL 却打得开。** Tim 的裁定(甲)点名
    //   要消除的正是那个状态 —— 它在一次审计里、或者在一句"我为什么找不到
    //   这一页"的支持问题里,是最难解释的一种。
    //
    // ★【这【不是】一次数据控制,写下来免得被后人读错】★
    //   **metal_prices 的 RLS 仍然是 `USING (true)`,一个字没动。**
    //   数据在库那一层对任何登录用户仍然可读;变的只有导航与这道路由守卫。
    //   失去它的五个角色(实测):cfo · employee · hr · operations · warehouse。
    //
    // ★【CONV-0 ②a:从 requireFunction(FN.metalPrices) 换成 requireModule(MOD.pricing)】★
    //   **求的是同一个字符串。** FN.metalPrices.permission 与 MOD.pricing.permission
    //   都是 'module.pricing.view' —— 换的不是判据,是判据【从哪一条注册表条目取】。
    //   本页的 FUNCTIONS 条目已经随②a 删掉(它不再是一条菜单条目),而 fnByHref 对
    //   一条不存在的 href 会在【模块加载时】抛错 —— 所以这一行必须跟着改,
    //   不改的话应用根本起不来(这是好事:它不会静默地放行)。
    //
    // 【拒绝页的标题因此从「金属价格」变成「定价」,而这是 Tim 明确接受的】
    //   一个被拒的读者现在读到的是【他进不去的那个模块】的名字,而不是一个
    //   菜单上根本不再提供的页面的名字 —— 本刀之后,后者才是那句假话。
    const denied = await requireModule(MOD.pricing)
    if (denied) return denied

    //   写(new / bulk / [id]/edit) 那三页的守卫一个字没动:
    //   写(new / bulk / [id]/edit) INSERT|UPDATE|DELETE ... has_permission('module.pricing.edit')
    //                             → requireEditPermission('module.pricing.edit', ...)
    //
    // (策略原文见 db/tables/metal_prices.sql;完整理由见 lib/modules.ts 的 /tools/pricing 那一条。)
    //
    // ★【以下这一段是【被推翻的旧理由】,留着是因为它是收窄那次改动的论据】★
    //   它主张本页【不该】有守卫,而上面那道守卫就是推翻它的结果(TOOLS-1 ①b)。
    //   ★ 不要照它读成"本页没有守卫" ★ —— 它描述的是这一页还在一级路由时的世界。
    //   推翻它的不是新道理,是它的【位置变了】:住进 /tools/pricing 之下以后,
    //   只收窄菜单而不收窄这一页会留下一个菜单里看不见、URL 却打得开的半开状态。
    //
    // 看行情人人可以:行情是市场报价,数据自己声明它是公开的。给本页挂 module.pricing.view
    // 会让 UI 比数据库还严 —— 对一个数据库愿意完整回答的人显示"你没有权限",而那道门
    // 数据库里根本不存在。目录的措辞不是策略:module.pricing.view 那一条写着"公式、计价器
    // 与行情",两者冲突时以策略为准。要改回去,先改 metal_prices 的 SELECT 策略,再改
    // 这里,顺序不能反。/tools/pricing 本身仍然受管 —— 公式与商务条款不是公开数据。

    const sp = await searchParams
    const supabase = await createClient()
    // PROC-4:物质清单从 substances 那张字典读(清单与顺序都由它定)。
    const substanceOptions = toOptions(await loadSubstances(supabase))
    const t = await getTranslations()
    const locale = await getLocale()

    // PROC-4:URL 里的 ?metal= 认哪些值,由字典说了算(而不是一份写死的七元素)。
    const { metal, sort, dir } = parseMetalPricesListParams(
        sp,
        substanceOptions.map((o) => o.value)
    )
    const requestedPage = parseMetalPricesPage(sp.page)
    const filterParams = { metal, sort, dir }

    // 1) 匹配总数(套用同一套过滤,只 select 'id')
    const { count } = await applyMetalPricesFilters(
        supabase.from('metal_prices').select('id', { count: 'exact', head: true }),
        filterParams
    )

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / METAL_PRICES_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * METAL_PRICES_PAGE_SIZE
    const to = from + METAL_PRICES_PAGE_SIZE - 1

    // 2) 取当前页的行
    const baseQuery = supabase
        .from('metal_prices')
        .select('id, metal, price_usd_per_tonne, price_date, source, price_index, notes, anomaly_check, metal_price_indices ( quote_currency )')

    const { data, error } = await applyMetalPricesFilters(baseQuery, filterParams).range(
        from,
        to
    )
    const rows = data as unknown as MetalPriceRow[] | null

    // METAL-1:阈值(人人可读)+ 能不能改(module.pricing.edit,与 RLS 同码)。
    // mustOne:引导必须给出这一行,读不到要炸,不能当成"没有配置"悄悄过去。
    const settingsRes = await supabase
        .from('pricing_settings')
        .select('metal_price_change_warn_pct, notes_en, notes_zh')
        .eq('id', true)
        .maybeSingle()
    const settings = mustOne(settingsRes, 'pricing_settings')
    if (!settings) {
        // 引导必须给出这一行。读不到就【说出来】—— 一块显示不出阈值的提示面板
        // 与"没有异常"在屏幕上是同一样东西,而 metal_price_anomaly 那一侧也会
        // 以 PRICING_SETTINGS_MISSING 拒答。
        throw new Error('pricing_settings 引导行缺失:异常提示的阈值读不到')
    }
    const canEditPrices = await can('module.pricing.edit')

    // metal 存储值反查成本地化文案;未知值原样显示
    const metalLabel = (value: string) => {
        const key = metalLabelKey(value)
        return key ? t(key) : value
    }

    // 表头排序链接:保留金属筛选,只改 sort/dir;不带 page —— 改排序回到第 1 页。
    function pageHref(targetPage: number) {
        const params = new URLSearchParams()
        if (metal) params.set('metal', metal)
        params.set('sort', sort)
        params.set('dir', dir)
        params.set('page', String(targetPage))
        return `/tools/pricing/metal-prices?${params.toString()}`
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('metalPrices.listTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('metalPrices.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ Q7:排序仍是服务端的。
    // ★ state 恒为 'ok' —— ThresholdPanel 是一个【设置】(一行行情都没有时
    //   照样要能改阈值),工具栏是筛选出口;两者都画在状态分支之前。
    const tableRows: MetalPricesTableRow[] = (rows ?? []).map((r) => ({
        id: r.id,
        metalLabel: metalLabel(r.metal),
        pricePerTonne: r.price_usd_per_tonne,
        quoteCurrency: r.metal_price_indices?.quote_currency ?? null,
        priceDate: r.price_date,
        priceIndex: r.price_index ?? null,
        sourceLabel: t(sourceLabelKey(r.source)),
        notes: r.notes ?? '—',
        // 判词为空 = 这一行录入时还没有这项检查(见 MetalPricesTable 抬头第三种)
        anomalyVerdict: (r.anomaly_check?.verdict as 'outside' | 'no_reference' | 'inside' | undefined) ?? null,
        anomalyChangePct: r.anomaly_check?.change_pct ?? 0,
        anomalyRefPrice: r.anomaly_check?.reference_price ?? 0,
        anomalyRefDate: r.anomaly_check?.reference_date ?? '',
    }))

    const filterQuery: Record<string, string> = {}
    if (metal) filterQuery.metal = metal

    return (
        <ListPage
            title={t('metalPrices.listTitle')}
            actions={
                <div className="flex gap-3">
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href="/tools/pricing/metal-prices/bulk"
                        >
                            {t('metalPrices.bulk.entry')}
                        </Link>
                    </Button>
                    <Button asChild>
                        <Link href="/tools/pricing/metal-prices/new">{t('metalPrices.addButton')}</Link>
                    </Button>
                </div>
            }
            notices={
                <ThresholdPanel
                    thresholdPct={Number(settings.metal_price_change_warn_pct)}
                    // ⑤a:按界面语言选一句。**不再渲染那个单语的 notes**。
                    notes={locale === 'zh' ? settings.notes_zh : settings.notes_en}
                    canEdit={canEditPrices}
                />
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <MetalPricesToolbar substanceOptions={substanceOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('metalPrices.recordCount', { count: total })}
            </p>

            <MetalPricesTable
                rows={tableRows}
                empty={t('metalPrices.emptyState')}
                sort={sort}
                dir={dir}
                filterQuery={filterQuery}
                shown={tableRows.length}
                total={total}
            />

            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={pageHref(page - 1)}
                        >
                            {t('metalPrices.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('metalPrices.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-gray-600">
                    {t('metalPrices.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={pageHref(page + 1)}
                        >
                            {t('metalPrices.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('metalPrices.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
