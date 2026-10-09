'use client'

// app/operation/blending/BlendingPlanForm.tsx
// MES-5b-3(MES-5b Step 0 Q17 · Q20):建 / 改一份配料计划 —— 产出物料、合同(可空)、目标品位、候选批次与计划的公斤数。
//   【这张表单不算预测】预测由数据库算(blending_plan_prediction),保存之后在计划页上读 —— 在这里用 TypeScript 再加权一遍,
//   就是给同一条规则留第二处实现(AGENTS.md:预览要问数据库)。
//   【抄合同】"Copy the contract's grade specs" 只是把那份合同的规格作为几行放进来(带 grade_spec_id);抄哪几条、能不能抄,
//   由服务端按名判(BLEND_TARGET_SPEC_*)—— 这里只帮人少敲几个数。
//   【能不能存】缺 action.wo_create 时整张表单在 PermissionGate 里,看得见、按不动、说出那个码(页面传 canEdit)。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { createBlendingPlan, amendBlendingPlan, type PlanTarget, type PlanLine } from './actions'
import type { MaterialOption, BatchOption, ContractOption, MetalOption } from './options'

type TargetRow = { uid: number; gradeSpecId: string | null; metal: string; min: string; max: string }
type LineRow = { uid: number; batchKey: string; plannedKg: string }

export type PlanInitial = {
    outputMaterialId: string
    contractId: string
    notes: string
    targets: { gradeSpecId: string | null; metal: string; min: number | null; max: number | null }[]
    lines: { batchKey: string; plannedKg: number }[]
}

let uidSeq = 0
const nextUid = () => ++uidSeq

export default function BlendingPlanForm({ mode, planId, materials, batches, contracts, metals, canEdit, inboundVisible, outputVisible, initial }: {
    mode: 'create' | 'amend'
    planId?: string
    materials: MaterialOption[]
    batches: BatchOption[]
    contracts: ContractOption[]
    metals: MetalOption[]
    canEdit: boolean
    inboundVisible: boolean
    outputVisible: boolean
    initial?: PlanInitial
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState(false)
    const [outputMaterialId, setOutputMaterialId] = useState(initial?.outputMaterialId ?? '')
    const [contractId, setContractId] = useState(initial?.contractId ?? '')
    const [notes, setNotes] = useState(initial?.notes ?? '')
    const [targets, setTargets] = useState<TargetRow[]>(() => (initial?.targets ?? []).map((x) => ({
        uid: nextUid(), gradeSpecId: x.gradeSpecId, metal: x.metal,
        min: x.min == null ? '' : String(x.min), max: x.max == null ? '' : String(x.max) })))
    const [lines, setLines] = useState<LineRow[]>(() => (initial?.lines ?? [{ batchKey: '', plannedKg: 0 }]).map((x) => ({
        uid: nextUid(), batchKey: x.batchKey, plannedKg: x.plannedKg ? String(x.plannedKg) : '' })))

    const contract = contracts.find((c) => c.id === contractId) ?? null
    const metalName = (code: string) => metals.find((m) => m.code === code)?.name ?? code

    function copyContract() {
        if (!contract) return
        const fresh = contract.specs
            .filter((s) => !targets.some((x) => x.metal === s.metal))
            .map((s) => ({ uid: nextUid(), gradeSpecId: s.id, metal: s.metal,
                           min: s.min_pct == null ? '' : String(s.min_pct), max: s.max_pct == null ? '' : String(s.max_pct) }))
        setTargets([...targets, ...fresh])
    }

    const validLines = lines.filter((l) => l.batchKey && Number(l.plannedKg) > 0)
    const canSave = !!outputMaterialId && validLines.length > 0 && !isPending

    function save() {
        setError('')
        setSaved(false)
        const payloadTargets: PlanTarget[] = targets
            .filter((x) => x.gradeSpecId || x.metal)
            .map((x) => x.gradeSpecId
                ? { grade_spec_id: x.gradeSpecId }
                : { metal: x.metal, min_pct: x.min === '' ? null : Number(x.min), max_pct: x.max === '' ? null : Number(x.max) })
        const payloadLines: PlanLine[] = validLines.map((l) => {
            const [kind, id] = l.batchKey.split(':')
            return kind === 'inbound' ? { inbound_batch_id: id, planned_kg: Number(l.plannedKg) } : { output_batch_id: id, planned_kg: Number(l.plannedKg) }
        })
        const payload = { output_material_id: outputMaterialId, source_contract_id: contractId || null, notes: notes.trim() || null,
                          targets: payloadTargets, lines: payloadLines }
        startTransition(async () => {
            const res = mode === 'create' ? await createBlendingPlan(payload) : await amendBlendingPlan(planId!, payload)
            if (res?.error) { setError(res.error); return }
            setSaved(true)
            router.refresh()
        })
    }

    return (
        <PermissionGate code="action.wo_create" allowed={canEdit}>
            <div className="space-y-6" data-form="blending-plan">
                {error && <p className="text-sm text-red-600">{error}</p>}
                {saved && <p className="text-sm text-green-700">{t('blending.form.saved')}</p>}

                <div className="flex flex-wrap gap-4">
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('blending.form.outputMaterial')} <span className="text-red-600">*</span></span>
                        <select value={outputMaterialId} onChange={(e) => setOutputMaterialId(e.target.value)}
                                className={`${CONTROL_SELECT} w-full`} data-field="output_material_id">
                            <option value="" disabled>{t('blending.form.pickMaterial')}</option>
                            {materials.map((m) => <option key={m.id} value={m.id}>{m.code} — {m.name}</option>)}
                        </select>
                        <span className="block mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('blending.form.outputMaterialWhy')}</span>
                    </label>
                    <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                        <span className="block mb-1">{t('blending.form.contract')}</span>
                        <select value={contractId} onChange={(e) => setContractId(e.target.value)}
                                className={`${CONTROL_SELECT} w-full`} data-field="source_contract_id">
                            <option value="">{t('blending.form.noContract')}</option>
                            {contracts.map((c) => <option key={c.id} value={c.id}>{c.code} — {c.title}</option>)}
                        </select>
                    </label>
                </div>

                {/* ── 目标品位 ── */}
                <section>
                    <h3 className="text-sm font-semibold mb-1">{t('blending.form.targets')}</h3>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('blending.form.targetsWhy')}</p>
                    <div className="space-y-2">
                        {targets.map((x, i) => (
                            <div key={x.uid} className="flex flex-wrap items-center gap-2" data-row="target">
                                {x.gradeSpecId ? (
                                    <span className="text-sm min-w-0 basis-full sm:basis-auto">
                                        {metalName(x.metal)} · {x.min || '—'} – {x.max || '—'} % · {t('blending.source.contract')}
                                    </span>
                                ) : (
                                    <>
                                        <select value={x.metal} onChange={(e) => setTargets(targets.map((y, j) => j === i ? { ...y, metal: e.target.value } : y))}
                                                className={`${CONTROL_SELECT} min-w-0 basis-full sm:basis-40`} aria-label={t('blending.form.metal')}>
                                            <option value="" disabled>{t('blending.form.metal')}</option>
                                            {metals.map((m) => <option key={m.code} value={m.code}>{m.name}</option>)}
                                        </select>
                                        <input type="number" inputMode="decimal" min={0} max={100} step="any" value={x.min} placeholder={t('blending.form.minPct')}
                                               onChange={(e) => setTargets(targets.map((y, j) => j === i ? { ...y, min: e.target.value } : y))}
                                               className={`${CONTROL_INPUT} w-28`} aria-label={t('blending.form.minPct')} />
                                        <input type="number" inputMode="decimal" min={0} max={100} step="any" value={x.max} placeholder={t('blending.form.maxPct')}
                                               onChange={(e) => setTargets(targets.map((y, j) => j === i ? { ...y, max: e.target.value } : y))}
                                               className={`${CONTROL_INPUT} w-28`} aria-label={t('blending.form.maxPct')} />
                                    </>
                                )}
                                <Button type="button" variant="ghost" size="sm" onClick={() => setTargets(targets.filter((_, j) => j !== i))}>
                                    {t('blending.form.remove')}
                                </Button>
                            </div>
                        ))}
                    </div>
                    <div className="flex flex-wrap gap-2 mt-2">
                        <Button type="button" variant="secondary" size="sm"
                                onClick={() => setTargets([...targets, { uid: nextUid(), gradeSpecId: null, metal: '', min: '', max: '' }])}>
                            {t('blending.form.addTarget')}
                        </Button>
                        <Button type="button" variant="secondary" size="sm" disabled={!contract || contract.specs.length === 0} onClick={copyContract}>
                            {t('blending.form.copyContract')}
                        </Button>
                        {contract && contract.specs.length === 0 && (
                            <span className="text-xs text-[color:var(--brand-muted-text)]">{t('blending.form.contractHasNoSpecs')}</span>
                        )}
                    </div>
                </section>

                {/* ── 候选批次 ── */}
                <section>
                    <h3 className="text-sm font-semibold mb-1">{t('blending.form.lines')}</h3>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('blending.form.linesWhy')}</p>
                    {(!inboundVisible || !outputVisible) && (
                        <p className="text-xs text-amber-700 mb-2">
                            {!inboundVisible ? t('blending.form.inboundRestricted') : t('blending.form.outputRestricted')}
                        </p>
                    )}
                    <div className="space-y-2">
                        {lines.map((l, i) => (
                            <div key={l.uid} className="flex flex-wrap items-center gap-2" data-row="line">
                                <select value={l.batchKey} onChange={(e) => setLines(lines.map((y, j) => j === i ? { ...y, batchKey: e.target.value } : y))}
                                        className={`${CONTROL_SELECT} min-w-0 basis-full sm:basis-0 flex-1`} aria-label={t('blending.form.batch')}>
                                    <option value="" disabled>{t('blending.form.pickBatch')}</option>
                                    {batches.map((b) => (
                                        <option key={b.key} value={b.key}>
                                            {b.code} · {b.materialCode} · {t('blending.form.remaining', { kg: String(b.remaining) })}
                                        </option>
                                    ))}
                                </select>
                                <input type="number" inputMode="decimal" min={0} step="any" value={l.plannedKg} placeholder={t('blending.form.plannedKg')}
                                       onChange={(e) => setLines(lines.map((y, j) => j === i ? { ...y, plannedKg: e.target.value } : y))}
                                       className={`${CONTROL_INPUT} w-32`} aria-label={t('blending.form.plannedKg')} />
                                <Button type="button" variant="ghost" size="sm" onClick={() => setLines(lines.filter((_, j) => j !== i))}>
                                    {t('blending.form.remove')}
                                </Button>
                            </div>
                        ))}
                    </div>
                    <Button type="button" variant="secondary" size="sm" className="mt-2"
                            onClick={() => setLines([...lines, { uid: nextUid(), batchKey: '', plannedKg: '' }])}>
                        {t('blending.form.addLine')}
                    </Button>
                </section>

                <label className="block text-sm">
                    <span className="block mb-1">{t('blending.form.notes')}</span>
                    <textarea value={notes} onChange={(e) => setNotes(e.target.value)} className={CONTROL_TEXTAREA} rows={2} />
                </label>

                <div className="flex flex-wrap items-center gap-3">
                    <Button type="button" disabled={!canSave} onClick={save}>
                        {isPending ? t('common.saving') : mode === 'create' ? t('blending.form.create') : t('blending.form.saveChanges')}
                    </Button>
                    {!canSave && !isPending && <span className="text-xs text-[color:var(--brand-muted-text)]">{t('blending.form.needs')}</span>}
                </div>
            </div>
        </PermissionGate>
    )
}
