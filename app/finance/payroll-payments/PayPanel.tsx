'use client'

// 逐期面板:勾人 → 付款;CPF / 代扣款各一键(金额 + 次月14日到期)。
//
// CONV-3 · Kind-C(勾选 → 批量动作)。表换成 DataTable —— 但【不用】新的
// selection prop:那个 prop 假设【每一行都能选】,而这张表里已付的行【没有】
// 勾选框(原表就是这么写的,`!l.paid_at && <input .../>`)。selection prop
// 硬套上去要么给已付行也画一个能点却不该点的框,要么去扩它加一个"这一行能不能选"
// 的口子——而这一页是唯一一个有"部分行不能选"这个形状的 Kind-C 页面
// (对照 processing-costs:那边每一行都能选,selection prop 直接够用)。
// 一个例子不足以设计那个扩展,所以这里退回普通列:勾选框就是【一列 render】,
// 与转换前的行为逐字相同,只是外壳换成了 DataTable。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { formatAmount } from '@/lib/format'
import { payLines, payCpf, payDeductions } from '../month-end/actions'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'

type Period = { id: string; code: string; period_month: string; net_pay_total: number
    employer_cpf_total: number; employee_cpf_total: number; other_deductions_total: number
    cpf_paid_at: string | null; deductions_paid_at: string | null }
type Line = { id: string; payroll_period_id: string; employee_id: string; net_pay: number | null; paid_at: string | null }
type Emp = { id: string; code: string; legal_name: string }

function cpfDue(periodMonth: string): string {
    const [y, m] = periodMonth.slice(0, 7).split('-').map(Number)
    return new Date(Date.UTC(m === 12 ? y + 1 : y, m === 12 ? 0 : m, 14)).toISOString().slice(0, 10)
}

// baseCurrency:本面板一个字都没写币种 —— 工资表没有 thead,CPF/代扣款按钮的文案
// (「汇 CPF {amount}」「汇代扣款 {amount}」)也只有数字。所以每个金额自己带币种,
// 币种来自数据(currencies.is_base),由页面传入(CCY-1)。
export default function PayPanel({ periods, lines, employees, baseCurrency }: { periods: Period[]; lines: Line[]; employees: Emp[]; baseCurrency: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [sel, setSel] = useState<Record<string, boolean>>({})
    const [date, setDate] = useState('')
    const empBy = new Map(employees.map((e) => [e.id, e]))

    function run(fn: () => Promise<{ error?: string }>) {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) setError(r.error)
            else { setSel({}); router.refresh() }
        })
    }

    return (
        <div>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {/* 【必填,而且不许默认】三个按钮都用这个日期。留空时动作层原本走
                `date || undefined`,函数 COALESCE(p_payment_date, CURRENT_DATE) 于是
                【静默按今天过账】—— 七月的薪资结进八月,屏幕上毫无迹象。
                更坏的一点:替换成"今天"永远撞不上 PERIOD_LOCKED,所以【填对日期会报错、
                留空反而顺利滑进未关的月份】。留空严格地比填错更危险。
                onBlur 与 onChange 双挂:自动填充/表单状态恢复会改 DOM 而不触发 change,
                受控输入会显示着日期而状态仍是空串(走查里就是这个形状)。 */}
            <label className="text-xs text-gray-600 block mb-4">
                {t('finance.payrollPay.date')} <span className="text-red-600">*</span>
                <input type="date" value={date} required aria-invalid={date === ''}
                       onChange={(e) => setDate(e.target.value)} onBlur={(e) => setDate(e.target.value)}
                       className={'block border rounded px-2 py-1 text-sm '
                           + (date === '' ? 'border-red-400 bg-red-50' : 'border-gray-300')} />
                <span className="mt-1 block max-w-md text-gray-500">{t('finance.payrollPay.dateHint')}</span>
            </label>
            {periods.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('finance.payrollPay.noPeriods')}</p>
            )}
            {periods.map((p) => {
                const pls = lines.filter((l) => l.payroll_period_id === p.id)
                const unpaid = pls.filter((l) => !l.paid_at)
                const chosen = unpaid.filter((l) => sel[l.id]).map((l) => l.id)
                const cpf = Number(p.employer_cpf_total ?? 0) + Number(p.employee_cpf_total ?? 0)

                const columns: Column<Line>[] = [
                    {
                        key: 'select', header: '', priority: true, className: 'w-6',
                        render: (l) => !l.paid_at && (
                            <input type="checkbox" checked={!!sel[l.id]}
                                onChange={(ev) => setSel({ ...sel, [l.id]: ev.target.checked })}
                                aria-label={t('finance.payrollPay.paySelected', { n: 1 })} />
                        ),
                    },
                    {
                        key: 'employee', header: t('finance.payrollPay.colEmployee'), priority: true,
                        render: (l) => {
                            const e = empBy.get(l.employee_id)
                            return <>{e?.code} · {e?.legal_name}</>
                        },
                    },
                    {
                        key: 'amount', header: t('finance.payrollPay.colAmount'), priority: true, align: 'right',
                        render: (l) => formatAmount(l.net_pay, baseCurrency),
                    },
                    {
                        key: 'status', header: '',
                        render: (l) => l.paid_at
                            ? <span className="text-green-700 text-xs">{t('finance.payrollPay.paidOn', { 0: l.paid_at.slice(0, 10) })}</span>
                            : <span className="text-amber-700 text-xs">{t('finance.payrollPay.outstanding')}</span>,
                    },
                ]

                return (
                    <section key={p.id} className="rounded border border-gray-200 p-4 mb-4">
                        <h3 className="font-bold mb-2">{p.code}
                            <span className="ml-2 text-xs text-gray-500 font-normal">{p.period_month.slice(0, 7)}</span>
                        </h3>
                        <div className="mb-3">
                            <DataTable
                                rows={pls}
                                columns={columns}
                                rowKey={(l) => l.id}
                                phone={{ mode: 'columns' }}
                            />
                        </div>
                        <div className="flex gap-2 flex-wrap items-center text-sm">
                            <Button size="sm" type="button" disabled={pending || chosen.length === 0 || date === ''}
                                onClick={() => run(() => payLines(p.id, chosen, date, ''))}>
                                {t('finance.payrollPay.paySelected', { n: chosen.length })}
                            </Button>
                            {cpf > 0 && (p.cpf_paid_at
                                ? <span className="text-xs text-green-700">{t('finance.payrollPay.cpfPaid', { 0: p.cpf_paid_at })}</span>
                                : <Button type="button" disabled={pending || date === ''}
                                    onClick={() => run(() => payCpf(p.id, date))}
                                    variant="secondary" size="sm">
                                    {t('finance.payrollPay.payCpf', { amount: formatAmount(cpf, baseCurrency), due: cpfDue(p.period_month) })}
                                  </Button>)}
                            {Number(p.other_deductions_total ?? 0) > 0 && (p.deductions_paid_at
                                ? <span className="text-xs text-green-700">{t('finance.payrollPay.dedPaid', { 0: p.deductions_paid_at })}</span>
                                : <Button type="button" disabled={pending || date === ''}
                                    onClick={() => run(() => payDeductions(p.id, date))}
                                    variant="secondary" size="sm">
                                    {t('finance.payrollPay.payDeductions', { amount: formatAmount(p.other_deductions_total, baseCurrency) })}
                                  </Button>)}
                        </div>
                    </section>
                )
            })}
        </div>
    )
}
