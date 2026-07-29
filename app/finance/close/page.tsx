// app/finance/close/page.tsx
// 月结关账:当前锁状态 + 月份选择(最近 12 个月末,已关/早于锁的禁选)+
// 所选月末的预览(分录数、Σ借/Σ贷、平衡指示、当月损益表/截至日资产负债表链接)
// + 关账按钮;下方关账历史(重开的行保留,状态列盖章),活跃行可行内重开。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { isYmd } from '@/lib/dateFilter'
import { formatUsd } from '@/lib/format'
import Subnav from '../Subnav'
import PeriodPicker, { type PeriodOption } from './PeriodPicker'
import CloseButton from './CloseButton'
import ReopenForm from './ReopenForm'

type CloseRow = {
    id: string
    period_end: string
    closed_at: string
    notes: string | null
    entries_count: number
    total_debits: number
    total_credits: number
    reopened_at: string | null
    reopen_reason: string | null
}

const round2 = (n: number) => Math.round(n * 100) / 100
const ymdUtc = (d: Date) => d.toISOString().slice(0, 10)

export default async function ClosePage({
    searchParams,
}: {
    searchParams: Promise<{ period?: string }>
}) {
    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const [settingsRes, closesRes] = await Promise.all([
        supabase.from('finance_settings').select('locked_before').eq('id', true).single(),
        supabase
            .from('period_closes')
            .select('id, period_end, closed_at, notes, entries_count, total_debits, total_credits, reopened_at, reopen_reason')
            .order('closed_at', { ascending: false }),
    ])

    const error = settingsRes.error ?? closesRes.error
    if (error) {
        return (
            <div className="p-8">
                <h1 className="text-2xl font-bold mb-4">{t('finance.closeTitle')}</h1>
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    <p className="font-bold">{t('finance.loadError')}</p>
                    <pre className="text-xs mt-2">{JSON.stringify(error, null, 2)}</pre>
                </div>
            </div>
        )
    }

    const lockedBefore = settingsRes.data?.locked_before ?? null
    const closes = (closesRes.data ?? []) as CloseRow[]
    const activeCloses = new Set(closes.filter((c) => !c.reopened_at).map((c) => c.period_end))

    // 最近 12 个月末;已有活跃关账或早于期间锁的禁选
    const now = new Date()
    const y = now.getUTCFullYear()
    const m = now.getUTCMonth()
    const options: PeriodOption[] = []
    for (let i = 0; i < 12; i++) {
        const periodEnd = ymdUtc(new Date(Date.UTC(y, m - i + 1, 0)))
        options.push({
            value: periodEnd,
            disabled:
                activeCloses.has(periodEnd) || (lockedBefore !== null && periodEnd < lockedBefore),
        })
    }

    // 选中月末:URL 优先(须在列表内),否则最近的可选项
    const requested = (sp.period ?? '').trim()
    const selected =
        isYmd(requested) && options.some((o) => o.value === requested)
            ? requested
            : options.find((o) => !o.disabled)?.value ?? ''
    const selectedDisabled = options.find((o) => o.value === selected)?.disabled ?? true

    // 预览:截至所选月末的分录数 + Σ借/Σ贷(与 close_period 同口径)
    let preview: { count: number; debits: number; credits: number } | null = null
    if (selected) {
        const { data: lines } = await supabase
            .from('journal_lines')
            .select('entry_id, debit, credit, journal_entries!inner(entry_date)')
            .lte('journal_entries.entry_date', selected)
        const rows = lines ?? []
        preview = {
            count: new Set(rows.map((l) => l.entry_id)).size,
            debits: round2(rows.reduce((s, l) => s + l.debit, 0)),
            credits: round2(rows.reduce((s, l) => s + l.credit, 0)),
        }
    }

    const monthStart = selected ? selected.slice(0, 8) + '01' : ''

    return (
        <div className="p-8 max-w-5xl">
            <h1 className="text-2xl font-bold mb-4">{t('finance.closeTitle')}</h1>

            <Subnav />

            {/* 当前锁状态 */}
            <div className="bg-gray-50 rounded p-4 mb-6 text-sm">
                <span className="text-gray-600 mr-1">{t('finance.lockedBefore')}:</span>
                {lockedBefore ? (
                    <span className="font-mono font-medium">{lockedBefore}</span>
                ) : (
                    <span className="text-gray-400">{t('finance.notSet')}</span>
                )}
            </div>

            {/* 月份选择 + 预览 + 关账 */}
            <div className="border border-gray-300 rounded p-4 mb-8 space-y-4">
                <PeriodPicker options={options} selected={selected} />

                {selected && preview && (
                    <>
                        <div className="bg-gray-50 rounded p-4 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                            <div>
                                <span className="text-gray-600 mr-1">{t('finance.entriesCount')}:</span>
                                <span className="font-mono font-medium">{preview.count}</span>
                            </div>
                            <div>
                                <span className="text-gray-600 mr-1">{t('finance.colDebits')}:</span>
                                <span className="font-mono font-medium">{formatUsd(preview.debits)}</span>
                            </div>
                            <div>
                                <span className="text-gray-600 mr-1">{t('finance.colCredits')}:</span>
                                <span className="font-mono font-medium">{formatUsd(preview.credits)}</span>
                            </div>
                            <span
                                className={
                                    'px-2 py-1 rounded text-xs ' +
                                    (preview.debits === preview.credits
                                        ? 'bg-green-100 text-green-800'
                                        : 'bg-red-100 text-red-800')
                                }
                            >
                                {preview.debits === preview.credits
                                    ? '✓ ' + t('finance.balanceIndicator.balanced')
                                    : t('finance.balanceIndicator.unbalanced')}
                            </span>
                        </div>

                        <div className="flex flex-wrap gap-4 text-sm">
                            <Link
                                href={`/finance/pnl?date_from=${monthStart}&date_to=${selected}`}
                                className="text-blue-600 hover:underline"
                            >
                                {t('finance.viewPnl')}
                            </Link>
                            <Link
                                href={`/finance/balance-sheet?as_of=${selected}`}
                                className="text-blue-600 hover:underline"
                            >
                                {t('finance.viewBs')}
                            </Link>
                        </div>

                        {!selectedDisabled && <CloseButton periodEnd={selected} />}
                    </>
                )}
            </div>

            {/* 关账历史 */}
            <h2 className="text-lg font-semibold mb-3">{t('finance.closeHistory')}</h2>
            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colPeriodEnd')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colClosedAt')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.entriesCount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colDebits')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('finance.colCredits')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('finance.colStatus')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left" />
                    </tr>
                </thead>
                <tbody>
                    {closes.map((c) => (
                        <tr key={c.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">{c.period_end}</td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {c.closed_at.slice(0, 16).replace('T', ' ')}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {c.entries_count}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatUsd(c.total_debits)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatUsd(c.total_credits)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (c.reopened_at
                                            ? 'bg-amber-100 text-amber-800'
                                            : 'bg-green-100 text-green-800')
                                    }
                                >
                                    {c.reopened_at
                                        ? t('finance.closeStatus.reopened')
                                        : t('finance.closeStatus.active')}
                                </span>
                                {c.reopen_reason && (
                                    <p className="text-xs text-gray-500 mt-1">{c.reopen_reason}</p>
                                )}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                {!c.reopened_at && <ReopenForm periodEnd={c.period_end} />}
                            </td>
                        </tr>
                    ))}
                    {closes.length === 0 && (
                        <tr>
                            <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('finance.closeHistoryEmpty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
