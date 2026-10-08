'use client'

// MES-5a-1(2026-10-08,规格 §3.1;MES-0 Q23–Q25;MES-5a Step 0 Q3–Q13,Tim):放电那一炉(verifies_by_unit 的工序)的逐模组结果。
//   【一批什么时候算"已放电并核实"】这一批记了模组数,而且每一个模组要么最新一条结论是通过、要么已拆去隔离(库里判,discharge_verify_batch;
//   这里只读 discharge_status_by_batch 的结果,不重算)。提交这一炉只记下"放过电",状态不动 —— 部分放电再也不会把整批标成已放电。
//   【记结果】模组编号(在这一批里唯一,再放电时沿用)、出口电压、通过 / 失败、判定时刻;失败必须说处置(再放电 / 隔离)。
//     可选:通道、起始电压、时长、回收能量、放电柜、屏幕照片、备注。与 V9 矛盾只标出,从不拒;V9 没设时"判不了"。码:action.confirm_capture。
//   【更正】新的一行指着旧的(理由必填),旧的留着。【通道分配】只追加,可选(手工录入时不必先分配)。码:action.processing_aftercare。
//   【拆去隔离】失败 · 隔离的模组从这里拆成另一批、进一个隔离库位(新的一炉 discharge_quarantine_split;码:action.processing_aftercare,
//     记那一炉本身另要 action.processing_commit)。没有隔离库位时库里永远拒 —— 这里照样摆出来,按得下去,拒绝会说去哪儿标一个。
//   【390 px】(MES-5a-1 close-out 第 e 项,Tim 的裁定 2026-10-08):放电柜下拉、隔离库位下拉与它们的 label 带 min-w-0 max-w-full,
//     照片的文件框带 max-w-full —— 原生控件的内在宽度由最长的选项(与浏览器的文件框)决定,在一个换行的容器里也会把整页撑宽。
import { CONTROL_INPUT, CONTROL_SELECT, CONTROL_FILE_BUTTON } from '@/app/components/ui/control-style'
import { useRef, useState, useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { createClient } from '@/lib/supabase/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { PHOTO_BUCKET, PHOTO_MAX_BYTES, PHOTO_TYPES } from '@/app/operation/weighbridge/ticketFields'
import {
    recordDischargeResult, correctDischargeResult, assignDischargeChannel, correctDischargeChannel,
    splitFailedModules, dischargePhotoUrl, type ResultInput, type SplitInput,
} from './dischargeActions'

export type DischargeBatchView = {
    kind: 'inbound' | 'output'; id: string; code: string; href: string
    moduleCount: number | null
    recorded: number; passed: number; failedRedischarge: number; failedQuarantine: number; splitOut: number; contradictions: number
    /** null = 这一批没有放电进度可读(这一炉回滚了、也没有模组数与结果)—— 画成「—」,不猜 */
    verified: boolean | null
    /** 这一批最新的结论(任何一炉)里"失败 · 隔离、还没拆走"的模组 —— 拆分的候选 */
    quarantineCandidates: string[]
    /** 这一批已有结论的模组编号(任何一炉)—— 记结果时给个提示 */
    knownModules: string[]
}
export type DischargeResultView = {
    id: number; kind: 'inbound' | 'output'; batchId: string; batchCode: string
    moduleRef: string; channelNo: number | null; outletV: number; startV: number | null
    verdict: 'pass' | 'fail'; disposition: 're_discharge' | 'quarantine' | null
    verdictAtIso: string; verdictAt: string
    durationMin: number | null; energyWh: number | null
    passVAt: number | null; contradicts: boolean | null
    deviceId: string | null; deviceLabel: string | null; photoPath: string | null; notes: string | null
    corrected: boolean; correctionReason: string | null
    isLatest: boolean; splitOut: boolean
}
export type DischargeChannelView = {
    id: number; kind: 'inbound' | 'output'; batchId: string; batchCode: string; channelNo: number; moduleRef: string
    corrected: boolean; correctionReason: string | null
}
export type DischargeSplitView = { splitRunId: string; splitRunCode: string; batchCode: string; newBatchId: string; newBatchCode: string; modules: string[] }
type Opt = { value: string; label: string }

const blank = (b?: DischargeBatchView): ResultInput => ({
    kind: b?.kind ?? 'inbound', batchId: b?.id ?? '', moduleRef: '', channelNo: '', outletV: '', startV: '',
    verdict: 'pass', disposition: '', verdictAt: '', durationMin: '', energyWh: '', deviceId: '', photoPath: '', notes: '',
})

/** 存储键里只留安全的字符(与地磅单照片同一条)。 */
function storageSafe(name: string): string {
    const s = name.normalize('NFKD').replace(/[^A-Za-z0-9._-]+/g, '_').replace(/_+/g, '_')
    return s.slice(-80) || 'photo'
}

export default function DischargePanel({
    runId, editable, batches, results, channels, splits, canRecord, canAftercare, devices, locations, locationsVisible, shifts, processDate,
}: {
    runId: string
    /** 已提交、没回滚的一炉才能记;回滚了的是历史 */
    editable: boolean
    batches: DischargeBatchView[]
    results: DischargeResultView[]
    channels: DischargeChannelView[]
    splits: DischargeSplitView[]
    canRecord: boolean
    canAftercare: boolean
    devices: Opt[]
    locations: Opt[]
    /** 库位要库存查看码才读得到;读不到时说「受限」,不说「没有隔离库位」 */
    locationsVisible: boolean
    shifts: Opt[]
    processDate: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [notice, setNotice] = useState<string | null>(null)
    const [f, setF] = useState<ResultInput>(blank(batches[0]))
    const [fixing, setFixing] = useState<DischargeResultView | null>(null)
    const [why, setWhy] = useState('')
    const fileRef = useRef<HTMLInputElement>(null)
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'
    const muted = 'text-sm text-[color:var(--brand-muted-text)]'

    const verdictText = (r: { verdict: string; disposition: string | null }) =>
        r.verdict === 'pass' ? t('discharge.verdict.pass')
            : r.disposition === 'quarantine' ? t('discharge.verdict.failQuarantine') : t('discharge.verdict.failRedischarge')

    // ── 每一批的进度 ────────────────────────────────────────────────────
    const batchColumns: Column<DischargeBatchView>[] = [
        { key: 'batch', header: t('discharge.colBatch'), priority: true, render: (b) => <Link href={b.href} className="hover:underline app-link app-link-inline">{b.code}</Link> },
        {
            key: 'count', header: t('discharge.colModuleCount'), priority: true,
            render: (b) => (b.moduleCount === null
                ? <span className="text-amber-700" data-not-set="module-count">{t('discharge.countNotSet')}</span>
                : t('discharge.progress', { done: b.passed + b.splitOut, count: b.moduleCount })),
        },
        { key: 'passed', header: t('discharge.colPassed'), render: (b) => String(b.passed) },
        { key: 'redis', header: t('discharge.colRedischarge'), render: (b) => String(b.failedRedischarge) },
        { key: 'quar', header: t('discharge.colQuarantine'), render: (b) => String(b.failedQuarantine) },
        { key: 'split', header: t('discharge.colSplitOut'), render: (b) => String(b.splitOut) },
        { key: 'contra', header: t('discharge.colContradictions'), render: (b) => (b.contradictions > 0 ? <span className="text-red-700">{b.contradictions}</span> : '0') },
        {
            key: 'verified', header: t('discharge.colVerified'), priority: true,
            render: (b) => (b.verified === null ? '—' : b.verified
                ? <span className="text-green-700 font-medium" data-verified="yes">{t('discharge.verified')}</span>
                : <span className="text-amber-700" data-verified="no">{t('discharge.notVerified')}</span>),
        },
    ]

    // ── 这一炉的结果 ────────────────────────────────────────────────────
    function openPhoto(path: string) {
        start(async () => {
            const r = await dischargePhotoUrl(path)
            if (r.error || !r.url) { setError(r.error ?? t('discharge.photoOpenError')); return }
            window.open(r.url, '_blank', 'noopener')
        })
    }
    const resultColumns: Column<DischargeResultView>[] = [
        { key: 'module', header: t('discharge.colModule'), priority: true, render: (r) => <span className="font-mono">{r.moduleRef}</span> },
        { key: 'batch', header: t('discharge.colBatch'), render: (r) => r.batchCode },
        {
            key: 'verdict', header: t('discharge.colVerdict'), priority: true,
            render: (r) => (
                <>
                    <span className={r.verdict === 'pass' ? 'text-green-700' : 'text-red-700'}>{verdictText(r)}</span>
                    {r.contradicts === true && <span className="ml-2 text-red-700 font-medium" data-flag="contradicts">{t('discharge.contradicts', { v: r.passVAt ?? '' })}</span>}
                    {r.contradicts === null && <span className="ml-2 text-amber-700" data-flag="not-judged">{t('discharge.notJudged')}</span>}
                    {r.splitOut && <span className="ml-2 text-[color:var(--brand-muted-text)]">{t('discharge.splitOutMark')}</span>}
                    {!r.isLatest && !r.splitOut && <span className="ml-2 text-[color:var(--brand-muted-text)]">{t('discharge.supersededByLater')}</span>}
                </>
            ),
        },
        { key: 'outlet', header: t('discharge.colOutletV'), render: (r) => `${r.outletV} V${r.startV !== null ? ` (${t('discharge.from', { v: r.startV })})` : ''}` },
        { key: 'channel', header: t('discharge.colChannel'), render: (r) => (r.channelNo === null ? '—' : String(r.channelNo)) },
        { key: 'when', header: t('discharge.colVerdictAt'), render: (r) => r.verdictAt },
        { key: 'duration', header: t('discharge.colDuration'), render: (r) => (r.durationMin === null ? '—' : `${r.durationMin} min`) },
        { key: 'energy', header: t('discharge.colEnergy'), render: (r) => (r.energyWh === null ? '—' : `${r.energyWh} Wh`) },
        { key: 'device', header: t('discharge.colDevice'), render: (r) => r.deviceLabel ?? '—' },
        {
            key: 'photo', header: t('discharge.colPhoto'),
            render: (r) => (r.photoPath
                ? <Button type="button" size="xs" variant="ghost" disabled={pending} onClick={() => openPhoto(r.photoPath as string)}>{t('discharge.openPhoto')}</Button>
                : '—'),
        },
        {
            key: 'notes', header: '', className: 'text-[color:var(--brand-muted-text)]',
            render: (r) => [r.notes, r.corrected ? t('discharge.correctedBecause', { reason: r.correctionReason ?? '' }) : null].filter(Boolean).join(' · '),
        },
        ...(editable && canRecord ? [{
            key: 'actions', header: '', align: 'right' as const,
            render: (r: DischargeResultView) => (
                <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={pending}
                        onClick={() => {
                            setFixing(r); setWhy(''); setError(null); setNotice(null)
                            setF({
                                kind: r.kind, batchId: r.batchId, moduleRef: r.moduleRef, channelNo: r.channelNo === null ? '' : String(r.channelNo),
                                outletV: String(r.outletV), startV: r.startV === null ? '' : String(r.startV), verdict: r.verdict,
                                disposition: r.disposition ?? '', verdictAt: r.verdictAtIso, durationMin: r.durationMin === null ? '' : String(r.durationMin),
                                energyWh: r.energyWh === null ? '' : String(r.energyWh), deviceId: r.deviceId ?? '', photoPath: r.photoPath ?? '', notes: r.notes ?? '',
                            })
                        }}>
                    {t('discharge.correct')}
                </Button>
            ),
        }] : []),
    ]

    function save() {
        setError(null); setNotice(null)
        const file = fileRef.current?.files?.[0]
        if (file && !(PHOTO_TYPES as readonly string[]).includes(file.type)) { setError(t('discharge.photoType')); return }
        if (file && file.size > PHOTO_MAX_BYTES) { setError(t('discharge.photoTooLarge')); return }
        start(async () => {
            let input = f
            if (file) {
                const path = `discharge/${runId}/${crypto.randomUUID()}-${storageSafe(file.name)}`
                const { error: upErr } = await createClient().storage.from(PHOTO_BUCKET).upload(path, file, { contentType: file.type, upsert: false })
                if (upErr) { setError(t('discharge.photoUploadError', { message: upErr.message })); return }
                input = { ...f, photoPath: path }
            }
            if (fixing) {
                const r = await correctDischargeResult(runId, fixing.id, input, why)
                if (r.error) { setError(r.error); return }
            } else {
                const r = await recordDischargeResult(runId, input)
                if (r.error) { setError(r.error); return }
                if (r.verified) setNotice(t('discharge.nowVerified', { batch: batches.find((b) => b.id === input.batchId)?.code ?? '' }))
            }
            setFixing(null); setWhy(''); setF({ ...blank(batches.find((b) => b.id === input.batchId)), kind: input.kind, batchId: input.batchId })
            if (fileRef.current) fileRef.current.value = ''
            router.refresh()
        })
    }
    const formBatch = batches.find((b) => b.id === f.batchId) ?? null

    return (
        <section className="mt-6" data-section="discharge">
            <h2 className="mb-1">{t('discharge.panelTitle')}</h2>
            <p className={`${muted} mb-3`}>{t('discharge.panelIntro')}</p>

            <DataTable rows={batches} columns={batchColumns} rowKey={(b) => b.id} phone={{ mode: 'columns' }} empty={t('discharge.noInputs')} />
            {batches.some((b) => b.moduleCount === null) && (
                <p className="mt-2 text-sm text-amber-700">{t('discharge.countNeeded')}</p>
            )}

            <h3 className="mt-5 mb-2 text-sm font-medium">{t('discharge.resultsTitle')}</h3>
            <DataTable rows={results} columns={resultColumns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t('discharge.noResults')} />
            {notice && <p className="mt-2 text-sm text-green-700" role="status">{notice}</p>}
            {error && <p className="mt-2 text-sm text-red-700" role="alert">{error}</p>}

            {editable && batches.length > 0 && (
                <PermissionGate code="action.confirm_capture" allowed={canRecord}>
                    <div className="mt-3 border border-gray-200 rounded p-3 space-y-3" data-discharge-form={fixing ? fixing.id : 'new'}>
                        <p className="text-sm font-medium">
                            {fixing ? t('discharge.correctTitle', { module: fixing.moduleRef, batch: fixing.batchCode }) : t('discharge.recordTitle')}
                        </p>
                        <div className="flex flex-wrap items-end gap-3">
                            {!fixing && (
                                <>
                                    <label className="block">
                                        <span className={lbl}>{t('discharge.colBatch')}</span>
                                        <select value={f.batchId} className={CONTROL_SELECT}
                                                onChange={(e) => { const b = batches.find((x) => x.id === e.target.value); setF({ ...f, batchId: e.target.value, kind: b?.kind ?? 'inbound' }) }}>
                                            {batches.map((b) => <option key={b.id} value={b.id}>{b.code}</option>)}
                                        </select>
                                    </label>
                                    <label className="block">
                                        <span className={lbl}>{t('discharge.colModule')}</span>
                                        <input type="text" value={f.moduleRef} list="discharge-known-modules" onChange={(e) => setF({ ...f, moduleRef: e.target.value })}
                                               className={`${CONTROL_INPUT} w-32`} />
                                        <datalist id="discharge-known-modules">
                                            {(formBatch?.knownModules ?? []).map((m) => <option key={m} value={m} />)}
                                        </datalist>
                                    </label>
                                </>
                            )}
                            <label className="block">
                                <span className={lbl}>{t('discharge.colChannel')}</span>
                                <input type="number" min="1" step="1" value={f.channelNo} onChange={(e) => setF({ ...f, channelNo: e.target.value })} className={`${CONTROL_INPUT} w-20`} />
                            </label>
                            <label className="block">
                                <span className={lbl}>{t('discharge.outletV')}</span>
                                <input type="number" min="0" step="any" value={f.outletV} onChange={(e) => setF({ ...f, outletV: e.target.value })} className={`${CONTROL_INPUT} w-24`} />
                            </label>
                            <label className="block">
                                <span className={lbl}>{t('discharge.startV')}</span>
                                <input type="number" min="0" step="any" value={f.startV} onChange={(e) => setF({ ...f, startV: e.target.value })} className={`${CONTROL_INPUT} w-24`} />
                            </label>
                        </div>
                        <div className="flex flex-wrap items-end gap-3">
                            <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                <input type="radio" checked={f.verdict === 'pass'} onChange={() => setF({ ...f, verdict: 'pass', disposition: '' })} />
                                {t('discharge.verdict.pass')}
                            </label>
                            <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                <input type="radio" checked={f.verdict === 'fail'} onChange={() => setF({ ...f, verdict: 'fail' })} />
                                {t('discharge.verdict.fail')}
                            </label>
                            {f.verdict === 'fail' && (
                                <label className="block">
                                    <span className={lbl}>{t('discharge.disposition')}</span>
                                    <select value={f.disposition} onChange={(e) => setF({ ...f, disposition: e.target.value as ResultInput['disposition'] })} className={CONTROL_SELECT}>
                                        <option value="">{t('discharge.pickDisposition')}</option>
                                        <option value="re_discharge">{t('discharge.dispositionOption.re_discharge')}</option>
                                        <option value="quarantine">{t('discharge.dispositionOption.quarantine')}</option>
                                    </select>
                                </label>
                            )}
                            <div>
                                <span className={lbl}>{t('discharge.colVerdictAt')}</span>
                                <DatePicker kind="datetime" value={f.verdictAt} onChange={(v) => setF({ ...f, verdictAt: v })} className="flex" />
                            </div>
                        </div>
                        <div className="flex flex-wrap items-end gap-3">
                            <label className="block">
                                <span className={lbl}>{t('discharge.durationMin')}</span>
                                <input type="number" min="0" step="any" value={f.durationMin} onChange={(e) => setF({ ...f, durationMin: e.target.value })} className={`${CONTROL_INPUT} w-24`} />
                            </label>
                            <label className="block">
                                <span className={lbl}>{t('discharge.energyWh')}</span>
                                <input type="number" min="0" step="any" value={f.energyWh} onChange={(e) => setF({ ...f, energyWh: e.target.value })} className={`${CONTROL_INPUT} w-24`} />
                            </label>
                            <label className="block min-w-0 max-w-full">
                                <span className={lbl}>{t('discharge.colDevice')}</span>
                                <select value={f.deviceId} onChange={(e) => setF({ ...f, deviceId: e.target.value })} className={`${CONTROL_SELECT} max-w-full`}>
                                    <option value="">{t('discharge.noDevice')}</option>
                                    {devices.map((d) => <option key={d.value} value={d.value}>{d.label}</option>)}
                                </select>
                            </label>
                            <label className="block flex-1 min-w-[10rem]">
                                <span className={lbl}>{t('discharge.notes')}</span>
                                <input type="text" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        </div>
                        <div>
                            <span className={lbl}>{t('discharge.photo')}</span>
                            <input ref={fileRef} type="file" accept={PHOTO_TYPES.join(',')} className={`${CONTROL_FILE_BUTTON} max-w-full`} aria-label={t('discharge.photo')} />
                            <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('discharge.photoHint')}</p>
                        </div>
                        {fixing && (
                            <label className="block">
                                <span className={lbl}>{t('discharge.correctReason')}</span>
                                <input type="text" value={why} onChange={(e) => setWhy(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        )}
                        <div className="flex gap-2">
                            <Button type="button" className="text-sm" disabled={pending} onClick={save}>{t('common.save')}</Button>
                            {fixing && (
                                <Button type="button" variant="secondary" className="text-sm" disabled={pending}
                                        onClick={() => { setFixing(null); setF(blank(batches[0])) }}>{t('common.cancel')}</Button>
                            )}
                        </div>
                    </div>
                </PermissionGate>
            )}

            <ChannelSection runId={runId} editable={editable} batches={batches} channels={channels} canEdit={canAftercare} />

            {editable && batches.filter((b) => b.quarantineCandidates.length > 0).map((b) => (
                <SplitForm key={b.id} runId={runId} batch={b} canSplit={canAftercare} locations={locations} locationsVisible={locationsVisible} shifts={shifts} processDate={processDate} />
            ))}

            {splits.length > 0 && (
                <div className="mt-5" data-section="discharge-splits">
                    <h3 className="mb-2 text-sm font-medium">{t('discharge.splitsTitle')}</h3>
                    <ul className="text-sm space-y-1">
                        {splits.map((s) => (
                            <li key={s.splitRunId}>
                                {t('discharge.splitLine', { modules: s.modules.join(', '), batch: s.batchCode })}{' '}
                                <Link href={`/operation/processing/${s.splitRunId}`} className="hover:underline app-link app-link-inline">{s.splitRunCode}</Link>{' → '}
                                <Link href={`/output/${s.newBatchId}/edit`} className="hover:underline app-link app-link-inline">{s.newBatchCode}</Link>
                            </li>
                        ))}
                    </ul>
                </div>
            )}
        </section>
    )
}

function ChannelSection({ runId, editable, batches, channels, canEdit }: {
    runId: string; editable: boolean; batches: DischargeBatchView[]; channels: DischargeChannelView[]; canEdit: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [batchId, setBatchId] = useState(batches[0]?.id ?? '')
    const [channel, setChannel] = useState('')
    const [moduleRef, setModuleRef] = useState('')
    const [fixing, setFixing] = useState<DischargeChannelView | null>(null)
    const [withdraw, setWithdraw] = useState(false)
    const [why, setWhy] = useState('')
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'

    const columns: Column<DischargeChannelView>[] = [
        { key: 'channel', header: t('discharge.colChannel'), priority: true, render: (c) => String(c.channelNo) },
        { key: 'module', header: t('discharge.colModule'), priority: true, render: (c) => <span className="font-mono">{c.moduleRef}</span> },
        { key: 'batch', header: t('discharge.colBatch'), render: (c) => c.batchCode },
        {
            key: 'correction', header: '', className: 'text-[color:var(--brand-muted-text)]',
            render: (c) => (c.corrected ? t('discharge.correctedBecause', { reason: c.correctionReason ?? '' }) : ''),
        },
        ...(editable && canEdit ? [{
            key: 'actions', header: '', align: 'right' as const,
            render: (c: DischargeChannelView) => (
                <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={pending}
                        onClick={() => { setFixing(c); setChannel(String(c.channelNo)); setModuleRef(c.moduleRef); setWithdraw(false); setWhy(''); setError(null) }}>
                    {t('discharge.correct')}
                </Button>
            ),
        }] : []),
    ]
    function save() {
        setError(null)
        start(async () => {
            const b = batches.find((x) => x.id === batchId)
            const r = fixing
                ? await correctDischargeChannel(runId, fixing.id, channel, moduleRef, withdraw, why)
                : await assignDischargeChannel(runId, b?.kind ?? 'inbound', batchId, channel, moduleRef)
            if (r.error) { setError(r.error); return }
            setFixing(null); setChannel(''); setModuleRef(''); setWithdraw(false); setWhy(''); router.refresh()
        })
    }
    return (
        <div className="mt-5" data-section="discharge-channels">
            <h3 className="mb-1 text-sm font-medium">{t('discharge.channelsTitle')}</h3>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('discharge.channelsIntro')}</p>
            <DataTable rows={channels} columns={columns} rowKey={(c) => String(c.id)} phone={{ mode: 'columns' }} empty={t('discharge.noChannels')} />
            {error && <p className="mt-2 text-sm text-red-700" role="alert">{error}</p>}
            {editable && batches.length > 0 && (
                <PermissionGate code="action.processing_aftercare" allowed={canEdit}>
                    <div className="mt-3 border border-gray-200 rounded p-3 space-y-3" data-channel-form={fixing ? fixing.id : 'new'}>
                        <p className="text-sm font-medium">{fixing ? t('discharge.channelCorrectTitle', { channel: fixing.channelNo }) : t('discharge.channelAssignTitle')}</p>
                        <div className="flex flex-wrap items-end gap-3">
                            {!fixing && (
                                <label className="block">
                                    <span className={lbl}>{t('discharge.colBatch')}</span>
                                    <select value={batchId} onChange={(e) => setBatchId(e.target.value)} className={CONTROL_SELECT}>
                                        {batches.map((b) => <option key={b.id} value={b.id}>{b.code}</option>)}
                                    </select>
                                </label>
                            )}
                            <label className="block">
                                <span className={lbl}>{t('discharge.colChannel')}</span>
                                <input type="number" min="1" step="1" value={channel} disabled={withdraw} onChange={(e) => setChannel(e.target.value)} className={`${CONTROL_INPUT} w-20`} />
                            </label>
                            <label className="block">
                                <span className={lbl}>{t('discharge.colModule')}</span>
                                <input type="text" value={moduleRef} disabled={withdraw} onChange={(e) => setModuleRef(e.target.value)} className={`${CONTROL_INPUT} w-32`} />
                            </label>
                            {fixing && (
                                <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                    <input type="checkbox" checked={withdraw} onChange={(e) => setWithdraw(e.target.checked)} />
                                    {t('discharge.channelWithdraw')}
                                </label>
                            )}
                        </div>
                        {fixing && (
                            <label className="block">
                                <span className={lbl}>{t('discharge.correctReason')}</span>
                                <input type="text" value={why} onChange={(e) => setWhy(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        )}
                        <div className="flex gap-2">
                            <Button type="button" className="text-sm" disabled={pending} onClick={save}>{t('common.save')}</Button>
                            {fixing && (
                                <Button type="button" variant="secondary" className="text-sm" disabled={pending}
                                        onClick={() => { setFixing(null); setChannel(''); setModuleRef(''); setWithdraw(false) }}>{t('common.cancel')}</Button>
                            )}
                        </div>
                    </div>
                </PermissionGate>
            )}
        </div>
    )
}

function SplitForm({ runId, batch, canSplit, locations, locationsVisible, shifts, processDate }: {
    runId: string; batch: DischargeBatchView; canSplit: boolean; locations: Opt[]; locationsVisible: boolean; shifts: Opt[]; processDate: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [s, setS] = useState<SplitInput>({
        kind: batch.kind, batchId: batch.id, modules: [...batch.quarantineCandidates], processDate, startedAt: '', endedAt: '',
        shift: shifts[0]?.value ?? '', locationId: locations[0]?.value ?? '', weightKg: '', notes: '',
    })
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'
    function toggle(m: string, on: boolean) {
        setS({ ...s, modules: on ? [...s.modules, m] : s.modules.filter((x) => x !== m) })
    }
    function save() {
        setError(null)
        start(async () => {
            const r = await splitFailedModules(runId, s)
            if (r.error) { setError(r.error); return }
            if (r.splitRunId) router.push(`/operation/processing/${r.splitRunId}`)
            else router.refresh()
        })
    }
    return (
        <div className="mt-5" data-section="discharge-split" data-batch={batch.code}>
            <h3 className="mb-1 text-sm font-medium">{t('discharge.splitTitle', { batch: batch.code })}</h3>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('discharge.splitIntro')}</p>
            {!locationsVisible
                ? <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('discharge.locationsRestricted')}</p>
                : locations.length === 0 && <p className="text-sm text-amber-700 mb-2" data-not-set="quarantine-location">{t('discharge.noQuarantineLocation')}</p>}
            <PermissionGate code="action.processing_aftercare" allowed={canSplit}>
                <div className="border border-gray-200 rounded p-3 space-y-3">
                    <div className="flex flex-wrap gap-3">
                        {batch.quarantineCandidates.map((m) => (
                            <label key={m} className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                <input type="checkbox" checked={s.modules.includes(m)} onChange={(e) => toggle(m, e.target.checked)} />
                                <span className="font-mono">{m}</span>
                            </label>
                        ))}
                    </div>
                    <div className="flex flex-wrap items-end gap-3">
                        <label className="block min-w-0 max-w-full">
                            <span className={lbl}>{t('discharge.quarantineLocation')}</span>
                            <select value={s.locationId} onChange={(e) => setS({ ...s, locationId: e.target.value })} className={`${CONTROL_SELECT} max-w-full`}>
                                <option value="">{t('discharge.pickLocation')}</option>
                                {locations.map((l) => <option key={l.value} value={l.value}>{l.label}</option>)}
                            </select>
                        </label>
                        <label className="block">
                            <span className={lbl}>{t('discharge.splitWeightKg')}</span>
                            <input type="number" min="0" step="any" value={s.weightKg} onChange={(e) => setS({ ...s, weightKg: e.target.value })} className={`${CONTROL_INPUT} w-28`} />
                        </label>
                        <div>
                            <span className={lbl}>{t('discharge.splitDate')}</span>
                            <DatePicker kind="date" value={s.processDate} onChange={(v) => setS({ ...s, processDate: v })} className="flex" />
                        </div>
                        <label className="block">
                            <span className={lbl}>{t('discharge.splitShift')}</span>
                            <select value={s.shift} onChange={(e) => setS({ ...s, shift: e.target.value })} className={CONTROL_SELECT}>
                                {shifts.map((x) => <option key={x.value} value={x.value}>{x.label}</option>)}
                            </select>
                        </label>
                    </div>
                    <div className="flex flex-wrap items-end gap-3">
                        <div>
                            <span className={lbl}>{t('discharge.splitStarted')}</span>
                            <DatePicker kind="datetime" value={s.startedAt} onChange={(v) => setS({ ...s, startedAt: v })} className="flex" />
                        </div>
                        <div>
                            <span className={lbl}>{t('discharge.splitEnded')}</span>
                            <DatePicker kind="datetime" value={s.endedAt} onChange={(v) => setS({ ...s, endedAt: v })} className="flex" />
                        </div>
                        <label className="block flex-1 min-w-[10rem]">
                            <span className={lbl}>{t('discharge.notes')}</span>
                            <input type="text" value={s.notes} onChange={(e) => setS({ ...s, notes: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                        </label>
                    </div>
                    {/* 加工日决定这一炉落在哪个期间 —— 空着不许按(AGENTS.md:决定期间的日期必填,库里另按名拒) */}
                    <Button type="button" className="text-sm" disabled={pending || s.processDate === ''} onClick={save}>{t('discharge.splitSubmit')}</Button>
                </div>
            </PermissionGate>
            {error && <p className="mt-2 text-sm text-red-700" role="alert">{error}</p>}
        </div>
    )
}
