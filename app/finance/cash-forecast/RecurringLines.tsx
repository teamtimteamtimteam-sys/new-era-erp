'use client'

// app/finance/cash-forecast/RecurringLines.tsx
// CASHFLOW-1:经常性成本与已知的一次性 —— 预测里【手工】的那一半。
// 给定实测(AP 一个日期都没有、经常性成本一张表都没有),这一半不是补充,
// 它是预测能不能用的前提。而 cadence <> 'once' 的那些同时是 KPI T2 量的
// 【固定 OPEX 集合】—— 一张表,两个用途。
//
// CONV-3 · 表换成 DataTable,新增表单外壳换成 AddRowPanel。
import { useState, useTransition } from 'react'
import { saveForecastLine } from './actions'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { AddRowPanel } from '@/app/components/ui/add-row-panel'

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

    // ★【停用的行仍在表里,只是淡出】—— 原表用 tr 级 text-gray-400;
    // DataTable 没有整行样式的口子(它的契约是逐列 render,不是逐行),
    // 所以这里把同一个视觉判断挪进每一列自己的 render。
    const dim = (r: Row) => !r.is_active
    const cell = (r: Row, content: React.ReactNode) =>
        dim(r) ? <span className="text-[color:var(--brand-muted-text)]">{content}</span> : content
    const columns: Column<Row>[] = [
        {
            key: 'label', header: t('cashForecast.label'), priority: true,
            render: (r) => cell(r, r.label), className: 'break-words',
        },
        { key: 'cadence', header: t('cashForecast.cadence'), render: (r) => cell(r, t('cashForecast.cadence_' + r.cadence)) },
        {
            key: 'amount', header: t('cashForecast.amount'), priority: true, align: 'right',
            render: (r) => cell(r, `${r.direction === 'out' ? `(${Number(r.amount_ccy).toLocaleString()})` : Number(r.amount_ccy).toLocaleString()} ${r.currency}`),
        },
        { key: 'startDate', header: t('cashForecast.startDate'), className: 'font-mono text-xs', render: (r) => cell(r, r.start_date) },
        { key: 'endDate', header: t('cashForecast.endDate'), className: 'font-mono text-xs', render: (r) => cell(r, r.end_date ?? '—') },
    ]

    return (
        <section className="mb-8">
            <h2 className="mb-1 text-lg font-semibold">{t('cashForecast.linesTitle')}</h2>
            <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">{t('cashForecast.linesHint')}</p>

            {canEdit && !open && (
                <button type="button" onClick={() => setOpen(true)}
                    className="mb-3 rounded border border-[color:var(--brand-border)] px-3 py-2 text-sm hover:bg-[color:var(--brand-muted)]">
                    {t('cashForecast.addLine')}
                </button>
            )}
            {canEdit && open && (
                <AddRowPanel
                    error={error}
                    className="mb-4"
                    actions={
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
                            className="rounded bg-blue-600 px-4 py-2 text-sm text-white hover:bg-blue-700 disabled:opacity-50">
                            {t('cashForecast.addLine')}
                        </button>
                    }
                >
                    <label className="text-sm text-[color:var(--brand-muted-text)]">{t('cashForecast.label')}
                        <input value={label} onChange={(e) => setLabel(e.target.value)}
                            className="block w-56 rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-3 py-2" /></label>
                    <label className="text-sm text-[color:var(--brand-muted-text)]">{t('cashForecast.direction')}
                        <select value={direction} onChange={(e) => setDirection(e.target.value)}
                            className="block rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-3 py-2">
                            <option value="out">{t('cashForecast.dir_out')}</option>
                            <option value="in">{t('cashForecast.dir_in')}</option>
                        </select></label>
                    <label className="text-sm text-[color:var(--brand-muted-text)]">{t('cashForecast.amount')}
                        <input type="number" step="0.01" min="0" value={amount}
                            onChange={(e) => setAmount(e.target.value)}
                            className="block w-32 rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-3 py-2" /></label>
                    <label className="text-sm text-[color:var(--brand-muted-text)]">{t('cashForecast.currency')}
                        <input value={currency} onChange={(e) => setCurrency(e.target.value.toUpperCase())}
                            className="block w-20 rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-3 py-2 font-mono" /></label>
                    <label className="text-sm text-[color:var(--brand-muted-text)]">{t('cashForecast.cadence')}
                        <select value={cadence} onChange={(e) => setCadence(e.target.value)}
                            className="block rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-3 py-2">
                            {CADENCES.map((c) => (
                                <option key={c} value={c}>{t('cashForecast.cadence_' + c)}</option>
                            ))}
                        </select></label>
                    <label className="text-sm text-[color:var(--brand-muted-text)]">{t('cashForecast.startDate')}
                        <input type="date" value={startDate} onChange={(e) => setStartDate(e.target.value)}
                            className="block rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-3 py-2" /></label>
                    <label className="text-sm text-[color:var(--brand-muted-text)]">{t('cashForecast.endDate')}
                        <input type="date" value={endDate} onChange={(e) => setEndDate(e.target.value)}
                            className="block rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-3 py-2" /></label>
                </AddRowPanel>
            )}

            <DataTable
                rows={rows}
                columns={columns}
                rowKey={(r) => r.id}
                phone={{ mode: 'columns' }}
                empty={t('cashForecast.noLines')}
            />
        </section>
    )
}
