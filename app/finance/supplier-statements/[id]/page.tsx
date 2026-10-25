// app/finance/supplier-statements/[id]/page.tsx
// MES-8a(2026-10-16,MES-0 Q79 · MES-8 Step 0 Q7–Q9,Tim):一份供应商对账单 —— 【冻下来的那一行】原样画出来(期初 · 发生 · 贷记 · 付款 · 预付冲抵 ·
//   期末;勾稽的另一边;每一笔明细,收货行标暂定价;期末未结;挂账的付款;已收到尚未计价的收货,只有数量)。PDF:看一眼(从这一行渲染,
//   不落档)· 存档(渲染、存桶、记 sha256 —— module.finance.edit)· 每一版存下的字节(取的时候重算哈希,对不上 409)。被取代的那一份说出被谁取代、为什么。
//   【门】requireFunction(FN.financeSupplierStatements) = module.finance.view。最底是它的审计记录(主语 supplier_statement)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { formatAmount } from '@/lib/format'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import type { SstLine, SstOpenItem, SstOnAccount, SstUnpriced } from './pdf/SupplierStatementDocument'
import StatementDetailTables from './StatementDetailTables'
import ArchiveButton from './ArchiveButton'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export default async function SupplierStatementPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.financeSupplierStatements)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const locale = await getLocale()
    const sp = await searchParams
    const supabase = await createClient()
    const st = mustOne(await supabase.from('supplier_statements')
        .select('id, code, supplier_id, supplier_code, supplier_name, period_start, period_end, base_currency, opening_base, charges_base, credits_base, payments_base, prepayments_base, '
              + 'closing_base, list_base, on_account_base, residue_base, lines, open_items, on_account, unpriced, issued_at, superseded_at, superseded_by, superseded_reason')
        .eq('id', id).maybeSingle(), 'supplier_statements') as unknown as {
            id: string; code: string; supplier_id: string; supplier_code: string; supplier_name: string; period_start: string; period_end: string; base_currency: string
            opening_base: number; charges_base: number; credits_base: number; payments_base: number; prepayments_base: number; closing_base: number
            list_base: number; on_account_base: number; residue_base: number
            lines: SstLine[]; open_items: SstOpenItem[]; on_account: SstOnAccount[]; unpriced: SstUnpriced[]
            issued_at: string; superseded_at: string | null; superseded_by: string | null; superseded_reason: string | null } | null
    if (!st) notFound()
    const [issuesRes, byRes, canArchive] = await Promise.all([
        supabase.from('supplier_statement_issues').select('version, sha256, issued_at').eq('statement_id', id).order('version', { ascending: false }),
        st.superseded_by ? supabase.from('supplier_statements').select('id, code').eq('id', st.superseded_by).maybeSingle()
                         : Promise.resolve({ data: null, error: null }),
        can('module.finance.edit'),
    ])
    const issues = mustRows(issuesRes, 'supplier_statement_issues') as { version: number; sha256: string; issued_at: string }[]
    const by = mustOne(byRes as never, 'supplier_statements superseded_by') as { id: string; code: string } | null
    const m = (n: number) => formatAmount(Number(n), st.base_currency)
    const sumRow = (label: string, v: number, paren = false) => (
        <div className="flex justify-between gap-4 py-0.5"><span className="text-[color:var(--brand-muted-text)]">{label}</span><span>{paren ? `(${m(v)})` : m(v)}</span></div>
    )

    return (
        <div className="p-4 sm:p-8 max-w-5xl">
            <div className="mb-6"><Link href="/finance/supplier-statements" className="hover:underline text-sm app-link">{t('common.back')}</Link></div>
            <h1 className="mb-2">{st.code}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                {`${st.supplier_code} · ${st.supplier_name}`} · {formatDate(st.period_start, locale)} – {formatDate(st.period_end, locale)}
                {' · '}{t('supplierStatements.issuedAt', { at: formatAuditStamp(st.issued_at) })}
            </p>
            {st.superseded_at && (
                <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="superseded">
                    {t('supplierStatements.supersededNotice', { code: by?.code ?? '', reason: st.superseded_reason ?? '' })}
                    {by && <>{' '}<Link href={`/finance/supplier-statements/${by.id}`} className="app-link hover:underline">{by.code}</Link></>}
                </div>
            )}
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">{t('supplierStatements.frozenHint')}</p>

            <section className="mb-6 max-w-md text-sm" data-section="summary">
                <h2 className="mb-2">{t('supplierStatements.summaryTitle', { ccy: st.base_currency })}</h2>
                {sumRow(t('supplierStatements.doc.opening'), st.opening_base)}
                {sumRow(t('supplierStatements.doc.charges'), st.charges_base)}
                {sumRow(t('supplierStatements.doc.credits'), st.credits_base, true)}
                {sumRow(t('supplierStatements.doc.payments'), st.payments_base, true)}
                {sumRow(t('supplierStatements.doc.prepayments'), st.prepayments_base, true)}
                <div className="flex justify-between border-t border-gray-400 mt-1 pt-1 font-medium">
                    <span>{t('supplierStatements.doc.closing')}</span><span data-value="closing">{m(st.closing_base)}</span>
                </div>
                <p className="mt-2 text-xs text-[color:var(--brand-muted-text)]" data-value="tie">
                    {t('supplierStatements.tieLine', { list: m(st.list_base), onAccount: m(st.on_account_base), residue: m(st.residue_base) })}
                </p>
            </section>

            <StatementDetailTables lines={st.lines} openItems={st.open_items} onAccount={st.on_account} unpriced={st.unpriced}
                baseCurrency={st.base_currency}
                about={[
                    [t('supplierStatements.colCode'), st.code],
                    [t('supplierStatements.colSupplier'), `${st.supplier_code} · ${st.supplier_name}`],
                    [t('supplierStatements.colPeriod'), `${st.period_start} → ${st.period_end}`],
                    ...(st.superseded_at ? [[t('supplierStatements.colSuperseded'), by?.code ?? '—'] as [string, string]] : []),
                ]} />

            <section className="mt-8" data-section="pdf">
                <h2 className="mb-2">{t('supplierStatements.pdfTitle')}</h2>
                <p className="text-sm mb-3">
                    <a href={`/finance/supplier-statements/${st.id}/pdf`} target="_blank" rel="noopener noreferrer" className="app-link hover:underline">{t('supplierStatements.viewPdf')}</a>
                    <span className="text-xs text-[color:var(--brand-muted-text)] ml-2">{t('supplierStatements.viewPdfHint')}</span>
                </p>
                {!st.superseded_at && <ArchiveButton statementId={st.id} canArchive={canArchive} />}
                <ul className="mt-3 text-sm space-y-1" data-section="versions">
                    {issues.length === 0 ? <li className="text-[color:var(--brand-muted-text)]">{t('supplierStatements.noPdfYet')}</li> : issues.map((i) => (
                        <li key={i.version}>
                            <a href={`/finance/supplier-statements/${st.id}/pdf?version=${i.version}`} target="_blank" rel="noopener noreferrer" className="app-link hover:underline">
                                {t('supplierStatements.versionLink', { version: String(i.version) })}
                            </a>
                            <span className="text-xs text-[color:var(--brand-muted-text)] ml-2">{formatAuditStamp(i.issued_at)} · sha256 {i.sha256.slice(0, 12)}…</span>
                        </li>
                    ))}
                </ul>
            </section>

            <AuditTrail subject="supplier_statement" id={st.id} show={trailCount(sp.trail)} />
        </div>
    )
}
