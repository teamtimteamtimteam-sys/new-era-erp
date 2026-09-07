// app/finance/fx/page.tsx
// 汇率列表页(端口自 metal-prices):币种筛选 / 排序 / 分页 / 编辑入口。
//
// CONV-4:套 CONV-1 的两文件模板。三块提示(月末就绪 / JE-70 一次性提醒 /
// 缺牌价)全部【无条件】渲染,与有没有数据无关 —— 走 notices,不进 children。
// state 恒为 'ok':筛选工具栏是真实出口,必须与表格一起无条件可见,理由与
// /finance/expenses 同一条。排序留在服务端,Q7 行为不变。
import { Button } from '@/app/components/ui/button'
import { Suspense } from 'react'
import { createClient } from '@/lib/supabase/server'
import Link from 'next/link'
import FxToolbar from './FxToolbar'
import FxRatesTable, { type FxRateRow } from './FxRatesTable'
import {
    parseFxListParams,
    parseFxPage,
    applyFxFilters,
    FX_PAGE_SIZE,
} from './fxQuery'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'

type FxRow = {
    id: string
    currency: string
    rate_type: string
    rate_sgd_per_unit: number
    rate_date: string
    source: string
    notes: string | null
}

export default async function FxRatesPage({
    searchParams,
}: {
    searchParams: Promise<{
        currency?: string
        sort?: string
        dir?: string
        page?: string
    }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const { currency, sort, dir } = parseFxListParams(sp)
    const requestedPage = parseFxPage(sp.page)
    const filterParams = { currency, sort, dir }

    // 1) 匹配总数 + 可选币种(非 SGD;并行)
    const [{ count }, currenciesRes] = await Promise.all([
        applyFxFilters(
            supabase.from('fx_rates').select('id', { count: 'exact', head: true }),
            filterParams
        ),
        supabase.from('currencies').select('code').eq('is_base', false).order('code'),
    ])

    const total = count ?? 0
    const totalPages = Math.max(1, Math.ceil(total / FX_PAGE_SIZE))
    const page = Math.min(requestedPage, totalPages)
    const from = (page - 1) * FX_PAGE_SIZE
    const to = from + FX_PAGE_SIZE - 1

    // 2) 取当前页的行
    const { data, error } = await applyFxFilters(
        supabase.from('fx_rates').select('id, currency, rate_type, rate_sgd_per_unit, rate_date, source, notes'),
        filterParams
    ).range(from, to)
    const rows = data as unknown as FxRow[] | null
    const currencyOptions = (mustRows(currenciesRes)).map((c) => c.code)

    // 缺牌价的日子 —— 牌价是日课,漏一天可能永远补不回。
    //
    // 【两个计数,不是一个】(FXG-1)这张视图有两支来源:过账与报价。过账那一支
    // 数【凭证】,报价那一支数【报价条数】,而混合日两支都命中 —— 它真的有两个数。
    // 此前它们被 sum() 进同一列、并被念成"当天 N 笔凭证":纯报价日因此声称了
    // 它一笔都没有的凭证,混合日则把两种单位加在一起。现在各画各的,单位跟着列走,
    // 本页不做任何推导。
    const gapsRes = await supabase
        .from('fx_rate_gaps')
        .select('rate_date, currency, missing_types, entry_count, quote_count, gap_source')
        .order('rate_date', { ascending: false })
        .limit(30)
    // 【失败必须失败】此前这里是 `data ?? []`,而且 error 根本没有被解构出来 ——
    // 一次读不到就渲染成"没有缺口",而"没有缺口"正是这块牌子最想说的好消息。
    // check-error-swallowing 抓不到这个形状(它自己的抬头写着这一类是残余),
    // 所以这一处是读代码读出来的。/finance/month-end 读同一张视图用的就是 mustRows。
    const gaps = mustRows(gapsRes, 'fx_rate_gaps') as unknown as {
        rate_date: string
        currency: string
        missing_types: string[]
        entry_count: number
        quote_count: number
        gap_source: string
    }[]

    // ── FX-RATES-1:月末就绪 ────────────────────────────────────────────────
    // 【fx_rate_gaps 看不见月末】它的日期只来自过账日与报价日,而一个没有过账、
    // 没有报价的月末对它是【结构性不可见】的 —— 偏偏月末重估非要那天的中间价不可。
    // 这张视图就是为那个盲区建的。两张各说各的,不要合并(理由写在两个视图头上)。
    const readyRes = await supabase
        .from('fx_month_end_readiness')
        .select('month_end, currency, has_mid, revalued, blocks_close')
        .order('month_end', { ascending: false })
    const readiness = mustRows(readyRes, 'fx_month_end_readiness') as unknown as {
        month_end: string
        currency: string
        has_mid: boolean
        revalued: boolean
        blocks_close: boolean
    }[]
    const blocking = readiness.filter((r) => r.blocks_close)

    // ── FX-RATES-1:一次性的提醒,【条件消失它就消失】 ──────────────────────
    // JE-2026-0070 是一张更正分录。载入第一个八月或更晚的中间价之后,
    // 下一次重估要么尊重它、要么把它翻倍 —— 取决于承载额有没有把它算进去。
    // 算得进去(它的 source_type 是 'revaluation'),而 fixture 133 的 C 臂盯着这件事。
    // 【自退休】只要还没有 2026-08-01 之后的中间价就显示;有了就再也不出现,
    // 于是它不会变成家具。
    const laterMid = await supabase
        .from('fx_rates')
        .select('id', { count: 'exact', head: true })
        .eq('rate_type', 'mid')
        .gte('rate_date', '2026-08-01')
        .is('deleted_at', null)
    const showCorrectionNotice = (laterMid.count ?? 0) === 0

    // 【这一行是哪一种缺口 —— 事实,由 gap_source 直说】
    // 三个分支都是【字面量】t() 调用,不是把 gap_source 拼进键里:静态那一半就
    // 盖得住它们,不必往 check-i18n 的 MANIFEST 里加一条动态前缀。能静态就别动态。
    function gapKindLabel(src: string): string {
        if (src === 'posting') return t('finance.fxPage.gapKindPosting')
        if (src === 'quote') return t('finance.fxPage.gapKindQuote')
        if (src === 'posting+quote') return t('finance.fxPage.gapKindBoth')
        // 视图只产出上面三种。真出了第四种,原样显示【而不是猜一个】——
        // 一个猜出来的分类,和一个说错了的分类,在屏幕上长得一模一样。
        return src
    }

    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.fxTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.fxPage.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const tableRows: FxRateRow[] = (rows ?? []).map((r) => ({
        id: r.id,
        currency: r.currency,
        rateType: r.rate_type,
        rateSgdPerUnit: r.rate_sgd_per_unit,
        rateDate: r.rate_date,
        source: r.source,
        notes: r.notes,
    }))

    return (
        <ListPage
            title={t('finance.fxTitle')}
            actions={
                // ★★ BTN-6/F4(2026-09-07):这个抬头此前【摊开成三段】,而那是【结构性的】★★
                //   原来这里是一个裸 fragment。fragment 不产生元素,于是这两个按钮
                //   【直接成了抬头行的 flex item】—— 而抬头行是 `justify-between`,
                //   三个 item(标题 + 两个钮)因此被摊成「左 / 中 / 右」:
                //   「+ Add FX Rate」贴着标题,「Enter a week」被甩到最右边。
                //   ☞ 那不是没对齐,是【没有容器】。ListPage 的动作槽现在自带一个
                //     flex-wrap 容器(见 list-page.tsx),fragment 从此是安全的写法。
                //   同时把顺序改回全站的形状:【次要在前,主要在后】——
                //   /suppliers、/tools/pricing/metal-prices 都是这个次序,本页原先是反的。
                //   `ml-3` 也一起撤掉:那是没有容器时用来顶开间距的调用点补丁,
                //   现在间距由容器的 gap-3 给,而它正好是同一个值。
                <>
                    <Button asChild variant="outline" size="sm">
                        <Link href="/finance/fx/bulk">{t('finance.fxPage.bulk.entryLink')}</Link>
                    </Button>
                    <Button asChild>
                        <Link href="/finance/fx/new">{t('finance.fxPage.addButton')}</Link>
                    </Button>
                </>
            }
            // ★ 三块提示【无条件】渲染 —— 与有没有数据无关,理由同 /sales/commissions
            // notices 抬头:一条只在有数据时才出现的警告,等于没有警告。
            notices={
                <>
                    {blocking.length > 0 && (
                        <div className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-3 rounded mb-4 text-sm">
                            <p className="font-medium mb-1">{t('finance.fxPage.readyTitle', { n: blocking.length })}</p>
                            <ul className="space-y-0.5">
                                {blocking.map((r) => (
                                    <li key={`${r.month_end}-${r.currency}`}>
                                        <span className="font-mono">{r.month_end}</span> · {r.currency} ·{' '}
                                        {t('finance.fxPage.readyMissingMid')}
                                    </li>
                                ))}
                            </ul>
                            <p className="text-xs mt-2 opacity-80">{t('finance.fxPage.readyWhy')}</p>
                        </div>
                    )}
                    {showCorrectionNotice && (
                        <div className="bg-blue-50 border border-blue-300 text-blue-900 px-4 py-3 rounded mb-4 text-sm">
                            <p className="font-medium mb-1">{t('finance.fxPage.je70Title')}</p>
                            <p>{t('finance.fxPage.je70Body')}</p>
                            <p className="text-xs mt-1 opacity-80">{t('finance.fxPage.je70Assured')}</p>
                        </div>
                    )}
                    {gaps.length > 0 && (
                        <div className="mb-4 rounded border border-amber-300 bg-amber-50 px-4 py-3 text-amber-900">
                            <p className="font-medium mb-1">{t('finance.fxPage.gapsTitle', { n: gaps.length })}</p>
                            <ul className="text-sm space-y-0.5">
                                {gaps.map((g) => (
                                    <li key={g.rate_date + g.currency}>
                                        <span className="font-mono">{g.rate_date}</span> · {g.currency} ·{' '}
                                        {t('finance.fxPage.gapsMissing', { 0: g.missing_types.join(', ') })} ·{' '}
                                        {gapKindLabel(g.gap_source)} ·{' '}
                                        {/* 【两个计数各说各的单位,零的那个不显示】
                                            显示一个 "0 entries" 不是更诚实,只是更吵:
                                            这一行为什么在这儿,gap_source 已经说了。 */}
                                        {[
                                            g.entry_count > 0
                                                ? t('finance.fxPage.gapsEntries', { n: g.entry_count })
                                                : null,
                                            g.quote_count > 0
                                                ? t('finance.fxPage.gapsQuotes', { n: g.quote_count })
                                                : null,
                                        ]
                                            .filter(Boolean)
                                            .join(' · ')}
                                    </li>
                                ))}
                            </ul>
                            {/* 【判断与事实分开一行】上面每一行是事实(缺哪几侧、哪一种缺口、
                                各有多少);这一句是它意味着什么,单独放,不混进行里。 */}
                            <p className="text-xs mt-2 opacity-80">{t('finance.fxPage.gapsKindNote')}</p>
                        </div>
                    )}
                </>
            }
            state={{ kind: 'ok' }}
        >
            {/* 工具栏用 useSearchParams,按文档包一层 Suspense */}
            <Suspense fallback={<div className="mb-4 h-10" />}>
                <FxToolbar currencies={currencyOptions} />
            </Suspense>

            <p className="text-sm text-gray-600 mb-4">
                {t('finance.fxPage.recordCount', { count: total })}
            </p>

            <FxRatesTable
                rows={tableRows}
                sort={sort}
                dir={dir}
                currency={currency}
                shown={tableRows.length}
                total={total}
            />

            {/* 分页控件:服务端 <Link>;首页禁用上一页、末页禁用下一页 */}
            <div className="mt-4 flex items-center justify-between">
                {page > 1 ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={`/finance/fx?${new URLSearchParams({ ...(currency ? { currency } : {}), sort, dir, page: String(page - 1) }).toString()}`}
                        >
                            {t('finance.pagination.prev')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('finance.pagination.prev')}
                    </Button>
                )}

                <span className="text-sm text-gray-600">
                    {t('finance.pagination.pageOf', { current: page, total: totalPages })}
                </span>

                {page < totalPages ? (
                    <Button asChild variant="outline" size="sm">
                        <Link
                            href={`/finance/fx?${new URLSearchParams({ ...(currency ? { currency } : {}), sort, dir, page: String(page + 1) }).toString()}`}
                        >
                            {t('finance.pagination.next')}
                        </Link>
                    </Button>
                ) : (
                    <Button variant="outline" size="sm" disabled>
                        {t('finance.pagination.next')}
                    </Button>
                )}
            </div>
        </ListPage>
    )
}
