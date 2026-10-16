'use client'

// app/safety/inspections/TemplateForm.tsx
// MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q13 · Q20,Tim):一张巡检清单 —— 代号、名字、片区、频率(天,V18;空 = Not yet set)、启用、
//   说明,以及按顺序的检查项(加一项、删一项、上下挪)。一次存下(save_inspection_template)。
//   ★ 改清单不改写过去的巡检:一次巡检记下那一刻把每一项的字抄走了(Q13)—— 表单上说出来。
//   必填没填时保存按不下去,服务端【独立】按名拒。缺 module.safety.edit 时表单在 PermissionGate 里,看得见、按不动、说出那个码。
import { CONTROL_INPUT, CONTROL_TEXTAREA, CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { saveInspectionTemplate } from '../actions'

export type TemplateInit = {
    id: string | null; code: string; name: string; area: string; frequencyDays: string; isActive: boolean; notes: string; items: string[]
}

export default function TemplateForm({ init, canEdit, hasRuns }: { init: TemplateInit; canEdit: boolean; hasRuns: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [f, setF] = useState({ code: init.code, name: init.name, area: init.area, frequencyDays: init.frequencyDays, notes: init.notes })
    const [active, setActive] = useState(init.isActive)
    const [items, setItems] = useState<string[]>(init.items.length ? init.items : [''])
    const set = (k: keyof typeof f) => (v: string) => { setSaved(false); setF((x) => ({ ...x, [k]: v })) }

    const freqOk = f.frequencyDays.trim() === '' || /^[1-9][0-9]*$/.test(f.frequencyDays.trim())
    const canSave = f.code.trim() !== '' && f.name.trim() !== '' && f.area.trim() !== '' && freqOk
        && items.length > 0 && items.every((x) => x.trim() !== '') && !isPending

    function setItem(i: number, v: string) { setSaved(false); setItems((xs) => xs.map((x, k) => (k === i ? v : x))) }
    function move(i: number, d: -1 | 1) {
        setSaved(false)
        setItems((xs) => { const j = i + d; if (j < 0 || j >= xs.length) return xs; const c = [...xs]; [c[i], c[j]] = [c[j], c[i]]; return c })
    }
    function save() {
        setError(''); setSaved(false)
        startTransition(async () => {
            const res = await saveInspectionTemplate(init.id, { ...f, isActive: active, items })
            if (res?.error) { setError(res.error); return }
            setSaved(true)
            router.refresh()
        })
    }

    const label = (key: string, required = false) => (
        <span className="block mb-1">{t(key)}{required && <> <span className="text-red-600">*</span></>}</span>
    )

    return (
        <PermissionGate code="module.safety.edit" allowed={canEdit}>
            <div className="space-y-4 max-w-3xl" data-form="inspection-template">
                {error && <p className="text-sm text-red-600" data-error="template">{error}</p>}
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.templateForm.code', true)}
                        <input type="text" value={f.code} onChange={(e) => set('code')(e.target.value.toUpperCase())} className={`${CONTROL_INPUT} w-full`}
                               placeholder={t('safety.templateForm.codePlaceholder')} data-field="code" />
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-[2]">
                        {label('safety.templateForm.name', true)}
                        <input type="text" value={f.name} onChange={(e) => set('name')(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="name" />
                    </label>
                </div>
                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-[2]">
                        {label('safety.templateForm.area', true)}
                        <input type="text" value={f.area} onChange={(e) => set('area')(e.target.value)} className={`${CONTROL_INPUT} w-full`}
                               placeholder={t('safety.templateForm.areaPlaceholder')} data-field="area" />
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        {label('safety.templateForm.frequency')}
                        <input type="text" inputMode="numeric" value={f.frequencyDays} onChange={(e) => set('frequencyDays')(e.target.value)}
                               className={`${CONTROL_INPUT} w-full`} placeholder={t('safety.templateForm.frequencyPlaceholder')} data-field="frequency_days" />
                        {!freqOk && <span className="block mt-1 text-xs text-red-600">{t('safety.errors.INSPECTION_TEMPLATE_FREQUENCY_INVALID')}</span>}
                    </label>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('safety.templateForm.frequencyHint')}</p>
                <fieldset className="border border-gray-300 rounded px-3 py-2 text-sm space-y-2" data-section="items">
                    <legend className="px-1">{t('safety.templateForm.items')} <span className="text-red-600">*</span></legend>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{hasRuns ? t('safety.templateForm.itemsHintRuns') : t('safety.templateForm.itemsHint')}</p>
                    {items.map((x, i) => (
                        <div key={i} className="flex flex-wrap items-center gap-2" data-item={i + 1}>
                            <span className="w-6 text-right tabular-nums">{i + 1}.</span>
                            <input type="text" value={x} onChange={(e) => setItem(i, e.target.value)} className={`${CONTROL_INPUT} min-w-0 flex-1 basis-48`}
                                   aria-label={t('safety.templateForm.itemLabel', { n: String(i + 1) })} />
                            <Button type="button" variant="outline" size="sm" disabled={i === 0} onClick={() => move(i, -1)}
                                    aria-label={t('safety.templateForm.moveUp')}>↑</Button>
                            <Button type="button" variant="outline" size="sm" disabled={i === items.length - 1} onClick={() => move(i, 1)}
                                    aria-label={t('safety.templateForm.moveDown')}>↓</Button>
                            <Button type="button" variant="outline" size="sm" disabled={items.length === 1}
                                    onClick={() => { setSaved(false); setItems((xs) => xs.filter((_, k) => k !== i)) }}>{t('safety.templateForm.removeItem')}</Button>
                        </div>
                    ))}
                    <Button type="button" variant="outline" size="sm" onClick={() => { setSaved(false); setItems((xs) => [...xs, '']) }}>
                        {t('safety.templateForm.addItem')}
                    </Button>
                </fieldset>
                <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" className={CONTROL_CHECKBOX} checked={active} onChange={(e) => { setSaved(false); setActive(e.target.checked) }} data-field="is_active" />
                    {t('safety.templateForm.active')}
                </label>
                <p className="text-xs text-[color:var(--brand-muted-text)] -mt-2">{t('safety.templateForm.activeHint')}</p>
                <label className="block text-sm">
                    {label('safety.templateForm.notes')}
                    <textarea value={f.notes} onChange={(e) => set('notes')(e.target.value)} rows={2} className={`${CONTROL_TEXTAREA} w-full`} data-field="notes" />
                </label>
                <div className="flex flex-wrap items-center gap-3">
                    <Button type="button" disabled={!canSave} onClick={save}>{isPending ? t('common.saving') : t('safety.templateForm.save')}</Button>
                    {saved && <span className="text-sm text-green-700" data-saved="template">{t('safety.templateForm.saved')}</span>}
                </div>
            </div>
        </PermissionGate>
    )
}
