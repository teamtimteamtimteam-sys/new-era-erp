'use client'

// MES-4b(2026-10-07,规格 §3.4;MES-0 Q52;MES-4b Step 0 Q21–Q25,Tim):这一炉的交叉污染抽检 —— 每一班、每一条流至少一次。
//   【抽了】样品与外来物的质量(克)、抽样时刻、方法;抽的那一批是这一炉这条流的一条极片产出。污染率由库算;超过那条流的警戒线(V11)
//   只标出来,从不拒;线没给时"判不了",不是"在范围内"。【没抽】必须写理由 —— 它关掉这一班这条流的提醒,而没抽这件事留在记录里。
//   【更正】新的一行指着旧的(理由必填),旧的留着。记与改都要 action.processing_aftercare(PermissionGate,缺码时说出那个码)。
//   与物料平衡无关:污染不改质量,结平不等它。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { recordContaminationCheck, correctContaminationCheck, type CheckInput } from './contaminationActions'

export type ContaminationStreamView = {
    code: string; label: string; warningPct: number | null
    batches: { id: string; code: string }[]   // 这一炉这条流的极片产出
}
export type ContaminationCheckView = {
    id: number; stream: string; streamLabel: string; kind: 'sampled' | 'not_sampled'
    batchId: string | null; batchCode: string | null
    sampleG: number | null; foreignG: number | null; ratePct: number | null; warningPctAt: number | null; above: boolean | null
    sampledAtIso: string | null; sampledAt: string | null; method: string | null; notSampledReason: string | null
    corrected: boolean; correctionReason: string | null
}

const blank: CheckInput = { kind: 'sampled', outputBatchId: '', sampleG: '', foreignG: '', sampledAt: '', method: '', reason: '' }

export default function ContaminationPanel({ runId, streams, checks, canRecord, predates }: {
    runId: string
    streams: ContaminationStreamView[]
    checks: ContaminationCheckView[]
    canRecord: boolean
    /** MES-4a 之前的单:没有班次,抽检挂不上 */
    predates: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [stream, setStream] = useState(streams[0]?.code ?? '')
    const [f, setF] = useState<CheckInput>({ ...blank })
    const [fixing, setFixing] = useState<ContaminationCheckView | null>(null)
    const [why, setWhy] = useState('')

    const flag = (c: ContaminationCheckView) => c.kind !== 'sampled' ? '—'
        : c.above === true ? <span className="text-red-700 font-medium" data-flag="above">{t('contamination.above')}</span>
            : c.above === false ? t('contamination.within')
                : <span className="text-amber-700">{t('contamination.notJudged')}</span>

    const columns: Column<ContaminationCheckView>[] = [
        { key: 'stream', header: t('contamination.colStream'), priority: true, render: (c) => c.streamLabel },
        {
            key: 'kind', header: t('contamination.colCheck'), priority: true,
            render: (c) => (c.kind === 'sampled'
                ? t('contamination.rate', { rate: c.ratePct === null ? '—' : String(Number(c.ratePct.toFixed(4))), batch: c.batchCode ?? '' })
                : t('contamination.notSampledBecause', { reason: c.notSampledReason ?? '' })),
        },
        { key: 'masses', header: t('contamination.colMasses'), render: (c) => (c.kind === 'sampled' ? `${c.foreignG} / ${c.sampleG} g` : '—') },
        { key: 'flag', header: t('contamination.colWarning'), render: (c) => <>{flag(c)}{c.warningPctAt !== null && c.kind === 'sampled' ? ` (${c.warningPctAt}%)` : ''}</> },
        { key: 'when', header: t('contamination.colSampledAt'), render: (c) => c.sampledAt ?? '—' },
        { key: 'method', header: t('contamination.colMethod'), render: (c) => c.method ?? '—' },
        {
            key: 'correction', header: '', className: 'text-[color:var(--brand-muted-text)]',
            render: (c) => (c.corrected ? t('contamination.correctedBecause', { reason: c.correctionReason ?? '' }) : ''),
        },
        ...(canRecord ? [{
            key: 'actions', header: '', align: 'right' as const,
            render: (c: ContaminationCheckView) => (
                <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={pending}
                        onClick={() => {
                            setFixing(c); setWhy(''); setError(null)
                            setF({ kind: c.kind, outputBatchId: c.batchId ?? '', sampleG: c.sampleG === null ? '' : String(c.sampleG),
                                   foreignG: c.foreignG === null ? '' : String(c.foreignG), sampledAt: c.sampledAtIso ?? '',
                                   method: c.method ?? '', reason: c.notSampledReason ?? '' })
                        }}>
                    {t('contamination.correct')}
                </Button>
            ),
        }] : []),
    ]

    const activeStream = streams.find((s) => s.code === (fixing ? fixing.stream : stream)) ?? null
    function save() {
        setError(null)
        start(async () => {
            const r = fixing
                ? await correctContaminationCheck(runId, fixing.id, f, why)
                : await recordContaminationCheck(runId, stream, f)
            if (r.error) { setError(r.error); return }
            setFixing(null); setF({ ...blank }); setWhy(''); router.refresh()
        })
    }
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'

    return (
        <section className="mt-6" data-section="contamination">
            <h2 className="mb-1">{t('contamination.panelTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-3">{t('contamination.panelIntro')}</p>
            {predates ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('contamination.predates')}</p>
            ) : streams.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]">{t('contamination.noSheets')}</p>
            ) : (
                <>
                    <p className="text-sm mb-2">
                        {streams.map((s) => (
                            <span key={s.code} className="mr-4">
                                {s.label}: {s.warningPct === null
                                    ? <span className="text-amber-700" data-not-set="warning">{t('contamination.warningNotSet')}</span>
                                    : t('contamination.warningAt', { pct: s.warningPct })}
                            </span>
                        ))}
                    </p>
                    <DataTable rows={checks} columns={columns} rowKey={(c) => String(c.id)} phone={{ mode: 'columns' }}
                               empty={t('contamination.emptyRun')} />
                    {error && <p className="mt-2 text-sm text-red-700">{error}</p>}
                    <PermissionGate code="action.processing_aftercare" allowed={canRecord}>
                        <div className="mt-3 border border-gray-200 rounded p-3 space-y-3" data-contamination-form={fixing ? fixing.id : 'new'}>
                            <p className="text-sm font-medium">
                                {fixing ? t('contamination.correctTitle', { stream: fixing.streamLabel }) : t('contamination.recordTitle')}
                            </p>
                            <div className="flex flex-wrap items-end gap-3">
                                {!fixing && (
                                    <label className="block">
                                        <span className={lbl}>{t('contamination.colStream')}</span>
                                        <select value={stream} onChange={(e) => { setStream(e.target.value); setF({ ...f, outputBatchId: '' }) }}
                                                className={CONTROL_SELECT}>
                                            {streams.map((s) => <option key={s.code} value={s.code}>{s.label}</option>)}
                                        </select>
                                    </label>
                                )}
                                <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                    <input type="radio" checked={f.kind === 'sampled'} onChange={() => setF({ ...f, kind: 'sampled' })} />
                                    {t('contamination.kind.sampled')}
                                </label>
                                <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                    <input type="radio" checked={f.kind === 'not_sampled'} onChange={() => setF({ ...f, kind: 'not_sampled' })} />
                                    {t('contamination.kind.not_sampled')}
                                </label>
                            </div>
                            {f.kind === 'sampled' ? (
                                <div className="flex flex-wrap items-end gap-3">
                                    <label className="block">
                                        <span className={lbl}>{t('contamination.colBatch')}</span>
                                        <select value={f.outputBatchId} onChange={(e) => setF({ ...f, outputBatchId: e.target.value })} className={CONTROL_SELECT}>
                                            <option value="">{t('contamination.pickBatch')}</option>
                                            {(activeStream?.batches ?? []).map((b) => <option key={b.id} value={b.id}>{b.code}</option>)}
                                        </select>
                                    </label>
                                    <label className="block">
                                        <span className={lbl}>{t('contamination.sampleG')}</span>
                                        <input type="number" min="0" step="any" value={f.sampleG} onChange={(e) => setF({ ...f, sampleG: e.target.value })}
                                               className={`${CONTROL_INPUT} w-28`} />
                                    </label>
                                    <label className="block">
                                        <span className={lbl}>{t('contamination.foreignG')}</span>
                                        <input type="number" min="0" step="any" value={f.foreignG} onChange={(e) => setF({ ...f, foreignG: e.target.value })}
                                               className={`${CONTROL_INPUT} w-28`} />
                                    </label>
                                    <div>
                                        <span className={lbl}>{t('contamination.colSampledAt')}</span>
                                        <DatePicker kind="datetime" value={f.sampledAt} onChange={(v) => setF({ ...f, sampledAt: v })} className="flex" />
                                    </div>
                                    <label className="block flex-1 min-w-[10rem]">
                                        <span className={lbl}>{t('contamination.colMethod')}</span>
                                        <input type="text" value={f.method} onChange={(e) => setF({ ...f, method: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                                    </label>
                                </div>
                            ) : (
                                <label className="block">
                                    <span className={lbl}>{t('contamination.notSampledReason')}</span>
                                    <input type="text" value={f.reason} onChange={(e) => setF({ ...f, reason: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                                </label>
                            )}
                            {fixing && (
                                <label className="block">
                                    <span className={lbl}>{t('contamination.correctReason')}</span>
                                    <input type="text" value={why} onChange={(e) => setWhy(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                                </label>
                            )}
                            <div className="flex gap-2">
                                <Button type="button" className="text-sm" disabled={pending} onClick={save}>{t('common.save')}</Button>
                                {fixing && (
                                    <Button type="button" variant="secondary" className="text-sm" disabled={pending}
                                            onClick={() => { setFixing(null); setF({ ...blank }) }}>{t('common.cancel')}</Button>
                                )}
                            </div>
                        </div>
                    </PermissionGate>
                </>
            )}
        </section>
    )
}
