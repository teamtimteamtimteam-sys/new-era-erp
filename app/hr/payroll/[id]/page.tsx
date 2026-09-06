// app/hr/payroll/[id]/page.tsx
// 薪资期间详情:抬头 + 合计 + 逐人明细 + 过账/撤销过账。
// 草稿可编辑;已过账变只读(要改先撤销过账 —— 那会冲销分录)。
import Link from 'next/link'
import { bankAccountFor } from '@/lib/currency'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import { PostPayrollButton, UnpostPayrollControl } from './PostControls'
import { can } from '@/lib/permissions'
import { Refusal } from '@/app/components/ui/refusal'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import PayrollLinesTable, { type PayrollLineRow } from './PayrollLinesTable'
import { Button } from '@/app/components/ui/button'

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
        // ★ FIX-2a(b):见 /hr/payroll —— journal_entries 挂 finance.view,hr 没有。
        //   此前读不到时整行【消失】,于是一张已经过账的薪资期间在 HR 眼里
        //   连"分录"这一栏都不存在。Tim 的裁定:不放宽,但要说出来。
        period.journal_entry_id && (await can('module.finance.view'))
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


    // ★【行数据在服务端压平】金额格式与 CCY-1 的"币种写在哪儿"说明都归服务端。
    const CCY_NOTE = '抬头「币种」:{currency} @ {fx}'
    const tableRows: PayrollLineRow[] = lines.map((l) => ({
        id: l.id,
        employeeCode: l.employees?.code ?? '',
        employeeName: l.employees?.legal_name ?? '—',
        employeeHref: l.employees ? `/hr/employees/${l.employees.id}` : null,
        grossText: formatMoneyBare(l.gross_pay, CCY_NOTE),
        employeeCpfText: formatMoneyBare(l.employee_cpf, CCY_NOTE),
        employerCpfText: formatMoneyBare(l.employer_cpf, CCY_NOTE),
        deductionsText: formatMoneyBare(l.other_deductions, CCY_NOTE),
        netText: formatMoneyBare(l.net_pay, CCY_NOTE),
    }))

    // ★ 合计行是【数据】,不是 <tfoot> —— CONV-4 §⑨-3 定的型,CONV-8 §⑧ 复核保留。
    //   ★ 这一行【无条件】画(转换前的 <tfoot> 也是无条件的):一个 0 行的期间
    //     仍然要说出它的合计是 0,那不是空,那是一个答案。
    tableRows.push({
        id: '__total__',
        employeeCode: '',
        employeeName: t('finance.totalsLabel'),
        employeeHref: null,
        grossText: formatMoneyBare(period.gross_total, CCY_NOTE),
        employeeCpfText: formatMoneyBare(period.employee_cpf_total, CCY_NOTE),
        employerCpfText: formatMoneyBare(period.employer_cpf_total, CCY_NOTE),
        deductionsText: formatMoneyBare(period.other_deductions_total, CCY_NOTE),
        netText: formatMoneyBare(period.net_pay_total, CCY_NOTE),
        isTotal: true,
        totalNote: t('hr.lineCount', { n: lines.length }),
    })

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={
                <Link href="/hr/payroll" className="text-blue-600 hover:underline text-sm">
                    {t('common.back')}
                </Link>
            }
            title={
                <>
                    {t('hr.payrollDetailTitle')}
                    <span className="ml-3 font-mono text-base text-gray-500">
                        {period.period_month?.slice(0, 7)}
                    </span>
                    <span className="ml-2 text-sm text-gray-400 font-mono">{period.code}</span>
                </>
            }
            // ★ 出口:改这个期间 / 过账。转换前它们画在 h1 右边 —— actions 是同一个位置,
            //   而且画在状态分支【之前】,任何空态都吃不掉它们。
            actions={
                !isPosted ? (
                    <span className="flex flex-wrap items-center gap-3 justify-end">
                        <Button asChild variant="outline" size="sm">
                            <Link
                                href={`/hr/payroll/${id}/edit`}
                            >
                                {t('purchasing.editLink')}
                            </Link>
                        </Button>
                        <PostPayrollButton
                            periodId={id}
                            subject={`${period.period_month?.slice(0, 7)} · ${period.code}`}
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
                    </span>
                ) : undefined
            }
            // ★★ 详情页恒为 ok —— 这个期间在不在由上面的 notFound() 回答。
            state={{ kind: 'ok' }}
        >
            {/* ★ 记录抬头 —— 转换前是一块 bg-gray-50 面板。这一页的动作住在
                标题那一排(见 actions),所以抬头不给 actions 槽。 */}
            <RecordHeader
                fields={[
                    { label: t('hr.colPaymentDate'), value: period.payment_date },
                    { label: t('hr.colCurrency'), value: `${period.currency} @ ${period.fx_rate}`, mono: true },
                    {
                        // hr.colStatus —— 工资期间列表页同一件事的现成键,不新造。
                        label: t('hr.colStatus'),
                        value: (
                            <span
                                className={
                                    'px-2 py-1 rounded text-xs ' +
                                    (isPosted ? 'bg-green-100 text-green-800' : 'bg-amber-100 text-amber-800')
                                }
                            >
                                {t('hr.payrollStatus.' + period.status)}
                            </span>
                        ),
                    },
                    // 三态:没有分录 → 这一行【不出现】(诚实:确实没有);
                    // 有分录且读得到 → 链接;有分录而读不到 → 具名受限,不画链接。
                    ...(jeRes.data
                        ? [{
                            label: t('assay.journalLink'),
                            value: (
                                <Link
                                    href={`/finance/journal/${jeRes.data.id}`}
                                    className="text-blue-600 hover:underline font-mono"
                                >
                                    {jeRes.data.code}
                                </Link>
                            ),
                          }]
                        : period.journal_entry_id
                          ? [{
                                label: t('assay.journalLink'),
                                value: (
                                    <Refusal why={t('hr.payrollEntryRestrictedHint')}>
                                        {t('common.restricted')}
                                    </Refusal>
                                ),
                            }]
                          : []),
                    ...(period.source_note
                        ? [{ label: t('hr.colSourceNote'), value: period.source_note }]
                        : []),
                ]}
            />

            {period.notes && (
                <p className="text-sm text-gray-600 mb-4 whitespace-pre-line">
                    <span className="text-gray-500 mr-1">{t('hr.colNotes')}:</span>
                    {period.notes}
                </p>
            )}

            <p className="text-xs text-gray-500 mb-3">{t('hr.payRestricted')}</p>

            {/* 明细 */}
            <div className="mb-6">
                <PayrollLinesTable rows={tableRows} />
            </div>

            {/* ★ 出口检查:反过账控件只在已过账时出现,住 children;
                  state 恒为 'ok',所以它不可能被空分支吃掉。 */}
            {isPosted && <UnpostPayrollControl periodId={id} subject={`${period.period_month?.slice(0, 7)} · ${period.code}`} />}
        </ListPage>
    )
}
