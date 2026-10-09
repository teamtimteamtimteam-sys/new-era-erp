// app/quality/disputes/[id]/page.tsx
// MES-6a-1(2026-10-09,MES-6a Step 0 Q16–Q25,Tim):一件化验争议 —— 三份结果并排、立案时在案的容差与仲裁费规则、
//   仲裁、结案或撤回、以及仲裁费那一张费用单与对手方那一份(只算给人看,不收)。
//   【门】requireFunction(FN.qualityDisputes) = module.quality.view;仲裁 / 撤回 / 挂费用单要 module.quality.edit;结案要 action.apply_assay。
//   【这一页不算任何数】最大差、超没超、对手方那一份全部读 assay_dispute_rows / assay_dispute_metals。
//   【钱遮给没有财务查看码的人】fee_amount_base 与 counterparty_share_base 读到 NULL 且 fee_restricted —— 屏幕说「受限」,不说 0。
//   【结案什么都不应用】(Q19):结案之后横幅指回说了算的那一份结果的页面,应用照常在那里走。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { getBaseCurrency } from '@/lib/currency'
import { ListPage } from '@/app/components/ui/list-page'
import { RecordHeader } from '@/app/components/ui/record-header'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { formatAmount } from '@/lib/format'
import { disputeStatusKey, resultPartyKey, feeRuleKey, sampleKindKey, batchHref, assayHref } from '../../qualityTypes'
import DisputeActions, { type Opt } from './DisputeActions'
import FeeLinkForm from './FeeLinkForm'
import MetalsTable, { type MetalRow } from './MetalsTable'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

type D = {
    id: string; status: string; inbound_batch_id: string | null; output_batch_id: string | null; batch_code: string; batch_kind: string
    our_assay_id: string; our_assay_code: string; counterparty_assay_id: string; counterparty_assay_code: string
    umpire_sample_id: string | null; umpire_sample_code: string | null; umpire_assay_id: string | null; umpire_assay_code: string | null
    umpire_lab_code: string | null; governing_assay_id: string | null; governing_assay_code: string | null; governing_party: string | null
    sales_order_code: string | null; opening_reason: string; limit_pct_at: number | null; max_diff_pct: number | null; beyond_limit: boolean | null
    fee_rule_at: string | null; fee_expense_id: string | null; fee_expense_code: string | null; fee_amount_base: number | null
    counterparty_share_pct: number | null; counterparty_share_base: number | null; fee_restricted: boolean
    resolution_note: string | null; resolved_at: string | null; withdrawn_at: string | null; withdraw_reason: string | null; created_at: string
}

const pct = (n: number | null) => (n == null ? '—' : `${Number(n)} %`)

export default async function DisputePage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.qualityDisputes)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const d = mustOne(
        await supabase.from('assay_dispute_rows')
            .select('id, status, inbound_batch_id, output_batch_id, batch_code, batch_kind, our_assay_id, our_assay_code, counterparty_assay_id, counterparty_assay_code, umpire_sample_id, umpire_sample_code, umpire_assay_id, umpire_assay_code, umpire_lab_code, governing_assay_id, governing_assay_code, governing_party, sales_order_code, opening_reason, limit_pct_at, max_diff_pct, beyond_limit, fee_rule_at, fee_expense_id, fee_expense_code, fee_amount_base, counterparty_share_pct, counterparty_share_base, fee_restricted, resolution_note, resolved_at, withdrawn_at, withdraw_reason, created_at')
            .eq('id', id).maybeSingle(),
        'assay_dispute_rows') as D | null
    if (!d) notFound()
    const batchId = (d.inbound_batch_id ?? d.output_batch_id)!
    const col = d.batch_kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id'
    const open = d.status === 'open'

    const [metalRes, substRes, assayRes, sampleRes, labRes, canEdit, canResolve, canFinance, baseCcy] = await Promise.all([
        supabase.from('assay_dispute_metals').select('metal, ours_pct, counterparty_pct, umpire_pct, diff_pct, beyond_limit').eq('dispute_id', id).order('metal'),
        supabase.from('substances').select('code, name_en, name_zh'),
        open ? supabase.from('assay_results').select('id, code, result_party, assay_date, lab_name').eq(col, batchId).is('deleted_at', null).order('assay_date', { ascending: false }) : null,
        open ? supabase.from('sample_rows').select('id, code, kind').eq(col, batchId).order('created_at', { ascending: false }) : null,
        d.umpire_lab_code ? supabase.from('laboratories').select('code, supplier_id').eq('code', d.umpire_lab_code).maybeSingle() : null,
        can('module.quality.edit'), can('action.apply_assay'), can('module.finance.view'), getBaseCurrency(),
    ])
    const metals = mustRows(metalRes, 'assay_dispute_metals') as { metal: string; ours_pct: number | null; counterparty_pct: number | null; umpire_pct: number | null; diff_pct: number | null; beyond_limit: boolean | null }[]
    const substances = mustRows(substRes, 'substances') as { code: string; name_en: string; name_zh: string }[]
    const metalName = (c: string) => { const m = substances.find((x) => x.code === c); return m ? (locale === 'zh' ? m.name_zh : m.name_en) : c }
    const metalRows: MetalRow[] = metals.map((m) => ({
        metal: metalName(m.metal), ours: pct(m.ours_pct), counterparty: pct(m.counterparty_pct), umpire: pct(m.umpire_pct),
        diff: m.diff_pct == null ? '—' : String(Number(m.diff_pct)), beyond: m.beyond_limit === true,
    }))

    const assays = assayRes ? mustRows(assayRes, 'assay_results') as { id: string; code: string; result_party: string; assay_date: string; lab_name: string | null }[] : []
    const assayLabel = (a: (typeof assays)[number]) => `${a.code} · ${t(resultPartyKey(a.result_party))} · ${formatDate(a.assay_date, locale)}`
    const governingOptions: Opt[] = assays.map((a) => ({ id: a.id, label: assayLabel(a) }))
    const umpireAssays: Opt[] = assays.filter((a) => a.result_party === 'umpire').map((a) => ({ id: a.id, label: assayLabel(a) }))
    const samples = sampleRes ? mustRows(sampleRes, 'sample_rows') as { id: string; code: string; kind: string }[] : []
    const umpireSamples: Opt[] = samples.map((s) => ({ id: s.id, label: `${s.code} · ${t(sampleKindKey(s.kind))}` }))

    // 仲裁费的选单:出仲裁结果那家实验室在字典里指着的那一户供应商名下、在册的费用单(读得到费用单的人才有)
    const lab = labRes ? mustOne(labRes, 'laboratories') as { code: string; supplier_id: string | null } | null : null
    let feeOptions: { id: string; label: string }[] = []
    if (!d.fee_expense_id && d.status !== 'withdrawn' && d.umpire_assay_id && lab?.supplier_id && canFinance) {
        feeOptions = (mustRows(
            await supabase.from('expenses').select('id, code, expense_date, amount_ccy, currency').eq('supplier_id', lab.supplier_id).eq('status', 'posted')
                .order('expense_date', { ascending: false }).limit(100),
            'expenses') as { id: string; code: string; expense_date: string; amount_ccy: number; currency: string }[])
            .map((x) => ({ id: x.id, label: `${x.code} · ${formatDate(x.expense_date, locale)} · ${formatAmount(x.amount_ccy, x.currency)}` }))
    }
    const feeAmount = d.fee_restricted ? t('common.restricted') : d.fee_amount_base == null ? '—' : formatAmount(d.fee_amount_base, baseCcy)
    const share = d.counterparty_share_pct == null
        ? (d.fee_rule_at ? t('quality.dispute.shareNotComputable') : t('quality.notYetSet'))
        : `${Number(d.counterparty_share_pct)} %${d.fee_expense_id ? ` · ${d.fee_restricted ? t('common.restricted') : d.counterparty_share_base == null ? '—' : formatAmount(d.counterparty_share_base, baseCcy)}` : ''}`

    const governingHref = d.governing_assay_id ? assayHref(d.batch_kind, batchId, d.governing_assay_id) : null

    return (
        <ListPage
            maxWidth="max-w-5xl"
            breadcrumb={<Link href="/quality/disputes" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            title={<span>{t('quality.dispute.title', { batch: d.batch_code })}</span>}
            actions={<span className={`px-3 py-1 rounded text-sm ${open ? 'bg-amber-100' : 'bg-gray-200'}`}>{t(disputeStatusKey(d.status))}</span>}
            state={{ kind: 'ok' }}
            notices={
                <>
                    {open && (
                        <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="dispute-open">
                            {d.batch_kind === 'inbound' ? t('quality.dispute.holdsInbound') : t('quality.dispute.holdsOutput')}
                        </div>
                    )}
                    {d.status === 'resolved' && (
                        <div className="bg-gray-50 border border-gray-300 px-4 py-3 rounded mb-4 text-sm" data-notice="dispute-resolved">
                            <p>{t('quality.dispute.resolvedBanner', { at: d.resolved_at ? formatAuditStamp(d.resolved_at) : '—', note: d.resolution_note ?? '—' })}</p>
                            <p className="mt-1">
                                {t('quality.dispute.nothingApplied')}{' '}
                                {governingHref && <Link href={governingHref} className="app-link hover:underline">{d.governing_assay_code}</Link>}
                            </p>
                        </div>
                    )}
                    {d.status === 'withdrawn' && (
                        <div className="bg-gray-50 border border-gray-300 px-4 py-3 rounded mb-4 text-sm" data-notice="dispute-withdrawn">
                            {t('quality.dispute.withdrawnBanner', { at: d.withdrawn_at ? formatAuditStamp(d.withdrawn_at) : '—', reason: d.withdraw_reason ?? '—' })}
                        </div>
                    )}
                </>
            }
        >
            <RecordHeader
                fields={[
                    { label: t('quality.disputes.colBatch'), value: <Link href={batchHref(d.batch_kind, batchId)} className="app-link hover:underline">{d.batch_code}</Link> },
                    { label: t('quality.party.ours'), value: <Link href={assayHref(d.batch_kind, batchId, d.our_assay_id)} className="app-link hover:underline">{d.our_assay_code}</Link> },
                    { label: t('quality.party.counterparty'), value: <Link href={assayHref(d.batch_kind, batchId, d.counterparty_assay_id)} className="app-link hover:underline">{d.counterparty_assay_code}</Link> },
                    { label: t('quality.party.umpire'), value: d.umpire_assay_id
                        ? <Link href={assayHref(d.batch_kind, batchId, d.umpire_assay_id)} className="app-link hover:underline">{d.umpire_assay_code}</Link> : '—' },
                    { label: t('quality.dispute.umpireSample'), value: d.umpire_sample_id
                        ? <Link href={`/quality/samples/${d.umpire_sample_id}`} className="app-link hover:underline">{d.umpire_sample_code}</Link> : '—' },
                    { label: t('quality.dispute.limit'), value: d.limit_pct_at == null ? t('quality.limitNotSet') : String(Number(d.limit_pct_at)) },
                    { label: t('quality.dispute.maxDiff'), value: d.max_diff_pct == null ? '—'
                        : `${Number(d.max_diff_pct)}${d.beyond_limit === true ? ` · ${t('quality.dispute.beyond')}` : d.beyond_limit === false ? ` · ${t('quality.dispute.within')}` : ''}` },
                    ...(d.batch_kind === 'output' ? [{ label: t('quality.form.salesOrder'), value: d.sales_order_code ?? '—' }] : []),
                    { label: t('quality.dispute.openingReason'), value: d.opening_reason },
                    { label: t('quality.disputes.colGoverning'), value: d.governing_assay_code ? `${d.governing_assay_code} · ${t(resultPartyKey(d.governing_party ?? ''))}` : '—' },
                    { label: t('quality.disputes.colOpened'), value: formatAuditStamp(d.created_at) },
                ]}
            />

            <h2 className="mt-6 mb-1">{t('quality.dispute.metalsTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quality.dispute.metalsNote')}</p>
            <MetalsTable rows={metalRows} />

            {open && (
                <>
                    <h2 className="mt-8 mb-2">{t('quality.dispute.actionsTitle')}</h2>
                    <DisputeActions id={id} umpireSamples={umpireSamples} umpireAssays={umpireAssays} governingOptions={governingOptions}
                        currentUmpireSampleId={d.umpire_sample_id} currentUmpireAssayId={d.umpire_assay_id} canEdit={canEdit} canResolve={canResolve} />
                </>
            )}

            <h2 className="mt-8 mb-1">{t('quality.dispute.feeTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('quality.dispute.feeNote')}</p>
            <RecordHeader
                fields={[
                    { label: t('quality.dispute.feeRule'), value: d.fee_rule_at ? t(feeRuleKey(d.fee_rule_at)) : d.batch_kind === 'output' ? t('quality.notYetSet') : t('quality.dispute.feeRuleSellOnly') },
                    { label: t('quality.dispute.feeExpense'), value: d.fee_expense_id
                        ? <Link href={`/finance/expenses/${d.fee_expense_id}`} className="app-link hover:underline">{d.fee_expense_code}</Link> : '—' },
                    { label: t('quality.dispute.feeAmount'), value: d.fee_expense_id ? feeAmount : '—' },
                    { label: t('quality.dispute.counterpartyShare'), value: share },
                ]}
            />
            {!d.fee_expense_id && d.status !== 'withdrawn' && (
                <div className="mt-3">
                    {!d.umpire_assay_id ? (
                        <p className="text-sm text-[color:var(--brand-muted-text)]">{t('quality.dispute.feeNeedsUmpire')}</p>
                    ) : !lab?.supplier_id ? (
                        <p className="text-sm text-amber-700">{t('quality.dispute.feeLabNoSupplier', { lab: d.umpire_lab_code ?? '—' })}</p>
                    ) : !canFinance ? (
                        <p className="text-sm text-[color:var(--brand-muted-text)]">{t('quality.dispute.feeAskFinance')}</p>
                    ) : (
                        <FeeLinkForm id={id} expenses={feeOptions} canEdit={canEdit} />
                    )}
                </div>
            )}

            <AuditTrail subject="assay_dispute" id={id} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
