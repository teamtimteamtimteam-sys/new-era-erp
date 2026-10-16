// app/quality/ncr/[id]/page.tsx
// MES-6b-1(2026-10-15,MES-0 Q65 · Q66;MES-6b Step 0 Q7 · Q9 · Q21 · Q22 · Q26,Tim):一张不合格报告 —— 它扣着哪一批、为什么开的、指着什么、
//   系统开的那一张的判定(参数、值、抄下的限),以及决定:谁、什么时候、怎么处置、钱走哪一张单据。
//   【门】requireFunction(FN.qualityNcr) = module.quality.view;决定要 action.ncr_decide(缺码时整块看得见、按不动、说出那个码)。
//   【四眼】开单人这个人永远不能决定自己那一张 —— 库里按人认(同一个人的另一个账号也算);这里只在【同一个账号】时先说一句,不替库判。
//   【这一页不判任何事】扣没扣着读 ncr_rows.holding(库里的 ncr_holds);处置的效果由 decide_ncr 回答。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { ncrStatusKey, ncrSourceKey, ncrDispositionKey, judgementResultKey, batchHref, assayHref } from '../../qualityTypes'
import { qualityParameterLabeller } from '@/app/components/quality/qualityParameters'
import DecideForm, { type Option } from './DecideForm'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type N = {
    id: string; code: string; status: string; source: string; batch_kind: string; inbound_batch_id: string | null; output_batch_id: string | null
    batch_code: string; description: string; assay_result_id: string | null; assay_code: string | null; assay_dispute_id: string | null
    sales_order_id: string | null; sales_order_code: string | null; judgement_id: number | null; judgement_parameter: string | null
    judgement_value: number | null; judgement_limit_min: number | null; judgement_limit_max: number | null; judgement_result: string | null
    judgement_contract_code: string | null; opened_at: string; opened_by: string | null; opened_by_system: boolean; disposition: string | null
    decision_note: string | null; decided_at: string | null; penalty_invoice_request_id: string | null; penalty_invoice_request_label: string | null
    penalty_price_request_id: string | null; penalty_price_request_label: string | null; holding: boolean
    incident_id: string | null; incident_code: string | null
}

const num = (v: number | null) => (v == null ? '—' : String(Number(v)))

export default async function NcrPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.qualityNcr)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const n = mustOne(
        await supabase.from('ncr_rows')
            .select('id, code, status, source, batch_kind, inbound_batch_id, output_batch_id, batch_code, description, assay_result_id, assay_code, assay_dispute_id, sales_order_id, sales_order_code, judgement_id, judgement_parameter, judgement_value, judgement_limit_min, judgement_limit_max, judgement_result, judgement_contract_code, opened_at, opened_by, opened_by_system, disposition, decision_note, decided_at, penalty_invoice_request_id, penalty_invoice_request_label, penalty_price_request_id, penalty_price_request_label, holding, incident_id, incident_code')
            .eq('id', id).maybeSingle(),
        'ncr_rows') as N | null
    if (!n) notFound()
    const batchId = (n.inbound_batch_id ?? n.output_batch_id)!
    const open = n.status === 'open'

    const [canDecide, canFinance, canPrices, canSafety, paramLabel] = await Promise.all([
        can('action.ncr_decide'), can('module.finance.view'), can('data.view_purchase_prices'), can('module.safety.view'),
        qualityParameterLabeller(supabase, locale, t),
    ])
    // 读不出"我是谁"(会话判断不出)→ 不预判"是你开的";库里的四眼守卫(forbid_self_approval)照样按名拒
    const { data: meData, error: meErr } = await supabase.auth.getUser()
    const myUserId = meErr ? null : (meData.user?.id ?? null)
    const selfOpened = !!myUserId && n.opened_by === myUserId

    // 带罚接受时钱走的那一张单据:产出批 → 贷项通知申请(财务读得到);进料批 → 这一批的收货定价申请(看得见采购价的人读得到)
    let penaltyOptions: Option[] = []
    let penaltyRestricted = false
    if (open) {
        if (n.batch_kind === 'output') {
            if (canFinance) {
                penaltyOptions = (mustRows(
                    await supabase.from('invoice_requests').select('id, label, status, created_at').eq('kind', 'credit_note')
                        .in('status', ['submitted', 'approved']).order('created_at', { ascending: false }).limit(100),
                    'invoice_requests') as { id: string; label: string; status: string }[])
                    .map((r) => ({ id: r.id, label: `${r.label} · ${t('quality.ncr.requestStatus.' + r.status)}` }))
            } else penaltyRestricted = true
        } else if (canPrices) {
            penaltyOptions = (mustRows(
                await supabase.from('receipt_price_requests').select('id, label, status').eq('inbound_batch_id', batchId)
                    .in('status', ['submitted', 'approved']).order('created_at', { ascending: false }),
                'receipt_price_requests') as { id: string; label: string; status: string }[])
                .map((r) => ({ id: r.id, label: `${r.label} · ${t('quality.ncr.requestStatus.' + r.status)}` }))
        } else penaltyRestricted = true
    }

    const judgement = n.judgement_id != null ? [
        { label: t('quality.ncr.judgedParameter'), value: paramLabel(n.judgement_parameter ?? '') },
        { label: t('quality.ncr.judgedValue'), value: n.judgement_value == null ? t('quality.judgementResult.not_measured') : num(n.judgement_value) },
        { label: t('quality.ncr.judgedLimit'), value: t('quality.ncr.limitRange', { min: num(n.judgement_limit_min), max: num(n.judgement_limit_max) }) },
        { label: t('quality.ncr.judgedResult'), value: t(judgementResultKey(n.judgement_result ?? '')) },
        { label: t('quality.ncr.judgedContract'), value: n.judgement_contract_code ?? '—' },
    ] : []
    const moneyDoc = n.penalty_invoice_request_label ?? n.penalty_price_request_label

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/quality/ncr" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{n.code}</span>}
            actions={
                <span className={`px-3 py-1 rounded text-sm ${open ? 'bg-amber-100' : 'bg-gray-200'}`}>
                    {open ? t(ncrStatusKey('open')) : t(ncrDispositionKey(n.disposition ?? ''))}
                </span>
            }
            state={{ kind: 'ok' }}
            notices={
                n.holding ? (
                    <div className="bg-red-50 border border-red-300 px-4 py-3 rounded mb-4 text-sm" data-notice="ncr-holding">
                        {open ? t('quality.ncr.holdingOpen', { batch: n.batch_code }) : t('quality.ncr.holdingReject', { batch: n.batch_code })}
                    </div>
                ) : null
            }
        >
            <RecordHeader
                fields={[
                    { label: t('quality.ncr.colBatch'), value: <Link href={batchHref(n.batch_kind, batchId)} className="app-link hover:underline">{n.batch_code}</Link> },
                    { label: t('quality.ncr.colSource'), value: t(ncrSourceKey(n.source)) },
                    // MES-7b-1(Q8):来源 incident 的那一张指着它那件事故(事故页的门是 module.safety.view;读不到就是一段字)
                    ...(n.incident_id ? [{ label: t('quality.ncr.incident'), value: canSafety
                        ? <Link href={`/safety/incidents/${n.incident_id}`} className="app-link hover:underline">{n.incident_code}</Link> : (n.incident_code ?? '—') }] : []),
                    { label: t('quality.ncr.colOpened'), value: `${formatAuditStamp(n.opened_at)}${n.opened_by_system ? ` · ${t('quality.ncr.bySystem')}` : ''}` },
                    { label: t('quality.ncr.linkAssay'), value: n.assay_result_id
                        ? <Link href={assayHref(n.batch_kind, batchId, n.assay_result_id)} className="app-link hover:underline">{n.assay_code}</Link> : '—' },
                    { label: t('quality.ncr.linkDispute'), value: n.assay_dispute_id
                        ? <Link href={`/quality/disputes/${n.assay_dispute_id}`} className="app-link hover:underline">{t('quality.ncr.openDispute')}</Link> : '—' },
                    ...(n.batch_kind === 'output' ? [{ label: t('quality.ncr.linkSalesOrder'), value: n.sales_order_id
                        ? <Link href={`/sales/orders/${n.sales_order_id}`} className="app-link hover:underline">{n.sales_order_code}</Link> : '—' }] : []),
                ]}
            />

            <h2 className="mt-6 mb-1">{t('quality.ncr.description')}</h2>
            <p className="text-sm whitespace-pre-wrap" data-field="ncr-description">{n.description}</p>

            {judgement.length > 0 && (
                <>
                    <h2 className="mt-6 mb-1">{t('quality.ncr.judgementTitle')}</h2>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quality.ncr.judgementNote')}</p>
                    <RecordHeader fields={judgement} />
                </>
            )}

            <h2 className="mt-8 mb-1">{t('quality.ncr.decisionTitle')}</h2>
            {open ? (
                <DecideForm ncrId={id} batchKind={n.batch_kind as 'inbound' | 'output'} batchId={batchId}
                            canDecide={canDecide} selfOpened={selfOpened} penaltyOptions={penaltyOptions} penaltyRestricted={penaltyRestricted} />
            ) : (
                <RecordHeader
                    fields={[
                        { label: t('quality.ncr.disposition'), value: t(ncrDispositionKey(n.disposition ?? '')) },
                        { label: t('quality.ncr.decisionNote'), value: n.decision_note ?? '—' },
                        { label: t('quality.ncr.decidedAt'), value: n.decided_at ? formatAuditStamp(n.decided_at) : '—' },
                        ...(moneyDoc ? [{ label: t('quality.ncr.moneyDocument'), value: moneyDoc }] : []),
                        { label: t('quality.ncr.batchNow'), value: n.holding ? t('quality.ncr.stillHeld') : t('quality.ncr.released') },
                    ]}
                />
            )}
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-2">{t('quality.ncr.dispositionNote', { date: formatDate(n.opened_at, locale) })}</p>

            <AuditTrail subject="ncr" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
