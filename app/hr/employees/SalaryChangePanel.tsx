'use client'

// app/hr/employees/SalaryChangePanel.tsx
// ★ APR-9(Tim 2026-09-27,grilling Q2–Q6):调薪申请 —— 财务提,CFO 批;CFO 这个人是提单人或主角时 cco 批。
//   批准之前月薪一分不动;批准那一刻写月薪与一行带生效日的履历。
//
// 这一块画三样东西:
//   ① 提一张申请的表单(新月薪、从哪个工资月起、理由)。门:module.hr.edit + data.view_pay(第一份月薪那扇门的
//      同一对码)。★ 给自己提 → 看得见、按不动、说出为什么(不是权限答复,是规矩,所以不走 PermissionGate)。
//      已有一张在等的调薪 → 同样按不动,并指向下面那一张。
//   ② 在等的那一张(看板 salary_change_pending 指到 #salary-requests):旧 → 新、生效月、理由、谁提的;
//      谁批(CFO / cco —— decided_via 由库按人算好);批准 / 驳回(要理由)/ 撤回。
//      ★ 读者此刻为什么批不了,由库说(decide_block),这里不在 TypeScript 里重算这条规矩:
//        NEEDS_CODE|<码> → PermissionGate 点名那个码;SELF|raiser / SELF|subject → 一句规矩。
//      起点变了(current_matches = false)→ 先说出来:批准会被 SALARY_CHANGED_SINCE_REQUEST 拒。
//   ③ 最近了结的几张。
//
// 【生效日为什么是一张月份下拉】与第一份月薪同一条理由(InitialSalaryForm 抬头):check-date-format 不许新的
//   原生日期框;工资按整月算,落不落得下也是按月判 —— 取那个月的 1 号。不给默认值:空着就按不动。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { formatAmount } from '@/lib/format'
import { submitSalaryChange, decideSalaryChange, withdrawSalaryChange } from './salaryChangeActions'

export type SalaryChangeView = {
    id: string
    status: 'submitted' | 'approved' | 'rejected' | 'withdrawn'
    label: string
    oldSalary: number
    newSalary: number
    effectiveText: string
    reason: string
    currentMatches: boolean
    createdText: string
    raisedBy: string | null
    raisedByMe: boolean
    decidedBy: string | null
    decidedVia: string | null
    decisionNotes: string | null
    withdrawReason: string | null
    /** 这一张要哪一个码才批得了(action.approve_review = CFO;action.hr_reviews = cco) */
    decideCode: string
    /** NULL = 读者批得了;'NEEDS_CODE|<码>' · 'SELF|raiser' · 'SELF|subject' */
    decideBlock: string | null
}

export default function SalaryChangePanel({
    employeeId, currency, currentSalary, months, canRaise, isOwn, open,
}: {
    employeeId: string
    currency: string
    currentSalary: number
    months: { value: string; label: string }[]
    /** module.hr.edit 且 data.view_pay —— 提单与撤回的那一对码 */
    canRaise: boolean
    /** 读者就是这个人(按人认)—— 谁都不能给自己提调薪 */
    isOwn: boolean
    open: SalaryChangeView[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [amount, setAmount] = useState('')
    const [effective, setEffective] = useState('')
    const [reason, setReason] = useState('')
    const [error, setError] = useState<string | null>(null)
    const notDone = t('common.actionMessage.headline.notDecided')

    const money = (v: number) => formatAmount(v, currency)
    const ready = amount.trim() !== '' && effective !== '' && reason.trim() !== ''
    // 【不是权限的那两条拒绝】各说各的话,不塞进同一个 disabled
    const ruleWhy = isOwn ? t('salaryChange.ownRefused')
        : open.length > 0 ? t('salaryChange.alreadyOpen', { label: open[0].label })
        : ''

    function run(subject: string, fn: () => Promise<{ error?: string; detail?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline: notDone, body: r.error, detail: r.detail })
                return
            }
            router.refresh()
        })
    }

    const blockText = (b: string) => b.startsWith('SELF|')
        ? t('salaryChange.selfBlock.' + (b.split('|')[1] === 'subject' ? 'subject' : 'raiser'))
        : ''

    return (
        <section id="salary-requests" className="mb-6 space-y-3 scroll-mt-24" aria-label={t('salaryChange.title')}>
            <h3>{t('salaryChange.title')}</h3>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('salaryChange.hint')}</p>

            {/* ① 提一张 */}
            <PermissionGate code="module.hr.edit" allowed={canRaise} className="flex w-full items-stretch">
                <div className="w-full rounded border border-gray-200 p-3 space-y-2">
                    {error && (
                        <div className="rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
                    )}
                    <div className="flex flex-wrap gap-3 items-end">
                        <label className="block">
                            {t('salaryChange.newSalary', { ccy: currency })}
                            <input type="number" min="0" step="0.01" value={amount}
                                   onChange={(e) => setAmount(e.target.value)}
                                   disabled={ruleWhy !== ''}
                                   className={`${CONTROL_INPUT} mt-1 block w-40 text-right tabular-nums`} />
                        </label>
                        <label className="block">
                            {t('salaryChange.effectiveMonth')}
                            <select value={effective} onChange={(e) => setEffective(e.target.value)}
                                    disabled={ruleWhy !== ''}
                                    className={`${CONTROL_SELECT} mt-1 block`}>
                                <option value="">{t('hr.initialSalary.pickMonth')}</option>
                                {months.map((m) => <option key={m.value} value={m.value}>{m.label}</option>)}
                            </select>
                        </label>
                        <label className="block grow min-w-0">
                            {t('salaryChange.reason')}
                            <input type="text" value={reason} onChange={(e) => setReason(e.target.value)}
                                   disabled={ruleWhy !== ''}
                                   className={`${CONTROL_INPUT} mt-1 block w-full`} />
                        </label>
                        <Button type="button" disabled={pending || !ready || ruleWhy !== ''}
                                onClick={() => start(async () => {
                                    setError(null)
                                    const r = await submitSalaryChange(employeeId, amount, effective, reason)
                                    if (r.error) { setError(r.error); return }
                                    setAmount(''); setEffective(''); setReason('')
                                    router.refresh()
                                })}>
                            {pending ? t('common.saving') : t('salaryChange.submit')}
                        </Button>
                    </div>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">
                        {t('salaryChange.current', { amount: money(currentSalary) })}
                    </p>
                    {ruleWhy !== '' && <p className="text-xs text-amber-700">{ruleWhy}</p>}
                    {ruleWhy === '' && !ready && (
                        <p className="text-xs text-amber-700">{t('salaryChange.allRequired')}</p>
                    )}
                </div>
            </PermissionGate>

            {/* ② 在等的那一张 */}
            {open.map((r) => (
                <div key={r.id} className="rounded border border-amber-300 bg-amber-50 p-4 space-y-3"
                     data-salary-change-request={r.label}>
                    <h4>{t('salaryChange.openTitle')}</h4>
                    <dl className="text-sm grid grid-cols-[max-content_1fr] gap-x-4 gap-y-1">
                        <dt className="text-[color:var(--brand-muted-text)]">{t('salaryChange.request')}</dt>
                        <dd>
                            <span className="font-mono">{r.label}</span> · {r.createdText}
                            {r.raisedBy && <> · {t('salaryChange.raisedBy', { who: r.raisedBy })}</>}
                        </dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('salaryChange.change')}</dt>
                        <dd className="tabular-nums">{money(r.oldSalary)} → {money(r.newSalary)}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('salaryChange.effectiveMonth')}</dt>
                        <dd>{r.effectiveText}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('salaryChange.reason')}</dt>
                        <dd className="whitespace-pre-line">{r.reason}</dd>
                        <dt className="text-[color:var(--brand-muted-text)]">{t('salaryChange.decider')}</dt>
                        <dd>{t('salaryChange.via.' + (r.decideCode === 'action.hr_reviews' ? 'cco' : 'cfo'))}</dd>
                    </dl>
                    {!r.currentMatches && (
                        <p className="text-sm font-medium text-red-700">{t('salaryChange.changedSince')}</p>
                    )}
                    <p className="text-xs text-[color:var(--brand-text)]">{t('salaryChange.decideHint')}</p>

                    <PermissionGate code={r.decideBlock?.startsWith('NEEDS_CODE|') ? r.decideBlock.split('|')[1] : r.decideCode}
                                    allowed={!r.decideBlock?.startsWith('NEEDS_CODE|')}>
                        <div className="flex flex-wrap items-start gap-3">
                            <ConfirmButton
                                subject={r.label}
                                title={t('salaryChange.approveConfirm')}
                                body={t('salaryChange.approveBody', { from: money(r.oldSalary), to: money(r.newSalary), month: r.effectiveText })}
                                confirmLabel={t('salaryChange.approve')}
                                tier="destructive"
                                triggerVariant="default"
                                disabled={pending || !!r.decideBlock}
                                onConfirm={() => run(r.label, () => decideSalaryChange(employeeId, r.id, true, ''))}
                            >
                                {pending ? t('common.saving') : t('salaryChange.approve')}
                            </ConfirmButton>
                            <ConfirmButton
                                subject={r.label}
                                title={t('salaryChange.rejectConfirm')}
                                body={t('salaryChange.rejectBody')}
                                confirmLabel={t('salaryChange.reject')}
                                tier="destructive"
                                triggerVariant="destructive"
                                reason={{ placeholder: t('salaryChange.rejectPlaceholder') }}
                                disabled={pending || !!r.decideBlock}
                                onConfirm={(why) => run(r.label, () => decideSalaryChange(employeeId, r.id, false, why))}
                            >
                                {t('salaryChange.reject')}
                            </ConfirmButton>
                        </div>
                    </PermissionGate>
                    {r.decideBlock?.startsWith('SELF|') && (
                        <p className="text-xs text-amber-700">{blockText(r.decideBlock)}</p>
                    )}

                    <PermissionGate code="module.hr.edit" allowed={r.raisedByMe || canRaise}>
                        <ConfirmButton
                            subject={r.label}
                            title={t('salaryChange.withdrawConfirm')}
                            body={t('salaryChange.withdrawBody')}
                            confirmLabel={t('salaryChange.withdraw')}
                            tier="reversal"
                            triggerVariant="outline"
                            disabled={pending}
                            onConfirm={() => run(r.label, () => withdrawSalaryChange(employeeId, r.id))}
                        >
                            {t('salaryChange.withdraw')}
                        </ConfirmButton>
                    </PermissionGate>
                </div>
            ))}

            {/* ③ AUDIT-TRAIL-1d-1(Tim 的 Q27):"最近了结的几张"那一段换成了页底的审计记录 —— 它是一份纯粹的决定史
                (批了 / 驳了 / 撤了,谁、为什么),审计记录说同样的事、加上是谁提出的,并且不止最近五张。
                在途那几张(上面 ②)是这块面板的控件,照旧 */}
        </section>
    )
}
