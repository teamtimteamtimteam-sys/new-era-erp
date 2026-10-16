'use client'

// app/safety/incidents/new/IncidentForm.tsx
// MES-7b-1(2026-10-16,MES-0 Q73 · Q76;MES-7b Step 0 Q3 · Q5 · Q6 · Q9 · Q10,Tim):记一件事故的表单。
//   必填六样(种类 · 时刻 · 发生了什么 · 当场做了什么 · 负责的人 · 要不要通报 NEA)缺一样,保存钮按不下去;服务端【独立】按名拒(record_incident)。
//   "要不要通报 NEA"没有默认:两个单选都不选就是没回答(Q10)—— 旁边印着那条义务的原文,由记录的人判断,没有一条规矩替他判。
//   时刻用 DatePicker(新加坡时间,交出带偏移的 ISO);在未来由库按名拒(INCIDENT_TIME_IN_FUTURE)。
//   引用一段停机要先选机器,停机清单只列那台机器的(同一台由库再判一次);一条异常事件可选。
//   受伤的细节(Q6):谁都记得进去,读回来只给 data.view_health 与受伤的那名员工本人 —— 那一块上面直说。
//   缺 module.safety.edit 时整张表单在 PermissionGate 里,看得见、按不动、说出那个码(DBLOCK-1)。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA, CONTROL_RADIO } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { recordIncident } from '../../actions'

export type Opt = { id: string; label: string }

export default function IncidentForm({ kinds, locations, people, machines, downtime, events, processingRestricted, canEdit }: {
    kinds: Opt[]
    locations: Opt[]
    people: Opt[]
    machines: Opt[]
    downtime: (Opt & { machineId: string })[]
    events: Opt[]
    processingRestricted: boolean
    canEdit: boolean
}) {
    const t = useTranslations()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [f, setF] = useState({
        kindCode: '', occurredAt: '', whatHappened: '', immediateAction: '', responsibleEmployeeId: '', responsibleName: '',
        locationId: '', equipmentId: '', durationMin: '', downtimeId: '', runEventId: '', injuredEmployeeId: '', injuredPersonName: '',
        injuryNature: '', injuryTreatment: '', daysLost: '',
    })
    const [nea, setNea] = useState<boolean | null>(null)
    const [timeBad, setTimeBad] = useState(false)
    const set = (k: keyof typeof f) => (v: string) => setF((x) => ({ ...x, [k]: v }))

    const machineDowntime = downtime.filter((d) => d.machineId === f.equipmentId)
    const canSave = !!f.kindCode && !!f.occurredAt && !timeBad && f.whatHappened.trim() !== '' && f.immediateAction.trim() !== ''
        && (f.responsibleEmployeeId !== '' || f.responsibleName.trim() !== '') && nea !== null && !isPending

    function save() {
        setError('')
        startTransition(async () => {
            const res = await recordIncident({ ...f, neaReportable: nea })
            if (res?.error) setError(res.error)
        })
    }

    const label = (key: string, required = false) => (
        <span className="block mb-1">{t(key)}{required && <> <span className="text-red-600">*</span></>}</span>
    )

    return (
        <PermissionGate code="module.safety.edit" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="incident">
                {error && <p className="text-sm text-red-600" data-error="incident">{error}</p>}
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.kind', true)}
                        <select value={f.kindCode} onChange={(e) => set('kindCode')(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="kind_code">
                            <option value="" disabled>{t('safety.form.pickKind')}</option>
                            {kinds.map((k) => <option key={k.id} value={k.id}>{k.label}</option>)}
                        </select>
                    </label>
                    <div className="block text-sm min-w-0">
                        {label('safety.form.occurredAt', true)}
                        <DatePicker kind="datetime" value={f.occurredAt} onChange={set('occurredAt')} onInvalidChange={setTimeBad} />
                    </div>
                </div>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.location')}
                        <select value={f.locationId} onChange={(e) => set('locationId')(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="location_id">
                            <option value="">{t('safety.form.none')}</option>
                            {locations.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.machine')}
                        <select value={f.equipmentId} onChange={(e) => setF((x) => ({ ...x, equipmentId: e.target.value, downtimeId: '' }))}
                                className={`${CONTROL_SELECT} w-full`} data-field="equipment_id" disabled={processingRestricted}>
                            <option value="">{processingRestricted ? t('safety.form.restrictedProcessing') : t('safety.form.none')}</option>
                            {machines.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm">
                        {label('safety.form.durationMin')}
                        <input type="number" inputMode="decimal" min={0} value={f.durationMin} onChange={(e) => set('durationMin')(e.target.value)}
                               className={`${CONTROL_INPUT} w-32`} data-field="duration_min" />
                    </label>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.form.whereWhy')}</p>
                <label className="block text-sm">
                    {label('safety.form.whatHappened', true)}
                    <textarea value={f.whatHappened} onChange={(e) => set('whatHappened')(e.target.value)} rows={3} className={`${CONTROL_TEXTAREA} w-full`} data-field="what_happened" />
                </label>
                <label className="block text-sm">
                    {label('safety.form.immediateAction', true)}
                    <textarea value={f.immediateAction} onChange={(e) => set('immediateAction')(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="immediate_action" />
                </label>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.responsibleEmployee', true)}
                        <select value={f.responsibleEmployeeId} onChange={(e) => set('responsibleEmployeeId')(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="responsible_employee_id">
                            <option value="">{t('safety.form.none')}</option>
                            {people.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.responsibleName')}
                        <input type="text" value={f.responsibleName} onChange={(e) => set('responsibleName')(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="responsible_name" />
                    </label>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.form.responsibleWhy')}</p>

                <fieldset className="border border-amber-300 bg-amber-50 rounded px-3 py-2 text-sm" data-field="nea_reportable">
                    <legend className="px-1">{t('safety.form.neaReportable')} <span className="text-red-600">*</span></legend>
                    <p className="text-xs mb-2">{t('safety.form.neaDuty')}</p>
                    <div className="flex flex-wrap gap-4">
                        <label className="flex items-center gap-2">
                            <input type="radio" name="nea" className={CONTROL_RADIO} checked={nea === true} onChange={() => setNea(true)} data-value="true" />
                            <span>{t('safety.form.neaYes')}</span>
                        </label>
                        <label className="flex items-center gap-2">
                            <input type="radio" name="nea" className={CONTROL_RADIO} checked={nea === false} onChange={() => setNea(false)} data-value="false" />
                            <span>{t('safety.form.neaNo')}</span>
                        </label>
                    </div>
                </fieldset>

                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.downtime')}
                        <select value={f.downtimeId} onChange={(e) => set('downtimeId')(e.target.value)} className={`${CONTROL_SELECT} w-full`}
                                data-field="downtime_id" disabled={!f.equipmentId}>
                            <option value="">{f.equipmentId ? t('safety.form.none') : t('safety.form.pickMachineFirst')}</option>
                            {machineDowntime.map((d) => <option key={d.id} value={d.id}>{d.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.form.runEvent')}
                        <select value={f.runEventId} onChange={(e) => set('runEventId')(e.target.value)} className={`${CONTROL_SELECT} w-full`}
                                data-field="run_event_id" disabled={processingRestricted}>
                            <option value="">{processingRestricted ? t('safety.form.restrictedProcessing') : t('safety.form.none')}</option>
                            {events.map((e) => <option key={e.id} value={e.id}>{e.label}</option>)}
                        </select>
                    </label>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.form.citeWhy')}</p>

                <fieldset className="border border-gray-300 rounded px-3 py-2 text-sm space-y-3" data-section="injury">
                    <legend className="px-1">{t('safety.form.injuryTitle')}</legend>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.form.injuryPrivacy')}</p>
                    <div className="flex flex-wrap gap-4">
                        <label className="block min-w-0 basis-full sm:basis-0 flex-1">
                            {label('safety.form.injuredEmployee')}
                            <select value={f.injuredEmployeeId} onChange={(e) => set('injuredEmployeeId')(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="injured_employee_id">
                                <option value="">{t('safety.form.none')}</option>
                                {people.map((p) => <option key={p.id} value={p.id}>{p.label}</option>)}
                            </select>
                        </label>
                        <label className="block min-w-0 basis-full sm:basis-0 flex-1">
                            {label('safety.form.injuredPersonName')}
                            <input type="text" value={f.injuredPersonName} onChange={(e) => set('injuredPersonName')(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="injured_person_name" />
                        </label>
                    </div>
                    <label className="block">
                        {label('safety.form.injuryNature')}
                        <textarea value={f.injuryNature} onChange={(e) => set('injuryNature')(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="injury_nature" />
                    </label>
                    <div className="flex flex-wrap gap-4">
                        <label className="block min-w-0 basis-full sm:basis-0 flex-1">
                            {label('safety.form.injuryTreatment')}
                            <input type="text" value={f.injuryTreatment} onChange={(e) => set('injuryTreatment')(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="injury_treatment" />
                        </label>
                        <label className="block">
                            {label('safety.form.daysLost')}
                            <input type="number" inputMode="decimal" min={0} value={f.daysLost} onChange={(e) => set('daysLost')(e.target.value)} className={`${CONTROL_INPUT} w-32`} data-field="days_lost" />
                        </label>
                    </div>
                </fieldset>

                <Button type="button" disabled={!canSave} onClick={save}>
                    {isPending ? t('common.saving') : t('safety.form.save')}
                </Button>
                {!canSave && !isPending && <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.form.requiredHint')}</p>}
            </div>
        </PermissionGate>
    )
}
