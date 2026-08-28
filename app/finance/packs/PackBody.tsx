// app/finance/packs/PackBody.tsx
// GLEXPORT-1:一份包的正文 —— **实时预览与已存档的包共用这一份渲染。**
//
// 【一份渲染,两个调用方】与 management_pack_data 是【一支函数两个调用方】同一条:
// 预览与存档如果各画各的,两块屏幕迟早会对同一份 payload 说出不同的话。
// 它拿到的永远是【已经算好的 payload】,自己一个数都不算。
import { formatAmount } from '@/lib/format'
import { getTranslations } from '@/lib/i18n/server'

type Recon = {
    side: string; control_account: string
    ledger_base: number; subledger_base: number; difference_base: number
    origination_variance_base: number; settlement_variance_base: number
    revaluation_base: number; unexplained_base: number; reconciled: boolean
}
type Split = {
    entry_code: string; entry_date: string
    counterpart_code: string; counterpart_date: string; amount_base: number
}
export type PackPayload = {
    period_month: string; period_start: string; period_end: string
    aging_as_of: string; generated_on: string; base_currency: string
    locked_before: string | null; month_locked: boolean
    pnl: { net_profit?: number } | null
    balance_sheet: { total_assets?: number } | null
    ar_aging: { total_open_base?: number } | null
    ap_aging: { total_open_base?: number } | null
    control_reconciliation: { sides: Recon[] } | null
    split_reversal_pairs: Split[]
    bank_reconciliations: unknown[]
    caveats: Record<string, unknown>
}

export default async function PackBody({ payload }: { payload: PackPayload }) {
    const t = await getTranslations()
    const ccy = payload.base_currency
    const sides = payload.control_reconciliation?.sides ?? []
    const cv = payload.caveats ?? {}

    // 【缺席清单是【算出来的】,不是手写的一段文字】每一条都对着 caveats 里
    // 那一个布尔,于是屏幕上说的与函数里判的不可能分开。
    const notes: string[] = []
    if (cv.month_not_locked) notes.push(t('pack.cvMonthNotLocked'))
    if (cv.aging_capped_at_today) notes.push(t('pack.cvAgingCapped', { date: payload.aging_as_of }))
    if (cv.fx_missing_mid) notes.push(t('pack.cvFxMissingMid'))
    if (cv.fx_not_revalued) notes.push(t('pack.cvFxNotRevalued'))
    if (Number(cv.split_reversal_pairs_n ?? 0) > 0) {
        notes.push(t('pack.cvSplitPairs', { n: String(cv.split_reversal_pairs_n) }))
    }
    if (cv.no_bank_reconciliation) notes.push(t('pack.cvNoBankRec'))
    if (cv.no_cash_forecast) notes.push(t('pack.cvNoForecast'))

    return (
        <div>
            {/* ── 三张报表的抬头数字 ─────────────────────────────────────── */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3 mb-6">
                {[
                    ['pack.netProfit', payload.pnl?.net_profit],
                    ['pack.totalAssets', payload.balance_sheet?.total_assets],
                    ['pack.arHeading', payload.ar_aging?.total_open_base],
                    ['pack.apHeading', payload.ap_aging?.total_open_base],
                ].map(([key, val]) => (
                    <div key={key as string} className="border border-gray-300 rounded p-3">
                        <div className="text-xs text-gray-600">{t(key as string)}</div>
                        <div className="font-mono text-lg">
                            {val === undefined || val === null
                                // 【具名的缺席,不是一个 0】读不到与等于零是两件事。
                                ? <span className="text-gray-500 text-sm">—</span>
                                : formatAmount(Number(val), ccy)}
                        </div>
                    </div>
                ))}
            </div>

            {/* ── ★ 勾稽:本包唯一一条两边独立推导的 ★ ───────────────────── */}
            <h2 className="font-semibold mb-1">{t('pack.reconHeading')}</h2>
            <p className="text-xs text-gray-600 mb-2 max-w-3xl">{t('pack.reconWhy')}</p>
            <table className="w-full border-collapse border border-gray-300 mb-2 text-sm">
                <thead className="bg-gray-50">
                    <tr>
                        {['pack.colSide', 'pack.colControl', 'pack.colLedger', 'pack.colSubledger',
                          'pack.colDifference', 'pack.colOrigination', 'pack.colSettlement',
                          'pack.colRevaluation', 'pack.colUnexplained'].map((k) => (
                            <th key={k} className="border border-gray-300 px-2 py-1 text-left">{t(k)}</th>
                        ))}
                    </tr>
                </thead>
                <tbody>
                    {sides.map((s) => (
                        <tr key={s.side}>
                            <td className="border border-gray-300 px-2 py-1">
                                {t(s.side === 'ar' ? 'pack.sideAr' : 'pack.sideAp')}
                            </td>
                            <td className="border border-gray-300 px-2 py-1 font-mono">{s.control_account}</td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{formatAmount(s.ledger_base, ccy)}</td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{formatAmount(s.subledger_base, ccy)}</td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{formatAmount(s.difference_base, ccy)}</td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{formatAmount(s.origination_variance_base, ccy)}</td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{formatAmount(s.settlement_variance_base, ccy)}</td>
                            <td className="border border-gray-300 px-2 py-1 text-right font-mono">{formatAmount(s.revaluation_base, ccy)}</td>
                            <td className={'border border-gray-300 px-2 py-1 text-right font-mono ' +
                                (s.reconciled ? '' : 'bg-red-50 text-red-800 font-semibold')}>
                                {formatAmount(s.unexplained_base, ccy)}
                            </td>
                        </tr>
                    ))}
                </tbody>
            </table>
            {/* ★【未解释余额是一条【发现】,不是一个装饰】★ 说出它是什么、以及
                该怎么办 —— 一个没有解释也没有动作的大红数字,正是"清不掉的告警"
                那个形状,而这个仓库为学会忽略告警付过账。 */}
            {sides.some((s) => !s.reconciled) ? (
                <p className="text-sm mb-6 bg-red-50 border border-red-300 text-red-900 px-3 py-2 rounded max-w-3xl">
                    {t('pack.reconFinding', {
                        amount: formatAmount(
                            sides.reduce((a, s) => a + Number(s.unexplained_base), 0), ''),
                        ccy,
                    })}
                </p>
            ) : (
                <p className="text-sm mb-6 text-green-800">{t('pack.reconOk')}</p>
            )}

            {/* ── 这份包看不见什么 ────────────────────────────────────────── */}
            <h2 className="font-semibold mb-2">{t('pack.cannotSeeHeading')}</h2>
            {notes.length === 0 ? (
                <p className="text-sm text-gray-600 mb-4">{t('pack.cannotSeeNone')}</p>
            ) : (
                <ul className="text-sm mb-4 bg-amber-50 border border-amber-300 text-amber-900 px-4 py-2 rounded list-disc list-inside max-w-3xl">
                    {notes.map((n, i) => <li key={i} className="my-1">{n}</li>)}
                </ul>
            )}

            {/* 拆散在两个月的冲销对 —— 列出来,因为"这个月怎么看着不对"最可能是它 */}
            {payload.split_reversal_pairs?.length > 0 && (
                <table className="w-full border-collapse border border-gray-300 mb-6 text-sm">
                    <thead className="bg-gray-50">
                        <tr>
                            {['pack.colEntry', 'pack.colDate', 'pack.colCounterpart',
                              'pack.colCounterpartDate', 'pack.colAmount'].map((k) => (
                                <th key={k} className="border border-gray-300 px-2 py-1 text-left">{t(k)}</th>
                            ))}
                        </tr>
                    </thead>
                    <tbody>
                        {payload.split_reversal_pairs.map((s) => (
                            <tr key={s.entry_code}>
                                <td className="border border-gray-300 px-2 py-1 font-mono">{s.entry_code}</td>
                                <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{s.entry_date}</td>
                                <td className="border border-gray-300 px-2 py-1 font-mono">{s.counterpart_code}</td>
                                <td className="border border-gray-300 px-2 py-1 font-mono text-xs">{s.counterpart_date}</td>
                                <td className="border border-gray-300 px-2 py-1 text-right font-mono">{formatAmount(s.amount_base, ccy)}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </div>
    )
}
