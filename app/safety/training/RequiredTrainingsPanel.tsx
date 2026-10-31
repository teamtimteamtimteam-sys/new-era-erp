'use client'

// ESG-2(Tim 2026-10-31 Q8 · Q9):培训合规页上的【必修培训清单】—— 加一门、改一门、停用一门(停用不删:挂着它的记录照旧在)。
//   门 action.manage_esg(admin · cco · cfo):不持的人看得见表单、按不动、说出码。规矩全在库里(required_training_save / _retire)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_CHECKBOX } from '@/app/components/ui/control-style'
import { TRAINING_CATEGORY_OPTIONS } from '@/app/hr/options'
import { saveRequiredTraining, retireRequiredTraining } from '../esgActions'

export type RequiredTrainingView = {
    id: string; name: string; category: string | null; validityMonths: number | null; appliesTo: string; positionIds: string[]; notes: string | null
    scopeLabel: string
}
export type PositionOption = { id: string; label: string }

const APPLIES = ['everyone', 'office', 'shopfloor', 'positions'] as const

export default function RequiredTrainingsPanel({ trainings, positions, canManage }: {
    trainings: RequiredTrainingView[]; positions: PositionOption[]; canManage: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [editing, setEditing] = useState<string | null>(null)
    const [name, setName] = useState('')
    const [category, setCategory] = useState('')
    const [validity, setValidity] = useState('')
    const [appliesTo, setAppliesTo] = useState<string>('everyone')
    const [posIds, setPosIds] = useState<string[]>([])
    const [notes, setNotes] = useState('')
    const [error, setError] = useState('')

    function reset() {
        setEditing(null); setName(''); setCategory(''); setValidity(''); setAppliesTo('everyone'); setPosIds([]); setNotes('')
    }
    function edit(r: RequiredTrainingView) {
        setEditing(r.id); setName(r.name); setCategory(r.category ?? ''); setValidity(r.validityMonths === null ? '' : String(r.validityMonths))
        setAppliesTo(r.appliesTo); setPosIds(r.positionIds); setNotes(r.notes ?? ''); setError('')
    }
    function save() {
        setError('')
        start(async () => {
            const r = await saveRequiredTraining({ id: editing, name, category, validityMonths: validity, appliesTo, positionIds: posIds, notes })
            if (r.error) { setError(r.error); return }
            reset()
            router.refresh()
        })
    }
    function retire(id: string) {
        setError('')
        start(async () => {
            const r = await retireRequiredTraining(id)
            if (r.error) { setError(r.error); return }
            if (editing === id) reset()
            router.refresh()
        })
    }

    return (
        <section className="mt-8 space-y-3" data-section="required-trainings" aria-label={t('esg.training.listTitle')}>
            <h2 className="mb-1">{t('esg.training.listTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('esg.training.listIntro')}</p>
            {trainings.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]" data-required-none="1">{t('esg.training.listNone')}</p>
            ) : (
                <ul className="divide-y divide-[color:var(--brand-border)] border-y border-[color:var(--brand-border)] text-sm">
                    {trainings.map((r) => (
                        <li key={r.id} className="py-2 flex flex-wrap items-center gap-x-4 gap-y-1" data-required-training={r.name}>
                            <span className="font-medium min-w-0 break-words">{r.name}</span>
                            <span>{r.category ? t('hr.trainingCategory.' + r.category) : '—'}</span>
                            <span>{r.validityMonths === null ? t('esg.training.noExpiry') : t('esg.training.validity', { n: r.validityMonths })}</span>
                            <span className="min-w-0 break-words">{r.scopeLabel}</span>
                            <PermissionGate code="action.manage_esg" allowed={canManage} inline wrap>
                                <span className="flex flex-wrap gap-2">
                                    <Button type="button" variant="outline" disabled={pending} onClick={() => edit(r)}>{t('esg.training.edit')}</Button>
                                    <ConfirmButton
                                        subject={r.name}
                                        title={t('esg.training.retireConfirm')}
                                        body={t('esg.training.retireBody')}
                                        confirmLabel={t('esg.training.retire')}
                                        tier="reversal"
                                        triggerVariant="outline"
                                        disabled={pending}
                                        onConfirm={() => retire(r.id)}
                                    >
                                        {t('esg.training.retire')}
                                    </ConfirmButton>
                                </span>
                            </PermissionGate>
                        </li>
                    ))}
                </ul>
            )}
            <PermissionGate code="action.manage_esg" allowed={canManage} wrap>
                <div className="space-y-2 max-w-3xl" data-form="required-training">
                    <p className="text-sm font-medium">{editing ? t('esg.training.editTitle') : t('esg.training.addTitle')}</p>
                    <div className="flex flex-wrap items-end gap-2">
                        <label className="block text-sm min-w-0 flex-1 basis-64">
                            <span className="block mb-1">{t('esg.training.name')} <span className="text-red-600">*</span></span>
                            <input type="text" value={name} onChange={(e) => setName(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="name" />
                        </label>
                        <label className="block text-sm">
                            <span className="block mb-1">{t('hr.colCategory')}</span>
                            <select value={category} onChange={(e) => setCategory(e.target.value)} className={CONTROL_SELECT} data-field="category">
                                <option value="">—</option>
                                {TRAINING_CATEGORY_OPTIONS.map((o) => <option key={o.value} value={o.value}>{t(o.labelKey)}</option>)}
                            </select>
                        </label>
                        <label className="block text-sm">
                            <span className="block mb-1">{t('esg.training.validityLabel')}</span>
                            <input type="number" inputMode="numeric" min={1} max={240} value={validity} onChange={(e) => setValidity(e.target.value)} className={`${CONTROL_INPUT} w-28`} data-field="validity" />
                        </label>
                        <label className="block text-sm">
                            <span className="block mb-1">{t('esg.training.appliesTo')} <span className="text-red-600">*</span></span>
                            <select value={appliesTo} onChange={(e) => setAppliesTo(e.target.value)} className={CONTROL_SELECT} data-field="applies-to">
                                {APPLIES.map((a) => <option key={a} value={a}>{t('esg.training.applies.' + a)}</option>)}
                            </select>
                        </label>
                    </div>
                    {appliesTo === 'positions' && (
                        <fieldset className="text-sm" data-field="positions">
                            <legend className="mb-1">{t('esg.training.positions')} <span className="text-red-600">*</span></legend>
                            <div className="flex flex-wrap gap-x-4 gap-y-1">
                                {positions.map((p) => (
                                    <label key={p.id} className="inline-flex items-center gap-2">
                                        <input type="checkbox" className={CONTROL_CHECKBOX} checked={posIds.includes(p.id)}
                                               onChange={(e) => setPosIds(e.target.checked ? [...posIds, p.id] : posIds.filter((x) => x !== p.id))} />
                                        {p.label}
                                    </label>
                                ))}
                            </div>
                        </fieldset>
                    )}
                    <label className="block text-sm">
                        <span className="block mb-1">{t('esg.training.notes')}</span>
                        <input type="text" value={notes} onChange={(e) => setNotes(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="notes" />
                    </label>
                    <div className="flex flex-wrap gap-2">
                        <Button type="button" disabled={pending || !name.trim() || (appliesTo === 'positions' && posIds.length === 0)} onClick={save}>
                            {editing ? t('esg.training.saveChanges') : t('esg.training.add')}
                        </Button>
                        {editing && <Button type="button" variant="outline" onClick={reset}>{t('common.cancel')}</Button>}
                    </div>
                    {error && <p className="text-sm text-red-600" data-error="required-training">{error}</p>}
                </div>
            </PermissionGate>
        </section>
    )
}
