// CONTRACT-1:合同登记簿那一屏。
//
// ★【整页服务端渲染,没有客户端开关】★ 藏在开关后面的话,fetch 冒烟永远看不见
//   (那条盲区记在 AGENTS.md)。本页每一句都在初次 HTML 里。
//
// ★★【这一页最要紧的一段是【覆盖率】,不是合同清单】★★
//   本刀没有强制任何单据挂上合同(现货采购本来就没有合同),
//   所以"没有任何合同被违反"很可能只意味着"没有人挂过任何东西"。
//   分母摆出来,那句话才有意义 —— 与 PARTY-1 的重叠报告同一条。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Link from 'next/link'

type Contract = {
    id: string; code: string; side: string; kind: string; title: string
    effective_from: string; effective_to: string | null; status: string
    currency: string | null; incoterm: string | null; payment_terms_days: number | null
    customer_id: string | null; supplier_id: string | null
}
type Coverage = {
    purchase_orders_total: number; purchase_orders_under_contract: number
    sales_orders_total: number; sales_orders_under_contract: number
    contracts_total: number; contracts_active: number
    contracts_buy_side: number; contracts_sell_side: number
    documents_with_grade_specs: number
}
type PricingTerm = {
    contract_id: string; metal: string; base_event: string
    qp_months: number; index_code: string; payable_pct: number
}
type CalRow = { index_code: string; calendar_date: string; is_trading_day: boolean }
type Breach = {
    purchase_order_code: string; contract_code: string; inbound_batch_code: string
    metal: string; content_pct: number
    min_pct: number | null; max_pct: number | null; breach_side: string
}

export default async function ContractsPage() {
    const denied = await requireModule(MOD.suppliers)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()

    const contracts = mustRows(
        await supabase.from('contracts')
            .select('id, code, side, kind, title, effective_from, effective_to, status, currency, incoterm, payment_terms_days, customer_id, supplier_id')
            .is('deleted_at', null).order('effective_from', { ascending: false }),
        'contracts') as Contract[]
    const cov = mustOne(await supabase.from('contract_coverage').select('*').single()) as unknown as Coverage
    const breaches = mustRows(
        await supabase.from('contract_grade_breaches').select('*').order('purchase_order_code'),
        'contract_grade_breaches') as Breach[]
    // PRICE-1:计价条款、开市日历、以及【标了指数的报价有几条】。
    // 三样都读出来,是因为这一页要能回答"为什么均价现在算不出来" ——
    // 而那个答案有三种,它们【必须分得开】(见下面那三段具名的缺席)。
    const pricingTerms = mustRows(
        await supabase.from('contract_pricing_terms')
            .select('contract_id, metal, base_event, qp_months, index_code, payable_pct')
            .order('metal'),
        'contract_pricing_terms') as PricingTerm[]
    const calendar = mustRows(
        await supabase.from('index_market_calendar')
            .select('index_code, calendar_date, is_trading_day')
            .order('index_code').order('calendar_date'),
        'index_market_calendar') as CalRow[]
    const quotesTotal = mustRows(
        await supabase.from('metal_prices').select('price_index').is('deleted_at', null),
        'metal_prices') as { price_index: string | null }[]
    const quotesTagged = quotesTotal.filter((q) => q.price_index !== null).length
    const calByIndex = new Map<string, CalRow[]>()
    for (const c of calendar) {
        const list = calByIndex.get(c.index_code) ?? []
        list.push(c); calByIndex.set(c.index_code, list)
    }
    const termsByContract = new Map<string, PricingTerm[]>()
    for (const t2 of pricingTerms) {
        const list = termsByContract.get(t2.contract_id) ?? []
        list.push(t2); termsByContract.set(t2.contract_id, list)
    }

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-1">{t('contracts.title')}</h1>
            <p className="text-sm text-gray-700 max-w-4xl mb-6">{t('contracts.what')}</p>

            {/* ★★ 覆盖率 —— 没有它,下面那句"没有违反"会撒谎 ★★ */}
            <div className="border border-gray-300 rounded p-4 mb-6 max-w-4xl">
                <h2 className="font-medium mb-1">{t('contracts.coverageTitle')}</h2>
                <p className="text-sm text-gray-800">
                    {t('contracts.coverageLine', {
                        poUnder: String(cov.purchase_orders_under_contract),
                        poTotal: String(cov.purchase_orders_total),
                        soUnder: String(cov.sales_orders_under_contract),
                        soTotal: String(cov.sales_orders_total),
                    })}
                </p>
                {/* 【具名的缺席】没挂合同不是缺陷 —— 现货买卖是正当的商业形态 */}
                <p className="text-sm text-amber-800 mt-2">{t('contracts.coverageWhy')}</p>
            </div>

            {/* ── 违反 ─────────────────────────────────────────────────────── */}
            <h2 className="text-lg font-semibold mb-1">{t('contracts.breachTitle')}</h2>
            <p className="text-xs text-gray-600 mb-2 max-w-4xl">{t('contracts.breachWhat')}</p>
            {breaches.length === 0 ? (
                /* ★ 一个具名的缺席:是"没有违反"还是"没有可比的东西"?说出来 ★ */
                <p className="text-sm text-gray-600 mb-6">
                    {cov.documents_with_grade_specs === 0
                        ? t('contracts.breachNothingComparable')
                        : t('contracts.breachNone', { n: String(cov.documents_with_grade_specs) })}
                </p>
            ) : (
                <table className="w-full border-collapse mb-6">
                    <thead>
                        <tr className="bg-gray-100">
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colDocument')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colContract')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colBatch')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colMetal')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('contracts.colMeasured')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colRequired')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {breaches.map((b, i) => (
                            <tr key={`${b.purchase_order_code}-${b.metal}-${i}`}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{b.purchase_order_code}</td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{b.contract_code}</td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{b.inbound_batch_code}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{b.metal}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm font-mono">{b.content_pct}%</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {b.breach_side === 'below_min'
                                        ? t('contracts.requiredMin', { v: String(b.min_pct) })
                                        : t('contracts.requiredMax', { v: String(b.max_pct) })}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {/* ── 合同清单 ─────────────────────────────────────────────────── */}
            <h2 className="text-lg font-semibold mb-2">{t('contracts.listTitle')}</h2>
            {contracts.length === 0 ? (
                <p className="text-sm text-gray-600">{t('contracts.listNone')}</p>
            ) : (
                <table className="w-full border-collapse">
                    <thead>
                        <tr className="bg-gray-100">
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colCode')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colSide')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colTitle')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colPeriod')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colStatus')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colTerms')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {contracts.map((c) => (
                            <tr key={c.id}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">
                                    <Link href={`/contracts/${c.id}`} className="text-blue-600 hover:underline">{c.code}</Link>
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t(`contracts.side.${c.side}`)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{c.title}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {c.effective_from} → {c.effective_to ?? (
                                        /* 【无固定期限不是"忘了填"】具名,不留白 */
                                        <span className="text-xs text-gray-500">{t('contracts.openEnded')}</span>
                                    )}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t(`contracts.status.${c.status}`)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {[c.incoterm, c.currency, c.payment_terms_days != null
                                        ? t('contracts.termsDays', { d: String(c.payment_terms_days) }) : null]
                                        .filter(Boolean).join(' · ') || (
                                        <span className="text-xs text-gray-500">{t('contracts.noHeadlineTerms')}</span>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {/* 【第 4 刀的交接点写在屏幕上,不只写在表注里】 */}
            {/* ════ PRICE-1:指数挂钩定价 ════════════════════════════════════════ */}
            <h2 className="text-lg font-semibold mb-1 mt-8">{t('contracts.pricing.title')}</h2>
            <p className="text-sm text-gray-700 max-w-4xl mb-3">{t('contracts.pricing.what')}</p>

            {/* ★★【本刀停在哪儿 —— 写在读者会遇见它的地方,不只在切次报告里】★★
                「指数定价上线了」与「我们能按指数开票了」是两句不同的话,
                而把前者读成后者的代价是有人去等一张永远不会自动出现的发票。 */}
            <div className="border border-amber-300 bg-amber-50 rounded p-4 mb-6 max-w-4xl">
                <h3 className="font-medium mb-1">{t('contracts.pricing.builtTitle')}</h3>
                <p className="text-sm text-gray-800">{t('contracts.pricing.canDo')}</p>
                <p className="text-sm text-amber-900 mt-2 font-medium">{t('contracts.pricing.cannotDo')}</p>
            </div>

            {/* ── 开市日历:三种"算不出来"里的第一种 ──────────────────────── */}
            <h3 className="font-medium mb-1">{t('contracts.pricing.calendarTitle')}</h3>
            <p className="text-xs text-gray-600 mb-2 max-w-4xl">{t('contracts.pricing.calendarWhy')}</p>
            {calByIndex.size === 0 ? (
                /* ★ 具名的缺席,不是一片空白 ★ 「日历是空的」与「那天没有报价」
                   是两件不同的事,而它们【不能长得一样】—— 这一段说的是前者。 */
                <p className="text-sm text-amber-800 mb-4 max-w-4xl">{t('contracts.pricing.calendarNone')}</p>
            ) : (
                <ul className="text-sm text-gray-800 mb-4 list-disc ml-5">
                    {[...calByIndex.entries()].map(([idx, rows]) => (
                        <li key={idx}>
                            {t('contracts.pricing.calendarLoaded', {
                                index: idx, days: String(rows.length),
                                from: rows[0].calendar_date,
                                to: rows[rows.length - 1].calendar_date,
                                trading: String(rows.filter((r) => r.is_trading_day).length),
                            })}
                        </li>
                    ))}
                </ul>
            )}

            {/* ── 标了指数的报价:第二种 ─────────────────────────────────── */}
            <h3 className="font-medium mb-1">{t('contracts.pricing.quotesTitle')}</h3>
            {quotesTagged === 0 ? (
                <p className="text-sm text-amber-800 mb-4 max-w-4xl">{t('contracts.pricing.quotesNone')}</p>
            ) : (
                <p className="text-sm text-gray-800 mb-4">
                    {t('contracts.pricing.quotesSome', { n: String(quotesTagged), total: String(quotesTotal.length) })}
                </p>
            )}

            {/* ── 冻结的时刻:挂接,不是下单 ─────────────────────────────── */}
            <h3 className="font-medium mb-1">{t('contracts.pricing.frozenTitle')}</h3>
            <p className="text-sm text-gray-800 mb-1 max-w-4xl">{t('contracts.pricing.frozenAtLinkTime')}</p>
            <p className="text-xs text-gray-600 mb-4 max-w-4xl">{t('contracts.pricing.noProvisional')}</p>

            {/* ── 按指数计价的合同 ──────────────────────────────────────── */}
            <h3 className="font-medium mb-1">{t('contracts.pricing.termsTitle')}</h3>
            {pricingTerms.length === 0 ? (
                <p className="text-sm text-gray-600 mb-4">{t('contracts.pricing.termsNone')}</p>
            ) : (
                <table className="w-full border-collapse mb-4 max-w-4xl">
                    <thead>
                        <tr className="bg-gray-100">
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.colCode')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.pricing.colMetal')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.pricing.colBaseEvent')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.pricing.colQp')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.pricing.colIndex')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('contracts.pricing.colPayable')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {contracts.flatMap((c) => (termsByContract.get(c.id) ?? []).map((pt) => (
                            <tr key={`${c.id}-${pt.metal}`}>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-sm">{c.code}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{pt.metal}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{t(`contracts.pricing.baseEvent.${pt.base_event}`)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">
                                    {pt.qp_months === 0
                                        ? t('contracts.pricing.qpSameMonth')
                                        : t('contracts.pricing.qpMonths', { n: String(pt.qp_months) })}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{pt.index_code}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{pt.payable_pct}%</td>
                            </tr>
                        )))}
                    </tbody>
                </table>
            )}

            <p className="text-xs text-gray-500 mt-8 max-w-4xl">{t('contracts.pricingComesLater')}</p>
        </div>
    )
}
