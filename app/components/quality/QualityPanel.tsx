// app/components/quality/QualityPanel.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q16 · Q11,Tim)· 一批的样品与化验争议
// ════════════════════════════════════════════════════════════════════════════
// 【住在哪】/inbound/[id]/edit · /output/[id]/edit · 两种化验页(进料 / 产出)。批次页上是这一批的全部;化验页上多一行"这份结果化验的是哪份样品"。
// 【谁看得见】持质量查看码、或这一批自己那一页查看码的人(sample_rows / assay_dispute_rows 的门是同一句)——
//   所以它照样画给没有质量码的读者;只是指向 /quality 的链接对他们是一段字(那几页要 module.quality.view,点进去只会得到一句拒绝)。
// 【开着的争议说出它挡着什么】进料:应用、试算、化验来源的定价过账;产出:卖方结算。说的是库里那几道拒绝(ASSAY_DISPUTE_OPEN),这里不判。
// 【入口】取样 / 立争议要 module.quality.edit —— 缺码时画真的 <Button disabled>,由 PermissionGate 点名那个码(DBLOCK-1)。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { sampleKindKey, sampleStateKey, disputeStatusKey } from '@/app/quality/qualityTypes'

export default async function QualityPanel({ kind, batchId, assaySampleId }: {
    kind: 'inbound' | 'output'
    batchId: string
    /** 化验页:这份结果化验的样品(可空)—— 有就多说一行 */
    assaySampleId?: string | null
}) {
    const t = await getTranslations()
    const supabase = await createClient()
    const col = kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id'
    const [sRes, dRes, canView, canEdit] = await Promise.all([
        supabase.from('sample_rows').select('id, code, kind, state, retention_due').eq(col, batchId).order('created_at', { ascending: false }),
        supabase.from('assay_dispute_rows').select('id, status, our_assay_code, counterparty_assay_code, created_at').eq(col, batchId).order('created_at', { ascending: false }),
        can('module.quality.view'),
        can('module.quality.edit'),
    ])
    const samples = mustRows(sRes, 'sample_rows') as { id: string; code: string; kind: string; state: string; retention_due: boolean | null }[]
    const disputes = mustRows(dRes, 'assay_dispute_rows') as { id: string; status: string; our_assay_code: string; counterparty_assay_code: string; created_at: string }[]
    const open = disputes.find((d) => d.status === 'open') ?? null
    const ref = `${kind}:${batchId}`
    const sampleLink = (s: { id: string; code: string }) =>
        canView ? <Link href={`/quality/samples/${s.id}`} className="app-link hover:underline">{s.code}</Link> : <span>{s.code}</span>
    const disputeLink = (d: { id: string }, label: string) =>
        canView ? <Link href={`/quality/disputes/${d.id}`} className="app-link hover:underline">{label}</Link> : <span>{label}</span>
    const assaySample = assaySampleId ? samples.find((s) => s.id === assaySampleId) ?? null : null

    return (
        <section className="mt-8" data-panel="quality">
            <h2 className="mb-1">{t('quality.panel.title')}</h2>
            {open && (
                <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-3 text-sm" data-notice="dispute-open">
                    {kind === 'inbound' ? t('quality.dispute.holdsInbound') : t('quality.dispute.holdsOutput')}{' '}
                    {disputeLink(open, t('quality.panel.openDispute', { ours: open.our_assay_code, counterparty: open.counterparty_assay_code }))}
                </div>
            )}
            {assaySampleId !== undefined && (
                <p className="text-sm mb-2">
                    {t('quality.panel.assaySample')}:{' '}
                    {assaySample ? sampleLink(assaySample) : <span className="text-[color:var(--brand-muted-text)]">{t('quality.panel.noSample')}</span>}
                </p>
            )}
            <p className="text-sm mb-1">{t('quality.panel.samples')}</p>
            {samples.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('quality.panel.noSamples')}</p>
            ) : (
                <ul className="text-sm mb-2 space-y-0.5">
                    {samples.map((s) => (
                        <li key={s.id}>
                            {sampleLink(s)} · {t(sampleKindKey(s.kind))} · {t(sampleStateKey(s.state))}
                            {s.retention_due && <span className="ml-2 text-xs text-amber-700">{t('quality.samples.flagDue')}</span>}
                        </li>
                    ))}
                </ul>
            )}
            {disputes.length > 0 && (
                <>
                    <p className="text-sm mb-1">{t('quality.panel.disputes')}</p>
                    <ul className="text-sm mb-2 space-y-0.5">
                        {disputes.map((d) => (
                            <li key={d.id}>
                                {disputeLink(d, `${d.our_assay_code} · ${d.counterparty_assay_code}`)} · {t(disputeStatusKey(d.status))}
                            </li>
                        ))}
                    </ul>
                </>
            )}
            <div className="flex flex-wrap gap-2">
                {canEdit ? (
                    <>
                        <Button asChild variant="secondary" size="sm"><Link href={`/quality/samples/new?batch=${ref}`}>{t('quality.samples.add')}</Link></Button>
                        {!open && <Button asChild variant="secondary" size="sm"><Link href={`/quality/disputes/new?batch=${ref}`}>{t('quality.disputes.add')}</Link></Button>}
                    </>
                ) : (
                    <PermissionGate code="module.quality.edit" allowed={false} inline className="flex-wrap">
                        <Button variant="secondary" size="sm" disabled>{t('quality.samples.add')}</Button>
                        <Button variant="secondary" size="sm" disabled>{t('quality.disputes.add')}</Button>
                    </PermissionGate>
                )}
            </div>
        </section>
    )
}
