'use client'

// MES-4a(2026-10-07,Step 0 Q10–Q30,Tim):一张加工单上【提交之后还能记的】四块 ——
//   ① 参数与指标(值:记一个、更正一个;越界只标出来,必填的到结算时才查)
//   ② 异常事件(种类、时刻、时长、处理措施、责任人;更正或撤回,都带理由)
//   ③ 物料平衡(投入 = 产出 + 具名损耗 + 余数;结算时余数不在容差内就要写解释)
//   ④ 抬头更正(开始 / 结束 / 班次 / 机器 / 配方版本 / 备注;旧值、新值、理由记成一行)
// 每一块都只追加:改 = 一条新行指着旧行,旧的留着(审计记录里看得见)。
// 【数都不在这里算】余数、容差、要不要解释 —— 读 processing_run_balance(结算函数读的是同一张底视图);
// 值差不差配方 —— 读 processing_run_values_current。屏幕只画数据库说的话。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_TEXTAREA } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DatePicker } from '@/app/components/ui/date-picker'
import type { Json } from '@/lib/database.types'
import {
    recordRunValue, correctRunValue, recordRunEvent, correctRunEvent, closeRunBalance, correctRunHeader,
    type EventInput,
} from './recordActions'

// ─────────────────────────────────────────────────────────────────────────────
// ① 参数与指标
// ─────────────────────────────────────────────────────────────────────────────
export type ValueRow = {
    field_code: string; name: string; kind: string; value_type: string; unit: string | null
    is_required: boolean; range_text: string | null
    /** 当前那一条(更正链末端);null = 还没记 */
    value_id: number | null
    /** 已经格式化好的值;null = 没记 / 撤回成空 */
    display: string | null
    /** 输入框里的原样字符串(更正时预填) */
    raw: string
    source: string | null
    out_of_range: boolean | null
    differs_from_recipe: boolean | null
    recipe_display: string | null
    corrected: boolean
    correction_reason: string | null
}

function encode(valueType: string, raw: string): Json {
    const v = raw.trim()
    if (v === '') return null
    if (valueType === 'number' || valueType === 'count') return Number(v)
    if (valueType === 'yes_no') return v === 'true'
    return v
}

function ValueInput({ valueType, value, onChange }: { valueType: string; value: string; onChange: (v: string) => void }) {
    const t = useTranslations()
    if (valueType === 'yes_no') {
        return (
            <select value={value} onChange={(e) => onChange(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                <option value="">{t('processing.rec.notRecorded')}</option>
                <option value="true">{t('common.yes')}</option>
                <option value="false">{t('common.no')}</option>
            </select>
        )
    }
    const numeric = valueType === 'number' || valueType === 'count'
    return (
        <input type={numeric ? 'number' : 'text'} step={valueType === 'count' ? '1' : 'any'} value={value}
               onChange={(e) => onChange(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
    )
}

export function ValuesPanel({ runId, rows, canEdit }: { runId: string; rows: ValueRow[]; canEdit: boolean }) {
    const t = useTranslations()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [editing, setEditing] = useState<string | null>(null)
    const [raw, setRaw] = useState('')
    const [reason, setReason] = useState('')
    const row = rows.find((r) => r.field_code === editing) ?? null

    function open(r: ValueRow) { setEditing(r.field_code); setRaw(r.raw); setReason(''); setError(null) }
    function save() {
        if (!row) return
        setError(null)
        start(async () => {
            const res = row.value_id === null
                ? await recordRunValue(runId, row.field_code, encode(row.value_type, raw))
                : await correctRunValue(runId, row.value_id, encode(row.value_type, raw), reason)
            if (res.error) setError(res.error)
            else setEditing(null)
        })
    }

    const columns: Column<ValueRow>[] = [
        {
            key: 'field', header: t('processing.rec.colField'), priority: true,
            render: (r) => (
                <>
                    {r.name}{r.unit ? ` (${r.unit})` : ''}
                    {r.is_required && <span className="text-red-600"> *</span>}
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">
                        {t(r.kind === 'parameter' ? 'processing.rec.kindParameter' : 'processing.rec.kindIndicator')}
                        {r.range_text ? ` · ${r.range_text}` : ''}
                    </span>
                </>
            ),
        },
        {
            key: 'value', header: t('processing.rec.colValue'), priority: true,
            render: (r) => (
                <>
                    {r.display ?? <span className="text-[color:var(--brand-muted-text)] italic">{t('processing.rec.notRecorded')}</span>}
                    {r.out_of_range && <span className="block text-xs text-amber-700" data-out-of-range>{t('processing.rec.outOfRange')}</span>}
                    {r.differs_from_recipe && (
                        <span className="block text-xs text-amber-700" data-differs>
                            {t('processing.rec.differsFromRecipe', { value: r.recipe_display ?? '—' })}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'source', header: t('processing.rec.colSource'),
            render: (r) => (r.source ? t('processing.rec.source.' + r.source) : '—'),
        },
        {
            key: 'correction', header: t('processing.rec.colCorrection'), className: 'text-[color:var(--brand-muted-text)]',
            render: (r) => (r.corrected ? t('processing.rec.correctedBecause', { reason: r.correction_reason ?? '' }) : ''),
        },
        ...(canEdit ? [{
            key: 'actions', header: '', align: 'right' as const,
            render: (r: ValueRow) => (
                <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={pending} onClick={() => open(r)}>
                    {r.value_id === null ? t('processing.rec.record') : t('processing.rec.correct')}
                </Button>
            ),
        }] : []),
    ]

    return (
        <section data-section="run-values">
            <h2 className="mb-1">{t('processing.rec.valuesTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.rec.valuesRunIntro')}</p>
            <DataTable rows={rows} columns={columns} rowKey={(r) => r.field_code} phone={{ mode: 'columns' }}
                       empty={t('processing.rec.valuesEmpty')} />
            {error && <p className="mt-2 text-sm text-red-700">{error}</p>}
            {!canEdit && rows.length > 0 && (
                <PermissionGate code="action.processing_aftercare" allowed={false} inline>
                    <Button type="button" variant="secondary" size="inline" disabled>{t('processing.rec.record')}</Button>
                </PermissionGate>
            )}
            {row && (
                <div className="mt-3 border border-gray-200 rounded p-3 grid grid-cols-1 sm:grid-cols-2 gap-3" data-value-edit={row.field_code}>
                    <div className="sm:col-span-2 text-sm">{row.name}{row.unit ? ` (${row.unit})` : ''}</div>
                    <label className="block">
                        <span className="block mb-1 text-sm">{t('processing.rec.colValue')}</span>
                        <ValueInput valueType={row.value_type} value={raw} onChange={setRaw} />
                        {row.value_id !== null && (
                            <span className="text-xs text-[color:var(--brand-muted-text)]">{t('processing.rec.emptyWithdraws')}</span>
                        )}
                    </label>
                    {row.value_id !== null && (
                        <label className="block">
                            <span className="block mb-1 text-sm">{t('processing.rec.reason')}</span>
                            <input value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                    )}
                    <div className="sm:col-span-2 flex gap-2">
                        <Button type="button" className="text-sm" disabled={pending} onClick={save}>{t('common.save')}</Button>
                        <Button type="button" variant="secondary" className="text-sm" disabled={pending} onClick={() => setEditing(null)}>
                            {t('common.cancel')}
                        </Button>
                    </div>
                </div>
            )}
        </section>
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// ② 异常事件
// ─────────────────────────────────────────────────────────────────────────────
export type EventRow = {
    id: number; event_type_code: string; type_label: string
    occurred_display: string; occurred_at: string
    duration_min: number | null; action_taken: string; responsible_person: string; notes: string | null
    withdrawn: boolean; corrected: boolean; correction_reason: string | null
}
export type EventTypeOption = { code: string; label: string }

const blankEvent = { event_type: '', occurred: '', duration: '', action: '', responsible: '', notes: '' }

export function EventsPanel({ runId, rows, types, canEdit }: {
    runId: string; rows: EventRow[]; types: EventTypeOption[]; canEdit: boolean
}) {
    const t = useTranslations()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    // 'new' | 'fix:<id>' | 'withdraw:<id>' | null
    const [mode, setMode] = useState<string | null>(null)
    const [f, setF] = useState({ ...blankEvent })
    const [reason, setReason] = useState('')

    const input = (): EventInput => ({
        event_type: f.event_type,
        occurred_at: f.occurred || null,
        duration_min: f.duration.trim() === '' ? null : Number(f.duration),
        action_taken: f.action, responsible_person: f.responsible, notes: f.notes,
    })
    function openFix(r: EventRow, withdraw: boolean) {
        setF({ event_type: r.event_type_code, occurred: r.occurred_at, duration: r.duration_min === null ? '' : String(r.duration_min),
               action: r.action_taken, responsible: r.responsible_person, notes: r.notes ?? '' })
        setReason(''); setError(null); setMode((withdraw ? 'withdraw:' : 'fix:') + r.id)
    }
    function save() {
        setError(null)
        start(async () => {
            let res
            if (mode === 'new') res = await recordRunEvent(runId, input())
            else if (mode?.startsWith('fix:')) res = await correctRunEvent(runId, Number(mode.slice(4)), input(), false, reason)
            else res = await correctRunEvent(runId, Number(mode!.slice(9)), input(), true, reason)
            if (res.error) setError(res.error)
            else { setMode(null); setF({ ...blankEvent }) }
        })
    }

    const columns: Column<EventRow>[] = [
        {
            key: 'type', header: t('processing.rec.colEventType'), priority: true,
            render: (r) => (
                <>
                    {r.type_label}
                    {r.withdrawn && <span className="ml-2 text-xs text-amber-700">{t('processing.rec.withdrawn')}</span>}
                </>
            ),
        },
        { key: 'when', header: t('processing.rec.colOccurred'), priority: true, render: (r) => r.occurred_display },
        { key: 'duration', header: t('processing.rec.colDuration'), align: 'right', render: (r) => (r.duration_min ?? '—') },
        { key: 'action', header: t('processing.rec.colAction'), render: (r) => r.action_taken },
        { key: 'responsible', header: t('processing.rec.colResponsible'), render: (r) => r.responsible_person },
        {
            key: 'correction', header: t('processing.rec.colCorrection'), className: 'text-[color:var(--brand-muted-text)]',
            render: (r) => (r.corrected ? t('processing.rec.correctedBecause', { reason: r.correction_reason ?? '' }) : (r.notes ?? '')),
        },
        ...(canEdit ? [{
            key: 'actions', header: '', align: 'right' as const,
            render: (r: EventRow) => (r.withdrawn ? null : (
                <span className="inline-flex gap-2">
                    <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={pending} onClick={() => openFix(r, false)}>
                        {t('processing.rec.correct')}
                    </Button>
                    <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={pending} onClick={() => openFix(r, true)}>
                        {t('processing.rec.withdraw')}
                    </Button>
                </span>
            )),
        }] : []),
    ]

    const withdrawing = mode?.startsWith('withdraw:') ?? false
    return (
        <section data-section="run-events">
            <div className="mb-1 flex items-baseline gap-3">
                <h2>{t('processing.rec.eventsTitle')}</h2>
                <PermissionGate code="action.processing_aftercare" allowed={canEdit} inline>
                    <Button variant="secondary" className="text-xs" type="button" disabled={pending}
                            onClick={() => { setF({ ...blankEvent }); setReason(''); setError(null); setMode('new') }}>
                        {t('processing.rec.eventAdd')}
                    </Button>
                </PermissionGate>
            </div>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.rec.eventsIntro')}</p>
            <DataTable rows={rows} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }}
                       empty={t('processing.rec.eventsEmpty')} />
            {error && <p className="mt-2 text-sm text-red-700">{error}</p>}
            {mode && (
                <div className="mt-3 border border-gray-200 rounded p-3 grid grid-cols-1 sm:grid-cols-2 gap-3" data-event-form={mode}>
                    {!withdrawing && (
                        <>
                            <label className="block">
                                <span className="block mb-1 text-sm">{t('processing.rec.colEventType')}</span>
                                <select value={f.event_type} onChange={(e) => setF({ ...f, event_type: e.target.value })}
                                        className={`${CONTROL_SELECT} w-full`}>
                                    <option value="" disabled>{t('processing.rec.eventTypePick')}</option>
                                    {types.map((ty) => <option key={ty.code} value={ty.code}>{ty.label}</option>)}
                                </select>
                            </label>
                            <label className="block">
                                <span className="block mb-1 text-sm">{t('processing.rec.colOccurred')}</span>
                                <DatePicker kind="datetime" value={f.occurred} onChange={(v) => setF({ ...f, occurred: v })} className="flex" />
                            </label>
                            <label className="block">
                                <span className="block mb-1 text-sm">{t('processing.rec.colDuration')}</span>
                                <input type="number" min="0" step="any" value={f.duration} onChange={(e) => setF({ ...f, duration: e.target.value })}
                                       className={`${CONTROL_INPUT} w-full`} />
                            </label>
                            <label className="block">
                                <span className="block mb-1 text-sm">{t('processing.rec.colResponsible')}</span>
                                <input value={f.responsible} onChange={(e) => setF({ ...f, responsible: e.target.value })}
                                       className={`${CONTROL_INPUT} w-full`} />
                            </label>
                            <label className="block sm:col-span-2">
                                <span className="block mb-1 text-sm">{t('processing.rec.colAction')}</span>
                                <textarea value={f.action} onChange={(e) => setF({ ...f, action: e.target.value })}
                                          className={`${CONTROL_TEXTAREA} w-full`} />
                            </label>
                            <label className="block sm:col-span-2">
                                <span className="block mb-1 text-sm">{t('processing.rec.notes')}</span>
                                <input value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })}
                                       className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        </>
                    )}
                    {withdrawing && <p className="sm:col-span-2 text-sm">{t('processing.rec.withdrawExplain')}</p>}
                    {mode !== 'new' && (
                        <label className="block sm:col-span-2">
                            <span className="block mb-1 text-sm">{t('processing.rec.reason')}</span>
                            <input value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                    )}
                    <div className="sm:col-span-2 flex gap-2">
                        <Button type="button" className="text-sm" disabled={pending} onClick={save}>
                            {withdrawing ? t('processing.rec.withdraw') : t('common.save')}
                        </Button>
                        <Button type="button" variant="secondary" className="text-sm" disabled={pending} onClick={() => setMode(null)}>
                            {t('common.cancel')}
                        </Button>
                    </div>
                </div>
            )}
        </section>
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// ③ 物料平衡
// ─────────────────────────────────────────────────────────────────────────────
export type BalanceView = {
    state: string
    input: string; output: string; loss: string; named: string; remainder: string
    tolerance: string | null
    within: boolean | null
    required_missing: string[]
    outputs_unweighed: number
    last_closed: string | null
    last_explanation: string | null
}

export function BalancePanel({ runId, b, canClose }: { runId: string; b: BalanceView; canClose: boolean }) {
    const t = useTranslations()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [explanation, setExplanation] = useState('')
    const needsExplanation = b.remainder !== '0' && b.within !== true

    function close() {
        setError(null)
        start(async () => {
            const res = await closeRunBalance(runId, explanation)
            if (res.error) setError(res.error)
            else setExplanation('')
        })
    }

    const line = (label: string, value: string) => (
        <div className="flex justify-between gap-4 py-0.5">
            <span className="text-[color:var(--brand-muted-text)]">{label}</span><span className="font-medium tabular-nums">{value}</span>
        </div>
    )

    return (
        <section data-section="run-balance" data-balance-state={b.state}>
            <h2 className="mb-1">{t('processing.rec.balanceTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('processing.rec.balanceIntro')}</p>
            <p className="mb-3 text-sm">
                <span className="px-2 py-1 rounded text-xs bg-gray-200">{t('processing.rec.balanceState.' + b.state)}</span>
                <span className="ml-2">{t('processing.rec.balanceStateHint.' + b.state)}</span>
            </p>
            {b.state !== 'not_applicable' && b.state !== 'before_closure' && (
                <div className="max-w-md text-sm border border-gray-200 rounded p-3">
                    {line(t('processing.rec.balInput'), b.input)}
                    {line(t('processing.rec.balOutput'), b.output)}
                    {line(t('processing.rec.balNamedLoss'), b.named)}
                    {line(t('processing.rec.balRemainder'), b.remainder)}
                    {line(t('processing.rec.balTolerance'), b.tolerance === null ? t('processing.rec.toleranceNotSet') : b.tolerance + '%')}
                    {b.within !== null && line(t('processing.rec.balWithin'), b.within ? t('common.yes') : t('common.no'))}
                </div>
            )}
            {b.last_closed && (
                <p className="mt-2 text-sm">
                    {t('processing.rec.lastClosed', { when: b.last_closed })}
                    {b.last_explanation && <span className="block text-[color:var(--brand-muted-text)]">{b.last_explanation}</span>}
                </p>
            )}
            {b.state === 'open' && (
                <div className="mt-3 space-y-2 max-w-xl">
                    {b.required_missing.length > 0 && (
                        <p className="text-sm text-amber-700">{t('processing.rec.requiredMissing', { fields: b.required_missing.join(', ') })}</p>
                    )}
                    {b.outputs_unweighed > 0 && (
                        <p className="text-sm text-amber-700">{t('processing.rec.outputsUnweighed', { n: String(b.outputs_unweighed) })}</p>
                    )}
                    <label className="block">
                        <span className="block mb-1 text-sm">
                            {t('processing.rec.explanation')}{needsExplanation && <span className="text-red-600"> *</span>}
                        </span>
                        <textarea value={explanation} onChange={(e) => setExplanation(e.target.value)} className={`${CONTROL_TEXTAREA} w-full`} />
                        <span className="text-xs text-[color:var(--brand-muted-text)]">
                            {needsExplanation ? t('processing.rec.explanationNeeded') : t('processing.rec.explanationOptional')}
                        </span>
                    </label>
                    {error && <p className="text-sm text-red-700">{error}</p>}
                    <PermissionGate code="action.processing_aftercare" allowed={canClose} inline>
                        <Button type="button" disabled={pending} onClick={close}>{t('processing.rec.closeBalance')}</Button>
                    </PermissionGate>
                </div>
            )}
        </section>
    )
}

// ─────────────────────────────────────────────────────────────────────────────
// ④ 抬头更正
// ─────────────────────────────────────────────────────────────────────────────
export type HeaderOption = { value: string; label: string }
export type CorrectionRow = { id: number; field_label: string; old_value: string; new_value: string; reason: string; when: string }

export function HeaderCorrectionPanel({ runId, canCorrect, current, shifts, machines, recipes, history, predates }: {
    runId: string
    canCorrect: boolean
    /** 每个字段今天的值(输入框里的原样字符串;时刻是 ISO,选择器按新加坡钟面显示) */
    current: Record<string, string>
    shifts: HeaderOption[]
    machines: HeaderOption[]
    recipes: HeaderOption[]
    history: CorrectionRow[]
    /** MES-4a 之前的单:抬头一个字段都不改(Q21 不回填) */
    predates: boolean
}) {
    const t = useTranslations()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [field, setField] = useState('')
    const [value, setValue] = useState('')
    const [reason, setReason] = useState('')
    const FIELDS = ['started_at', 'ended_at', 'shift_code', 'equipment_id', 'recipe_version_id', 'notes'] as const

    function pick(fd: string) { setField(fd); setValue(current[fd] ?? ''); setError(null) }
    function save() {
        setError(null)
        start(async () => {
            const res = await correctRunHeader(runId, field, value, reason)
            if (res.error) setError(res.error)
            else { setField(''); setValue(''); setReason('') }
        })
    }
    const columns: Column<CorrectionRow>[] = [
        { key: 'field', header: t('processing.rec.colField'), priority: true, render: (r) => r.field_label },
        { key: 'old', header: t('processing.rec.colOld'), render: (r) => r.old_value },
        { key: 'new', header: t('processing.rec.colNew'), priority: true, render: (r) => r.new_value },
        { key: 'reason', header: t('processing.rec.reason'), render: (r) => r.reason },
        { key: 'when', header: t('processing.rec.colWhen'), render: (r) => r.when },
    ]

    return (
        <section data-section="run-header-corrections">
            <h2 className="mb-1">{t('processing.rec.headerTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">
                {predates ? t('processing.rec.headerPredates') : t('processing.rec.headerIntro')}
            </p>
            <DataTable rows={history} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }}
                       empty={t('processing.rec.headerEmpty')} />
            {!predates && (
                <PermissionGate code="action.processing_commit" allowed={canCorrect}>
                    <div className="mt-3 grid grid-cols-1 sm:grid-cols-3 gap-3 items-end" data-header-form>
                        <label className="block">
                            <span className="block mb-1 text-sm">{t('processing.rec.colField')}</span>
                            <select value={field} onChange={(e) => pick(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                                <option value="" disabled>{t('processing.rec.headerPick')}</option>
                                {FIELDS.map((fd) => <option key={fd} value={fd}>{t('processing.rec.headerField.' + fd)}</option>)}
                            </select>
                        </label>
                        <label className="block">
                            <span className="block mb-1 text-sm">{t('processing.rec.colNew')}</span>
                            {field === 'started_at' || field === 'ended_at' ? (
                                <DatePicker kind="datetime" value={value} onChange={setValue} className="flex" />
                            ) : field === 'shift_code' || field === 'equipment_id' || field === 'recipe_version_id' ? (
                                <select value={value} onChange={(e) => setValue(e.target.value)} className={`${CONTROL_SELECT} w-full`}>
                                    <option value="">{t(field === 'shift_code' ? 'processing.rec.shiftPick' : 'processing.rec.noneOption')}</option>
                                    {(field === 'shift_code' ? shifts : field === 'equipment_id' ? machines : recipes)
                                        .map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                                </select>
                            ) : (
                                <input value={value} onChange={(e) => setValue(e.target.value)} disabled={!field} className={`${CONTROL_INPUT} w-full`} />
                            )}
                        </label>
                        <label className="block">
                            <span className="block mb-1 text-sm">{t('processing.rec.reason')}</span>
                            <input value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                        <div className="sm:col-span-3">
                            {error && <p className="mb-2 text-sm text-red-700">{error}</p>}
                            <Button type="button" disabled={pending || !field} onClick={save}>{t('processing.rec.headerSave')}</Button>
                            {!field && <span className="ml-2 text-xs text-[color:var(--brand-muted-text)]">{t('processing.rec.headerPickFirst')}</span>}
                        </div>
                    </div>
                </PermissionGate>
            )}
        </section>
    )
}
