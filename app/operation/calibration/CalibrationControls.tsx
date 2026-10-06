'use client'

// app/operation/calibration/CalibrationControls.tsx
// MES-2(2026-10-06,规格 §8.2;MES-2 Step 0 Q24 · Q26 · Q30):校准页的客户端控件 —— 记一次校准、作废一条、两样设定。
//   全部要 action.manage_devices(看得见、按不动、说出缺哪个码)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { recordCalibration, voidCalibration, saveCalibrationSettings } from './actions'
import type { Option } from '@/app/operation/capture/captureFields'

export function RecordCalibrationForm({ instruments, canManage, presetDeviceId }: { instruments: Option[]; canManage: boolean; presetDeviceId?: string }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [f, setF] = useState({ deviceId: presetDeviceId ?? instruments[0]?.id ?? '', calibratedOn: '', validUntil: '', result: 'passed', certificateNo: '', body: '', notes: '' })
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState(false)
    const set = (k: keyof typeof f, v: string) => setF({ ...f, [k]: v })
    return (
        <PermissionGate code="action.manage_devices" allowed={canManage}>
            <div className="max-w-2xl space-y-2 text-sm">
                <div className="flex flex-wrap gap-2">
                    {!presetDeviceId && (
                        <label className="block min-w-0 flex-1">
                            <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.colInstrument')}</span>
                            <select className={`${CONTROL_SELECT} w-full`} value={f.deviceId} onChange={(e) => set('deviceId', e.target.value)} data-calibration-device="1">
                                {instruments.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
                            </select>
                        </label>
                    )}
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.colCalibratedOn')}</span>
                        <DatePicker value={f.calibratedOn} onChange={(iso) => set('calibratedOn', iso)} aria-label={t('calibration.colCalibratedOn')} />
                    </label>
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.colValidUntil')}</span>
                        <DatePicker value={f.validUntil} onChange={(iso) => set('validUntil', iso)} aria-label={t('calibration.colValidUntil')} />
                    </label>
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.colResult')}</span>
                        <select className={`${CONTROL_SELECT} w-full`} value={f.result} onChange={(e) => set('result', e.target.value)}>
                            <option value="passed">{t('calibration.result.passed')}</option>
                            <option value="failed">{t('calibration.result.failed')}</option>
                        </select>
                    </label>
                </div>
                <div className="flex flex-wrap gap-2">
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.colCertificate')}</span>
                        <input className={`${CONTROL_INPUT} w-full`} value={f.certificateNo} onChange={(e) => set('certificateNo', e.target.value)} />
                    </label>
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.colBody')}</span>
                        <input className={`${CONTROL_INPUT} w-full`} value={f.body} onChange={(e) => set('body', e.target.value)} />
                    </label>
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.colNotes')}</span>
                        <input className={`${CONTROL_INPUT} w-full`} value={f.notes} onChange={(e) => set('notes', e.target.value)} />
                    </label>
                </div>
                <div className="flex flex-wrap items-center gap-2">
                    <Button type="button" size="sm" disabled={pending || !f.deviceId || !f.calibratedOn || !f.validUntil} data-calibration-record="1"
                            onClick={() => {
                                setError(null); setDone(false)
                                start(async () => {
                                    const r = await recordCalibration(f)
                                    if (r.error) { setError(r.error); return }
                                    setF({ ...f, calibratedOn: '', validUntil: '', certificateNo: '', body: '', notes: '' })
                                    setDone(true)
                                    router.refresh()
                                })
                            }}>
                        {t('calibration.record')}
                    </Button>
                    {done && <span className="text-xs" role="status">{t('calibration.recorded')}</span>}
                </div>
                {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
            </div>
        </PermissionGate>
    )
}

export function VoidCalibration({ id, deviceId, label, canManage }: { id: number; deviceId: string; label: string; canManage: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    return (
        <PermissionGate code="action.manage_devices" allowed={canManage} inline>
            <ConfirmButton
                subject={label}
                title={t('calibration.voidTitle')}
                body={t('calibration.voidBody')}
                confirmLabel={t('calibration.void')}
                tier="destructive"
                reason={{ placeholder: t('calibration.voidPlaceholder') }}
                triggerVariant="outline"
                triggerSize="xs"
                disabled={pending}
                onConfirm={(reason) => start(async () => {
                    setError(null)
                    const r = await voidCalibration(id, deviceId, reason)
                    if (r.error) { setError(r.error); return }
                    router.refresh()
                })}
            >
                {t('calibration.void')}
            </ConfirmButton>
            {error && <span className="text-xs text-red-700" role="alert">{error}</span>}
        </PermissionGate>
    )
}

export function CalibrationSettings({ leadDays, requireSince, canManage }: { leadDays: number | null; requireSince: string | null; canManage: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [editing, setEditing] = useState(false)
    const [lead, setLead] = useState(leadDays == null ? '' : String(leadDays))
    const [since, setSince] = useState(requireSince ?? '')
    const [error, setError] = useState<string | null>(null)
    return (
        <div className="max-w-xl space-y-2 text-sm">
            <dl className="grid grid-cols-1 gap-x-6 gap-y-1 sm:grid-cols-2">
                <div className="flex flex-wrap justify-between gap-x-3">
                    <dt className="text-[color:var(--brand-muted-text)]">{t('calibration.leadDays')}</dt>
                    <dd className="font-medium" data-calibration-lead={leadDays ?? ''}>{leadDays == null ? t('devices.notYetSet') : t('calibration.daysN', { n: String(leadDays) })}</dd>
                </div>
                <div className="flex flex-wrap justify-between gap-x-3">
                    <dt className="text-[color:var(--brand-muted-text)]">{t('calibration.requireSince')}</dt>
                    <dd className="font-medium" data-calibration-rule={requireSince ?? 'off'}>{requireSince ?? t('calibration.ruleOff')}</dd>
                </div>
            </dl>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{requireSince ? t('calibration.ruleOnHint', { date: requireSince }) : t('calibration.ruleOffHint')}</p>
            {!editing && (
                <PermissionGate code="action.manage_devices" allowed={canManage} inline>
                    <Button type="button" size="sm" variant="outline" onClick={() => setEditing(true)}>{t('calibration.editSettings')}</Button>
                </PermissionGate>
            )}
            {editing && (
                <div className="space-y-2 rounded border border-[color:var(--brand-border)] p-3">
                    <label className="block">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.leadDays')}</span>
                        <input inputMode="numeric" className={`${CONTROL_INPUT} w-full`} value={lead} onChange={(e) => setLead(e.target.value)} />
                    </label>
                    <label className="block">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.requireSince')}</span>
                        <DatePicker value={since} onChange={(iso) => setSince(iso)} aria-label={t('calibration.requireSince')} />
                        <span className="mt-1 block text-xs text-[color:var(--brand-muted-text)]">{t('calibration.requireSinceHint')}</span>
                    </label>
                    <div className="flex flex-wrap gap-2">
                        <Button type="button" size="sm" disabled={pending}
                                onClick={() => {
                                    setError(null)
                                    start(async () => {
                                        const r = await saveCalibrationSettings(lead, since)
                                        if (r.error) { setError(r.error); return }
                                        setEditing(false)
                                        router.refresh()
                                    })
                                }}>{t('common.save')}</Button>
                        <Button type="button" size="sm" variant="secondary" disabled={pending} onClick={() => { setEditing(false); setError(null) }}>{t('common.cancel')}</Button>
                    </div>
                    {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
                </div>
            )}
        </div>
    )
}
