// app/hr/payroll/page.tsx
// 薪资期间列表:月份、发薪日、币种、应发合计、实发合计、人数、状态、分录链接。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatUsd } from '@/lib/format'
import Subnav from '../Subnav'

export default async function PayrollListPage() {
    const supabase = await createClient()
    const t = await getTranslations()

    const [periodsRes, linesRes] = await Promise.all([
        supabase
            .from('payroll_periods')
            .select('id, code, period_month, payment_date, currency, gross_total, net_pay_total, status, journal_entry_id')
            .is('deleted_at', null)
            .order('period_month', { ascending: false }),
        supabase.from('payroll_lines').select('payroll_period_id'),
    ])

    const periods = periodsRes.data ?? []
    const countByPeriod = new Map<string, number>()
    for (const l of linesRes.data ?? []) {
        countByPeriod.set(l.payroll_period_id, (countByPeriod.get(l.payroll_period_id) ?? 0) + 1)
    }

    // 已过账的期间要能一键跳到那张分录
    const jeIds = periods.map((p) => p.journal_entry_id).filter(Boolean) as string[]
    const { data: jes } = jeIds.length
        ? await supabase.from('journal_entries').select('id, code').in('id', jeIds)
        : { data: [] as { id: string; code: string }[] }
    const jeCodeById = new Map((jes ?? []).map((j) => [j.id, j.code]))

    return (
        <div className="p-8 max-w-5xl">
            <div className="flex justify-between items-center mb-4">
                <h1 className="text-2xl font-bold">{t('hr.payrollTitle')}</h1>
                <Link
                    href="/hr/payroll/new"
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700"
                >
                    {t('hr.newPayroll')}
                </Link>
            </div>

            <Subnav />

            <p className="text-sm text-gray-600 mb-4">{t('finance.recordCount', { count: periods.length })}</p>

            <table className="w-full border-collapse border border-gray-300">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colPeriod')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colPaymentDate')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colCurrency')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('hr.colGrossTotal')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('hr.colNetTotal')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-right">{t('hr.colLineCount')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('hr.colStatus')}</th>
                        <th className="border border-gray-300 px-4 py-2 text-left">{t('assay.journalLink')}</th>
                    </tr>
                </thead>
                <tbody>
                    {periods.map((p) => (
                        <tr key={p.id}>
                            <td className="border border-gray-300 px-4 py-2 font-mono text-sm">
                                <Link href={`/hr/payroll/${p.id}`} className="text-blue-600 hover:underline">
                                    {p.period_month?.slice(0, 7)}
                                </Link>
                                <span className="text-gray-400 ml-2 text-xs">{p.code}</span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2">{p.payment_date}</td>
                            <td className="border border-gray-300 px-4 py-2">{p.currency}</td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {formatUsd(p.gross_total)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm font-medium">
                                {formatUsd(p.net_pay_total)}
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-right font-mono text-sm">
                                {countByPeriod.get(p.id) ?? 0}
                            </td>
                            <td className="border border-gray-300 px-4 py-2">
                                <span
                                    className={
                                        'px-2 py-1 rounded text-xs ' +
                                        (p.status === 'posted'
                                            ? 'bg-green-100 text-green-800'
                                            : 'bg-amber-100 text-amber-800')
                                    }
                                >
                                    {t('hr.payrollStatus.' + p.status)}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-4 py-2 text-sm">
                                {p.journal_entry_id ? (
                                    <Link
                                        href={`/finance/journal/${p.journal_entry_id}`}
                                        className="text-blue-600 hover:underline font-mono"
                                    >
                                        {jeCodeById.get(p.journal_entry_id) ?? '—'}
                                    </Link>
                                ) : (
                                    '—'
                                )}
                            </td>
                        </tr>
                    ))}
                    {periods.length === 0 && (
                        <tr>
                            <td colSpan={8} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('hr.payrollEmpty')}
                            </td>
                        </tr>
                    )}
                </tbody>
            </table>
        </div>
    )
}
