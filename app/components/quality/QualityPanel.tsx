// app/components/quality/QualityPanel.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-6a-1(2026-10-09,MES-6a Step 0 Q7 · Q16 · Q11,Tim)· 一批的样品与化验争议
// ════════════════════════════════════════════════════════════════════════════
// 【住在哪】/inbound/[id]/edit · /output/[id]/edit · 两种化验页(进料 / 产出)。批次页上是这一批的全部;化验页上多一行"这份结果化验的是哪份样品"。
// 【谁看得见】持质量查看码、或这一批自己那一页查看码的人(sample_rows / assay_dispute_rows 的门是同一句)——
//   所以它照样画给没有质量码的读者;只是指向 /quality 的链接对他们是一段字(那几页要 module.quality.view,点进去只会得到一句拒绝)。
// 【开着的争议说出它挡着什么】进料:应用、试算、化验来源的定价过账;产出:卖方结算。说的是库里那几道拒绝(ASSAY_DISPUTE_OPEN),这里不判。
// 【入口】取样 / 立争议要 module.quality.edit —— 缺码时画真的 <Button disabled>,由 PermissionGate 点名那个码(DBLOCK-1)。
// ★ MES-6b-1(2026-10-15,MES-6b Step 0 Q5 · Q26 · Q39,Tim):【质量暂扣】一行 —— 扣着这一批的那张不合格报告(开着的,或拒收而货还在的)
//   单独一行,与争议那一行、批次页上的隔离那一行各说各的(三件事互不放行,Q5);这一批的报告清单;"开一张不合格报告"(module.quality.edit);
//   产出批另列质量验收限的判定(参数 · 值 · 判的那一刻抄下的限 · 结果 · 销售单)。扣没扣着读 ncr_rows.holding(库里的 ncr_holds),这里不判。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { sampleKindKey, sampleStateKey, disputeStatusKey, ncrStatusKey, ncrDispositionKey, judgementResultKey } from '@/app/quality/qualityTypes'
import { qualityParameterLabeller } from './qualityParameters'

export default async function QualityPanel({ kind, batchId, assaySampleId }: {
    kind: 'inbound' | 'output'
    batchId: string
    /** 化验页:这份结果化验的样品(可空)—— 有就多说一行 */
    assaySampleId?: string | null
}) {
    const t = await getTranslations()
    const supabase = await createClient()
    const col = kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id'
    const locale = await getLocale()
    const [sRes, dRes, nRes, jRes, canView, canEdit, paramLabel] = await Promise.all([
        supabase.from('sample_rows').select('id, code, kind, state, retention_due').eq(col, batchId).order('created_at', { ascending: false }),
        supabase.from('assay_dispute_rows').select('id, status, our_assay_code, counterparty_assay_code, created_at').eq(col, batchId).order('created_at', { ascending: false }),
        supabase.from('ncr_rows').select('id, code, status, disposition, holding, opened_at').eq(col, batchId).order('opened_at', { ascending: true }),
        kind === 'output'
            ? supabase.from('quality_limit_judgements').select('id, parameter, value, limit_min_at, limit_max_at, result, sales_order_id, assay_result_id, judged_at, sales_orders ( code ), assay_results ( code )')
                .eq('output_batch_id', batchId).order('id', { ascending: false })
            : null,
        can('module.quality.view'),
        can('module.quality.edit'),
        qualityParameterLabeller(supabase, locale, t),
    ])
    const ncrs = mustRows(nRes, 'ncr_rows') as { id: string; code: string; status: string; disposition: string | null; holding: boolean }[]
    const judgements = jRes ? mustRows(jRes, 'quality_limit_judgements') as unknown as {
        id: number; parameter: string; value: number | null; limit_min_at: number | null; limit_max_at: number | null; result: string
        sales_order_id: string; sales_orders: { code: string } | null; assay_results: { code: string } | null
    }[] : []
    const holdingNcr = ncrs.find((x) => x.holding) ?? null
    const samples = mustRows(sRes, 'sample_rows') as { id: string; code: string; kind: string; state: string; retention_due: boolean | null }[]
    const disputes = mustRows(dRes, 'assay_dispute_rows') as { id: string; status: string; our_assay_code: string; counterparty_assay_code: string; created_at: string }[]
    const open = disputes.find((d) => d.status === 'open') ?? null
    const ref = `${kind}:${batchId}`
    const sampleLink = (s: { id: string; code: string }) =>
        canView ? <Link href={`/quality/samples/${s.id}`} className="app-link hover:underline">{s.code}</Link> : <span>{s.code}</span>
    const disputeLink = (d: { id: string }, label: string) =>
        canView ? <Link href={`/quality/disputes/${d.id}`} className="app-link hover:underline">{label}</Link> : <span>{label}</span>
    const assaySample = assaySampleId ? samples.find((s) => s.id === assaySampleId) ?? null : null
    const ncrLink = (x: { id: string; code: string }) =>
        canView ? <Link href={`/quality/ncr/${x.id}`} className="app-link hover:underline">{x.code}</Link> : <span>{x.code}</span>
    const num = (v: number | null) => (v == null ? '—' : String(Number(v)))

    return (
        <section className="mt-8" data-panel="quality">
            <h2 className="mb-1">{t('quality.panel.title')}</h2>
            {holdingNcr && (
                <div className="bg-red-50 border border-red-300 px-4 py-3 rounded mb-3 text-sm" data-notice="quality-hold">
                    {holdingNcr.status === 'open' ? t('quality.panel.holdOpen') : t('quality.panel.holdReject')}{' '}{ncrLink(holdingNcr)}
                </div>
            )}
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
            {ncrs.length > 0 && (
                <>
                    <p className="text-sm mb-1">{t('quality.panel.ncrs')}</p>
                    <ul className="text-sm mb-2 space-y-0.5" data-list="ncrs">
                        {ncrs.map((x) => (
                            <li key={x.id}>
                                {ncrLink(x)} · {x.status === 'open' ? t(ncrStatusKey('open')) : t(ncrDispositionKey(x.disposition ?? ''))}
                                {x.holding && <span className="ml-2 text-xs text-red-700">{t('quality.ncr.holdingFlag')}</span>}
                            </li>
                        ))}
                    </ul>
                </>
            )}
            {judgements.length > 0 && (
                <>
                    <p className="text-sm mb-1">{t('quality.panel.judgements')}</p>
                    <ul className="text-sm mb-2 space-y-0.5" data-list="quality-judgements">
                        {judgements.map((j) => (
                            <li key={j.id}>
                                {paramLabel(j.parameter)} · {j.value == null ? '—' : num(j.value)} ·{' '}
                                {t('quality.ncr.limitRange', { min: num(j.limit_min_at), max: num(j.limit_max_at) })} ·{' '}
                                <span className={j.result === 'below_min' || j.result === 'above_max' ? 'text-red-700' : ''}>{t(judgementResultKey(j.result))}</span>
                                {' '}· {j.sales_orders?.code ?? t('common.restricted')} · {j.assay_results?.code ?? '—'}
                            </li>
                        ))}
                    </ul>
                </>
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
                        <Button asChild variant="secondary" size="sm"><Link href={`/quality/ncr/new?batch=${ref}`}>{t('quality.ncr.add')}</Link></Button>
                    </>
                ) : (
                    <PermissionGate code="module.quality.edit" allowed={false} inline className="flex-wrap">
                        <Button variant="secondary" size="sm" disabled>{t('quality.samples.add')}</Button>
                        <Button variant="secondary" size="sm" disabled>{t('quality.disputes.add')}</Button>
                        <Button variant="secondary" size="sm" disabled>{t('quality.ncr.add')}</Button>
                    </PermissionGate>
                )}
            </div>
        </section>
    )
}
