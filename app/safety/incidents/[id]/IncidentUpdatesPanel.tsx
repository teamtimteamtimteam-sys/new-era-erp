'use client'

// app/safety/incidents/[id]/IncidentUpdatesPanel.tsx
// MES-7b-1(2026-10-16,MES-7b Step 0 Q3 · Q10,Tim):一件事故之后的事实 —— 事故那一行不改,这里每一次各记一行(record_incident_update)。
//   记下通报了 NEA · 交了书面报告(要不要通报以更正过的值为准;不用通报的事故这两块不画)· 关闭(一句总结)· 带理由的更正(七个字段之一)。
//   时刻必填、不在未来、不早于事故,由库按名拒;这里只在没填时让按钮按不下去。关闭之后不收更正(INCIDENT_CLOSED),NEA 的两件照收。
//   缺 module.safety.edit 时表单在 PermissionGate 里,看得见、按不动、说出码(DBLOCK-1)。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'
import { recordIncidentUpdate } from '../../actions'
import { CORRECTABLE_FIELDS, fieldKey } from '../../safetyTypes'

export type UpdateRow = {
    id: number; kindLabel: string; when: string; detail: string; reason: string | null
    /** TABLE-EXPORT-3c(Tim 2026-10-25):那件事发生的时刻本身(occurred_at,没有就 recorded_at —— 与屏幕同一个取法) */
    whenRaw: string
}

export default function IncidentUpdatesPanel({ incidentId, incidentCode, updates, canEdit, reportable, notified, reportSubmitted, closed, kinds }: {
    incidentId: string
    /** TABLE-EXPORT-3c:导出的 About 表写明是哪一件事故 */
    incidentCode: string
    updates: UpdateRow[]
    canEdit: boolean
    reportable: boolean
    notified: boolean
    reportSubmitted: boolean
    closed: boolean
    kinds: { id: string; label: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [notifyAt, setNotifyAt] = useState(''); const [notifyRef, setNotifyRef] = useState('')
    const [reportAt, setReportAt] = useState(''); const [reportRef, setReportRef] = useState('')
    const [summary, setSummary] = useState('')
    const [field, setField] = useState(''); const [value, setValue] = useState(''); const [reason, setReason] = useState('')
    const [timeBad, setTimeBad] = useState(false)

    function run(input: Parameters<typeof recordIncidentUpdate>[1], reset: () => void) {
        setError('')
        startTransition(async () => {
            const res = await recordIncidentUpdate(incidentId, input)
            if (res?.error) { setError(res.error); return }
            reset()
            router.refresh()
        })
    }

    // ★ TABLE-EXPORT-3c(Tim 2026-10-25):只可追加的日志(事故那一行不改,每件事各记一行)—— 导出【全部】行。
    //   时刻读原始值(xTime);细节那一格是服务端拼好的一句话(更正的「字段: 新值」/ 总结 / 通报编号)→ 导出那句字本身;
    //   没有理由的行屏幕上画「—」,导出为空。
    const columns: ExportableColumn<UpdateRow>[] = [
        { key: 'kind', header: t('safety.updates.colKind'), priority: true, render: (r) => r.kindLabel, exportAs: (r) => xText(r.kindLabel) },
        { key: 'when', header: t('safety.updates.colWhen'), render: (r) => r.when, exportAs: (r) => xTime(r.whenRaw) },
        { key: 'detail', header: t('safety.updates.colDetail'), priority: true, render: (r) => <span className="whitespace-pre-wrap">{r.detail}</span>,
          exportAs: (r) => xText(r.detail) },
        { key: 'reason', header: t('safety.updates.colReason'), render: (r) => r.reason ?? '—', exportAs: (r) => xText(r.reason) },
    ]

    return (
        <section className="mt-8" data-section="updates">
            <h2 className="mb-1">{t('safety.updates.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('safety.updates.hint')}</p>
            <DataTable rows={updates} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t('safety.updates.empty')}
                       exportSpec={{ name: 'safety-incident-updates', title: t('safety.updates.title'),
                                     aboutExtra: [[t('safety.incidents.colCode'), incidentCode]] }} />
            {error && <p className="text-sm text-red-600 mt-2" data-error="update">{error}</p>}
            <PermissionGate code="module.safety.edit" allowed={canEdit}>
                <div className="space-y-4 mt-4 max-w-3xl">
                    {reportable && !notified && (
                        <div className="flex flex-wrap items-end gap-3" data-form="nea-notified">
                            <div className="text-sm">
                                <span className="block mb-1">{t('safety.updates.notifiedAt')} <span className="text-red-600">*</span></span>
                                <DatePicker kind="datetime" value={notifyAt} onChange={setNotifyAt} onInvalidChange={setTimeBad} />
                            </div>
                            <label className="block text-sm min-w-0 flex-1 basis-48">
                                <span className="block mb-1">{t('safety.updates.notifiedHow')}</span>
                                <input type="text" value={notifyRef} onChange={(e) => setNotifyRef(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                            <Button type="button" disabled={isPending || !notifyAt || timeBad}
                                    onClick={() => run({ kind: 'nea_notified', occurredAt: notifyAt, reference: notifyRef }, () => { setNotifyAt(''); setNotifyRef('') })}>
                                {t('safety.updates.recordNotified')}
                            </Button>
                        </div>
                    )}
                    {reportable && !reportSubmitted && (
                        <div className="flex flex-wrap items-end gap-3" data-form="report-submitted">
                            <div className="text-sm">
                                <span className="block mb-1">{t('safety.updates.reportAt')} <span className="text-red-600">*</span></span>
                                <DatePicker kind="datetime" value={reportAt} onChange={setReportAt} onInvalidChange={setTimeBad} />
                            </div>
                            <label className="block text-sm min-w-0 flex-1 basis-48">
                                <span className="block mb-1">{t('safety.updates.reportRef')}</span>
                                <input type="text" value={reportRef} onChange={(e) => setReportRef(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                            <Button type="button" disabled={isPending || !reportAt || timeBad}
                                    onClick={() => run({ kind: 'report_submitted', occurredAt: reportAt, reference: reportRef }, () => { setReportAt(''); setReportRef('') })}>
                                {t('safety.updates.recordReport')}
                            </Button>
                        </div>
                    )}
                    {!closed && (
                        <div className="space-y-2 border-t border-gray-200 pt-3" data-form="correction">
                            <p className="text-sm font-medium">{t('safety.updates.correctTitle')}</p>
                            <div className="flex flex-wrap items-end gap-3">
                                <label className="block text-sm">
                                    <span className="block mb-1">{t('safety.updates.field')}</span>
                                    <select value={field} onChange={(e) => { setField(e.target.value); setValue('') }} className={CONTROL_SELECT} data-field="field">
                                        <option value="" disabled>{t('safety.updates.pickField')}</option>
                                        {CORRECTABLE_FIELDS.map((f) => <option key={f} value={f}>{t(fieldKey(f))}</option>)}
                                    </select>
                                </label>
                                <div className="block text-sm min-w-0 flex-1 basis-48">
                                    <span className="block mb-1">{t('safety.updates.newValue')}</span>
                                    {field === 'kind_code' ? (
                                        <select value={value} onChange={(e) => setValue(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                                            <option value="" disabled>{t('safety.form.pickKind')}</option>
                                            {kinds.map((k) => <option key={k.id} value={k.id}>{k.label}</option>)}
                                        </select>
                                    ) : field === 'occurred_at' ? (
                                        <DatePicker kind="datetime" value={value} onChange={setValue} onInvalidChange={setTimeBad} />
                                    ) : field === 'nea_reportable' ? (
                                        <select value={value} onChange={(e) => setValue(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                                            <option value="" disabled>{t('safety.updates.pickAnswer')}</option>
                                            <option value="true">{t('safety.form.neaYes')}</option>
                                            <option value="false">{t('safety.form.neaNo')}</option>
                                        </select>
                                    ) : field === 'duration_min' ? (
                                        <input type="number" inputMode="decimal" min={0} value={value} onChange={(e) => setValue(e.target.value)} className={`${CONTROL_INPUT} w-32`} />
                                    ) : (
                                        <input type="text" value={value} onChange={(e) => setValue(e.target.value)} disabled={!field} className={`${CONTROL_INPUT} w-full`} />
                                    )}
                                </div>
                            </div>
                            <label className="block text-sm">
                                <span className="block mb-1">{t('safety.updates.reason')} <span className="text-red-600">*</span></span>
                                <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="reason" />
                            </label>
                            <Button type="button" disabled={isPending || !field || value.trim() === '' || reason.trim() === '' || timeBad}
                                    onClick={() => run({ kind: 'correction', field, newValue: value, reason }, () => { setField(''); setValue(''); setReason('') })}>
                                {t('safety.updates.recordCorrection')}
                            </Button>
                        </div>
                    )}
                    {!closed && (
                        <div className="space-y-2 border-t border-gray-200 pt-3" data-form="close">
                            <label className="block text-sm">
                                <span className="block mb-1">{t('safety.updates.closeSummary')} <span className="text-red-600">*</span></span>
                                <textarea value={summary} onChange={(e) => setSummary(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="summary" />
                            </label>
                            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.updates.closeHint')}</p>
                            <Button type="button" variant="outline" disabled={isPending || summary.trim() === ''}
                                    onClick={() => run({ kind: 'closed', summary }, () => setSummary(''))}>
                                {t('safety.updates.close')}
                            </Button>
                        </div>
                    )}
                </div>
            </PermissionGate>
        </section>
    )
}
