'use client'

// 两半:实际额勾选汇付;估算勾选 + 发票额 → 【先看到差异再提交】(C3 的要点)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatMoney } from '@/lib/format'
import { remitCosts, relieveAccruals } from '../month-end/actions'

type Entry = { id: string; run_id: string; cost_type: string; amount_base: number; is_estimate: boolean; created_at: string }
type Run = { id: string; code: string }
type Sup = { id: string; legal_name: string }

export default function CostSettlePanel({ entries, runs, suppliers }: { entries: Entry[]; runs: Run[]; suppliers: Sup[] }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [selA, setSelA] = useState<Record<string, boolean>>({})
    const [selE, setSelE] = useState<Record<string, boolean>>({})
    const [actual, setActual] = useState('')
    const [date, setDate] = useState('')
    const [payStatus, setPayStatus] = useState('paid')
    const [supplier, setSupplier] = useState('')
    const runBy = new Map(runs.map((r) => [r.id, r.code]))

    const actuals = entries.filter((e) => !e.is_estimate)
    const estimates = entries.filter((e) => e.is_estimate)
    const chosenA = actuals.filter((e) => selA[e.id])
    const chosenE = estimates.filter((e) => selE[e.id])
    const accrued = Math.round(chosenE.reduce((s, e) => s + Number(e.amount_base), 0) * 100) / 100
    const actualN = Number(actual)
    const variance = actual !== '' && !Number.isNaN(actualN)
        ? Math.round((actualN - accrued) * 100) / 100 : null
    const mixedTypes = new Set(chosenE.map((e) => e.cost_type)).size > 1

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else { setSelA({}); setSelE({}); setActual(''); router.refresh() }
        })
    }

    const row = (e: Entry, sel: Record<string, boolean>, set: (v: Record<string, boolean>) => void) => (
        <tr key={e.id}>
            <td className="py-0.5 w-6"><input type="checkbox" checked={!!sel[e.id]}
                onChange={(ev) => set({ ...sel, [e.id]: ev.target.checked })} /></td>
            <td className="py-0.5 font-mono">{runBy.get(e.run_id)}</td>
            <td className="py-0.5">{t('processing.costTypes.' + e.cost_type)}</td>
            <td className="py-0.5 text-right font-mono">{formatMoney(e.amount_base)}</td>
            <td className="py-0.5 pl-3 text-xs text-gray-500">{e.created_at.slice(0, 10)}</td>
        </tr>
    )

    return (
        <div>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            <label className="text-xs text-gray-600 block mb-4">{t('finance.costSettle.date')}
                <input type="date" value={date} onChange={(e) => setDate(e.target.value)}
                       className="block border border-gray-300 rounded px-2 py-1 text-sm" />
            </label>

            <h2 className="text-lg font-bold mb-2">{t('finance.costSettle.actualTitle')}</h2>
            {actuals.length === 0 ? <p className="text-sm text-gray-500 mb-4">{t('finance.costSettle.none')}</p> : (
                <div className="mb-4">
                    <table className="w-full text-sm mb-2"><tbody>{actuals.map((e) => row(e, selA, setSelA))}</tbody></table>
                    <button type="button" disabled={pending || chosenA.length === 0}
                        onClick={() => run(() => remitCosts(chosenA.map((e) => e.id), date, ''))}
                        className="bg-blue-600 text-white px-3 py-1.5 rounded text-sm disabled:opacity-50">
                        {t('finance.costSettle.remit', { n: chosenA.length })}
                    </button>
                </div>
            )}

            <h2 className="text-lg font-bold mb-2">{t('finance.costSettle.estimateTitle')}</h2>
            {estimates.length === 0 ? <p className="text-sm text-gray-500">{t('finance.costSettle.none')}</p> : (
                <div className="rounded border border-gray-200 p-4">
                    <table className="w-full text-sm mb-3"><tbody>{estimates.map((e) => row(e, selE, setSelE))}</tbody></table>
                    <div className="flex gap-3 flex-wrap items-end text-xs">
                        <label>{t('finance.costSettle.invoiceAmount')}
                            <input type="number" value={actual} onChange={(e) => setActual(e.target.value)}
                                   className="block border border-gray-300 rounded px-2 py-1 text-sm w-32 text-right" />
                        </label>
                        <label>{t('finance.costSettle.payStatus')}
                            <select value={payStatus} onChange={(e) => setPayStatus(e.target.value)}
                                    className="block border border-gray-300 rounded px-2 py-1 text-sm">
                                <option value="paid">{t('finance.costSettle.paid')}</option>
                                <option value="unpaid">{t('finance.costSettle.unpaid')}</option>
                            </select>
                        </label>
                        {payStatus === 'unpaid' && (
                            <label>{t('finance.costSettle.supplier')}
                                <select value={supplier} onChange={(e) => setSupplier(e.target.value)}
                                        className="block border border-gray-300 rounded px-2 py-1 text-sm">
                                    <option value=""></option>
                                    {suppliers.map((s) => <option key={s.id} value={s.id}>{s.legal_name}</option>)}
                                </select>
                            </label>
                        )}
                        <button type="button"
                            disabled={pending || chosenE.length === 0 || variance === null || mixedTypes || (payStatus === 'unpaid' && !supplier)}
                            onClick={() => run(() => relieveAccruals({ entryIds: chosenE.map((e) => e.id), actual: actualN, date, paymentStatus: payStatus, bank: '', supplierId: supplier }))}
                            className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm disabled:opacity-50">
                            {t('finance.costSettle.relieve', { n: chosenE.length })}
                        </button>
                    </div>
                    {/* 差异在提交【之前】就摆出来 */}
                    {chosenE.length > 0 && (
                        <p className="text-sm mt-3">
                            {t('finance.costSettle.preview', { accrued: formatMoney(accrued) })}
                            {variance !== null && (
                                <span className={'ml-2 font-mono font-medium ' + (variance > 0 ? 'text-red-700' : variance < 0 ? 'text-green-700' : 'text-gray-600')}>
                                    {t('finance.costSettle.previewVariance', { v: formatMoney(variance) })}
                                </span>
                            )}
                            {mixedTypes && <span className="ml-2 text-red-700">{t('finance.costSettle.mixedTypes')}</span>}
                        </p>
                    )}
                </div>
            )}
        </div>
    )
}
