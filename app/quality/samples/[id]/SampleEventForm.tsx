'use client'

// app/quality/samples/[id]/SampleEventForm.tsx
// MES-6a-1(MES-6a Step 0 Q7 · Q15):记一件保管上的事 —— 送实验室 · 拿回来 · 挪库位 · 处置。只追加,一行一件事。
//   【此刻能记哪几种】按这份样品的状态把选不了的画成灰的(allowedEventKinds,与 record_sample_event 的顺序规矩同一句);
//   拒绝仍由服务端按名给。时刻必填、没有默认值;处置要理由;早于留样日的处置照收,并直说它会被标成"提前处置"(Q15)。
//   缺 module.quality.edit 时整块在 PermissionGate 里,看得见、按不动、说出那个码。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { recordSampleEvent } from '../../actions'
import { SAMPLE_EVENT_KINDS, allowedEventKinds, sampleEventKey } from '../../qualityTypes'

export type LabOption = { code: string; label: string }
export type LocationOption = { id: string; label: string }

export default function SampleEventForm({ sampleId, state, labs, locations, beforeRetention, canEdit }: {
    sampleId: string
    state: string
    labs: LabOption[]
    locations: LocationOption[]
    /** 留样日还没到 —— 处置时说一句"会被标成提前处置" */
    beforeRetention: boolean
    canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [kind, setKind] = useState('')
    const [occurredAt, setOccurredAt] = useState('')
    const [timeInvalid, setTimeInvalid] = useState(false)
    const [lab, setLab] = useState('')
    const [labRef, setLabRef] = useState('')
    const [locationId, setLocationId] = useState('')
    const [reason, setReason] = useState('')
    const [notes, setNotes] = useState('')
    const allowed = allowedEventKinds(state)

    const missing = !kind || !occurredAt || timeInvalid
        || (kind === 'sent_to_lab' && !lab)
        || (kind === 'moved' && !locationId)
        || (kind === 'disposed' && reason.trim() === '')

    function save() {
        setError('')
        startTransition(async () => {
            const res = await recordSampleEvent(sampleId, {
                eventKind: kind, occurredAt,
                laboratoryCode: kind === 'sent_to_lab' ? lab : null,
                labReference: kind === 'sent_to_lab' ? labRef : '',
                storageLocationId: kind === 'received_back' || kind === 'moved' ? (locationId || null) : null,
                reason: kind === 'disposed' ? reason : '',
                notes,
            })
            if (res?.error) { setError(res.error); return }
            setKind(''); setOccurredAt(''); setLab(''); setLabRef(''); setLocationId(''); setReason(''); setNotes('')
            router.refresh()
        })
    }

    if (allowed.length === 0) {
        return <p className="text-sm text-[color:var(--brand-muted-text)]">{t('quality.sample.disposedNoMore')}</p>
    }

    return (
        <PermissionGate code="module.quality.edit" allowed={canEdit}>
            <div className="space-y-3 max-w-3xl" data-form="sample-event">
                {error && <p className="text-sm text-red-600">{error}</p>}
                <div className="flex flex-wrap items-end gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-56">
                        <span className="block mb-1">{t('quality.sample.eventKind')} <span className="text-red-600">*</span></span>
                        <select value={kind} onChange={(e) => setKind(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="event_kind">
                            <option value="" disabled>{t('quality.sample.pickEvent')}</option>
                            {SAMPLE_EVENT_KINDS.map((k) => (
                                <option key={k} value={k} disabled={!allowed.includes(k)}>{t(sampleEventKey(k))}</option>
                            ))}
                        </select>
                    </label>
                    <div className="block text-sm">
                        <span className="block mb-1">{t('quality.sample.occurredAt')} <span className="text-red-600">*</span></span>
                        <DatePicker kind="datetime" value={occurredAt} onChange={setOccurredAt} onInvalidChange={setTimeInvalid}
                                    required aria-label={t('quality.sample.occurredAt')} />
                    </div>
                </div>
                {kind === 'sent_to_lab' && (
                    <div className="flex flex-wrap gap-4">
                        <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                            <span className="block mb-1">{t('quality.sample.lab')} <span className="text-red-600">*</span></span>
                            <select value={lab} onChange={(e) => setLab(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="laboratory_code">
                                <option value="" disabled>{t('quality.sample.pickLab')}</option>
                                {labs.map((l) => <option key={l.code} value={l.code}>{l.label}</option>)}
                            </select>
                        </label>
                        <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                            <span className="block mb-1">{t('quality.sample.labRef')}</span>
                            <input type="text" value={labRef} onChange={(e) => setLabRef(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                    </div>
                )}
                {(kind === 'received_back' || kind === 'moved') && (
                    <label className="block text-sm max-w-md">
                        <span className="block mb-1">{t('quality.form.location')}{kind === 'moved' && <> <span className="text-red-600">*</span></>}</span>
                        <select value={locationId} onChange={(e) => setLocationId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="storage_location_id">
                            <option value="">{kind === 'moved' ? t('quality.sample.pickLocation') : t('quality.noLocation')}</option>
                            {locations.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                        </select>
                    </label>
                )}
                {kind === 'disposed' && (
                    <label className="block text-sm">
                        <span className="block mb-1">{t('quality.sample.disposalReason')} <span className="text-red-600">*</span></span>
                        <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} placeholder={t('quality.sample.disposalReasonPlaceholder')}
                               className={`${CONTROL_INPUT} w-full`} data-field="reason" />
                        {beforeRetention && <span className="block mt-1 text-xs text-amber-700">{t('quality.sample.earlyDisposalWarning')}</span>}
                    </label>
                )}
                <label className="block text-sm">
                    <span className="block mb-1">{t('quality.form.notes')}</span>
                    <input type="text" value={notes} onChange={(e) => setNotes(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                </label>
                <Button type="button" disabled={missing || isPending} onClick={save}>
                    {isPending ? t('common.saving') : t('quality.sample.recordEvent')}
                </Button>
            </div>
        </PermissionGate>
    )
}
