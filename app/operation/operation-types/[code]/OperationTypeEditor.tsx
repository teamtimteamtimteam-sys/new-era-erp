'use client'

// MES-4a:一道工序的四块配置 —— 容差 · 参数与指标 · 机器 · 配方与版本。
// 【只读】没有 module.processing.edit 的人:控件看得见、按不动,旁边说出缺哪个码(PermissionGate,DBLOCK-1)。
// 【规则不在这里】退役不删、用过之后类型与单位不许改、只挂设备类、版本写了不改 —— 全在库里;这里只把拒绝说成人话。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import type { Json } from '@/lib/database.types'
import {
    setTolerance, setElectrolyte, addField, updateField, setFieldActive, linkMachine, unlinkMachine,
    addRecipe, setRecipeActive, addRecipeVersion, type FieldInput,
} from '../actions'

export type EditorField = {
    field_code: string; name_en: string; name_zh: string; name: string; kind: string; value_type: string; unit: string | null
    is_required: boolean; has_range: boolean; range_min: number | null; range_max: number | null
    is_active: boolean; sort_order: number; notes: string | null
}
export type EditorMachine = { id: string; label: string; disposed: boolean; linked: boolean }
export type EditorRecipe = {
    id: string; code: string; name: string; is_active: boolean; notes: string | null
    versions: { id: string; version: number; notes: string | null; values: string[] }[]
}

const EDIT = 'module.processing.edit'
const blankField: FieldInput = {
    field_code: '', name_en: '', name_zh: '', kind: 'parameter', value_type: 'number', unit: '',
    is_required: false, has_range: false, range_min: '', range_max: '', sort_order: '', notes: '',
}

export default function OperationTypeEditor({ code, transforming, tolerance, electrolyteApplies, electrolyteShare, requiresCellConstruction,
    fields, machines, recipes, canEdit }: {
    code: string
    transforming: boolean
    tolerance: string | null
    /** MES-4b(Q17):「Electrolyte evaporates in this step」· 电解液份额(V10,空 = 还没给)· 投料要不要带电芯结构(Q5,只读) */
    electrolyteApplies: boolean
    electrolyteShare: string | null
    requiresCellConstruction: boolean
    fields: EditorField[]
    machines: EditorMachine[]
    recipes: EditorRecipe[]
    canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [where, setWhere] = useState<string | null>(null)

    function run(section: string, fn: () => Promise<{ error?: string }>, after?: () => void) {
        setError(null); setWhere(section)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            after?.(); router.refresh()
        })
    }
    const err = (section: string) => (error && where === section ? <p className="mt-2 text-sm text-red-700">{error}</p> : null)

    // ── 容差 ─────────────────────────────────────────────────────────────
    const [tol, setTol] = useState(tolerance ?? '')
    // ── 电解液(MES-4b)─────────────────────────────────────────────────
    const [elApplies, setElApplies] = useState(electrolyteApplies)
    const [elShare, setElShare] = useState(electrolyteShare ?? '')

    // ── 字段 ─────────────────────────────────────────────────────────────
    const [editingField, setEditingField] = useState<string | null>(null)   // field_code | '__new__'
    const [ff, setFf] = useState<FieldInput>({ ...blankField })
    function openField(f: EditorField | null) {
        setError(null)
        if (!f) { setFf({ ...blankField, sort_order: String((fields.at(-1)?.sort_order ?? 0) + 10) }); setEditingField('__new__'); return }
        setFf({
            field_code: f.field_code, name_en: f.name_en, name_zh: f.name_zh, kind: f.kind, value_type: f.value_type, unit: f.unit ?? '',
            is_required: f.is_required, has_range: f.has_range,
            range_min: f.range_min === null ? '' : String(f.range_min), range_max: f.range_max === null ? '' : String(f.range_max),
            sort_order: String(f.sort_order), notes: f.notes ?? '',
        })
        setEditingField(f.field_code)
    }
    const rangeCell = (f: EditorField) => !f.has_range ? <span className="text-[color:var(--brand-muted-text)]">{t('processing.opType.noRange')}</span>
        : f.range_min === null && f.range_max === null ? <span className="text-amber-700" data-not-set="range">{t('dict.notYetSet')}</span>
            : `${f.range_min ?? '—'} – ${f.range_max ?? '—'}`
    const fieldColumns: Column<EditorField>[] = [
        {
            key: 'name', header: t('processing.opType.colField'), priority: true,
            render: (f) => (
                <>
                    {f.name}{f.is_required && <span className="text-red-600"> *</span>}
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">{f.field_code}</span>
                    {!f.is_active && <span className="text-xs text-amber-700">{t('processing.opType.retired')}</span>}
                </>
            ),
        },
        { key: 'kind', header: t('processing.opType.colFieldKind'), render: (f) => t('processing.opType.kind.' + f.kind) },
        { key: 'type', header: t('processing.opType.colValueType'), render: (f) => t('processing.opType.valueType.' + f.value_type) },
        { key: 'unit', header: t('processing.opType.colUnit'), render: (f) => f.unit ?? '—' },
        { key: 'range', header: t('processing.opType.colRange'), priority: true, render: rangeCell },
        {
            key: 'actions', header: '', align: 'right',
            render: (f) => (
                <PermissionGate code={EDIT} allowed={canEdit} inline>
                    <span className="inline-flex gap-2">
                        <Button variant="secondary" size="xs" type="button" disabled={pending} onClick={() => openField(f)}>{t('common.edit')}</Button>
                        {f.is_active ? (
                            <ConfirmButton subject={`${f.field_code} — ${f.name}`} title={t('processing.opType.retireTitle')}
                                body={t('processing.opType.retireBody')} confirmLabel={t('processing.opType.retire')} tier="destructive"
                                disabled={pending} triggerVariant="destructive" triggerSize="xs"
                                onConfirm={() => run('fields', () => setFieldActive(code, f.field_code, false))}>
                                {t('processing.opType.retire')}
                            </ConfirmButton>
                        ) : (
                            <Button variant="secondary" size="xs" type="button" disabled={pending}
                                    onClick={() => run('fields', () => setFieldActive(code, f.field_code, true))}>
                                {t('processing.opType.restore')}
                            </Button>
                        )}
                    </span>
                </PermissionGate>
            ),
        },
    ]

    // ── 机器 ─────────────────────────────────────────────────────────────
    const [pickMachine, setPickMachine] = useState('')
    const linked = machines.filter((m) => m.linked)
    const linkable = machines.filter((m) => !m.linked && !m.disposed)
    const machineColumns: Column<EditorMachine>[] = [
        {
            key: 'machine', header: t('processing.opType.colMachine'), priority: true,
            render: (m) => <>{m.label}{m.disposed && <span className="ml-2 text-xs text-amber-700">{t('processing.opType.disposedNotCounted')}</span>}</>,
        },
        {
            key: 'actions', header: '', align: 'right',
            render: (m) => (
                <PermissionGate code={EDIT} allowed={canEdit} inline>
                    <ConfirmButton subject={m.label} title={t('processing.opType.unlinkTitle')} body={t('processing.opType.unlinkBody')}
                        confirmLabel={t('processing.opType.unlink')} tier="destructive" disabled={pending}
                        triggerVariant="destructive" triggerSize="xs" onConfirm={() => run('machines', () => unlinkMachine(code, m.id))}>
                        {t('processing.opType.unlink')}
                    </ConfirmButton>
                </PermissionGate>
            ),
        },
    ]

    // ── 配方 ─────────────────────────────────────────────────────────────
    const [newRecipe, setNewRecipe] = useState<{ code: string; name_en: string; name_zh: string; notes: string } | null>(null)
    const [versionFor, setVersionFor] = useState<string | null>(null)
    const [vals, setVals] = useState<Record<string, string>>({})
    const [vNotes, setVNotes] = useState('')
    const params = fields.filter((f) => f.kind === 'parameter' && f.is_active)
    function openVersion(r: EditorRecipe) { setVersionFor(r.id); setVals({}); setVNotes(''); setError(null) }
    function saveVersion() {
        const out: Record<string, Json> = {}
        for (const f of params) {
            const raw = (vals[f.field_code] ?? '').trim()
            if (raw === '') continue
            out[f.field_code] = f.value_type === 'number' || f.value_type === 'count' ? Number(raw)
                : f.value_type === 'yes_no' ? raw === 'true' : raw
        }
        run('recipes', () => addRecipeVersion(code, versionFor!, out, vNotes), () => setVersionFor(null))
    }

    const box = 'border border-gray-200 rounded p-4'
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'

    return (
        <div className="space-y-8">
            {/* ── 平衡容差(V1)── */}
            <section data-section="tolerance">
                <h2 className="mb-1">{t('processing.opType.toleranceTitle')}</h2>
                {transforming ? (
                    <>
                        <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.opType.toleranceIntro')}</p>
                        <PermissionGate code={EDIT} allowed={canEdit}>
                            <div className="flex flex-wrap items-end gap-3">
                                <label className="block">
                                    <span className={lbl}>{t('processing.opType.colTolerance')}</span>
                                    <span className="inline-flex items-center gap-1">
                                        <input type="number" min="0" step="any" value={tol} placeholder={t('dict.notYetSet')}
                                               onChange={(e) => setTol(e.target.value)} className={`${CONTROL_INPUT} w-28`} />
                                        <span>%</span>
                                    </span>
                                </label>
                                <Button type="button" disabled={pending} onClick={() => run('tolerance', () => setTolerance(code, tol))}>
                                    {t('common.save')}
                                </Button>
                            </div>
                        </PermissionGate>
                        {tolerance === null && <p className="mt-2 text-sm text-amber-700">{t('processing.opType.toleranceUnset')}</p>}
                        {err('tolerance')}
                    </>
                ) : (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('processing.opType.toleranceNotApplicable')}</p>
                )}
            </section>

            {/* ── 电解液挥发(MES-4b · V10)与电芯结构 ── */}
            <section data-section="electrolyte">
                <h2 className="mb-1">{t('processing.opType.electrolyteTitle')}</h2>
                {transforming ? (
                    <>
                        <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.opType.electrolyteIntro')}</p>
                        <PermissionGate code={EDIT} allowed={canEdit}>
                            <div className="flex flex-wrap items-end gap-4">
                                <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                    <input type="checkbox" checked={elApplies} onChange={(e) => setElApplies(e.target.checked)} />
                                    {t('processing.opType.electrolyteApplies')}
                                </label>
                                <label className="block">
                                    <span className={lbl}>{t('processing.opType.colElectrolyteShare')}</span>
                                    <span className="inline-flex items-center gap-1">
                                        <input type="number" min="0" max="100" step="any" value={elShare} placeholder={t('dict.notYetSet')}
                                               onChange={(e) => setElShare(e.target.value)} className={`${CONTROL_INPUT} w-28`} />
                                        <span>%</span>
                                    </span>
                                </label>
                                <Button type="button" disabled={pending} onClick={() => run('electrolyte', () => setElectrolyte(code, elApplies, elShare))}>
                                    {t('common.save')}
                                </Button>
                            </div>
                        </PermissionGate>
                        {electrolyteApplies && electrolyteShare === null && (
                            <p className="mt-2 text-sm text-amber-700" data-not-set="electrolyte-share">{t('processing.opType.electrolyteShareUnset')}</p>
                        )}
                        {err('electrolyte')}
                    </>
                ) : (
                    <p className="text-sm text-[color:var(--brand-muted-text)]">{t('processing.opType.electrolyteNotApplicable')}</p>
                )}
                {requiresCellConstruction && (
                    <p className="mt-3 text-sm" data-requires="cell-construction">{t('processing.opType.requiresCellConstruction')}</p>
                )}
            </section>

            {/* ── 参数与指标 ── */}
            <section data-section="fields">
                <div className="mb-1 flex items-baseline gap-3">
                    <h2>{t('processing.opType.fieldsTitle')}</h2>
                    <PermissionGate code={EDIT} allowed={canEdit} inline>
                        <Button variant="secondary" className="text-xs" type="button" disabled={pending} onClick={() => openField(null)}>
                            {t('processing.opType.addField')}
                        </Button>
                    </PermissionGate>
                </div>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.opType.fieldsIntro')}</p>
                <DataTable rows={fields} columns={fieldColumns} rowKey={(f) => f.field_code} phone={{ mode: 'columns' }}
                           empty={t('processing.opType.fieldsEmpty')} />
                {err('fields')}
                {editingField && (
                    <div className={`${box} mt-3 grid grid-cols-1 sm:grid-cols-2 gap-3`} data-field-form={editingField}>
                        <label className="block">
                            <span className={lbl}>{t('processing.opType.fieldCode')}</span>
                            <input value={ff.field_code} disabled={editingField !== '__new__'}
                                   onChange={(e) => setFf({ ...ff, field_code: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                            <span className="text-xs text-[color:var(--brand-muted-text)]">
                                {editingField === '__new__' ? t('processing.opType.fieldCodeHint') : t('processing.opType.fieldCodeLocked')}
                            </span>
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('dict.f.sortOrder')}</span>
                            <input type="number" value={ff.sort_order} onChange={(e) => setFf({ ...ff, sort_order: e.target.value })}
                                   className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('dict.f.nameEn')}</span>
                            <input value={ff.name_en} onChange={(e) => setFf({ ...ff, name_en: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('dict.f.nameZh')}</span>
                            <input value={ff.name_zh} onChange={(e) => setFf({ ...ff, name_zh: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('processing.opType.colFieldKind')}</span>
                            <select value={ff.kind} onChange={(e) => setFf({ ...ff, kind: e.target.value })} className={`${CONTROL_SELECT} w-full`}>
                                <option value="parameter">{t('processing.opType.kind.parameter')}</option>
                                <option value="indicator">{t('processing.opType.kind.indicator')}</option>
                            </select>
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('processing.opType.colValueType')}</span>
                            <select value={ff.value_type} onChange={(e) => setFf({ ...ff, value_type: e.target.value })} className={`${CONTROL_SELECT} w-full`}>
                                <option value="number">{t('processing.opType.valueType.number')}</option>
                                <option value="count">{t('processing.opType.valueType.count')}</option>
                                <option value="text">{t('processing.opType.valueType.text')}</option>
                                <option value="yes_no">{t('processing.opType.valueType.yes_no')}</option>
                            </select>
                            {editingField !== '__new__' && <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.opType.typeLockedWhenUsed')}</span>}
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('processing.opType.colUnit')}</span>
                            <input value={ff.unit} onChange={(e) => setFf({ ...ff, unit: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('processing.opType.required')}</span>
                            <select value={ff.is_required ? 'true' : 'false'} onChange={(e) => setFf({ ...ff, is_required: e.target.value === 'true' })}
                                    className={`${CONTROL_SELECT} w-full`}>
                                <option value="false">{t('common.no')}</option>
                                <option value="true">{t('common.yes')}</option>
                            </select>
                            <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.opType.requiredHint')}</span>
                        </label>
                        {(ff.value_type === 'number' || ff.value_type === 'count') && (
                            <>
                                <label className="block">
                                    <span className={lbl}>{t('processing.opType.hasRange')}</span>
                                    <select value={ff.has_range ? 'true' : 'false'} onChange={(e) => setFf({ ...ff, has_range: e.target.value === 'true' })}
                                            className={`${CONTROL_SELECT} w-full`}>
                                        <option value="false">{t('common.no')}</option>
                                        <option value="true">{t('common.yes')}</option>
                                    </select>
                                    <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.opType.hasRangeHint')}</span>
                                </label>
                                {ff.has_range && (
                                    <div className="grid grid-cols-2 gap-2">
                                        <label className="block">
                                            <span className={lbl}>{t('processing.opType.rangeMin')}</span>
                                            <input type="number" step="any" value={ff.range_min} placeholder={t('dict.notYetSet')}
                                                   onChange={(e) => setFf({ ...ff, range_min: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                                        </label>
                                        <label className="block">
                                            <span className={lbl}>{t('processing.opType.rangeMax')}</span>
                                            <input type="number" step="any" value={ff.range_max} placeholder={t('dict.notYetSet')}
                                                   onChange={(e) => setFf({ ...ff, range_max: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                                        </label>
                                    </div>
                                )}
                            </>
                        )}
                        <label className="block sm:col-span-2">
                            <span className={lbl}>{t('dict.f.notes')}</span>
                            <input value={ff.notes} onChange={(e) => setFf({ ...ff, notes: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <div className="sm:col-span-2 flex gap-2">
                            <Button type="button" className="text-xs" disabled={pending}
                                    onClick={() => run('fields', () => (editingField === '__new__'
                                        ? addField(code, { ...ff, has_range: ff.has_range && (ff.value_type === 'number' || ff.value_type === 'count') })
                                        : updateField(code, { ...ff, has_range: ff.has_range && (ff.value_type === 'number' || ff.value_type === 'count') })),
                                        () => setEditingField(null))}>
                                {t('common.save')}
                            </Button>
                            <Button type="button" variant="secondary" className="text-xs" disabled={pending} onClick={() => setEditingField(null)}>
                                {t('common.cancel')}
                            </Button>
                        </div>
                    </div>
                )}
            </section>

            {/* ── 机器(Q9)── */}
            <section data-section="machines">
                <h2 className="mb-1">{t('processing.opType.machinesTitle')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.opType.machinesIntro')}</p>
                <DataTable rows={linked} columns={machineColumns} rowKey={(m) => m.id} phone={{ mode: 'columns' }}
                           empty={t('processing.opType.machinesEmpty')} />
                <PermissionGate code={EDIT} allowed={canEdit}>
                    <div className="mt-3 flex flex-wrap items-end gap-3">
                        <label className="block flex-1 min-w-0">
                            <span className={lbl}>{t('processing.opType.colMachine')}</span>
                            <select value={pickMachine} onChange={(e) => setPickMachine(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                                <option value="" disabled>{t('processing.opType.pickMachine')}</option>
                                {linkable.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
                            </select>
                        </label>
                        <Button type="button" disabled={pending || !pickMachine}
                                onClick={() => run('machines', () => linkMachine(code, pickMachine), () => setPickMachine(''))}>
                            {t('processing.opType.link')}
                        </Button>
                    </div>
                    {linkable.length === 0 && <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('processing.opType.noLinkable')}</p>}
                </PermissionGate>
                {err('machines')}
            </section>

            {/* ── 配方与版本(Q16)── */}
            <section data-section="recipes">
                <div className="mb-1 flex items-baseline gap-3">
                    <h2>{t('processing.opType.recipesTitle')}</h2>
                    <PermissionGate code={EDIT} allowed={canEdit} inline>
                        <Button variant="secondary" className="text-xs" type="button" disabled={pending}
                                onClick={() => { setError(null); setNewRecipe({ code: '', name_en: '', name_zh: '', notes: '' }) }}>
                            {t('processing.opType.addRecipe')}
                        </Button>
                    </PermissionGate>
                </div>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.opType.recipesIntro')}</p>
                {recipes.length === 0 && <p className="text-sm text-[color:var(--brand-muted-text)]">{t('processing.opType.recipesEmpty')}</p>}
                <div className="space-y-3">
                    {recipes.map((r) => (
                        <div key={r.id} className={box} data-recipe={r.code}>
                            <div className="flex flex-wrap items-baseline gap-3">
                                <span className="font-medium">{r.code}</span>
                                <span>{r.name}</span>
                                {!r.is_active && <span className="text-xs text-amber-700">{t('processing.opType.inactive')}</span>}
                                <PermissionGate code={EDIT} allowed={canEdit} inline>
                                    <span className="inline-flex gap-2">
                                        {r.is_active && (
                                            <Button variant="secondary" size="xs" type="button" disabled={pending || params.length === 0} onClick={() => openVersion(r)}>
                                                {t('processing.opType.addVersion')}
                                            </Button>
                                        )}
                                        <Button variant="secondary" size="xs" type="button" disabled={pending}
                                                onClick={() => run('recipes', () => setRecipeActive(code, r.id, !r.is_active))}>
                                            {r.is_active ? t('processing.opType.deactivate') : t('processing.opType.restore')}
                                        </Button>
                                    </span>
                                </PermissionGate>
                            </div>
                            {r.versions.length === 0 ? (
                                <p className="text-sm text-[color:var(--brand-muted-text)] mt-1">{t('processing.opType.noVersions')}</p>
                            ) : (
                                <ul className="mt-2 space-y-1 text-sm">
                                    {r.versions.map((v) => (
                                        <li key={v.id}>
                                            <span className="font-medium">v{v.version}</span>{' — '}
                                            {v.values.length ? v.values.join(' · ') : t('processing.opType.noValues')}
                                            {v.notes && <span className="block text-xs text-[color:var(--brand-muted-text)]">{v.notes}</span>}
                                        </li>
                                    ))}
                                </ul>
                            )}
                            {versionFor === r.id && (
                                <div className="mt-3 grid grid-cols-1 sm:grid-cols-2 gap-3" data-version-form={r.code}>
                                    {params.map((f) => (
                                        <label key={f.field_code} className="block">
                                            <span className={lbl}>{f.name}{f.unit ? ` (${f.unit})` : ''}</span>
                                            {f.value_type === 'yes_no' ? (
                                                <select value={vals[f.field_code] ?? ''} onChange={(e) => setVals({ ...vals, [f.field_code]: e.target.value })}
                                                        className={`${CONTROL_SELECT} w-full`}>
                                                    <option value="">{t('processing.opType.notInRecipe')}</option>
                                                    <option value="true">{t('common.yes')}</option>
                                                    <option value="false">{t('common.no')}</option>
                                                </select>
                                            ) : (
                                                <input type={f.value_type === 'text' ? 'text' : 'number'} step="any" value={vals[f.field_code] ?? ''}
                                                       placeholder={t('processing.opType.notInRecipe')}
                                                       onChange={(e) => setVals({ ...vals, [f.field_code]: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                                            )}
                                        </label>
                                    ))}
                                    <label className="block sm:col-span-2">
                                        <span className={lbl}>{t('dict.f.notes')}</span>
                                        <input value={vNotes} onChange={(e) => setVNotes(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                                        <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.opType.versionFixed')}</span>
                                    </label>
                                    <div className="sm:col-span-2 flex gap-2">
                                        <Button type="button" className="text-xs" disabled={pending} onClick={saveVersion}>{t('processing.opType.saveVersion')}</Button>
                                        <Button type="button" variant="secondary" className="text-xs" disabled={pending} onClick={() => setVersionFor(null)}>
                                            {t('common.cancel')}
                                        </Button>
                                    </div>
                                </div>
                            )}
                        </div>
                    ))}
                </div>
                {params.length === 0 && recipes.length > 0 && (
                    <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]">{t('processing.opType.noParameters')}</p>
                )}
                {newRecipe && (
                    <div className={`${box} mt-3 grid grid-cols-1 sm:grid-cols-2 gap-3`} data-recipe-form>
                        <label className="block">
                            <span className={lbl}>{t('processing.opType.recipeCode')}</span>
                            <input value={newRecipe.code} onChange={(e) => setNewRecipe({ ...newRecipe, code: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                            <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.opType.recipeCodeHint')}</span>
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('dict.f.notes')}</span>
                            <input value={newRecipe.notes} onChange={(e) => setNewRecipe({ ...newRecipe, notes: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('dict.f.nameEn')}</span>
                            <input value={newRecipe.name_en} onChange={(e) => setNewRecipe({ ...newRecipe, name_en: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('dict.f.nameZh')}</span>
                            <input value={newRecipe.name_zh} onChange={(e) => setNewRecipe({ ...newRecipe, name_zh: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <div className="sm:col-span-2 flex gap-2">
                            <Button type="button" className="text-xs" disabled={pending}
                                    onClick={() => run('recipes', () => addRecipe(code, newRecipe), () => setNewRecipe(null))}>
                                {t('common.save')}
                            </Button>
                            <Button type="button" variant="secondary" className="text-xs" disabled={pending} onClick={() => setNewRecipe(null)}>
                                {t('common.cancel')}
                            </Button>
                        </div>
                    </div>
                )}
                {err('recipes')}
            </section>
        </div>
    )
}
