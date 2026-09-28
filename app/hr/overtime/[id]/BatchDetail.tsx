'use client'

// app/hr/overtime/[id]/BatchDetail.tsx
// OVERTIME-1:一张加班批的行与动作。
//
// 【钮的三种样子】(DBLOCK-1 的规矩:库一定会拒的动作,钮看得见、按不动、带着理由)
//   ① 缺码 → <PermissionGate>(说出缺的那个码);
//   ② 有码、但这一批此刻不是那个状态 → 那颗钮根本不属于这个状态,不画(草稿上没有"批准");
//   ③ 有码、状态也对,却轮不到你(你交的 / 批里有你)→ 按不动,旁边一行说为什么。
// 【小时】输入框 step 0.25,但库里的判据是 > 0、≤ 24、至多两位小数 —— 那一条住在库里,这里不复述。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import {
    addOvertimeLine, deleteOvertimeLine, submitOvertimeBatch, withdrawOvertimeBatch,
    discardOvertimeBatch, reverseOvertimeBatch, decideOvertimeBatch,
} from '../actions'

export type LineRow = {
    id: string
    employeeId: string
    employeeCode: string
    employeeName: string
    workDate: string
    /** 界面语言的日期(服务端 formatDate)—— workDate 本身是给机器的 YYYY-MM-DD */
    workDateLabel: string
    dayKind: string
    hours: number
    note: string | null
    voided: boolean
}

export type StaffOption = {
    id: string; code: string; name: string; hireDate: string; separationDate: string | null
}

export default function BatchDetail({
    batchId, label, status, rows, staff, dayOptions, canEnter, canApprove, iSubmitted, iAmInIt,
}: {
    batchId: string; label: string; periodMonth: string; status: string
    rows: LineRow[]; staff: StaffOption[]; dayOptions: { value: string; label: string }[]
    canEnter: boolean; canApprove: boolean; iSubmitted: boolean; iAmInIt: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()
    const [employeeId, setEmployeeId] = useState('')
    const [workDate, setWorkDate] = useState('')
    const [hours, setHours] = useState('')
    const [note, setNote] = useState('')

    const editable = status === 'draft' || status === 'rejected'

    const run = (fn: () => Promise<{ error?: string }>, after?: () => void) =>
        startTransition(async () => {
            setError(null)
            const res = await fn()
            if (res.error) { setError(res.error); return }
            after?.()
            router.refresh()
        })

    const live = rows.filter((r) => !r.voided)
    const totals = live.reduce(
        (acc, r) => ({ ...acc, [r.dayKind]: (acc[r.dayKind] ?? 0) + r.hours, all: acc.all + r.hours }),
        { all: 0 } as Record<string, number>,
    )

    const columns: Column<LineRow>[] = [
        { key: 'date', header: t('overtime.colDate'), priority: true, render: (r) => r.workDateLabel },
        {
            key: 'employee', header: t('overtime.colEmployee'), priority: true,
            render: (r) => (
                <>
                    <div>{r.employeeName}</div>
                    <div className="text-xs text-gray-500">{r.employeeCode}</div>
                </>
            ),
        },
        { key: 'dayKind', header: t('overtime.colDayKind'), render: (r) => t('overtime.dayKind_' + r.dayKind) },
        {
            key: 'hours', header: t('overtime.colHours'), align: 'right', priority: true,
            render: (r) => <span className={r.voided ? 'line-through text-gray-400' : ''}>{r.hours.toFixed(2)}</span>,
        },
        { key: 'note', header: t('overtime.colNote'), render: (r) => <span className="text-gray-600">{r.note ?? '—'}</span> },
        {
            key: 'actions', header: '', align: 'right',
            render: (r) => editable ? (
                <PermissionGate code="action.overtime_enter" allowed={canEnter} inline>
                    <Button variant="reversal" size="xs" type="button" disabled={pending}
                        onClick={() => run(() => deleteOvertimeLine(batchId, r.id))}>
                        {t('overtime.deleteLine')}
                    </Button>
                </PermissionGate>
            ) : r.voided ? (
                <span className="text-xs text-gray-500">{t('overtime.lineVoided')}</span>
            ) : null,
        },
    ]

    // 选中的那个人,这个月里哪几天在职 —— 只用来收窄日子下拉,判据仍在库里(OVERTIME_EMPLOYEE_NOT_ACTIVE)。
    //   YYYY-MM-DD 按字符串比就是按日期比。
    const chosen = staff.find((s) => s.id === employeeId)
    const days = dayOptions.filter((d) =>
        !chosen || (d.value >= chosen.hireDate && (!chosen.separationDate || d.value <= chosen.separationDate)))

    return (
        <>
            {error && <div role="alert" className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}

            <DataTable
                rows={rows}
                columns={columns}
                rowKey={(r) => r.id}
                phone={{ mode: 'columns' }}
                className="mb-2"
                empty={t('overtime.noLines')}
            />
            <p className="mb-5 text-sm text-[color:var(--brand-muted-text)]">
                {t('overtime.totals', {
                    all: (totals.all ?? 0).toFixed(2),
                    weekday: (totals.weekday ?? 0).toFixed(2),
                    rest: (totals.rest_day ?? 0).toFixed(2),
                    holiday: (totals.public_holiday ?? 0).toFixed(2),
                })}
            </p>

            {editable && (
                <div className="mb-6 rounded border bg-gray-50 px-4 py-3">
                    <h2 className="mb-2 text-base">{t('overtime.addLineTitle')}</h2>
                    <div className="flex flex-wrap items-end gap-3">
                        <label>
                            <span className="block text-[color:var(--brand-muted-text)] mb-1">{t('overtime.colEmployee')}</span>
                            <select value={employeeId} onChange={(e) => setEmployeeId(e.target.value)}
                                    disabled={!canEnter} className={CONTROL_SELECT}>
                                <option value="">{t('overtime.pickEmployee')}</option>
                                {staff.map((s) => (
                                    <option key={s.id} value={s.id}>{s.code} · {s.name}</option>
                                ))}
                            </select>
                        </label>
                        <label>
                            <span className="block text-[color:var(--brand-muted-text)] mb-1">{t('overtime.colDate')}</span>
                            <select value={workDate} onChange={(e) => setWorkDate(e.target.value)}
                                    disabled={!canEnter} className={CONTROL_SELECT}>
                                <option value="">{t('overtime.pickDay')}</option>
                                {days.map((d) => (
                                    <option key={d.value} value={d.value}>{d.label}</option>
                                ))}
                            </select>
                        </label>
                        <label>
                            <span className="block text-[color:var(--brand-muted-text)] mb-1">{t('overtime.colHours')}</span>
                            <input type="number" inputMode="decimal" step="0.25" min="0.25" max="24" value={hours}
                                   onChange={(e) => setHours(e.target.value)} disabled={!canEnter} className={`${CONTROL_INPUT} w-24`} />
                        </label>
                        <label className="flex-1 min-w-[12rem]">
                            <span className="block text-[color:var(--brand-muted-text)] mb-1">{t('overtime.colNoteOptional')}</span>
                            <input value={note} onChange={(e) => setNote(e.target.value)} disabled={!canEnter}
                                   className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <PermissionGate code="action.overtime_enter" allowed={canEnter} inline>
                            <Button type="button"
                                disabled={pending || employeeId === '' || workDate === '' || hours.trim() === ''}
                                onClick={() => run(() => addOvertimeLine(batchId, employeeId, workDate, hours, note), () => {
                                    setWorkDate(''); setHours(''); setNote('')
                                })}>
                                {t('overtime.addLine')}
                            </Button>
                        </PermissionGate>
                    </div>
                </div>
            )}

            <div className="flex flex-wrap items-start gap-3">
                {editable && (
                    <>
                        <PermissionGate code="action.overtime_enter" allowed={canEnter}>
                            <Button type="button" disabled={pending || live.length === 0}
                                onClick={() => run(() => submitOvertimeBatch(batchId))}>
                                {t('overtime.submit')}
                            </Button>
                        </PermissionGate>
                        <PermissionGate code="action.overtime_enter" allowed={canEnter}>
                            <ConfirmButton
                                subject={label}
                                title={t('overtime.discardTitle')}
                                body={t('overtime.discardBody')}
                                confirmLabel={t('overtime.discard')}
                                tier="destructive"
                                triggerVariant="destructive"
                                disabled={pending}
                                onConfirm={() => run(() => discardOvertimeBatch(batchId))}>
                                {t('overtime.discard')}
                            </ConfirmButton>
                        </PermissionGate>
                    </>
                )}

                {status === 'submitted' && (
                    <>
                        <PermissionGate code="action.overtime_approve" allowed={canApprove}>
                            <span className="inline-flex flex-col items-start gap-1">
                                <span className="inline-flex gap-2">
                                    <ConfirmButton
                                        subject={label}
                                        title={t('overtime.approveTitle')}
                                        body={t('overtime.approveBody', { n: live.length, hours: (totals.all ?? 0).toFixed(2) })}
                                        confirmLabel={t('overtime.approve')}
                                        tier="default"
                                        triggerVariant="default"
                                        disabled={pending || iSubmitted || iAmInIt}
                                        onConfirm={() => run(() => decideOvertimeBatch(batchId, 'approved', ''))}>
                                        {t('overtime.approve')}
                                    </ConfirmButton>
                                    <ConfirmButton
                                        subject={label}
                                        title={t('overtime.rejectTitle')}
                                        body={t('overtime.rejectBody')}
                                        confirmLabel={t('overtime.reject')}
                                        tier="reversal"
                                        triggerVariant="reversal"
                                        reason={{ placeholder: t('overtime.rejectPlaceholder') }}
                                        disabled={pending || iSubmitted || iAmInIt}
                                        onConfirm={(reason) => run(() => decideOvertimeBatch(batchId, 'rejected', reason))}>
                                        {t('overtime.reject')}
                                    </ConfirmButton>
                                </span>
                                {canApprove && (iSubmitted || iAmInIt) && (
                                    <span className="text-xs text-[color:var(--brand-muted-text)] max-w-md">
                                        {iSubmitted ? t('overtime.cannotDecideOwnSubmission') : t('overtime.cannotDecideOwnHours')}
                                    </span>
                                )}
                            </span>
                        </PermissionGate>
                        <PermissionGate code="action.overtime_enter" allowed={canEnter}>
                            <ConfirmButton
                                subject={label}
                                title={t('overtime.withdrawTitle')}
                                body={t('overtime.withdrawBody')}
                                confirmLabel={t('overtime.withdraw')}
                                tier="reversal"
                                triggerVariant="secondary"
                                disabled={pending}
                                onConfirm={() => run(() => withdrawOvertimeBatch(batchId))}>
                                {t('overtime.withdraw')}
                            </ConfirmButton>
                        </PermissionGate>
                    </>
                )}

                {status === 'approved' && (
                    <PermissionGate code="action.overtime_enter" allowed={canEnter}>
                        <span className="inline-flex flex-col items-start gap-1">
                            <ConfirmButton
                                subject={label}
                                title={t('overtime.reverseTitle')}
                                body={t('overtime.reverseBody')}
                                confirmLabel={t('overtime.reverse')}
                                tier="reversal"
                                triggerVariant="reversal"
                                reason={{ placeholder: t('overtime.reversePlaceholder') }}
                                disabled={pending}
                                onConfirm={(reason) => run(() => reverseOvertimeBatch(batchId, reason))}>
                                {t('overtime.reverse')}
                            </ConfirmButton>
                            <span className="text-xs text-[color:var(--brand-muted-text)] max-w-md">{t('overtime.reverseHint')}</span>
                        </span>
                    </PermissionGate>
                )}
            </div>
        </>
    )
}
