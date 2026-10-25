'use client'

// app/safety/incidents/[id]/IncidentBatchesPanel.tsx
// MES-7b-1(2026-10-16,MES-0 Q73;MES-7b Step 0 Q7 · Q8,Tim):这件事故碰过哪几批货 —— 建议、确认、按批号挑、带理由解开。
//   【建议】库给的(suggest_incident_batches):那一刻在事故库位上有货的批 · 那一刻在那台机器上跑的加工单的投入与产出。没有编一个时间窗;
//   一条都不自动链上 —— 每一条由人按「确认」各建一行。没有库位与机器的事故没有建议,这里照直说(不是"没有碰过任何一批")。
//   【按批号挑】任何一批(依据 picked)。【解开】要一句理由,解过就不再改。
//   【一条链接从不设安全状态、不扣货】(MES-0 Q73)。要扣住一批:持 module.quality.edit 的人在这里对一条有效链接开一张来源 incident 的
//   不合格报告(Q8)—— 既有的质量暂扣照常生效,由持 action.ncr_decide 的另一个人决定。
//   缺码时控件看得见、按不动、说出码(DBLOCK-1):链 / 解要 module.safety.edit,开报告要 module.quality.edit。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import Link from 'next/link'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DataTable, type Column, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xTime } from '@/lib/export/cells'
import { linkIncidentBatch, unlinkIncidentBatch, openIncidentNcr } from '../../actions'
import { basisKey } from '../../safetyTypes'

export type LinkRow = {
    id: number; batchKind: 'inbound' | 'output'; batchId: string; batchCode: string; material: string; basis: string; linkedAt: string
    unlinkedAt: string | null; unlinkReason: string | null; active: boolean; href: string
    /** TABLE-EXPORT-3c(Tim 2026-10-25):链上的那个时刻本身(ISO);上面的 linkedAt 是格式化过的字 */
    linkedAtRaw: string
}
export type SuggestionRow = {
    batchKind: 'inbound' | 'output'; batchId: string; batchCode: string; basis: string; evidence: string; qty: string; linked: boolean; href: string
}
type Opt = { value: string; label: string }

export default function IncidentBatchesPanel({ incidentId, incidentCode, links, suggestions, canEdit, canQualityEdit, hasLocation, hasMachine, inboundOptions, outputOptions }: {
    incidentId: string
    /** TABLE-EXPORT-3c:链接批次导出的 About 表写明是哪一件事故 */
    incidentCode: string
    links: LinkRow[]
    suggestions: SuggestionRow[]
    canEdit: boolean
    canQualityEdit: boolean
    hasLocation: boolean
    hasMachine: boolean
    inboundOptions: Opt[]
    outputOptions: Opt[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [pick, setPick] = useState('')
    const [unlinking, setUnlinking] = useState<number | null>(null)
    const [reason, setReason] = useState('')
    const [ncrFor, setNcrFor] = useState<number | null>(null)
    const [description, setDescription] = useState('')

    const stateText = (r: LinkRow) =>
        r.active ? t('safety.batches.active') : t('safety.batches.unlinked', { date: r.unlinkedAt ?? '', reason: r.unlinkReason ?? '' })

    function run(fn: () => Promise<{ error?: string }>, reset: () => void) {
        setError('')
        startTransition(async () => {
            const res = await fn()
            if (res?.error) { setError(res.error); return }
            reset()
            router.refresh()
        })
    }

    // ★ TABLE-EXPORT-3c · Tim Q2(d) PERMANENT:建议批次这张表不导出 —— suggestions to act on, not a record; the linked batches export on the incident page.
    const sugColumns: Column<SuggestionRow>[] = [
        { key: 'batch', header: t('safety.batches.colBatch'), priority: true,
          render: (r) => <Link href={r.href} className="app-link hover:underline">{r.batchCode}</Link> },
        { key: 'why', header: t('safety.batches.colWhy'), render: (r) => `${t(basisKey(r.basis))} · ${r.evidence}` },
        { key: 'qty', header: t('safety.batches.colQty'), align: 'right', render: (r) => r.qty },
        { key: 'act', header: t('safety.batches.colAction'), priority: true,
          render: (r) => r.linked ? <span className="text-xs">{t('safety.batches.alreadyLinked')}</span> : (
              <PermissionGate code="module.safety.edit" allowed={canEdit} inline>
                  <Button type="button" size="sm" disabled={isPending}
                          onClick={() => run(() => linkIncidentBatch(incidentId, { basis: r.basis as 'location' | 'machine_run', batchKind: r.batchKind, batchId: r.batchId }), () => {})}>
                      {t('safety.batches.confirm')}
                  </Button>
              </PermissionGate>
          ) },
    ]

    // ★ TABLE-EXPORT-3c(Tim 2026-10-25):链接批次这张表有一对导出 —— 有效的与【已解开】的都在里面(解开不删行,只记时刻与理由)。
    //   批次那一格屏幕上叠着「批号 · 物料」→ 导出写批号(主值,物料是那一批自己的属性)。
    //   链上的时刻读原始值(xTime)。状态那一格在解开的行上是一句「已解开 <时刻> — <理由>」:
    //     一格只装得下一个值,而 Tim 要这三件(状态 · 时刻 · 理由)都在文件里 → 导出写屏幕上那整句字
    //     (与 docs/table-export.md「组合格导出屏幕上的那段字」同一条;时刻在那句里是文字,与屏幕同一个格式化)。
    //   操作那一列是控件 → exportAs:false。
    const linkColumns: ExportableColumn<LinkRow>[] = [
        { key: 'batch', header: t('safety.batches.colBatch'), priority: true,
          render: (r) => <span><Link href={r.href} className="app-link hover:underline">{r.batchCode}</Link>{r.material ? ` · ${r.material}` : ''}</span>,
          exportAs: (r) => xText(r.batchCode) },
        { key: 'basis', header: t('safety.batches.colBasis'), render: (r) => t(basisKey(r.basis)), exportAs: (r) => xText(t(basisKey(r.basis))) },
        { key: 'linked', header: t('safety.batches.colLinked'), render: (r) => r.linkedAt, exportAs: (r) => xTime(r.linkedAtRaw) },
        { key: 'state', header: t('safety.batches.colState'), priority: true,
          render: (r) => stateText(r), exportAs: (r) => xText(stateText(r)) },
        { key: 'act', header: t('safety.batches.colAction'),
          exportAs: false,
          render: (r) => !r.active ? null : (
              <span className="inline-flex flex-wrap gap-2">
                  <PermissionGate code="module.safety.edit" allowed={canEdit} inline>
                      <Button type="button" size="sm" variant="secondary" disabled={isPending} onClick={() => { setUnlinking(r.id); setReason(''); setNcrFor(null) }}>
                          {t('safety.batches.unlink')}
                      </Button>
                  </PermissionGate>
                  <PermissionGate code="module.quality.edit" allowed={canQualityEdit} inline>
                      <Button type="button" size="sm" variant="secondary" disabled={isPending} onClick={() => { setNcrFor(r.id); setDescription(''); setUnlinking(null) }}>
                          {t('safety.batches.openNcr')}
                      </Button>
                  </PermissionGate>
              </span>
          ) },
    ]

    const unlinkRow = links.find((l) => l.id === unlinking)
    const ncrRow = links.find((l) => l.id === ncrFor)
    const [pickKind, pickId] = pick.split(':')

    return (
        <section className="mt-8" data-section="batches">
            <h2 className="mb-1">{t('safety.batches.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('safety.batches.hint')}</p>
            {error && <p className="text-sm text-red-600 mb-2" data-error="batches">{error}</p>}
            <DataTable rows={links} columns={linkColumns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t('safety.batches.noLinks')}
                       exportSpec={{ name: 'safety-incident-batches', title: t('safety.batches.title'),
                                     aboutExtra: [[t('safety.incidents.colCode'), incidentCode]] }} />

            {unlinkRow && (
                <div className="flex flex-wrap items-end gap-3 mt-3 max-w-3xl" data-form="unlink">
                    <label className="block text-sm min-w-0 flex-1 basis-60">
                        <span className="block mb-1">{t('safety.batches.unlinkReason', { batch: unlinkRow.batchCode })} <span className="text-red-600">*</span></span>
                        <input type="text" value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="unlink_reason" />
                    </label>
                    <Button type="button" disabled={isPending || reason.trim() === ''}
                            onClick={() => run(() => unlinkIncidentBatch(incidentId, unlinkRow.id, reason), () => setUnlinking(null))}>
                        {t('safety.batches.unlinkConfirm')}
                    </Button>
                    <Button type="button" variant="ghost" onClick={() => setUnlinking(null)}>{t('common.cancel')}</Button>
                </div>
            )}
            {ncrRow && (
                <div className="space-y-2 mt-3 max-w-3xl border border-amber-300 bg-amber-50 rounded px-3 py-2" data-form="incident-ncr">
                    <p className="text-sm">{t('safety.batches.ncrWarning', { batch: ncrRow.batchCode })}</p>
                    <label className="block text-sm">
                        <span className="block mb-1">{t('safety.batches.ncrDescription')} <span className="text-red-600">*</span></span>
                        <input type="text" value={description} onChange={(e) => setDescription(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="ncr_description" />
                    </label>
                    <span className="inline-flex flex-wrap gap-2">
                        <Button type="button" disabled={isPending || description.trim() === ''}
                                onClick={() => run(() => openIncidentNcr(incidentId, { batchKind: ncrRow.batchKind, batchId: ncrRow.batchId, description }), () => setNcrFor(null))}>
                            {t('safety.batches.ncrSave')}
                        </Button>
                        <Button type="button" variant="ghost" onClick={() => setNcrFor(null)}>{t('common.cancel')}</Button>
                    </span>
                </div>
            )}

            <h3 className="mt-6 mb-1 text-sm font-medium">{t('safety.batches.suggestionsTitle')}</h3>
            {!hasLocation && !hasMachine ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]" data-value="no-basis">{t('safety.batches.noBasis')}</p>
            ) : (
                <DataTable rows={suggestions} columns={sugColumns} rowKey={(r) => `${r.basis}:${r.batchId}`} phone={{ mode: 'columns' }}
                           empty={t('safety.batches.noSuggestions')} />
            )}

            <div className="flex flex-wrap items-end gap-3 mt-4 max-w-3xl" data-form="pick">
                <label className="block text-sm min-w-0 flex-1 basis-60">
                    <span className="block mb-1">{t('safety.batches.pickLabel')}</span>
                    <select value={pick} onChange={(e) => setPick(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="pick">
                        <option value="">{t('safety.batches.pickNone')}</option>
                        {inboundOptions.length > 0 && <optgroup label={t('safety.batches.inbound')}>{inboundOptions.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</optgroup>}
                        {outputOptions.length > 0 && <optgroup label={t('safety.batches.output')}>{outputOptions.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}</optgroup>}
                    </select>
                </label>
                <PermissionGate code="module.safety.edit" allowed={canEdit} inline>
                    <Button type="button" disabled={isPending || !pick}
                            onClick={() => run(() => linkIncidentBatch(incidentId, { basis: 'picked', batchKind: pickKind as 'inbound' | 'output', batchId: pickId }), () => setPick(''))}>
                        {t('safety.batches.pickSave')}
                    </Button>
                </PermissionGate>
            </div>
        </section>
    )
}
