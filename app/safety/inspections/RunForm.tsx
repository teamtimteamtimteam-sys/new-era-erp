'use client'

// app/safety/inspections/RunForm.tsx
// MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13 · Q14,Tim):交一次巡检 —— 照一张清单,每一项一个结果(合格 · 不合格 · 不适用),
//   不合格的那一项写一句说明,并且可以当场记一条发现(纠正措施、负责的人、人选的到期日 —— 可空,没有默认);巡检的人、时刻必填,
//   库位与机器可选。更正一次巡检时(?corrects=)要写理由。一次交完(record_inspection_run),交了就不改。
//   必填没填时交不下去,服务端【独立】按名拒。缺 module.safety.edit 时整张表单在 PermissionGate 里,看得见、按不动、说出那个码。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA, CONTROL_RADIO, CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { recordInspectionRun } from '../actions'
import { INSPECTION_RESULTS, inspectionResultKey } from '../safetyTypes'

type Opt = { id: string; label: string }
type Item = { position: number; text: string }
type Answer = { result: string; note: string; finding: boolean; action: string; owner: string; due: string }

export default function RunForm({ templateId, items, people, locations, machines, processingRestricted, correctsRunId, correctsRunCode, canEdit }: {
    templateId: string
    items: Item[]
    people: Opt[]
    locations: Opt[]
    machines: Opt[]
    processingRestricted: boolean
    correctsRunId: string | null
    correctsRunCode: string | null
    canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [inspectedAt, setInspectedAt] = useState('')
    const [timeBad, setTimeBad] = useState(false)
    const [inspector, setInspector] = useState('')
    const [locationId, setLocationId] = useState('')
    const [equipmentId, setEquipmentId] = useState('')
    const [notes, setNotes] = useState('')
    const [reason, setReason] = useState('')
    const [answers, setAnswers] = useState<Record<number, Answer>>(
        Object.fromEntries(items.map((i) => [i.position, { result: '', note: '', finding: false, action: '', owner: '', due: '' }])))
    const setA = (pos: number, patch: Partial<Answer>) => setAnswers((a) => ({ ...a, [pos]: { ...a[pos], ...patch } }))

    const allAnswered = items.every((i) => answers[i.position].result !== '')
    const failNotes = items.every((i) => answers[i.position].result !== 'fail' || answers[i.position].note.trim() !== '')
    const findingsOk = items.every((i) => { const a = answers[i.position]; return !(a.result === 'fail' && a.finding) || (a.action.trim() !== '' && a.owner !== '') })
    const canSave = !!inspectedAt && !timeBad && inspector !== '' && allAnswered && failNotes && findingsOk
        && (!correctsRunId || reason.trim() !== '') && !isPending

    function save() {
        setError('')
        startTransition(async () => {
            const res = await recordInspectionRun({
                templateId, inspectedAt, inspectorEmployeeId: inspector, locationId, equipmentId, notes,
                results: items.map((i) => ({ position: i.position, result: answers[i.position].result, note: answers[i.position].note })),
                findings: items.filter((i) => answers[i.position].result === 'fail' && answers[i.position].finding)
                    .map((i) => ({ position: i.position, correctiveAction: answers[i.position].action, ownerEmployeeId: answers[i.position].owner,
                                   dueDate: answers[i.position].due })),
                correctsRunId, correctionReason: reason,
            })
            if (res?.error) setError(res.error)
        })
    }

    const label = (key: string, required = false) => (
        <span className="block mb-1">{t(key)}{required && <> <span className="text-red-600">*</span></>}</span>
    )

    return (
        <PermissionGate code="module.safety.edit" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="inspection-run">
                {error && <p className="text-sm text-red-600" data-error="run">{error}</p>}
                {correctsRunId && (
                    <div className="bg-amber-50 border border-amber-300 px-3 py-2 rounded text-sm space-y-2" data-section="correction">
                        <p>{t('safety.runForm.correcting', { code: correctsRunCode ?? '' })}</p>
                        <label className="block">
                            {label('safety.runForm.correctionReason', true)}
                            <textarea value={reason} onChange={(e) => setReason(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="correction_reason" />
                        </label>
                    </div>
                )}
                <div className="flex flex-wrap gap-4">
                    <div className="block text-sm min-w-0">
                        {label('safety.runForm.inspectedAt', true)}
                        <DatePicker kind="datetime" value={inspectedAt} onChange={setInspectedAt} onInvalidChange={setTimeBad} />
                    </div>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.runForm.inspector', true)}
                        <select value={inspector} onChange={(e) => setInspector(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="inspector_employee_id">
                            <option value="" disabled>{t('safety.runForm.pickInspector')}</option>
                            {people.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                        </select>
                    </label>
                </div>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.location')}
                        <select value={locationId} onChange={(e) => setLocationId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="location_id">
                            <option value="">{t('safety.form.none')}</option>
                            {locations.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.machine')}
                        <select value={equipmentId} onChange={(e) => setEquipmentId(e.target.value)} className={`${CONTROL_SELECT} w-full`}
                                data-field="equipment_id" disabled={processingRestricted}>
                            <option value="">{processingRestricted ? t('safety.form.restrictedProcessing') : t('safety.form.none')}</option>
                            {machines.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
                        </select>
                    </label>
                </div>
                <fieldset className="border border-gray-300 rounded px-3 py-2 text-sm space-y-3" data-section="results">
                    <legend className="px-1">{t('safety.runForm.results')} <span className="text-red-600">*</span></legend>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.runForm.resultsHint')}</p>
                    {items.map((i) => {
                        const a = answers[i.position]
                        return (
                            <div key={i.position} className="border-t border-gray-200 pt-2 space-y-2" data-item={i.position}>
                                <p className="font-medium">{`${i.position}. ${i.text}`}</p>
                                <div className="flex flex-wrap gap-4" role="radiogroup" aria-label={i.text}>
                                    {INSPECTION_RESULTS.map((r) => (
                                        <label key={r} className="flex items-center gap-1">
                                            <input type="radio" className={CONTROL_RADIO} name={`result-${i.position}`} value={r} checked={a.result === r}
                                                   onChange={() => setA(i.position, { result: r })} />
                                            {t(inspectionResultKey(r))}
                                        </label>
                                    ))}
                                </div>
                                {a.result === 'fail' && (
                                    <div className="space-y-2 pl-2 border-l-2 border-amber-300">
                                        <label className="block">
                                            {label('safety.runForm.failNote', true)}
                                            <input type="text" value={a.note} onChange={(e) => setA(i.position, { note: e.target.value })}
                                                   className={`${CONTROL_INPUT} w-full`} data-field={`note-${i.position}`} />
                                        </label>
                                        <label className="flex items-center gap-2">
                                            <input type="checkbox" className={CONTROL_CHECKBOX} checked={a.finding} onChange={(e) => setA(i.position, { finding: e.target.checked })} />
                                            {t('safety.runForm.addFinding')}
                                        </label>
                                        {a.finding && (
                                            <div className="flex flex-wrap gap-3">
                                                <label className="block min-w-0 basis-full">
                                                    {label('safety.findings.correctiveAction', true)}
                                                    <input type="text" value={a.action} onChange={(e) => setA(i.position, { action: e.target.value })}
                                                           className={`${CONTROL_INPUT} w-full`} />
                                                </label>
                                                <label className="block min-w-0 basis-full sm:basis-0 flex-1">
                                                    {label('safety.findings.owner', true)}
                                                    <select value={a.owner} onChange={(e) => setA(i.position, { owner: e.target.value })} className={`${CONTROL_SELECT} w-full`}>
                                                        <option value="" disabled>{t('safety.findings.pickOwner')}</option>
                                                        {people.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                                                    </select>
                                                </label>
                                                <div className="block min-w-0">
                                                    {label('safety.findings.dueDate')}
                                                    <DatePicker kind="date" value={a.due} onChange={(v) => setA(i.position, { due: v })} />
                                                </div>
                                            </div>
                                        )}
                                    </div>
                                )}
                                {a.result !== 'fail' && a.result !== '' && (
                                    <input type="text" value={a.note} onChange={(e) => setA(i.position, { note: e.target.value })}
                                           className={`${CONTROL_INPUT} w-full`} placeholder={t('safety.runForm.optionalNote')} />
                                )}
                            </div>
                        )
                    })}
                </fieldset>
                <label className="block text-sm">
                    {label('safety.runForm.notes')}
                    <textarea value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="notes" />
                </label>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.runForm.onceHint')}</p>
                <Button type="button" disabled={!canSave} onClick={save}>{isPending ? t('common.saving') : t('safety.runForm.save')}</Button>
            </div>
        </PermissionGate>
    )
}
