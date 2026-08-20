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

    // ── 报价那一侧 ──────────────────────────────────────────────────────────
    let quoteState:
        | { kind: 'no_lane' }
        | { kind: 'no_forwarder' }
        | { kind: 'none_from_forwarder' }
        | { kind: 'not_valid_on_departure' }
        | { kind: 'found'; amount: number; currency: string; from: string; to: string }
    if (!laneId) {
        quoteState = { kind: 'no_lane' }
    } else if (!forwarderId) {
        quoteState = { kind: 'no_forwarder' }
    } else {
        const quotes = mustRows(
            await supabase.from('forwarder_rate_quotes')
                .select('amount_ccy, currency, valid_from, valid_to')
                .eq('supplier_id', forwarderId).eq('lane_id', laneId)
                .is('deleted_at', null),
            'forwarder rate quotes'
        ) as unknown as { amount_ccy: number; currency: string; valid_from: string; valid_to: string }[]
        if (quotes.length === 0) {
            quoteState = { kind: 'none_from_forwarder' }
        } else {
            // 【有效期含两端】与库里那条重叠守卫用的 daterange(…, '[]') 同一口径
            const hit = quotes.find((q) => q.valid_from <= departureDate && departureDate <= q.valid_to)
            quoteState = hit
                ? { kind: 'found', amount: Number(hit.amount_ccy), currency: hit.currency,
                    from: hit.valid_from, to: hit.valid_to }
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
                    {quoteState.kind === 'no_forwarder' && empty(t('logistics.quoteNoForwarder'))}
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
