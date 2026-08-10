// app/hr/payroll/[id]/page.tsx
// 薪资期间详情:抬头 + 合计 + 逐人明细 + 过账/撤销过账。
// 草稿可编辑;已过账变只读(要改先撤销过账 —— 那会冲销分录)。
import Link from 'next/link'
import { bankAccountFor } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import Subnav from '../../Subnav'
import { PostPayrollButton, UnpostPayrollControl } from './PostControls'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'

export default async function PayrollDetailPage({
    params,
}: {
    params: Promise<{ id: string }>
}) {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    const { data: period, error } = await supabase
        .from('payroll_periods')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !period) {
        notFound()
    }

    const [linesRes, jeRes] = await Promise.all([
        supabase
            .from('payroll_lines_masked')
            .select('id, gross_pay, employer_cpf, employee_cpf, other_deductions, net_pay, notes, employees(id, code, legal_name)')
            .eq('payroll_period_id', id),
        period.journal_entry_id
            ? supabase.from('journal_entries').select('id, code').eq('id', period.journal_entry_id).single()
            : Promise.resolve({ data: null, error: null }),
    ])

    type LineRow = {
        id: string
        gross_pay: number
        employer_cpf: number
        employee_cpf: number
        other_deductions: number
        net_pay: number
        notes: string | null
        employees: { id: string; code: string; legal_name: string } | null
    }
    const lines = ((linesRes.data as unknown as LineRow[] | null) ?? []).sort((a, b) =>
        (a.employees?.code ?? '').localeCompare(b.employees?.code ?? '')
    )

    const isPosted = period.status === 'posted'
    const bankAccount = bankAccountFor(period.currency ?? '')

    return (
        <div className="p-8 max-w-5xl">
            <div className="mb-6">
                <Link href="/hr/payroll" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            </div>

            <div className="flex justify-between items-start mb-2 gap-4">
                <h1 className="text-2xl font-bold">
                    {t('hr.payrollDetailTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">
                        {period.period_month?.slice(0, 7)}
                    </span>
                    <span className="ml-2 text-sm text-gray-400 font-mono">{period.code}</span>
                </h1>
                <div className="flex flex-wrap items-center gap-3 justify-end">
                    {!isPosted && (
                        <>
                            <Link
                                href={`/hr/payroll/${id}/edit`}
                                className="border border-gray-300 px-3 py-1.5 rounded hover:bg-gray-50 text-sm"
                            >
                                {t('purchasing.editLink')}
                            </Link>
                            <PostPayrollButton
                                periodId={id}
                                currency={period.currency}
                                bankAccount={bankAccount}
                                totals={{
                                    gross: Number(period.gross_total),
                                    employerCpf: Number(period.employer_cpf_total),
                                    employeeCpf: Number(period.employee_cpf_total),
                                    other: Number(period.other_deductions_total),
                                    net: Number(period.net_pay_total),
                                }}
                            />
                        </>
                    )}
                </div>
            </div>

            <Subnav />

            {/* 抬头 */}
            <div className="bg-gray-50 rounded p-4 mb-4 flex flex-wrap gap-x-8 gap-y-2 text-sm items-center">
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colPaymentDate')}:</span>
                    {period.payment_date}
                </div>
                <div>
                    <span className="text-gray-600 mr-1">{t('hr.colCurrency')}:</span>
                    <span className="font-mono">
                        {period.currency} @ {period.fx_rate}
                    </span>
                </div>
                <div>
                    <span
                        className={
                            'px-2 py-1 rounded text-xs ' +
                            (isPosted ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')
                        }
                    >
                        {t('hr.payrollStatus.' + period.status)}
                    </span>
                </div>
                {jeRes.data && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('assay.journalLink')}:</span>
                        <Link
                            href={`/finance/journal/${jeRes.data.id}`}
                            className="text-blue-600 hover:underline font-mono"
                        >
                            {jeRes.data.code}
                        </Link>
                    </div>
                )}
                {period.source_note && (
                    <div>
                        <span className="text-gray-600 mr-1">{t('hr.colSourceNote')}:</span>
                        {period.source_note}
                    </div>
                )}
            </div>

            {period.notes && (
                <p className="text-sm text-gray-600 mb-4 whitespace-pre-line">
                    <span className="text-gray-500 mr-1">{t('hr.colNotes')}:</span>
                    {period.notes}
                </p>
            )}

            <p className="text-xs text-gray-500 mb-3">{t('hr.payRestricted')}</p>

            {/* 明细 */}
            <table className="w-full border-collapse border border-gray-300 text-sm mb-6">
                <thead className="bg-gray-100">
                    <tr>
                        <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colEmployee')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colGross')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colEmployeeCpf')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colEmployerCpf')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colDeductions')}</th>
                        <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colNet')}</th>
                    </tr>
                </thead>
                <tbody>
                    {lines.map((l) => (
                        <tr key={l.id}>
                            <td className="border border-gray-300 px-3 py-2">
                                {l.employees ? (
                                    <Link
                                        href={`/hr/employees/${l.employees.id}`}
                                        className="text-blue-600 hover:underline"
                                    >
                                        <span className="font-mono text-xs text-gray-500 mr-2">
                                            {l.employees.code}
                                        </span>
                                        {l.employees.legal_name}
                                    </Link>
                                ) : (
                                    '—'
                                )}
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(l.gross_pay, '抬头「币种」:{currency} @ {fx}')}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(l.employee_cpf, '抬头「币种」:{currency} @ {fx}')}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(l.employer_cpf, '抬头「币种」:{currency} @ {fx}')}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(l.other_deductions, '抬头「币种」:{currency} @ {fx}')}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono font-medium">{formatMoneyBare(l.net_pay, '抬头「币种」:{currency} @ {fx}')}</td>
                        </tr>
                    ))}
                    {lines.length === 0 && (
                        <tr>
                            <td colSpan={6} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                {t('hr.errors.NO_LINES')}
                            </td>
                        </tr>
                    )}
                </tbody>
                <tfoot>
                    <tr className="bg-gray-100 font-bold">
                        <td className="border border-gray-300 px-3 py-2">
                            {t('finance.totalsLabel')}
                            <span className="ml-2 font-normal text-gray-500">
                                {t('hr.lineCount', { n: lines.length })}
                            </span>
                        </td>
                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(period.gross_total, '抬头「币种」:{currency} @ {fx}')}</td>
                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(period.employee_cpf_total, '抬头「币种」:{currency} @ {fx}')}</td>
                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(period.employer_cpf_total, '抬头「币种」:{currency} @ {fx}')}</td>
                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(period.other_deductions_total, '抬头「币种」:{currency} @ {fx}')}</td>
                        <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatMoneyBare(period.net_pay_total, '抬头「币种」:{currency} @ {fx}')}</td>
                    </tr>
                </tfoot>
            </table>

            {isPosted && <UnpostPayrollControl periodId={id} />}
        </div>
    )
}
