'use client'

// 过账 / 撤销过账 —— ★ PAYROLL-APR-1(Tim 的矩阵 §5,2026-09-24)起,两件事都要先经 CFO 批准:
//   财务提申请 → CFO 批 / 驳 → 财务执行(过账 / 撤销过账)。批之前什么都不进总账。
//
// 【谁能批,这里不预判】二级审批角色、而且不是提单人(按人认)—— 两条都只有数据库知道
// (decide_payroll_request → require_approver_for(2) + forbid_self_approval)。与付款申请的
// RequestActions 同一条:钮亮着,拒绝由库出,就地说成人话。
// 【权限码的那一半看得见、按不动、带理由】(DBLOCK-1)—— 提 / 撤回 / 执行要 module.hr.edit;
// 批 / 驳要 data.view_pay(能进这一页的人已经持有 module.hr.view,那是门的另一半)。
//
// 【本期含你自己的工资行】工资期是公司的单据(Tim 的 Q1 (A)):主角那条腿对谁都不成立,所以 CFO
// 批一期含他自己工资行的工资是允许的 —— 这一页把它说出来,留痕的备注也记下它。
//
// ★ 过账预览的第五行从【银行】改成了 2300 应付净薪:FIN-4 起过账不碰银行(净额挂 2300,逐人付款时
//   才贷银行),这一行此前一直在说一件过账并不做的事。
// ★ AUDIT-TRAIL-1d-3(Tim 的 Q27):这一块下面原来那一段"以往的申请"(每一张了结的申请:状态 · 时刻 · 决定的说明)是一段
//   纯粹的决定史 —— 换成页底的审计记录(谁、何时、送审 / 批准 / 驳回 / 撤回 / 执行,理由在同一句里)。
//   挂着的那一张申请与过账 / 撤销的按钮是【控制】,留着(与 1c-1 的发票申请同一个裁定)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { Refusal } from '@/app/components/ui/refusal'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAmount, businessToday } from '@/lib/format'
import { DatePicker } from '@/app/components/ui/date-picker'
import {
    submitPayrollRequest,
    decidePayrollRequest,
    withdrawPayrollRequest,
    postPayroll,
    unpostPayroll,
    reversePayrollPayment,
} from '../actions'

export type PayrollRequestView = {
    id: string
    label: string
    kind: 'post' | 'reversal' | 'payment_reversal'
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn' | 'executed'
    notes: string | null
    decisionNotes: string | null
    createdText: string
    /** ★ PAYROLL-PAY-REVERSAL-1:payment_reversal 冲的那一张付款分录 */
    targetEntryId: string | null
    /** 那一次付款(付薪页同一支读者答的):编号 · 种类 · 金额(受限为 null)· 日期 · 银行行配在哪张对账单(没配为 null) */
    target: { code: string; kind: 'salary' | 'cpf' | 'deductions'; amount: number | null; entryDate: string; bankStatement: string | null } | null
}

export function PayrollRequestPanel({
    periodId,
    subject,
    isPosted,
    currency,
    totals,
    open,
    canRaise,
    canDecide,
    ownLineCode,
}: {
    periodId: string
    /** CONFIRM-1:动的是【哪一个期间】。 */
    subject: string
    isPosted: boolean
    currency: string
    /** U1-A(UNBLOCK-1 Q9):不持 data.view_pay 的人是 null(payroll_periods_masked)—— 过账预览印「受限」,不印 0.00 */
    totals: { gross: number | null; employerCpf: number | null; employeeCpf: number | null; other: number | null; net: number | null }
    open: PayrollRequestView | null
    canRaise: boolean
    canDecide: boolean
    /** 看这一页的人自己在本期里有没有工资行 —— 有就是他的员工编号。 */
    ownLineCode: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    // ★ PAYROLL-PAY-REVERSAL-1(Tim Q3):冲销日由执行的人给、必填、不默认 —— 空着(或敲错)执行钮按不下去,动作层与库各自再拒一次
    const [revDate, setRevDate] = useState('')
    const [revDateBad, setRevDateBad] = useState(false)

    function run(headline: string, fn: () => Promise<{ error?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline, body: r.error })
                return
            }
            router.refresh()
        })
    }

    // 一个数受限,整张预览就受限(五个数是同一组合计的五种拆法)
    const restricted = totals.gross === null || totals.employerCpf === null || totals.employeeCpf === null
        || totals.other === null || totals.net === null
    const amt = (sign: string, v: number | null) => (restricted || v === null ? null : `${sign}${formatAmount(v, currency)}`)
    const postingLines = [
        { acct: '6100', name: t('hr.acct6100'), amount: amt('+', totals.gross) },
        { acct: '6110', name: t('hr.acct6110'), amount: amt('+', totals.employerCpf) },
        { acct: '2400', name: t('hr.acct2400'), amount: amt('−', (totals.employerCpf ?? 0) + (totals.employeeCpf ?? 0)) },
        { acct: '2200', name: t('hr.acct2200'), amount: amt('−', totals.other) },
        { acct: '2300', name: t('hr.acct2300'), amount: amt('−', totals.net) },
    ]
    const postingTable = (
        <dl className="divide-y divide-[color:var(--brand-border)] rounded border border-[color:var(--brand-border)]">
            {postingLines.map((l) => (
                <div key={l.acct} className="flex items-baseline justify-between gap-4 px-3 py-1.5 text-sm">
                    <dt className="text-[color:var(--brand-muted-text)]">
                        <span>{l.acct}</span> {l.name}
                    </dt>
                    <dd className="whitespace-nowrap">{l.amount ?? <Refusal>{t('common.restricted')}</Refusal>}</dd>
                </div>
            ))}
        </dl>
    )
    const notDone = t('common.actionMessage.headline.notDecided')

    return (
        <section className="space-y-4 mt-6" aria-label={t('hr.payrollRequest.title')}>
            <h2>{t('hr.payrollRequest.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('hr.payrollRequest.intro')}</p>

            {/* ── 没有未了结的申请:提一张 ─────────────────────────────────── */}
            {!open && (
                <PermissionGate code="module.hr.edit" allowed={canRaise}>
                    {!isPosted ? (
                        <ConfirmButton
                            subject={subject}
                            title={t('hr.payrollRequest.requestPostConfirm')}
                            body={t('hr.payrollRequest.requestPostBody')}
                            details={postingTable}
                            confirmLabel={t('hr.payrollRequest.requestPost')}
                            tier="default"
                            triggerVariant="default"
                            disabled={pending}
                            onConfirm={() => run(notDone, () => submitPayrollRequest(periodId, 'post', ''))}
                        >
                            {pending ? t('common.saving') : t('hr.payrollRequest.requestPost')}
                        </ConfirmButton>
                    ) : (
                        <ConfirmButton
                            subject={subject}
                            title={t('hr.payrollRequest.requestReversalConfirm')}
                            body={t('hr.payrollRequest.requestReversalBody')}
                            confirmLabel={t('hr.payrollRequest.requestReversal')}
                            tier="reversal"
                            triggerVariant="reversal"
                            reason={{ placeholder: t('hr.payrollRequest.reasonPlaceholder') }}
                            disabled={pending}
                            onConfirm={(reason) => run(notDone, () => submitPayrollRequest(periodId, 'reversal', reason))}
                        >
                            {pending ? t('common.saving') : t('hr.payrollRequest.requestReversal')}
                        </ConfirmButton>
                    )}
                </PermissionGate>
            )}

            {/* ── 一张未了结的申请 ─────────────────────────────────────────── */}
            {open && (
                <div
                    className={
                        'rounded border p-4 space-y-3 ' +
                        (open.status === 'submitted' ? 'border-amber-300 bg-amber-50' : 'border-blue-300 bg-blue-50')
                    }
                >
                    <h3>
                        {open.status === 'submitted' ? t('hr.payrollRequest.openTitle') : t('hr.payrollRequest.approvedTitle')}
                    </h3>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('hr.payrollRequest.label')}</dt>
                        <dd>
                            {t('hr.payrollRequest.kind.' + open.kind)} · <span className="font-mono">{open.label}</span> · {open.createdText}
                        </dd>
                        {open.kind === 'payment_reversal' && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('hr.payrollRequest.payment')}</dt>
                                <dd>
                                    {open.target ? (
                                        <>
                                            <span className="font-mono">{open.target.code}</span> · {t('finance.payrollPay.paymentKind.' + open.target.kind)}
                                            {' · '}{open.target.entryDate}{' · '}
                                            {open.target.amount === null ? <Refusal>{t('common.restricted')}</Refusal> : formatAmount(open.target.amount, currency)}
                                        </>
                                    ) : t('hr.payrollRequest.paymentGone')}
                                </dd>
                            </>
                        )}
                        {open.notes && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('hr.payrollRequest.reason')}</dt>
                                <dd className="whitespace-pre-line">{open.notes}</dd>
                            </>
                        )}
                        {open.decisionNotes && (
                            <>
                                <dt className="text-[color:var(--brand-muted-text)]">{t('hr.payrollRequest.decisionNotes')}</dt>
                                <dd className="whitespace-pre-line">{open.decisionNotes}</dd>
                            </>
                        )}
                    </dl>

                    {open.status === 'submitted' && (
                        <>
                            {ownLineCode && (
                                <p className="text-sm border-l-4 border-amber-500 pl-3" data-own-pay-line={ownLineCode}>
                                    {t('hr.payrollRequest.ownLine')}
                                </p>
                            )}
                            <p className="text-xs text-[color:var(--brand-text)]">{t('hr.payrollRequest.decideHint')}</p>
                            <PermissionGate code="data.view_pay" allowed={canDecide}>
                                <div className="flex flex-wrap items-start gap-3">
                                    <ConfirmButton
                                        subject={`${subject} · ${open.label}`}
                                        title={t('hr.payrollRequest.approveConfirm')}
                                        body={t('hr.payrollRequest.approveBody')}
                                        details={open.kind === 'post' ? postingTable : undefined}
                                        confirmLabel={t('hr.payrollRequest.approve')}
                                        tier="default"
                                        triggerVariant="default"
                                        disabled={pending}
                                        onConfirm={() => run(notDone, () => decidePayrollRequest(periodId, open.id, true, ''))}
                                    >
                                        {pending ? t('common.saving') : t('hr.payrollRequest.approve')}
                                    </ConfirmButton>
                                    <ConfirmButton
                                        subject={`${subject} · ${open.label}`}
                                        title={t('hr.payrollRequest.rejectConfirm')}
                                        body={t('hr.payrollRequest.rejectBody')}
                                        confirmLabel={t('hr.payrollRequest.reject')}
                                        tier="destructive"
                                        triggerVariant="destructive"
                                        reason={{ placeholder: t('hr.payrollRequest.rejectPlaceholder') }}
                                        disabled={pending}
                                        onConfirm={(reason) => run(notDone, () => decidePayrollRequest(periodId, open.id, false, reason))}
                                    >
                                        {t('hr.payrollRequest.reject')}
                                    </ConfirmButton>
                                </div>
                            </PermissionGate>
                        </>
                    )}

                    {open.status === 'approved' && open.kind === 'payment_reversal' && (
                        <PermissionGate code="module.hr.edit" allowed={canRaise}>
                            <div className="flex flex-wrap items-start gap-3">
                                <label className="block text-sm">
                                    {t('hr.payrollRequest.reversalDate')} <span className="text-red-600">*</span>
                                    {/* FIN-CHAIN-1 的规矩:钱回来是已经发生的事 —— 晚于今天服务端按名拒,框也不给选 */}
                                    <DatePicker value={revDate} required aria-invalid={revDate === ''} max={businessToday()}
                                                onChange={setRevDate} onInvalidChange={setRevDateBad} className="flex" />
                                    <span className="mt-1 block max-w-md text-xs text-[color:var(--brand-muted-text)]">{t('hr.payrollRequest.reversalDateHint')}</span>
                                </label>
                                <ConfirmButton
                                    subject={`${subject} · ${open.target?.code ?? open.label}`}
                                    title={t('hr.payrollRequest.executePaymentReversalConfirm')}
                                    body={t('hr.payrollRequest.executePaymentReversalBody', { date: revDate })}
                                    confirmLabel={t('hr.payrollRequest.executePaymentReversal')}
                                    tier="reversal"
                                    triggerVariant="reversal"
                                    disabled={pending || revDate === '' || revDateBad || !!open.target?.bankStatement}
                                    onConfirm={() => run(notDone, () => reversePayrollPayment(periodId, open.id, revDate))}
                                >
                                    {pending ? t('common.saving') : t('hr.payrollRequest.executePaymentReversal')}
                                </ConfirmButton>
                            </div>
                            {open.target?.bankStatement && (
                                <p className="text-xs text-[color:var(--brand-text)]">
                                    {t('finance.payrollPay.bankMatched', { statement: open.target.bankStatement })}
                                </p>
                            )}
                        </PermissionGate>
                    )}

                    {open.status === 'approved' && open.kind !== 'payment_reversal' && (
                        <PermissionGate code="module.hr.edit" allowed={canRaise}>
                            {open.kind === 'post' ? (
                                <ConfirmButton
                                    subject={subject}
                                    title={t('hr.payrollRequest.executePostConfirm')}
                                    details={postingTable}
                                    confirmLabel={t('hr.payrollRequest.executePost')}
                                    tier="destructive"
                                    triggerVariant="default"
                                    disabled={pending}
                                    onConfirm={() => run(notDone, () => postPayroll(periodId))}
                                >
                                    {pending ? t('common.saving') : t('hr.payrollRequest.executePost')}
                                </ConfirmButton>
                            ) : (
                                <ConfirmButton
                                    subject={subject}
                                    title={t('hr.payrollRequest.executeUnpostConfirm')}
                                    body={t('hr.payrollRequest.executeUnpostBody')}
                                    confirmLabel={t('hr.payrollRequest.executeUnpost')}
                                    tier="reversal"
                                    triggerVariant="reversal"
                                    disabled={pending}
                                    onConfirm={() => run(notDone, () => unpostPayroll(periodId))}
                                >
                                    {pending ? t('common.saving') : t('hr.payrollRequest.executeUnpost')}
                                </ConfirmButton>
                            )}
                        </PermissionGate>
                    )}

                    <PermissionGate code="module.hr.edit" allowed={canRaise}>
                        <ConfirmButton
                            subject={`${subject} · ${open.label}`}
                            title={t('hr.payrollRequest.withdrawConfirm')}
                            body={t('hr.payrollRequest.withdrawBody')}
                            confirmLabel={t('hr.payrollRequest.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(notDone, () => withdrawPayrollRequest(periodId, open.id))}
                        >
                            {t('hr.payrollRequest.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            )}

        </section>
    )
}
