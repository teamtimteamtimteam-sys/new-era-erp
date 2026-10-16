'use client'

// app/safety/environment/EnvironmentForm.tsx
// MES-7b-2(2026-10-16,MES-0 Q75;MES-7b Step 0 Q16,Tim):记一条环境监测结果 —— 参数(字典;旁边说出它此刻的限值,或"没有限值 → 不判定")、
//   采样点、采样日、实验室、报告编号、数值。更正一条结果时(?corrects=)要写理由。
//   ★ 超标与否由库判(记下那一刻抄下的限值,一份判据),这里一个比较都不做。超标的结果会在同一笔事务里开一件排放超标的事故 ——
//     所以表单上总有"若超标"那一块:要不要通报 NEA(由人答,没有默认)与当场做了什么。超标而没答,库按名拒,句子说出数值与限值。
//   必填没填时按不下去,服务端【独立】按名拒。缺 module.safety.edit 时整张表单在 PermissionGate 里。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA, CONTROL_RADIO } from '@/app/components/ui/control-style'
import Link from 'next/link'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import { recordEnvironmentalResult } from '../actions'

export type ParamOpt = { code: string; label: string; unit: string; limit: string | null }
type Opt = { id: string; label: string }

export default function EnvironmentForm({ params, labs, canEdit, corrects }: {
    params: ParamOpt[]
    labs: Opt[]
    canEdit: boolean
    corrects: { id: string; label: string; parameterCode: string; samplePoint: string; sampledOn: string; laboratoryCode: string } | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState<{ incidentId: string | null } | null>(null)
    const [f, setF] = useState({
        parameterCode: corrects?.parameterCode ?? '', samplePoint: corrects?.samplePoint ?? '', sampledOn: corrects?.sampledOn ?? '',
        laboratoryCode: corrects?.laboratoryCode ?? '', reportReference: '', value: '', immediateAction: '', correctionReason: '',
    })
    const [nea, setNea] = useState<boolean | null>(null)
    const [dateBad, setDateBad] = useState(false)
    const set = (k: keyof typeof f) => (v: string) => { setSaved(null); setF((x) => ({ ...x, [k]: v })) }
    const param = params.find((p) => p.code === f.parameterCode)
    const valueOk = f.value.trim() !== '' && Number.isFinite(Number(f.value))
    const canSave = !!f.parameterCode && f.samplePoint.trim() !== '' && !!f.sampledOn && !dateBad && !!f.laboratoryCode
        && f.reportReference.trim() !== '' && valueOk && (!corrects || f.correctionReason.trim() !== '') && !isPending

    function save() {
        setError(''); setSaved(null)
        startTransition(async () => {
            const res = await recordEnvironmentalResult({ ...f, neaReportable: nea, correctsResultId: corrects?.id ?? null })
            if (res?.error) { setError(res.error); return }
            setSaved({ incidentId: res.incidentId ?? null })
            setF((x) => ({ ...x, reportReference: '', value: '', immediateAction: '', correctionReason: '' })); setNea(null)
            router.refresh()
        })
    }

    const label = (key: string, required = false) => (
        <span className="block mb-1">{t(key)}{required && <> <span className="text-red-600">*</span></>}</span>
    )

    return (
        <PermissionGate code="module.safety.edit" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="environmental-result">
                {error && <p className="text-sm text-red-600" data-error="environment">{error}</p>}
                {saved && (
                    <p className="text-sm text-green-700" data-saved="environment">
                        {t('safety.envForm.saved')}
                        {saved.incidentId && <>{' '}{t('safety.envForm.incidentOpened')}{' '}<Link href={`/safety/incidents/${saved.incidentId}`} className="app-link hover:underline">{t('safety.envForm.openIncident')}</Link></>}
                    </p>
                )}
                {corrects && (
                    <div className="bg-amber-50 border border-amber-300 px-3 py-2 rounded text-sm space-y-2" data-section="correction">
                        <p>{t('safety.envForm.correcting', { label: corrects.label })}</p>
                        <label className="block">
                            {label('safety.envForm.correctionReason', true)}
                            <textarea value={f.correctionReason} onChange={(e) => set('correctionReason')(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} />
                        </label>
                    </div>
                )}
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-[2]">
                        {label('safety.envForm.parameter', true)}
                        <select value={f.parameterCode} onChange={(e) => set('parameterCode')(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="parameter_code">
                            <option value="" disabled>{t('safety.envForm.pickParameter')}</option>
                            {params.map((p) => <option key={p.code} value={p.code}>{p.label}</option>)}
                        </select>
                        {param && <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]" data-value="limit-in-force">
                            {param.limit ? t('safety.envForm.limitInForce', { limit: param.limit }) : t('safety.envForm.noLimit')}</span>}
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.envForm.value', true)}
                        <span className="flex items-center gap-2">
                            <input type="text" inputMode="decimal" value={f.value} onChange={(e) => set('value')(e.target.value)} className={`${CONTROL_INPUT} min-w-0 flex-1`} data-field="value" />
                            <span className="text-[color:var(--brand-muted-text)]">{param?.unit ?? ''}</span>
                        </span>
                    </label>
                </div>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.envForm.samplePoint', true)}
                        <input type="text" value={f.samplePoint} onChange={(e) => set('samplePoint')(e.target.value)} className={`${CONTROL_INPUT} w-full`}
                               placeholder={t('safety.envForm.samplePointPlaceholder')} data-field="sample_point" />
                    </label>
                    <div className="block text-sm min-w-0">
                        {label('safety.envForm.sampledOn', true)}
                        <DatePicker kind="date" value={f.sampledOn} onChange={set('sampledOn')} onInvalidChange={setDateBad} />
                    </div>
                </div>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.envForm.laboratory', true)}
                        <select value={f.laboratoryCode} onChange={(e) => set('laboratoryCode')(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="laboratory_code">
                            <option value="" disabled>{t('safety.envForm.pickLaboratory')}</option>
                            {labs.map((l) => <option key={l.id} value={l.id}>{l.label}</option>)}
                        </select>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.envForm.reportReference', true)}
                        <input type="text" value={f.reportReference} onChange={(e) => set('reportReference')(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="report_reference" />
                    </label>
                </div>
                <fieldset className="border border-gray-300 rounded px-3 py-2 text-sm space-y-2" data-section="if-exceeds">
                    <legend className="px-1">{t('safety.envForm.ifExceeds')}</legend>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.envForm.ifExceedsHint')}</p>
                    <div className="flex flex-wrap gap-4" role="radiogroup" aria-label={t('safety.envForm.neaReportable')}>
                        <span>{t('safety.envForm.neaReportable')}</span>
                        <label className="flex items-center gap-1"><input type="radio" className={CONTROL_RADIO} name="env-nea" checked={nea === true} onChange={() => setNea(true)} />{t('safety.form.neaYes')}</label>
                        <label className="flex items-center gap-1"><input type="radio" className={CONTROL_RADIO} name="env-nea" checked={nea === false} onChange={() => setNea(false)} />{t('safety.form.neaNo')}</label>
                    </div>
                    <label className="block">
                        {label('safety.form.immediateAction')}
                        <textarea value={f.immediateAction} onChange={(e) => set('immediateAction')(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="immediate_action" />
                    </label>
                </fieldset>
                <Button type="button" disabled={!canSave} onClick={save}>{isPending ? t('common.saving') : t('safety.envForm.save')}</Button>
            </div>
        </PermissionGate>
    )
}
