// app/logistics/containers/[id]/ContainerFreightPanel.tsx
// LOG-4b:这个箱子的运费 —— 实际 vs 报价,并排,【永不相减】。
//
// 【为什么不相减】报价那张表【不锁汇率】(forwarder_rate_quotes 的表注释明写),
// 实际单据把汇率锁在单据日的 tt_sell。所以"差多少"至少有两个都说得通的答案:
// 按报价币种比(两张单币种不同时无法相减),或按本位币比(要替报价挑一个汇率日,
// 而那正是那张表拒绝回答的事)。并排放着的两个数,读的人会自己相减 ——
// 所以币种不同时【必须明说】,而不是让它看起来可以比。
//
// 【两边都是每箱口径】报价的分母是每一个集装箱(Tim 定,LOG-4a 落在
// forwarder_rate_quotes.amount_ccy 的列注释里);这一页的实际额也只数指向这个箱子的单据。
// 两个标签都写着"每箱",因为一个没有分母的比较不是比较。
//
// 【六种空,六句话】brief 点了五种;第六种是【箱子没有指定货代】——
// containers.forwarder_id 可空,线上 4 个箱子里 2 个就是空的。没有它,
// 那种情况会掉进"这家货代没有报价"那一句,而那句话在说一件没发生的事。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAmount } from '@/lib/format'
import { mustRows } from '@/lib/db-helpers'
import { operativeOf } from './operativeMilestone'

type Doc = {
    id: string; code: string; doc_date: string
    amount_ccy: number; currency: string; status: string; direction: string
}

export default async function ContainerFreightPanel({
    containerId, laneId, forwarderId, departureDate,
}: {
    containerId: string
    laneId: string | null
    forwarderId: string | null
    departureDate: string
}) {
    const supabase = await createClient()
    const t = await getTranslations()

    const docs = mustRows(
        await supabase.from('freight_documents')
            .select('id, code, doc_date, amount_ccy, currency, status, direction')
            .eq('container_id', containerId)
            .is('deleted_at', null)
            .order('doc_date', { ascending: false }),
        'container freight documents'
    ) as unknown as Doc[]

    // 【只有 posted 的进合计】已冲销的单据仍然列出来(它发生过),但它不欠钱、
    // 也不该被算进"我们被收了多少" —— 两件事,所以行在、数不在。
    const totals = new Map<string, number>()
    for (const d of docs) {
        if (d.status !== 'posted') continue
        totals.set(d.currency, (totals.get(d.currency) ?? 0) + Number(d.amount_ccy))
    }
    const actualCurrencies = [...totals.keys()].sort()

    // ── 免柜期那一侧:【最后被录入】的那条 arrived ─────────────────────────
    // ════════════════════════════════════════════════════════════════════════
    // 【锚点规则:recorded_at DESC, id DESC —— 与库里那一支臂逐字一致】
    // 对应实现在 db/views/operations_now.sql 的 free_time_expiring 那一支
    // (migration:db/migrations/2026-08-20-log5d-a-correction-must-win.sql)。
    // **两处必须一起改** —— 这一页与看板算的是同一件事,口径一旦分岔,
    // 屏幕上写着"剩余 1 天"而看板一声不吭(或反过来),而没有任何东西会报错。
    // LOG-5d 就是把两处一起改的那一刀。
    //
    // 【为什么不是 event_date DESC】里程碑只增不改,更正的写法是再记一条;
    // 而一条把日期改【早】的更正在 event_date 排序下永远排不到前面 ——
    // 它一次都不会生效。线上 CTR-2026-0009 就是这么躺着的:
    // arrived 08-16(先录)、arrived 08-14(后录、更早),所有读者仍锚在 08-16。
    // ════════════════════════════════════════════════════════════════════════
    // CTN-OP:【判据不再写在这条查询的 ORDER BY 里】—— 它与时间轴上那个
    // 「当前认定」标记必须是同一句话,所以两处都调 operativeMilestone.ts。
    // 排序从 SQL 挪进那一份判据,行为不变(fetch 全部 arrived,再挑算数的那条);
    // 变的是【这条规则在页面这一侧只剩一份】。
    const arrivals = mustRows(
        await supabase.from('container_milestones')
            .select('id, milestone, event_date, recorded_at')
            .eq('container_id', containerId).eq('milestone', 'arrived'),
        'container arrivals'
    ) as unknown as { id: string; milestone: string; event_date: string; recorded_at: string }[]
    const arrivedOn = operativeOf(arrivals, 'arrived')?.event_date ?? null

    // ── 报价那一侧 ──────────────────────────────────────────────────────────
    let quoteState:
        | { kind: 'no_lane' }
        | { kind: 'no_forwarder' }
        | { kind: 'none_from_forwarder' }
        | { kind: 'not_valid_on_departure' }
        | { kind: 'found'; amount: number; currency: string; from: string; to: string; free_days: number | null }
    if (!laneId) {
        quoteState = { kind: 'no_lane' }
    } else if (!forwarderId) {
        quoteState = { kind: 'no_forwarder' }
    } else {
        const quotes = mustRows(
            await supabase.from('forwarder_rate_quotes')
                .select('amount_ccy, currency, valid_from, valid_to, free_days')
                .eq('supplier_id', forwarderId).eq('lane_id', laneId)
                .is('deleted_at', null),
            'forwarder rate quotes'
        ) as unknown as { amount_ccy: number; currency: string; valid_from: string; valid_to: string; free_days: number | null }[]
        if (quotes.length === 0) {
            quoteState = { kind: 'none_from_forwarder' }
        } else {
            // 【有效期含两端】与库里那条重叠守卫用的 daterange(…, '[]') 同一口径
            const hit = quotes.find((q) => q.valid_from <= departureDate && departureDate <= q.valid_to)
            quoteState = hit
                ? { kind: 'found', amount: Number(hit.amount_ccy), currency: hit.currency,
                    from: hit.valid_from, to: hit.valid_to,
                    free_days: hit.free_days === null ? null : Number(hit.free_days) }
                : { kind: 'not_valid_on_departure' }
        }
    }

    // 【币种不同要明说】—— 报价有了、实际也有了,但两个数不在同一个空间里
    const currencyMismatch =
        quoteState.kind === 'found' && actualCurrencies.length > 0
        && !actualCurrencies.includes(quoteState.currency)

    const empty = (msg: string) => <p className="text-sm text-gray-600 max-w-xl">{msg}</p>

    return (
        <section className="mt-8 border-t pt-6">
            <h2 className="mb-1 text-xl font-bold">{t('logistics.freightPanelHeading')}</h2>
            <p className="mb-4 text-sm text-gray-600 max-w-3xl">{t('logistics.freightPanelHint')}</p>

            {/* ── 免柜期:一行,五种"算不出来"各说各的话 ─────────────────────
                【这一页算 remaining 只为了【显示】,而不是决定何时告警】——
                告警的阈值住在 operations_now 的 free_time_expiring 那一支里,
                这里连 <= 2 都不判。两处若各判一次,屏幕与看板迟早各说各话。
                (口径仍然是同一条:同一个锚点、同一份报价。这一处重复是【已知的】,
                 见本刀的报告 —— 去掉它要一个库侧的算子,而本刀不动库。) */}
            <div className="mb-6 rounded-lg border border-gray-300 p-4">
                <h3 className="font-semibold mb-2 text-sm">{t('logistics.freeTimeHeading')}</h3>
                {!forwarderId ? (
                    /* 【指向那个控件】—— 与"清单从没实例化过"那句指向它的按钮同一条:
                       一句说出缺什么的话,要顺带说出去哪里补。此前这一句指着的是一个
                       【没有门】的字段(CTN-FWD 之前箱子页既不显示也不能改承运方)。 */
                    <p className="text-sm text-gray-600 max-w-3xl">
                        {t('logistics.freeTimeNoForwarder')}{' '}
                        <span className="text-gray-800">{t('logistics.containerNoForwarderPointer')}</span>
                    </p>
                ) : quoteState.kind !== 'found' ? (
                    <p className="text-sm text-gray-600 max-w-3xl">{t('logistics.freeTimeNoQuote')}</p>
                ) : arrivedOn === null ? (
                    /* 【"还没到港"不是"时间还很多"】—— 这一句就是那条区别 */
                    <p className="text-sm text-gray-600 max-w-3xl">{t('logistics.freeTimeNoArrival')}</p>
                ) : quoteState.free_days === null ? (
                    /* 【NULL ≠ 0】报价没写免柜期,不是零个免费天 */
                    <p className="text-sm text-gray-600 max-w-3xl">{t('logistics.freeTimeQuoteSilent')}</p>
                ) : (() => {
                    const since = Math.floor(
                        (Date.parse(new Date().toISOString().slice(0, 10)) - Date.parse(arrivedOn)) / 86400000)
                    const remaining = (quoteState.free_days as number) - since
                    return (
                        <>
                            {quoteState.free_days === 0 && (
                                <p className="mb-2 text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-3xl">
                                    {t('logistics.freeTimeZero')}
                                </p>
                            )}
                            {/* 【两段,不是一段】剩余天数要能单独染红,而在一整句里
                                按数字去 split 会在"到港 2 天 / 剩余 2 天"这种句子上
                                把同一个 span 插两次 —— 那是一个等着发生的渲染错。 */}
                            <p className="text-sm">
                                {t('logistics.freeTimeComputed', {
                                    days: String(since), free: String(quoteState.free_days),
                                })}
                                {' · '}
                                <span className={remaining < 0 ? 'text-red-700 font-semibold' : ''}>
                                    {t('logistics.freeTimeRemaining', { remaining: String(remaining) })}
                                </span>
                            </p>
                        </>
                    )
                })()}
            </div>

            <div className="grid gap-6 md:grid-cols-2">
                {/* ── 实际 ─────────────────────────────────────────────── */}
                <div className="border border-gray-300 rounded-lg p-4">
                    <h3 className="font-semibold mb-2 text-sm">{t('logistics.freightActualHeading')}</h3>
                    {docs.length === 0 ? empty(t('logistics.freightNoneYet')) : (
                        <>
                            <ul className="mb-3 space-y-1">
                                {docs.map((d) => (
                                    <li key={d.id} className="text-sm flex items-baseline gap-2">
                                        <Link href={`/finance/freight/${d.id}`}
                                            className="text-blue-700 hover:underline font-mono text-xs">
                                            {d.code}
                                        </Link>
                                        <span className="text-xs text-gray-500">
                                            {t('finance.freight.directionShort.' + d.direction)}
                                        </span>
                                        <span className="text-gray-500 text-xs">{d.doc_date}</span>
                                        <span className={'font-mono ml-auto ' + (d.status === 'posted' ? '' : 'line-through text-gray-400')}>
                                            {formatAmount(Number(d.amount_ccy), d.currency)}
                                        </span>
                                        {d.status !== 'posted' && (
                                            <span className="text-xs text-amber-700">{t('logistics.freightReversedNote')}</span>
                                        )}
                                    </li>
                                ))}
                            </ul>
                            {/* 【逐币种列,不求和】—— 两种货币相加是这个仓库点过名的那个错 */}
                            <div className="border-t pt-2 space-y-1">
                                {actualCurrencies.map((c) => (
                                    <div key={c} className="flex justify-between text-sm font-mono">
                                        <span>{c}</span>
                                        <span>{formatAmount(totals.get(c) as number, c)}</span>
                                    </div>
                                ))}
                            </div>
                        </>
                    )}
                </div>

                {/* ── 报价 ─────────────────────────────────────────────── */}
                <div className="border border-gray-300 rounded-lg p-4">
                    <h3 className="font-semibold mb-2 text-sm">{t('logistics.freightQuoteHeading')}</h3>
                    {quoteState.kind === 'no_lane' && empty(t('logistics.quoteNoLane'))}
                    {quoteState.kind === 'no_forwarder' && empty(
                        t('logistics.quoteNoForwarder') + ' ' + t('logistics.containerNoForwarderPointer'))}
                    {quoteState.kind === 'none_from_forwarder' && empty(t('logistics.quoteNoneFromForwarder'))}
                    {quoteState.kind === 'not_valid_on_departure'
                        && empty(t('logistics.quoteNotValidOnDeparture', { date: departureDate }))}
                    {quoteState.kind === 'found' && (
                        <>
                            <div className="flex justify-between text-sm font-mono">
                                <span>{quoteState.currency}</span>
                                <span>{formatAmount(quoteState.amount, quoteState.currency)}</span>
                            </div>
                            <p className="text-xs text-gray-500 mt-1">
                                {t('logistics.quoteValidRange', { from: quoteState.from, to: quoteState.to })}
                            </p>
                        </>
                    )}
                </div>
            </div>

            {/* 【第五种空:两个数不在同一个空间里】—— 说出来,而不是让它们并排看起来可比 */}
            {currencyMismatch && quoteState.kind === 'found' && (
                <p className="mt-3 text-sm text-amber-900 bg-amber-50 border border-amber-300 rounded px-3 py-2 max-w-3xl">
                    {t('logistics.quoteDifferentCurrency', {
                        quoteCcy: quoteState.currency,
                        actualCcy: actualCurrencies.join(' / '),
                    })}
                </p>
            )}
        </section>
    )
}
