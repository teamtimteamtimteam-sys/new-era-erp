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
import { formatAmount, businessToday } from '@/lib/format'
import { payLines, payCpf, payDeductions } from '../month-end/actions'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { xDate, xMasked, xMoney, xRestricted, xText, xTime } from '@/lib/export/cells'
import { Button } from '@/app/components/ui/button'
import { CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { formatAuditStamp, formatMonth } from '@/lib/dates'
import { DatePicker } from '@/app/components/ui/date-picker'
import { useLocale } from '@/lib/i18n/client'
import Link from 'next/link'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'
import { formatDate } from '@/lib/dates'
import { submitPayrollPaymentReversal } from '@/app/hr/payroll/actions'
import type { PayrollPaymentEntry } from './paymentEntries'
import { cpfDue } from './cpfDue'

type Period = { id: string; code: string; period_month: string; net_pay_total: number
    employer_cpf_total: number; employee_cpf_total: number; other_deductions_total: number
    cpf_paid_at: string | null; deductions_paid_at: string | null }
type Line = { id: string; payroll_period_id: string; employee_id: string; net_pay: number | null; paid_at: string | null }
type Emp = { id: string; code: string; legal_name: string }


// baseCurrency:本面板一个字都没写币种 —— 工资表没有 thead,CPF/代扣款按钮的文案
// (「汇 CPF {amount}」「汇代扣款 {amount}」)也只有数字。所以每个金额自己带币种,
// 币种来自数据(currencies.is_base),由页面传入(CCY-1)。
// ★ PAYROLL-PAY-REVERSAL-1(Tim 2026-10-22,Q1 · Q2 · Q6 · Q7):每一期下面多一张「付款」表 —— 每一次付款(一次付薪调用 · 一次 CPF · 一次扣款)一行,
//   各带一颗「申请冲销」(整张冲,不能只冲一个人;理由必填;CFO 批,在工资期页上执行并给冲销日)。按不下去的时候【看得见、说出为什么】(DBLOCK-1):
//   银行行已经配上了对账单行(先取消配对)· 这一期已经挂着一张申请(一期同时只挂一张)· 没有 module.hr.edit。
// ★ TABLE-EXPORT-3a(Tim 2026-10-23 Q4;TABLE-EXPORT-2 Q8 把这一块的「受限」排到这里):每一期的两张表各一对导出,【不论勾了谁】
//   全部行都导出(TABLE-EXPORT-1 Q2:勾选不收窄)。勾选框与「申请冲销」那两列是控件,不导出。
//   实发那一格:payroll_lines_masked 对不持 data.view_pay 的读者给 NULL —— 屏幕此前经 formatAmount 画成「—」,读起来像「没有数」;
//   现在与 MaskedValue 同一条判据画「受限」,导出写 "Restricted"(canViewPay 由页面按 data.view_pay 传进来)。
export default function PayPanel({ periods, lines, employees, baseCurrency, payments, canRaise, canViewPay }: {
    periods: Period[]; lines: Line[]; employees: Emp[]; baseCurrency: string
    payments: PayrollPaymentEntry[]; canRaise: boolean; canViewPay: boolean
}) {
    const locale = useLocale()
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [sel, setSel] = useState<Record<string, boolean>>({})
    const [date, setDate] = useState('')
    // DATE-PICK-1:三个按钮都靠 onClick 提交(不走原生表单)—— 框里是敲错的日子时三个一起关掉
    const [dateBad, setDateBad] = useState(false)
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
                受控输入会显示着日期而状态仍是空串(走查里就是这个形状)。
                ★ DATE-PICK-1:那道 onBlur 回写已经拿掉 —— 日期框的值只来自 React 状态,没有 DOM 漂移可回写。 */}
            <label className="block mb-4">
                {t('finance.payrollPay.date')} <span className="text-red-600">*</span>
                {/* ★★ POLISH-1(2026-09-12,Tim 的裁定 R10 · S3「状态色留着」)★★
                   ⚠ 本段【刻意不写那个类名的字面】—— 注释里的一个 token 会被
                     将来对它自己的计数数进去(AGENTS.md · CONFIRM-1/ALERT-1,四次)。
                   这里原来在调用点上手写了【一个红描边类 + 一个红底类】,而那个描边类
                   **一个像素都没有画过**:`CONTROL_INPUT` 里有
                   `aria-invalid:border-destructive`,它的选择器是【类 + 属性】,
                   特指度压过一个光秃秃的类;而这串类只在 `value === ''` 时挂上,
                   也就是**只在 aria-invalid 为真的时候** —— 于是它永远是输的那一边。
                   (round 1 实测:那条边框渲染出来是 `#B75B53`,一个模块值。)
                   ☞ S3 说【状态色留着】,而一条画不出来的类不是状态色,是死代码:
                     拿掉那个描边类,**屏幕上零变化**;
                     留下那个红底类 —— 模块那一支**没有**底色,它是真的在画。
                   ⚠ 「只读底色该长什么样」那一条(z③)Tim 2026-09-11 已裁**留**,
                     见 `app/hr/payroll/PayrollGrid.tsx` 那一行的注释。 */}
            {/* ★ DATE-PICK-1:日期框自带它的 32px 框,上面说的那个红底类随原生框一起退场;空着时仍由 aria-invalid 画红描边。 */}
            {/* FIN-CHAIN-1(Tim Step 0 Q13):钱离开银行是已经发生的事 —— 晚于今天服务端按名拒 DOCUMENT_DATE_IN_FUTURE,框也不给选。 */}
            <DatePicker value={date} required aria-invalid={date === ''} max={businessToday()}
                        onChange={setDate} onInvalidChange={setDateBad} className="flex" />
                <span className="mt-1 block max-w-md text-[color:var(--brand-muted-text)]">{t('finance.payrollPay.dateHint')}</span>
            </label>
            {periods.length === 0 && (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('finance.payrollPay.noPeriods')}</p>
            )}
            {periods.map((p) => {
                const pls = lines.filter((l) => l.payroll_period_id === p.id)
                const unpaid = pls.filter((l) => !l.paid_at)
                const chosen = unpaid.filter((l) => sel[l.id]).map((l) => l.id)
                const cpf = Number(p.employer_cpf_total ?? 0) + Number(p.employee_cpf_total ?? 0)
                const pays = payments.filter((x) => x.payroll_period_id === p.id && x.status === 'posted')
                const openReq = pays.find((x) => x.open_request)?.open_request ?? null
                const payColumns: ExportableColumn<PayrollPaymentEntry>[] = [
                    {
                        key: 'code', header: t('finance.payrollPay.colEntry'), priority: true,
                        render: (x) => <Link href={`/finance/journal/${x.entry_id}`} className="font-mono underline">{x.code}</Link>,
                        exportAs: (x) => xText(x.code),
                    },
                    {
                        key: 'kind', header: t('finance.payrollPay.colKind'),
                        render: (x) => <>{t('finance.payrollPay.paymentKind.' + x.kind)}{x.kind === 'salary' && x.lines_paid !== null
                            ? <span className="text-xs text-[color:var(--brand-muted-text)]"> · {t('finance.payrollPay.linesPaid', { n: x.lines_paid })}</span> : null}</>,
                        exportAs: (x) => xText(t('finance.payrollPay.paymentKind.' + x.kind)
                            + (x.kind === 'salary' && x.lines_paid !== null ? ` · ${t('finance.payrollPay.linesPaid', { n: x.lines_paid })}` : '')),
                    },
                    { key: 'date', header: t('finance.payrollPay.colDate'), render: (x) => formatDate(x.entry_date, locale), exportAs: (x) => xDate(x.entry_date) },
                    {
                        key: 'amount', header: t('finance.payrollPay.colAmount'), priority: true, align: 'right',
                        render: (x) => x.amount === null ? <Refusal>{t('common.restricted')}</Refusal> : formatAmount(x.amount, baseCurrency),
                        // payroll_payment_entries 把看不见的金额给成 NULL,屏幕一律画「受限」—— 导出同一条
                        exportAs: (x) => (x.amount === null ? xRestricted : xMoney(x.amount, baseCurrency)),
                    },
                    {
                        key: 'reverse', header: '', priority: true, align: 'right', exportAs: false,
                        render: (x) => {
                            const why = x.bank_statement
                                ? t('finance.payrollPay.bankMatched', { statement: x.bank_statement })
                                : openReq
                                    ? (openReq.target_entry_id === x.entry_id
                                        ? t('finance.payrollPay.reversalWaiting', { label: openReq.label })
                                        : t('finance.payrollPay.periodRequestOpen', { label: openReq.label }))
                                    : null
                            return (
                                <PermissionGate code="module.hr.edit" allowed={canRaise}>
                                    <span className="inline-flex flex-col items-end gap-1">
                                        <ConfirmButton
                                            subject={`${p.code} · ${x.code}`}
                                            title={t('finance.payrollPay.reversalConfirm')}
                                            body={t('finance.payrollPay.reversalBody')}
                                            confirmLabel={t('finance.payrollPay.requestReversal')}
                                            tier="reversal"
                                            triggerVariant="reversal"
                                            triggerSize="xs"
                                            reason={{ placeholder: t('hr.payrollRequest.reasonPlaceholder') }}
                                            disabled={pending || !!why}
                                            onConfirm={(reason) => run(() => submitPayrollPaymentReversal(p.id, x.entry_id, reason))}
                                        >
                                            {t('finance.payrollPay.requestReversal')}
                                        </ConfirmButton>
                                        {why && (
                                            <span className="block max-w-[16rem] text-xs text-[color:var(--brand-muted-text)]">
                                                {why}{openReq && !x.bank_statement && <> <Link href={`/hr/payroll/${p.id}`} className="underline">{t('finance.payrollPay.openPeriod')}</Link></>}
                                            </span>
                                        )}
                                    </span>
                                </PermissionGate>
                            )
                        },
                    },
                ]

                const columns: ExportableColumn<Line>[] = [
                    {
                        key: 'select', header: '', priority: true, className: 'w-6', exportAs: false,
                        render: (l) => !l.paid_at && (
                            <input type="checkbox" className={CONTROL_CHECKBOX} checked={!!sel[l.id]}
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
                        exportAs: (l) => {
                            const e = empBy.get(l.employee_id)
                            return xText(`${e?.code ?? ''} · ${e?.legal_name ?? ''}`)
                        },
                    },
                    {
                        key: 'amount', header: t('finance.payrollPay.colAmount'), priority: true, align: 'right',
                        render: (l) => <MaskedValue value={l.net_pay} canView={canViewPay} format={(v: number) => formatAmount(v, baseCurrency)} fallback="—" />,
                        exportAs: (l) => xMasked(l.net_pay, canViewPay, (v) => xMoney(v, baseCurrency)),
                    },
                    {
                        key: 'status', header: '', exportHeader: t('finance.payrollPay.colStatus'),
                        exportAs: (l) => (l.paid_at ? xTime(l.paid_at) : xText(t('finance.payrollPay.outstanding'))),
                        render: (l) => l.paid_at
                            ? <span className="text-green-700 text-xs">{t('finance.payrollPay.paidOn', { 0: formatAuditStamp(l.paid_at) })}</span>
                            : <span className="text-amber-700 text-xs">{t('finance.payrollPay.outstanding')}</span>,
                    },
                ]

                return (
                    <section key={p.id} className="rounded border border-gray-200 p-4 mb-4">
                        <h3 className="mb-2">{p.code}
                            <span className="ml-2 text-xs text-[color:var(--brand-muted-text)] font-normal">{formatMonth(p.period_month, locale)}</span>
                        </h3>
                        <div className="mb-3">
                            <DataTable
                                rows={pls}
                                columns={columns}
                                rowKey={(l) => l.id}
                                phone={{ mode: 'columns' }}
                                exportSpec={{ name: 'finance-payroll-payment-lines', title: `${p.code} — ${t('finance.payrollPay.title')}`, aboutExtra: [[t('table.export.aboutPeriod'), p.period_month.slice(0, 7)]] }}
                            />
                        </div>
                        {pays.length > 0 && (
                            <div className="mb-3">
                                <h4 className="mb-1 text-sm">{t('finance.payrollPay.paymentsTitle')}</h4>
                                <DataTable rows={pays} columns={payColumns} rowKey={(x) => x.entry_id} phone={{ mode: 'columns' }}
                                    exportSpec={{ name: 'finance-payroll-payments-made', title: `${p.code} — ${t('finance.payrollPay.paymentsTitle')}`, aboutExtra: [[t('table.export.aboutPeriod'), p.period_month.slice(0, 7)]] }} />
                            </div>
                        )}
                        <div className="flex gap-2 flex-wrap items-center text-sm">
                            <Button type="button" disabled={pending || chosen.length === 0 || date === '' || dateBad}
                                onClick={() => run(() => payLines(p.id, chosen, date, ''))}>
                                {t('finance.payrollPay.paySelected', { n: chosen.length })}
                            </Button>
                            {cpf > 0 && (p.cpf_paid_at
                                ? <span className="text-xs text-green-700">{t('finance.payrollPay.cpfPaid', { 0: formatAuditStamp(p.cpf_paid_at) })}</span>
                                : <Button type="button" disabled={pending || date === '' || dateBad}
                                    onClick={() => run(() => payCpf(p.id, date))}
                                    variant="secondary">
                                    {t('finance.payrollPay.payCpf', { amount: formatAmount(cpf, baseCurrency), due: cpfDue(p.period_month) })}
                                  </Button>)}
                            {Number(p.other_deductions_total ?? 0) > 0 && (p.deductions_paid_at
                                ? <span className="text-xs text-green-700">{t('finance.payrollPay.dedPaid', { 0: formatAuditStamp(p.deductions_paid_at) })}</span>
                                : <Button type="button" disabled={pending || date === '' || dateBad}
                                    onClick={() => run(() => payDeductions(p.id, date))}
                                    variant="secondary">
                                    {t('finance.payrollPay.payDeductions', { amount: formatAmount(p.other_deductions_total, baseCurrency) })}
                                  </Button>)}
                        </div>
                    </section>
                )
            })}
        </div>
    )
}
