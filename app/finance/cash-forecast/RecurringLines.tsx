'use client'

// app/finance/cash-forecast/RecurringLines.tsx
// CASHFLOW-1:经常性成本与已知的一次性 —— 预测里【手工】的那一半。
// 给定实测(AP 一个日期都没有、经常性成本一张表都没有),这一半不是补充,
// 它是预测能不能用的前提。而 cadence <> 'once' 的那些同时是 KPI T2 量的
// 【固定 OPEX 集合】—— 一张表,两个用途。
import { useState, useTransition } from 'react'
import { saveForecastLine } from './actions'
import { useTranslations } from '@/lib/i18n/client'

type Row = {
    id: string; label: string; direction: string; amount_ccy: number; currency: string
    cadence: string; start_date: string; end_date: string | null; is_active: boolean
}
const CADENCES = ['once', 'weekly', 'monthly', 'quarterly', 'annual'] as const

export default function RecurringLines({
    rows, canEdit, baseCurrency,
}: { rows: Row[]; canEdit: boolean; baseCurrency: string }) {
    const t = useTranslations()
    const [open, setOpen] = useState(false)
    const [label, setLabel] = useState('')
    const [direction, setDirection] = useState('out')
    const [amount, setAmount] = useState('')
    const [currency, setCurrency] = useState(baseCurrency)
    const [cadence, setCadence] = useState<string>('monthly')
    // 【首次发生的日子不预填】—— 一个决定这笔钱落在哪一周的日期,
    // 预填就是奖励留空;服务端也独立地要求它非空(NOT NULL)。
    const [startDate, setStartDate] = useState('')
    const [endDate, setEndDate] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const canSubmit = label.trim() !== '' && amount !== '' && startDate !== ''

    return (
        <section className="mb-8">
            <h2 className="text-lg font-semibold mb-1">{t('cashForecast.linesTitle')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('cashForecast.linesHint')}</p>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}

            {canEdit && !open && (
                <button type="button" onClick={() => setOpen(true)}
                    className="mb-3 border border-gray-300 rounded px-3 py-2 text-sm hover:bg-gray-50">
                    {t('cashForecast.addLine')}
                </button>
            )}
            {canEdit && open && (
                <div className="mb-4 rounded border border-gray-300 p-3 flex flex-wrap gap-3 items-end">
                    <label className="text-sm text-gray-600">{t('cashForecast.label')}
                        <input value={label} onChange={(e) => setLabel(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2 w-56" /></label>
                    <label className="text-sm text-gray-600">{t('cashForecast.direction')}
                        <select value={direction} onChange={(e) => setDirection(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2">
                            <option value="out">{t('cashForecast.dir_out')}</option>
                            <option value="in">{t('cashForecast.dir_in')}</option>
                        </select></label>
                    <label className="text-sm text-gray-600">{t('cashForecast.amount')}
                        <input type="number" step="0.01" min="0" value={amount}
                            onChange={(e) => setAmount(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2 w-32" /></label>
                    <label className="text-sm text-gray-600">{t('cashForecast.currency')}
                        <input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())}
                            className="block rounded border border-gray-300 px-3 py-2 w-20 font-mono" /></label>
                    <label className="text-sm text-gray-600">{t('cashForecast.cadence')}
                        <select value={cadence} onChange={(e) => setCadence(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2">
                            {CADENCES.map((c) => (
                                <option key={c} value={c}>{t('cashForecast.cadence_' + c)}</option>
                            ))}
                        </select></label>
                    <label className="text-sm text-gray-600">{t('cashForecast.startDate')}
                        <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2" /></label>
                    <label className="text-sm text-gray-600">{t('cashForecast.endDate')}
                        <input type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)}
                            className="block rounded border border-gray-300 px-3 py-2" /></label>
                    <button type="button" disabled={pending || !canSubmit}
                        onClick={() => {
                            setError(null)
                            startTransition(async () => {
                                const r = await saveForecastLine({
                                    label, direction, amount, currency, cadence,
                                    startDate, endDate: endDate || null,
                                })
                                if (r.error) setError(r.error)
                                else { setOpen(false); setLabel(''); setAmount(''); setStartDate(''); setEndDate('') }
                            })
                        }}
                        className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 text-sm disabled:opacity-50">
                        {t('cashForecast.addLine')}
                    </button>
                </div>
            )}

            {rows.length === 0 ? (
                // 【命名的缺席,不是空白】
                <p className="text-sm text-gray-500">{t('cashForecast.noLines')}</p>
            ) : (
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cashForecast.label')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cashForecast.cadence')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('cashForecast.amount')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cashForecast.startDate')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('cashForecast.endDate')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.id} className={r.is_active ? '' : 'text-gray-400'}>
                                <td className="border border-gray-300 px-3 py-2">{r.label}</td>
                                <td className="border border-gray-300 px-3 py-2">{t('cashForecast.cadence_' + r.cadence)}</td>
                                <td className="border border-gray-300 px-3 py-2 text-right font-mono">
                                    {r.direction === 'out' ? `(${Number(r.amount_ccy).toLocaleString()})` : Number(r.amount_ccy).toLocaleString()} {r.currency}
                                </td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{r.start_date}</td>
                                <td className="border border-gray-300 px-3 py-2 font-mono text-xs">{r.end_date ?? '—'}</td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </section>
    )
}
