// app/quality/coa/[id]/page.tsx
// MES-6b-2(2026-10-15,MES-0 Q67 · MES-6b Step 0 Q10–Q14 · Q31 · Q32,Tim):一张分析证书 —— 它【签发那一刻】说了什么(全部读快照,不读活数据):
//   那一批、给谁、说话的那一份化验与它怎么被选出来、成分(惩罚元素旁边是 ppm)、指标、来料化学确定度、点了单时那份合同的验收限与判定、
//   签发人与时刻;作废了的写出理由与替代它的那一张。下载存下的那一份(?coa=,重算哈希);提 CFO 作废申请(action.issue_coa)。
//   【门】requireFunction(FN.qualityCoa)(质量查看码与产出查看码);证书行再过一次它自己的读策略(module.output.view)。
//   【这一页不判任何事】作废只经 CFO 申请,签发在那一批的页上。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import WarehouseRequestButton from '@/app/components/inventory/WarehouseRequestButton'
import { formatAuditStamp } from '@/lib/dates'
import { COA_ROW_COLUMNS, type CoaRow, type CoaSnapshot } from '@/app/output/coa/coaTypes'
import { CoaCompositionTable, CoaLimitsTable } from './CoaContentTables'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const ppm = (v: number | string) => `${Math.round(Number(v) * 10000 * 1000) / 1000} ppm`

export default async function CoaPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.qualityCoa)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const supabase = await createClient()
    const [rowRes, snapRes, canIssue] = await Promise.all([
        supabase.from('coa_rows').select(COA_ROW_COLUMNS).eq('id', id).maybeSingle(),
        supabase.from('certificates_of_analysis').select('snapshot').eq('id', id).maybeSingle(),
        can('action.issue_coa'),
    ])
    const c = mustOne(rowRes, 'coa_rows') as unknown as CoaRow | null
    const snapRow = mustOne(snapRes, 'certificates_of_analysis') as { snapshot: CoaSnapshot } | null
    if (!c || !snapRow) notFound()
    const s = snapRow.snapshot
    const issued = c.status === 'issued'
    const so = s.sales_order

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/quality/coa" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{c.code}</span>}
            actions={<span className={`px-3 py-1 rounded text-sm ${issued ? 'bg-green-100' : 'bg-gray-200'}`}>{t('coa.status.' + c.status)}</span>}
            state={{ kind: 'ok' }}
            notices={!issued ? (
                <div className="bg-gray-50 border border-gray-300 px-4 py-3 rounded mb-4 text-sm" data-notice="coa-void">
                    {t('coa.detail.voided', { reason: c.void_reason ?? '—', at: formatAuditStamp(c.voided_at) ?? '—' })}
                    {c.replaced_by_coa_id && c.replaced_by_code && (
                        <> {' '}<Link href={`/quality/coa/${c.replaced_by_coa_id}`} className="app-link hover:underline">{t('coa.replacedBy', { code: c.replaced_by_code })}</Link></>
                    )}
                </div>
            ) : null}
        >
            <RecordHeader
                fields={[
                    { label: t('coa.col.batch'), value: <Link href={`/output/${c.output_batch_id}/edit`} className="app-link hover:underline">{c.batch_code}</Link> },
                    { label: t('coa.col.issuedTo'), value: so ? `${so.customer_name ?? '—'} · ${so.code ?? '—'}` : t('coa.panel.noOrder') },
                    { label: t('coa.detail.assay'), value: s.assay ? `${s.assay.code} · ${t('coa.governedBy.' + s.assay.basis)}` : '—' },
                    { label: t('coa.col.issued'), value: `${formatAuditStamp(c.issued_at) ?? '—'}${s.issuer ? ` · ${s.issuer.name}, ${s.issuer.position}` : ''}` },
                    { label: t('coa.panel.feedChemistry'), value: s.chemistry ? `${s.chemistry.certainty_name} (${s.chemistry.inbound_leaves})` : '—' },
                ]}
            />

            <div className="mt-4 flex flex-wrap gap-4 items-start">
                {c.has_bytes ? (
                    <a className="app-link underline text-sm" href={`/output/${c.output_batch_id}/coa/pdf?coa=${encodeURIComponent(c.code)}`} target="_blank" rel="noopener noreferrer">
                        {t('coa.download')}
                    </a>
                ) : <span className="text-sm text-[color:var(--brand-muted-text)]">{t('coa.noBytes')}</span>}
                {issued && (
                    <WarehouseRequestButton kind="coa_void" subjectId={c.id} subjectCode={c.code} permissionCode="action.issue_coa"
                        allowed={canIssue} openRequestLabel={c.open_request_label} extraPath={`/quality/coa/${c.id}`} size="default" />
                )}
            </div>

            <h2 className="mt-8 mb-1">{t('coa.detail.content')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('coa.detail.contentNote')}</p>
            <CoaCompositionTable rows={s.composition.map((m) => ({
                substance: m.substance, label: m.symbol ? `${m.name} (${m.symbol})` : m.name,
                content: `${String(m.content_pct)}%`, ppm: m.role === 'penalty_element' ? ppm(m.content_pct) : '',
            }))} />
            {s.indicators.length > 0 && (
                <RecordHeader fields={s.indicators.map((i) => ({ label: i.name, value: `${String(i.value)}${i.unit ? ' ' + i.unit : ''}` }))} />
            )}
            {so && so.quality_limit_basis === 'per_parameter' && (
                <>
                    <h2 className="mt-6 mb-1">{t('coa.detail.limits')}</h2>
                    <CoaLimitsTable rows={so.limits.map((l) => {
                        const j = so.judgements.find((x) => x.parameter === l.parameter)
                        return {
                            parameter: l.parameter, label: `${l.name}${l.unit ? ` (${l.unit})` : ''}`,
                            min: l.min_value == null ? '—' : String(l.min_value), max: l.max_value == null ? '—' : String(l.max_value),
                            measured: j && j.value != null ? String(j.value) : '—',
                            judgement: j ? `${t('quality.judgementResult.' + j.result)} · ${j.assay_code}` : t('coa.detail.notJudged'),
                        }
                    })} />
                </>
            )}

            <AuditTrail subject="coa" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
