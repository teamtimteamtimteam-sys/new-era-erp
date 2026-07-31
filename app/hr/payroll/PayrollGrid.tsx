'use client'

// 薪资录入表格:一名在职员工一行,从【上一期】的数字预填 —— 逐月录入本该是
// "核对"而不是"重敲"。预填的数字上方有明确提示:那是上月的,必须对着服务商的
// 报表逐行核。
//
// 每行实时校验 net =? gross − 员工CPF − 其它扣款:对了给绿勾,错了标红并显示差额,
// 且只要有一行不平就禁用提交 —— DB 的 LINE_NOT_BALANCED 是后墙,不是第一道防线。
// 整行留空的员工不提交(当月没发薪的人不该以 0 混进工资单)。
import { useActionState, useState } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { formatUsd } from '@/lib/format'
import DecimalInput, { parseDecimal } from '@/app/components/forms/DecimalInput'
import { savePayrollPeriod, type PayrollFormState, type PayrollLineInput } from './actions'

const initialState: PayrollFormState = {}

export type EmployeeRow = { id: string; code: string; legal_name: string }

const round2 = (n: number) => Math.round(n * 100) / 100

function blankLine(employeeId: string): PayrollLineInput {
    return {
        employee_id: employeeId,
        gross_pay: '',
        employee_cpf: '',
        employer_cpf: '',
        other_deductions: '',
        net_pay: '',
    }
}

export default function PayrollGrid({
    employees,
    prefill,
    defaults,
    monthLocked = false,
    hasPrefill,
}: {
    employees: EmployeeRow[]
    // 上一期的数字(employee_id → 各列字符串);没有上一期时为空
    prefill: Record<string, Partial<PayrollLineInput>>
    // 抬头默认值(全部用字符串:空串 = 让用户填,不会预填出 0 这种非法汇率)
    defaults: {
        period_month: string // 'YYYY-MM'
        payment_date: string
        currency: string
        fx_rate: string
        source_note: string
        notes: string
    }
    // 编辑既有期间时月份不可改 —— 换月份等于换一张单,应该另建
    monthLocked?: boolean
    hasPrefill: boolean
}) {
    const t = useTranslations()
    const [state, formAction, isPending] = useActionState(savePayrollPeriod, initialState)

    const [lines, setLines] = useState<Record<string, PayrollLineInput>>(() => {
        const out: Record<string, PayrollLineInput> = {}
        for (const e of employees) {
            const p = prefill[e.id] ?? {}
            out[e.id] = { ...blankLine(e.id), ...p, employee_id: e.id }
        }
        return out
    })

    function patch(empId: string, key: keyof PayrollLineInput, value: string) {
        setLines((ls) => ({ ...ls, [empId]: { ...ls[empId], [key]: value } }))
    }

    const isBlank = (l: PayrollLineInput) =>
        ['gross_pay', 'employee_cpf', 'employer_cpf', 'other_deductions', 'net_pay'].every(
            (k) => ((l as unknown as Record<string, string>)[k] ?? '').trim() === ''
        )

    // 每行的自洽校验:留空行不参与
    const rowCheck = (l: PayrollLineInput) => {
        if (isBlank(l)) return { skip: true, ok: true, delta: 0, expected: 0 }
        const gross = parseDecimal(l.gross_pay) ?? 0
        const eeCpf = parseDecimal(l.employee_cpf) ?? 0
        const other = parseDecimal(l.other_deductions) ?? 0
        const net = parseDecimal(l.net_pay) ?? 0
        const expected = round2(gross - eeCpf - other)
        return { skip: false, ok: expected === round2(net), delta: round2(net - expected), expected }
    }

    const active = employees.map((e) => lines[e.id]).filter((l) => !isBlank(l))
    const anyBad = active.some((l) => !rowCheck(l).ok)
    const totals = active.reduce(
        (acc, l) => ({
            gross: round2(acc.gross + (parseDecimal(l.gross_pay) ?? 0)),
            eeCpf: round2(acc.eeCpf + (parseDecimal(l.employee_cpf) ?? 0)),
            erCpf: round2(acc.erCpf + (parseDecimal(l.employer_cpf) ?? 0)),
            other: round2(acc.other + (parseDecimal(l.other_deductions) ?? 0)),
            net: round2(acc.net + (parseDecimal(l.net_pay) ?? 0)),
        }),
        { gross: 0, eeCpf: 0, erCpf: 0, other: 0, net: 0 }
    )

    const cell = 'w-24 border border-gray-300 px-2 py-1 rounded text-right'

    return (
        <form action={formAction} className="space-y-4">
            {state.error && (
                <div className="bg-red-100 border border-red-400 text-red-700 px-4 py-3 rounded">
                    {state.error}
                </div>
            )}

            <input type="hidden" name="lines_json" value={JSON.stringify(Object.values(lines))} />

            {/* 期间抬头 */}
            <div className="flex flex-wrap gap-4">
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('hr.colPeriod')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="month"
                        name="period_month"
                        required
                        defaultValue={defaults.period_month}
                        readOnly={monthLocked}
                        className="border border-gray-300 px-3 py-2 rounded read-only:bg-gray-100"
                    />
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('hr.colPaymentDate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="date"
                        name="payment_date"
                        required
                        defaultValue={defaults.payment_date}
                        className="border border-gray-300 px-3 py-2 rounded"
                    />
                    <p className="text-xs text-gray-500 mt-1">{t('hr.paymentDateHint')}</p>
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">{t('hr.colCurrency')}</label>
                    <select
                        name="currency"
                        defaultValue={defaults.currency}
                        className="border border-gray-300 px-3 py-2 rounded"
                    >
                        <option value="SGD">SGD</option>
                        <option value="USD">USD</option>
                    </select>
                </div>
                <div>
                    <label className="block text-sm font-medium mb-1">
                        {t('hr.colFxRate')} <span className="text-red-600">*</span>
                    </label>
                    <input
                        type="text"
                        name="fx_rate"
                        required
                        inputMode="decimal"
                        defaultValue={defaults.fx_rate}
                        className="w-28 border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[14rem]">
                    <label className="block text-sm font-medium mb-1">{t('hr.colSourceNote')}</label>
                    <input
                        type="text"
                        name="source_note"
                        defaultValue={defaults.source_note}
                        placeholder={t('hr.sourceNoteHint')}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
                <div className="flex-1 min-w-[12rem]">
                    <label className="block text-sm font-medium mb-1">{t('hr.colNotes')}</label>
                    <input
                        type="text"
                        name="notes"
                        defaultValue={defaults.notes}
                        className="w-full border border-gray-300 px-3 py-2 rounded"
                    />
                </div>
            </div>

            {hasPrefill && (
                <p className="bg-amber-50 border border-amber-300 text-amber-900 px-4 py-2 rounded text-sm">
                    {t('hr.prefillNote')}
                </p>
            )}

            {/* 明细表 */}
            <div className="overflow-x-auto">
                <table className="w-full border-collapse border border-gray-300 text-sm">
                    <thead className="bg-gray-100">
                        <tr>
                            <th className="border border-gray-300 px-3 py-2 text-left">{t('hr.colEmployee')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colGross')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colEmployeeCpf')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colEmployerCpf')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colDeductions')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-right">{t('hr.colNet')}</th>
                            <th className="border border-gray-300 px-3 py-2 text-left w-32">{t('hr.colCheck')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {employees.map((e) => {
                            const l = lines[e.id]
                            const check = rowCheck(l)
                            return (
                                <tr key={e.id} className={!check.ok ? 'bg-red-50' : ''}>
                                    <td className="border border-gray-300 px-3 py-1.5">
                                        <span className="font-mono text-xs text-gray-500 mr-2">{e.code}</span>
                                        {e.legal_name}
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        <DecimalInput
                                            value={l.gross_pay}
                                            onChange={(v) => patch(e.id, 'gross_pay', v)}
                                            className={cell}
                                        />
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        <DecimalInput
                                            value={l.employee_cpf}
                                            onChange={(v) => patch(e.id, 'employee_cpf', v)}
                                            className={cell}
                                        />
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        <DecimalInput
                                            value={l.employer_cpf}
                                            onChange={(v) => patch(e.id, 'employer_cpf', v)}
                                            className={cell}
                                        />
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        <DecimalInput
                                            value={l.other_deductions}
                                            onChange={(v) => patch(e.id, 'other_deductions', v)}
                                            className={cell}
                                        />
                                    </td>
                                    <td className="border border-gray-300 px-2 py-1">
                                        <DecimalInput
                                            value={l.net_pay}
                                            onChange={(v) => patch(e.id, 'net_pay', v)}
                                            className={cell}
                                        />
                                    </td>
                                    <td className="border border-gray-300 px-3 py-1.5 text-xs">
                                        {check.skip ? (
                                            <span className="text-gray-300">—</span>
                                        ) : check.ok ? (
                                            <span className="text-green-700">✓</span>
                                        ) : (
                                            <span className="text-red-700">
                                                {t('hr.expectedNet', { amount: formatUsd(check.expected) })}
                                            </span>
                                        )}
                                    </td>
                                </tr>
                            )
                        })}
                        {employees.length === 0 && (
                            <tr>
                                <td colSpan={7} className="border border-gray-300 px-4 py-8 text-center text-gray-500">
                                    {t('hr.employeesEmpty')}
                                </td>
                            </tr>
                        )}
                    </tbody>
                    <tfoot>
                        <tr className="bg-gray-100 font-bold">
                            <td className="border border-gray-300 px-3 py-2">
                                {t('finance.totalsLabel')}
                                <span className="ml-2 font-normal text-gray-500">
                                    {t('hr.lineCount', { n: active.length })}
                                </span>
                            </td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatUsd(totals.gross)}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatUsd(totals.eeCpf)}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatUsd(totals.erCpf)}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatUsd(totals.other)}</td>
                            <td className="border border-gray-300 px-3 py-2 text-right font-mono">{formatUsd(totals.net)}</td>
                            <td className="border border-gray-300 px-3 py-2" />
                        </tr>
                    </tfoot>
                </table>
            </div>

            {anyBad && (
                <p className="text-sm text-red-600">{t('hr.gridHasErrors')}</p>
            )}

            <div className="flex gap-3 pt-2">
                <button
                    type="submit"
                    disabled={isPending || anyBad || active.length === 0}
                    className="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 disabled:bg-gray-400"
                >
                    {isPending ? t('common.saving') : t('common.save')}
                </button>
                <Link href="/hr/payroll" className="border border-gray-300 px-4 py-2 rounded hover:bg-gray-50">
                    {t('common.cancel')}
                </Link>
            </div>
        </form>
    )
}
