// app/hr/payroll/[id]/page.tsx
// 薪资期间详情:抬头 + 合计 + 逐人明细 + 过账/撤销过账。
// 草稿可编辑;已过账变只读(要改先撤销过账 —— 那会冲销分录)。
// ★ PAYROLL-APR-1(2026-09-24):过账与撤销都要先经 CFO 批准 —— 这一页承载申请、决定与执行
//   (PayrollRequestPanel)。挂着未了结的申请时,编辑入口看得见、按不动,并说出理由。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import type { Database } from '@/lib/database.types'
import { getTranslations } from '@/lib/i18n/server'
import { formatMoneyBare } from '@/lib/format'
import { PayrollRequestPanel, type PayrollRequestView } from './PostControls'
import { can } from '@/lib/permissions'
import { Refusal } from '@/app/components/ui/refusal'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import PayrollLinesTable, { type PayrollLineRow } from './PayrollLinesTable'
import { Button } from '@/app/components/ui/button'
import { formatDate, formatMonth, formatAuditStamp } from '@/lib/dates'
import { mustRows } from '@/lib/db-helpers'
import { getLocale } from '@/lib/i18n/server'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'

export default async function PayrollDetailPage({
    params,
    searchParams,
}: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const locale = await getLocale()
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前 ——
    // 拒绝必须是权限答复,不能是从空结果倒推。
    const denied = await requireModule(MOD.hr)
    if (denied) return denied

    const { id } = await params
    const supabase = await createClient()
    const t = await getTranslations()

    // ★ U1-A(Tim 的 UNBLOCK-1 Q9,2026-10-05):读 payroll_periods_masked —— 五个合计对不持 data.view_pay 的人是 null(合计行与过账预览印「受限」)。
    //   基表上那五列已经不对 authenticated 开放,select('*') 会 42501。
    const { data: periodRaw, error } = await supabase
        .from('payroll_periods_masked')
        .select('*')
        .eq('id', id)
        .is('deleted_at', null)
        .single()

    if (error || !periodRaw) {
        notFound()
    }
    // 视图的生成类型把每一列都标成可空;列与基表逐列相同 —— 按基表的行类型读,只有五个合计是真的可空(受限 = null)
    type PeriodTotals = 'gross_total' | 'employer_cpf_total' | 'employee_cpf_total' | 'other_deductions_total' | 'net_pay_total'
    const period = periodRaw as unknown as Omit<Database['public']['Tables']['payroll_periods']['Row'], PeriodTotals>
        & { [K in PeriodTotals]: number | null }

    const [linesRes, jeRes, reqRes, canRaise, canDecide, meRes, otRes] = await Promise.all([
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
        // PAYROLL-APR-1:这一期的申请,最新的在前(读策略与本页同一个码,module.hr.view)
        supabase
            .from('payroll_requests_masked')
            .select('id, label, kind, status, notes, decision_notes, created_at')
            .eq('payroll_period_id', id)
            .order('created_at', { ascending: false }),
        can('module.hr.edit'),
        can('data.view_pay'),
        supabase.rpc('current_user_employee'),
        // ★ OVERTIME-1(Tim Q1):批过的加班【小时】—— 只读、不算钱(政策 7.1);那个月考勤完成之后读冻住的数
        supabase.rpc('overtime_month_hours', { p_month: period.period_month }),
    ])
    const otRows = mustRows(otRes, 'overtime_month_hours')
    const otByEmployee = new Map(otRows.map((o) => [o.employee_id, Number(o.total_hours)]))
    const otFixed = otRows.length === 0 || otRows.every((o) => o.fixed)

    type LineRow = {
        id: string
        gross_pay: number | null
        employer_cpf: number | null
        employee_cpf: number | null
        other_deductions: number | null
        net_pay: number | null
        notes: string | null
        employees: { id: string; code: string; legal_name: string } | null
    }
    const lines = ((linesRes.data as unknown as LineRow[] | null) ?? []).sort((a, b) =>
        (a.employees?.code ?? '').localeCompare(b.employees?.code ?? '')
    )

    const isPosted = period.status === 'posted'
    const subjectLabel = `${formatMonth(period.period_month, locale)} · ${period.code}`

    type ReqRow = {
        id: string; label: string; kind: 'post' | 'reversal'
        status: PayrollRequestView['status']; notes: string | null; decision_notes: string | null; created_at: string
    }
    const requests: PayrollRequestView[] = (mustRows(reqRes, 'payroll requests') as unknown as ReqRow[]).map((r) => ({
        id: r.id,
        label: r.label,
        kind: r.kind,
        status: r.status,
        notes: r.notes,
        decisionNotes: r.decision_notes,
        createdText: formatAuditStamp(r.created_at),
    }))
    const openRequest = requests.find((r) => r.status === 'submitted' || r.status === 'approved') ?? null
    // 看这一页的人自己在本期里有没有工资行(按人认:current_user_employee 就是 account_person)
    const myEmployeeId = (meRes.data as string | null) ?? null
    const ownLineCode = myEmployeeId
        ? (lines.find((l) => l.employees?.id === myEmployeeId)?.employees?.code ?? null)
        : null


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
        otHoursText: l.employees ? (otByEmployee.get(l.employees.id) ?? 0).toFixed(2) : '—',
        restricted: l.gross_pay === null,
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
        otHoursText: lines.reduce((acc, l) => acc + (l.employees ? (otByEmployee.get(l.employees.id) ?? 0) : 0), 0).toFixed(2),
        isTotal: true,
        totalNote: t('hr.lineCount', { n: lines.length }),
        restricted: period.gross_total === null,
    })

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={
                <Link href="/hr/payroll" className="hover:underline text-sm app-link">
                    {t('common.back')}
                </Link>
            }
            title={
                <>
                    {t('hr.payrollDetailTitle')}
                    <span className="ml-3 text-sm text-[color:var(--brand-muted-text)]">
                        {formatMonth(period.period_month, locale)}
                    </span>
                    <span className="ml-2 text-sm text-gray-400">{period.code}</span>
                </>
            }
            // ★ 出口:改这个期间 / 过账。转换前它们画在 h1 右边 —— actions 是同一个位置,
            //   而且画在状态分支【之前】,任何空态都吃不掉它们。
            actions={
                !isPosted ? (
                    <span className="flex flex-wrap items-center gap-3 justify-end">
                        {openRequest ? (
                            // PAYROLL-APR-1:挂着未了结的申请时保存会被库按名拒(PAYROLL_REQUEST_OPEN)——
                            //   入口看得见、按不动,理由写在旁边(DBLOCK-1)。
                            <Button variant="outline" disabled title={t('hr.payrollRequest.editLocked')}>
                                {t('purchasing.editLink')}
                            </Button>
                        ) : (
                            <Button asChild variant="outline">
                                <Link href={`/hr/payroll/${id}/edit`}>{t('purchasing.editLink')}</Link>
                            </Button>
                        )}
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
                    { label: t('hr.colPaymentDate'), value: formatDate(period.payment_date, locale) },
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
                                    className="hover:underline app-link app-link-inline"
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
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-4 whitespace-pre-line">
                    <span className="text-[color:var(--brand-muted-text)] mr-1">{t('hr.colNotes')}:</span>
                    {period.notes}
                </p>
            )}

            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('hr.payRestricted')}</p>

            {/* 明细 */}
            <div className="mb-6">
                <PayrollLinesTable rows={tableRows} />
                <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">
                    {otFixed ? t('hr.otHoursFixedNote') : t('hr.otHoursLiveNote')}
                </p>
            </div>

            {openRequest && !isPosted && (
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('hr.payrollRequest.editLocked')}</p>
            )}

            {/* ★ 出口检查:申请 / 决定 / 执行住 children;state 恒为 'ok',所以它不可能被空分支吃掉。 */}
            <PayrollRequestPanel
                periodId={id}
                subject={subjectLabel}
                isPosted={isPosted}
                currency={period.currency}
                totals={{
                    // null 留 null —— Number(null) 是 0,那正是本仓库反复付账的「受限」读成 0.00
                    gross: period.gross_total === null ? null : Number(period.gross_total),
                    employerCpf: period.employer_cpf_total === null ? null : Number(period.employer_cpf_total),
                    employeeCpf: period.employee_cpf_total === null ? null : Number(period.employee_cpf_total),
                    other: period.other_deductions_total === null ? null : Number(period.other_deductions_total),
                    net: period.net_pay_total === null ? null : Number(period.net_pay_total),
                }}
                open={openRequest}
                canRaise={canRaise}
                canDecide={canDecide}
                ownLineCode={ownLineCode}
            />

            {/* AUDIT-TRAIL-1d-3:页底的审计记录 —— 这一期的保存(工资行按员工配对,Q11)· 过账 / 撤销与它们的申请和审批 ·
                发薪 · CPF · 代扣款。它替掉了申请那一块下面的"以往的申请"(Q27);分录对不持财务权限的人是 Restricted,与页头同一条 */}
            <AuditTrail subject="payroll_period" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
