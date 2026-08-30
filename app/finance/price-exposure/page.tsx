// COMM-1:价格敞口 —— 一份【说得出自己看不见什么】的报告。
//
// ★★【这一页的全部价值是【诚实地说出缺席】,所以它的每一句都是无条件渲染的】★★
//   队列那句话是「浮动价买进的吨数 vs 固定价卖出的吨数」,而今天:
//     · 卖方向有结构,但一份合同都没有 → 它说【没有主语】,不说 0
//     · 买方向【根本没有被建模】       → 它说【一句关于表结构的话】,不说 0 吨
//     · 开市日历是空的                 → 它单独说一句,因为那是【另一个】原因
//
//   **0 与"没有记录"是两个不同的答案**,而这一页把它们分开 ——
//   与 PARTY-1 的重叠报告(带分母)同一条规矩。
//
// ★【为什么这一页可以上线,而同一刀里的 RFQ 被拒了】★
//   一个半成品的 RFQ 会【冒充】另一个问题的答案;
//   一份半成品的敞口报表【自己说出】它答不了的那一半。
//   **一个会自报家门的缺口可以上线;一个要靠人记住的缺口不可以。**
//
// 【整页服务端渲染】没有客户端开关 —— 藏在开关后面的话,fetch 冒烟看不见。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

type Position = {
    contract_id: string; contract_code: string; metal: string; index_code: string
    base_event: string; qp_months: number; payable_pct: number; ordered_quantity: number
}
type Report = {
    sell_side: { state: string; positions: Position[] }
    purchase_side: { modelled: boolean; why: string }
    quotational_period: {
        calendar_days_loaded: number; calendar_trading_days: number
        average_available: boolean; why: string
    }
    coverage: {
        contracts_total: number; contracts_sell_side: number; contracts_buy_side: number
        contracts_with_pricing_terms: number; pricing_terms_total: number
        documents_linked_to_contract: number
        metal_quotes_total: number; metal_quotes_carrying_index: number
    }
}

export default async function PriceExposurePage() {
    const denied = await requireModule(MOD.finance)
    if (denied) return denied

    const supabase = await createClient()
    const t = await getTranslations()
    const report = mustOne(await supabase.rpc('price_exposure_report')) as unknown as Report
    const cov = report.coverage
    const qp = report.quotational_period

    return (
        <div className="p-8">
            <h1 className="text-2xl font-bold mb-1">{t('priceExposure.title')}</h1>
            <p className="text-sm text-gray-700 max-w-3xl mb-4">{t('priceExposure.what')}</p>

            {/* ★【先说它看不见什么】—— 无条件渲染 ★ */}
            <div className="border-l-4 border-amber-500 bg-amber-50 p-3 mb-6 max-w-3xl">
                <p className="text-sm text-gray-800">{t('priceExposure.cannotSee')}</p>
            </div>

            {/* ── 卖方向:三种状态,每一种都是一句具名的话,没有一种是空白 ── */}
            <h2 className="text-lg font-semibold mb-2">{t('priceExposure.sellPositions')}</h2>
            {report.sell_side.state === 'no_contracts' ? (
                <p className="text-sm text-amber-800 mb-6 max-w-3xl">{t('priceExposure.sellNoContracts')}</p>
            ) : report.sell_side.state === 'no_pricing_terms' ? (
                <p className="text-sm text-amber-800 mb-6 max-w-3xl">{t('priceExposure.sellNoTerms')}</p>
            ) : (
                <table className="w-full border-collapse mb-6">
                    <thead>
                        <tr className="bg-gray-100">
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('priceExposure.colContract')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('priceExposure.colMetal')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('priceExposure.colIndex')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left text-sm">{t('priceExposure.colBaseEvent')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('priceExposure.colQpMonths')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('priceExposure.colPayable')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right text-sm">{t('priceExposure.colQuantity')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {report.sell_side.positions.map((p) => (
                            <tr key={`${p.contract_id}-${p.metal}`}>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{p.contract_code}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{p.metal}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{p.index_code}</td>
                                <td className="border border-gray-300 px-3 py-2 text-sm">{p.base_event}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm">{p.qp_months}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm">{p.payable_pct}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right text-sm">{p.ordered_quantity}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}

            {/* ★★【买方向:一句关于结构的话,永远不是一个 0 吨】★★
                这一段【不在任何条件里面】—— 它今天为真,而且要一直为真到 §9 被回答为止。 */}
            <div className="border-l-4 border-red-500 bg-red-50 p-3 mb-6 max-w-3xl">
                <p className="text-sm text-gray-900">{t('priceExposure.purchaseNotModelled')}</p>
                <p className="text-xs text-gray-700 mt-2">{t('priceExposure.purchaseOpenQuestion')}</p>
            </div>

            {/* ── 均价能不能算:【另一个】原因,单独一段 ── */}
            <div className="border border-gray-300 rounded p-3 mb-6 max-w-3xl">
                <p className="text-sm text-gray-800">
                    {qp.calendar_days_loaded === 0
                        ? t('priceExposure.calendarNone')
                        : t('priceExposure.calendarLoaded')}
                </p>
            </div>

            {/* ── 分母:让每一个 0 说得出它是哪一种 0 ── */}
            <div className="border border-gray-300 rounded p-3 mb-6 max-w-3xl">
                <h2 className="font-medium mb-1">{t('priceExposure.coverageTitle')}</h2>
                <ul className="text-sm text-gray-800 space-y-1">
                    <li>{t('priceExposure.covContracts', {
                        total: String(cov.contracts_total),
                        sell: String(cov.contracts_sell_side),
                        buy: String(cov.contracts_buy_side),
                    })}</li>
                    <li>{t('priceExposure.covTerms', {
                        contracts: String(cov.contracts_with_pricing_terms),
                        terms: String(cov.pricing_terms_total),
                    })}</li>
                    <li>{t('priceExposure.covDocs', { docs: String(cov.documents_linked_to_contract) })}</li>
                    <li>{t('priceExposure.covQuotes', {
                        quotes: String(cov.metal_quotes_total),
                        indexed: String(cov.metal_quotes_carrying_index),
                    })}</li>
                    <li>{t('priceExposure.covCalendar', {
                        days: String(qp.calendar_days_loaded),
                        trading: String(qp.calendar_trading_days),
                    })}</li>
                </ul>
            </div>

            {/* 【两侧不轧成一个数】—— 跟着数字走的那句话,不只躺在文档里 */}
            <p className="text-xs text-gray-600 max-w-3xl">{t('priceExposure.notNetted')}</p>
        </div>
    )
}
