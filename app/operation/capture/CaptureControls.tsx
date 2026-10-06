'use client'

// app/operation/capture/CaptureControls.tsx
// MES-2(2026-10-06,规格 §6.3;MES-0 Q10–Q13;MES-2 Step 0 Q7–Q16):确认队列上的客户端控件。
//   · SubjectFields        —— 这一磅挂在哪:单独一次净重 · 开一张地磅单(进厂第一磅是毛重,出厂第一磅是皮重)· 完成一张开着的单
//   · DraftActions         —— 一张草稿:确认(读数预填,改了就要理由)或驳回(理由必填)
//   · ManualWeighingForm   —— 手工录入一次称重:仪器可选(不选 = "instrument not recorded"),读数的时刻可选
//   · CorrectWeighing      —— 更正一次已确认的称重:新的读数 + 理由
// 控件看得见、按不动、说出缺哪个码(action.confirm_capture,DBLOCK-1)。判据全在库里。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { confirmDraft, rejectDraft, submitManualWeighing, correctWeighing } from './actions'
import type { OpenTicket, Option, Subject } from './captureFields'

type SubjectKind = Subject['kind']

export function SubjectFields({ value, onChange, openTickets, allowNone = true, fixedKind }: {
    value: Subject; onChange: (s: Subject) => void; openTickets: OpenTicket[]; allowNone?: boolean; fixedKind?: SubjectKind
}) {
    const t = useTranslations()
    const kind = fixedKind ?? value.kind
    const setKind = (k: SubjectKind) => {
        if (k === 'none') onChange({ kind: 'none' })
        else if (k === 'new') onChange({ kind: 'new', direction: 'inbound', vehicleReg: '' })
        else onChange({ kind: 'ticket', ticketId: openTickets[0]?.id ?? '' })
    }
    return (
        <div className="space-y-2">
            {!fixedKind && (
                <label className="block">
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('capture.form.subject')}</span>
                    <select className={`${CONTROL_SELECT} w-full`} value={kind} onChange={(e) => setKind(e.target.value as SubjectKind)} data-capture-subject="1">
                        {allowNone && <option value="none">{t('capture.subject.none')}</option>}
                        <option value="new">{t('capture.subject.new')}</option>
                        <option value="ticket" disabled={openTickets.length === 0}>{t('capture.subject.ticket')}</option>
                    </select>
                </label>
            )}
            {kind === 'new' && value.kind === 'new' && (
                <div className="flex flex-wrap gap-2">
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.colDirection')}</span>
                        <select className={`${CONTROL_SELECT} w-full`} value={value.direction}
                                onChange={(e) => onChange({ ...value, direction: e.target.value as 'inbound' | 'outbound' })}>
                            <option value="inbound">{t('weighbridge.direction.inbound')}</option>
                            <option value="outbound">{t('weighbridge.direction.outbound')}</option>
                        </select>
                    </label>
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.colVehicle')}</span>
                        <input className={`${CONTROL_INPUT} w-full`} value={value.vehicleReg} maxLength={20}
                               onChange={(e) => onChange({ ...value, vehicleReg: e.target.value })} data-capture-vehicle="1" />
                    </label>
                    <p className="w-full text-xs text-[color:var(--brand-muted-text)]">
                        {value.direction === 'inbound' ? t('capture.subject.firstIsGross') : t('capture.subject.firstIsTare')}
                    </p>
                </div>
            )}
            {kind === 'ticket' && value.kind === 'ticket' && (
                <label className="block">
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('capture.form.openTicket')}</span>
                    <select className={`${CONTROL_SELECT} w-full`} value={value.ticketId} onChange={(e) => onChange({ kind: 'ticket', ticketId: e.target.value })}>
                        {openTickets.map((o) => (
                            <option key={o.id} value={o.id}>{`${o.code} · ${o.vehicle_reg} · ${t('weighbridge.direction.' + o.direction)}`}</option>
                        ))}
                    </select>
                    <span className="mt-1 block text-xs text-[color:var(--brand-muted-text)]">{t('capture.subject.secondIsOther')}</span>
                </label>
            )}
        </div>
    )
}

export function DraftActions({ draftId, label, proposedKg, openTickets, canConfirm }: {
    draftId: string; label: string; proposedKg: number; openTickets: OpenTicket[]; canConfirm: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [open, setOpen] = useState(false)
    const [weight, setWeight] = useState(String(proposedKg))
    const [reason, setReason] = useState('')
    const [subject, setSubject] = useState<Subject>({ kind: 'none' })
    const [error, setError] = useState<string | null>(null)
    const changed = weight.trim() !== '' && Number(weight) !== proposedKg
    const go = (fn: () => Promise<{ error?: string }>) => {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            setOpen(false)
            router.refresh()
        })
    }
    return (
        <PermissionGate code="action.confirm_capture" allowed={canConfirm} inline>
            <div className="space-y-2">
                <div className="flex flex-wrap items-center gap-1">
                    <Button type="button" size="xs" variant={open ? 'secondary' : 'default'} disabled={pending}
                            onClick={() => setOpen(!open)} data-capture-confirm-open="1">
                        {t('capture.confirm')}
                    </Button>
                    <ConfirmButton
                        subject={label}
                        title={t('capture.rejectTitle')}
                        body={t('capture.rejectBody')}
                        confirmLabel={t('capture.reject')}
                        tier="destructive"
                        reason={{ placeholder: t('capture.rejectPlaceholder') }}
                        triggerVariant="outline"
                        triggerSize="xs"
                        disabled={pending}
                        onConfirm={(r) => go(() => rejectDraft(draftId, r))}
                    >
                        {t('capture.reject')}
                    </ConfirmButton>
                </div>
                {open && (
                    <div className="w-72 max-w-full space-y-2 rounded border border-[color:var(--brand-border)] p-3 text-sm">
                        <label className="block">
                            <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('capture.form.weightKg')}</span>
                            <input inputMode="decimal" className={`${CONTROL_INPUT} w-full`} value={weight}
                                   onChange={(e) => setWeight(e.target.value)} data-capture-weight="1" />
                        </label>
                        {changed && (
                            <label className="block">
                                <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('capture.form.changeReason', { kg: String(proposedKg) })}</span>
                                <input className={`${CONTROL_INPUT} w-full`} value={reason} onChange={(e) => setReason(e.target.value)} data-capture-reason="1" />
                            </label>
                        )}
                        <SubjectFields value={subject} onChange={setSubject} openTickets={openTickets} />
                        <div className="flex flex-wrap gap-2">
                            <Button type="button" size="sm" disabled={pending || (changed && reason.trim() === '')}
                                    onClick={() => go(() => confirmDraft(draftId, proposedKg, weight, reason, subject))} data-capture-confirm="1">
                                {t('capture.confirm')}
                            </Button>
                            <Button type="button" size="sm" variant="secondary" disabled={pending} onClick={() => { setOpen(false); setError(null) }}>
                                {t('common.cancel')}
                            </Button>
                        </div>
                    </div>
                )}
                {error && <p className="text-xs text-red-700" role="alert">{error}</p>}
            </div>
        </PermissionGate>
    )
}

export function ManualWeighingForm({ instruments, openTickets, canConfirm, fixedSubject, submitLabel }: {
    instruments: Option[]; openTickets: OpenTicket[]; canConfirm: boolean
    /** 地磅单页:'new' = 开一张单;{ticketId} = 补这张单的第二磅 */
    fixedSubject?: { kind: 'new' } | { kind: 'ticket'; ticketId: string }
    submitLabel?: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [deviceId, setDeviceId] = useState('')
    const [weight, setWeight] = useState('')
    const [weighedAt, setWeighedAt] = useState('')
    const [subject, setSubject] = useState<Subject>(
        fixedSubject?.kind === 'new' ? { kind: 'new', direction: 'inbound', vehicleReg: '' }
            : fixedSubject?.kind === 'ticket' ? { kind: 'ticket', ticketId: fixedSubject.ticketId } : { kind: 'none' })
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState<string | null>(null)
    function submit() {
        setError(null); setDone(null)
        start(async () => {
            const r = await submitManualWeighing({ deviceId: deviceId || null, weight, weighedAt: weighedAt || null, subject })
            if (r.error) { setError(r.error); return }
            setWeight(''); setWeighedAt('')
            setDone(t('capture.form.recorded'))
            if (fixedSubject?.kind === 'new' && r.ticketId) { router.push(`/operation/weighbridge/${r.ticketId}`); return }
            router.refresh()
        })
    }
    return (
        <PermissionGate code="action.confirm_capture" allowed={canConfirm}>
            <div className="max-w-xl space-y-2 text-sm">
                {/* 三格各有一个起码的宽度:读数时刻那一格(日期 + 时间,共 ~15 rem、不收缩)按它自己的宽度占位,于是手机上它换到下一行,
                    而不是被挤进三分之一行、从页面右边伸出去(MES-2 版式普查 390 px 实测 +103 px)。 */}
                <div className="flex flex-wrap gap-2">
                    <label className="block min-w-[10rem] flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('capture.form.instrument')}</span>
                        <select className={`${CONTROL_SELECT} w-full`} value={deviceId} onChange={(e) => setDeviceId(e.target.value)} data-capture-instrument="1">
                            <option value="">{t('capture.form.noInstrument')}</option>
                            {instruments.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
                        </select>
                    </label>
                    <label className="block min-w-[7rem] flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('capture.form.weightKg')}</span>
                        <input inputMode="decimal" className={`${CONTROL_INPUT} w-full`} value={weight} onChange={(e) => setWeight(e.target.value)}
                               data-capture-manual-weight="1" />
                    </label>
                    <label className="block shrink-0">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('capture.form.weighedAt')}</span>
                        <DatePicker kind="datetime" value={weighedAt} onChange={(iso) => setWeighedAt(iso)} aria-label={t('capture.form.weighedAt')} />
                    </label>
                </div>
                {deviceId === '' && <p className="text-xs text-amber-700">{t('capture.form.noInstrumentHint')}</p>}
                {fixedSubject?.kind !== 'ticket' && (
                    <SubjectFields value={subject} onChange={setSubject} openTickets={openTickets}
                                   fixedKind={fixedSubject?.kind === 'new' ? 'new' : undefined} />
                )}
                <div className="flex flex-wrap items-center gap-2">
                    <Button type="button" size="sm" disabled={pending || weight.trim() === ''} onClick={submit} data-capture-manual-submit="1">
                        {submitLabel ?? t('capture.form.record')}
                    </Button>
                    {done && <span className="text-xs" role="status">{done}</span>}
                </div>
                {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
            </div>
        </PermissionGate>
    )
}

export function CorrectWeighing({ weighingId, currentKg, canConfirm }: { weighingId: string; currentKg: number; canConfirm: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [open, setOpen] = useState(false)
    const [weight, setWeight] = useState(String(currentKg))
    const [reason, setReason] = useState('')
    const [error, setError] = useState<string | null>(null)
    return (
        <PermissionGate code="action.confirm_capture" allowed={canConfirm} inline>
            <div className="space-y-1">
                {!open && <Button type="button" size="xs" variant="outline" onClick={() => setOpen(true)}>{t('capture.correct')}</Button>}
                {open && (
                    <div className="w-64 max-w-full space-y-2 rounded border border-[color:var(--brand-border)] p-2 text-sm">
                        <input inputMode="decimal" className={`${CONTROL_INPUT} w-full`} value={weight} onChange={(e) => setWeight(e.target.value)}
                               aria-label={t('capture.form.weightKg')} />
                        <input className={`${CONTROL_INPUT} w-full`} value={reason} onChange={(e) => setReason(e.target.value)}
                               placeholder={t('capture.form.correctionReason')} aria-label={t('capture.form.correctionReason')} />
                        <div className="flex flex-wrap gap-2">
                            <Button type="button" size="xs" disabled={pending || reason.trim() === ''}
                                    onClick={() => {
                                        setError(null)
                                        start(async () => {
                                            const r = await correctWeighing(weighingId, weight, reason)
                                            if (r.error) { setError(r.error); return }
                                            setOpen(false); setReason('')
                                            router.refresh()
                                        })
                                    }}>
                                {t('capture.correct')}
                            </Button>
                            <Button type="button" size="xs" variant="secondary" disabled={pending} onClick={() => { setOpen(false); setError(null) }}>
                                {t('common.cancel')}
                            </Button>
                        </div>
                    </div>
                )}
                {error && <p className="text-xs text-red-700" role="alert">{error}</p>}
            </div>
        </PermissionGate>
    )
}
