'use client'

// app/safety/inspections/[id]/FindingsPanel.tsx
// MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q14 · Q15,Tim):一次巡检的发现 —— 每一条:那一项、纠正措施、负责的人、人选的到期日(可空)、
//   它那张任务的编号、关闭了没有。
//   · 记一条发现:挂在一项【不合格】上(module.safety.edit);一次已经被更正过的巡检不再收新发现(库按名拒;这里不画那张表单)。
//   · 关闭:写下做了什么(module.safety.edit),只关一次。
//   · "建一张任务"(Q14):给【按下的人】建一张私人任务(任务模块自己的规矩:要有员工档案、要有任务的码);按完说出任务编号。
//     ★ 关掉那张任务不关闭这条发现 —— 这一格上照直写着。
//   · 开一张不合格报告(Q15):一条发现说的是一批货时,持 module.quality.edit 的人从这里去开 —— 来源 inspection、引用这条发现,
//     那一批进质量暂扣。
//   缺码的控件看得见、按不动、说出码(DBLOCK-1)。
import Link from 'next/link'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { recordInspectionFinding, closeInspectionFinding, raiseInspectionFindingTask } from '../../actions'

type Opt = { id: string; label: string }
export type FindingRow = {
    id: string; position: number; itemText: string; correctiveAction: string; owner: string; due: string | null; overdue: boolean
    taskCode: string | null; open: boolean; closedAt: string | null; whatWasDone: string | null; ncrCount: number
}
export type FailRow = { position: number; text: string; note: string }

export default function FindingsPanel({ runId, findings, fails, people, canEdit, canQualityEdit, canRaiseTask, superseded }: {
    runId: string
    findings: FindingRow[]
    fails: FailRow[]
    people: Opt[]
    canEdit: boolean
    canQualityEdit: boolean
    canRaiseTask: boolean
    superseded: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [notice, setNotice] = useState('')
    const [pos, setPos] = useState(fails.length === 1 ? String(fails[0].position) : '')
    const [action, setAction] = useState(''); const [owner, setOwner] = useState(''); const [due, setDue] = useState('')
    const [closing, setClosing] = useState<string | null>(null); const [done, setDone] = useState('')

    function run(fn: () => Promise<{ error?: string; taskCode?: string }>, after: (r: { taskCode?: string }) => void) {
        setError(''); setNotice('')
        startTransition(async () => {
            const res = await fn()
            if (res?.error) { setError(res.error); return }
            after(res)
            router.refresh()
        })
    }

    return (
        <section className="mt-8" data-section="findings">
            <h2 className="mb-1">{t('safety.findings.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('safety.findings.hint')}</p>
            {error && <p className="text-sm text-red-600 mb-2" data-error="finding">{error}</p>}
            {notice && <p className="text-sm text-green-700 mb-2" data-notice="finding">{notice}</p>}
            {findings.length === 0 ? <p className="text-sm text-[color:var(--brand-muted-text)]">{t('safety.findings.none')}</p> : (
                <ul className="space-y-3">
                    {findings.map((f) => (
                        <li key={f.id} id={`finding-${f.id}`} className="border border-gray-200 rounded px-3 py-2 text-sm space-y-1" data-finding={f.id}>
                            <p className="font-medium">{`${f.position}. ${f.itemText}`}</p>
                            <p>{t('safety.findings.correctiveAction')}: {f.correctiveAction}</p>
                            <p className="text-[color:var(--brand-muted-text)]">
                                {t('safety.findings.owner')}: {f.owner}{' · '}{t('safety.findings.dueDate')}: {f.due ?? t('safety.findings.noDue')}
                                {f.overdue && <span className="ml-1 text-amber-800" data-flag="overdue">{t('safety.findings.overdue')}</span>}
                            </p>
                            <p data-value="finding-state">
                                {f.open ? <span className="px-2 py-0.5 rounded text-xs bg-amber-100">{t('safety.findings.open')}</span>
                                    : <span className="px-2 py-0.5 rounded text-xs bg-gray-200">{t('safety.findings.closed', { date: f.closedAt ?? '' })}</span>}
                                {f.taskCode && <span className="ml-2 text-xs">{t('safety.findings.taskLinked', { code: f.taskCode })}</span>}
                                {f.ncrCount > 0 && <span className="ml-2 text-xs">{t('safety.findings.ncrCount', { n: String(f.ncrCount) })}</span>}
                            </p>
                            {!f.open && f.whatWasDone && <p>{t('safety.findings.whatWasDone')}: {f.whatWasDone}</p>}
                            {f.open && (
                                <div className="flex flex-wrap items-center gap-2 pt-1">
                                    {f.taskCode ? null : (
                                        <PermissionGate code="module.tasks.view" allowed={canRaiseTask}>
                                            <Button type="button" variant="outline" size="sm" disabled={isPending}
                                                    onClick={() => run(() => raiseInspectionFindingTask(runId, f.id),
                                                        (r) => setNotice(t('safety.findings.taskRaised', { code: r.taskCode ?? '' })))}>
                                                {t('safety.findings.raiseTask')}
                                            </Button>
                                        </PermissionGate>
                                    )}
                                    <PermissionGate code="module.safety.edit" allowed={canEdit}>
                                        <Button type="button" variant="outline" size="sm" disabled={isPending}
                                                onClick={() => { setClosing(closing === f.id ? null : f.id); setDone('') }}>{t('safety.findings.close')}</Button>
                                    </PermissionGate>
                                    <PermissionGate code="module.quality.edit" allowed={canQualityEdit}>
                                        {canQualityEdit
                                            ? <Button asChild variant="outline" size="sm"><Link href={`/quality/ncr/new?finding=${f.id}`}>{t('safety.findings.openNcr')}</Link></Button>
                                            : <Button type="button" variant="outline" size="sm" disabled>{t('safety.findings.openNcr')}</Button>}
                                    </PermissionGate>
                                </div>
                            )}
                            {f.open && f.taskCode && <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.findings.taskNotFinding')}</p>}
                            {closing === f.id && (
                                <div className="flex flex-wrap items-end gap-2 pt-1" data-form="close-finding">
                                    <label className="block min-w-0 flex-1 basis-64">
                                        <span className="block mb-1">{t('safety.findings.whatWasDone')} <span className="text-red-600">*</span></span>
                                        <input type="text" value={done} onChange={(e) => setDone(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                                    </label>
                                    <Button type="button" disabled={isPending || done.trim() === ''}
                                            onClick={() => run(() => closeInspectionFinding(runId, f.id, done), () => { setClosing(null); setDone('') })}>
                                        {t('safety.findings.closeConfirm')}
                                    </Button>
                                    <Button type="button" variant="ghost" onClick={() => setClosing(null)}>{t('common.cancel')}</Button>
                                </div>
                            )}
                        </li>
                    ))}
                </ul>
            )}
            {fails.length > 0 && !superseded && (
                <PermissionGate code="module.safety.edit" allowed={canEdit}>
                    <div className="space-y-3 mt-4 max-w-3xl text-sm" data-form="record-finding">
                        <h3 className="font-medium">{t('safety.findings.recordTitle')}</h3>
                        <div className="flex flex-wrap gap-3">
                            <label className="block min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('safety.findings.item')} <span className="text-red-600">*</span></span>
                                <select value={pos} onChange={(e) => setPos(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="position">
                                    <option value="" disabled>{t('safety.findings.pickItem')}</option>
                                    {fails.map((x) => <option key={x.position} value={String(x.position)}>{`${x.position}. ${x.text}`}</option>)}
                                </select>
                            </label>
                            <label className="block min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('safety.findings.owner')} <span className="text-red-600">*</span></span>
                                <select value={owner} onChange={(e) => setOwner(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="owner_employee_id">
                                    <option value="" disabled>{t('safety.findings.pickOwner')}</option>
                                    {people.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                                </select>
                            </label>
                        </div>
                        <label className="block">
                            <span className="block mb-1">{t('safety.findings.correctiveAction')} <span className="text-red-600">*</span></span>
                            <input type="text" value={action} onChange={(e) => setAction(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="corrective_action" />
                        </label>
                        <div className="block">
                            <span className="block mb-1">{t('safety.findings.dueDate')}</span>
                            <DatePicker kind="date" value={due} onChange={setDue} />
                            <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('safety.findings.dueHint')}</span>
                        </div>
                        <Button type="button" disabled={isPending || pos === '' || owner === '' || action.trim() === ''}
                                onClick={() => run(() => recordInspectionFinding(runId, { position: Number(pos), correctiveAction: action, ownerEmployeeId: owner, dueDate: due }),
                                    () => { setAction(''); setOwner(''); setDue('') })}>
                            {t('safety.findings.save')}
                        </Button>
                    </div>
                </PermissionGate>
            )}
            {superseded && fails.length > 0 && <p className="text-xs text-[color:var(--brand-muted-text)] mt-3">{t('safety.findings.supersededHint')}</p>}
        </section>
    )
}
