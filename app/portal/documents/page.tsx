// app/portal/documents/page.tsx
// MES-9b(2026-10-19,MES-9 Step 0 Q14 · Q15 · Q22,Tim):【门户的单据】—— 调用者自己那一家的采购单、对账单、销毁证书。
//   读的只有 portal_documents()(只授 supplier_portal;先过 portal_require_link)。每一份只以【它签发时存下的 PDF】出现:
//   下载链接指向 /portal/documents/file(以这个会话自己的令牌写下载记录、从桶里取字节、重算 sha256 —— 对不上就 409)。
//   没签发、作废、被取代的照直写出来,【绝不按活数据渲染】(这一页没有一个金额、没有一个"预览")。没有价钱(Q15):价钱只印在那几份 PDF 上。
//   门户函数按名拒的三种(撤销了 · 会话结束了 · 令牌不是门户角色)各说一句人话;别的失败照常抛(失败不是空集)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { localizePortalError } from '../portalErrorCodes'

type Issue = { issue_id: string; version: number; issued_at: string; current: boolean }
type PortalDocuments = {
    supplier_code: string
    purchase_orders: { id: string; code: string; order_date: string; state: 'open' | 'closed' | 'cancelled'; issues: Issue[] }[]
    statements: {
        id: string; code: string; period_start: string; period_end: string; issued_at: string
        state: 'current' | 'superseded'; superseded_by_code: string | null; issues: Issue[]
    }[]
    cods: {
        id: string; code: string | null; receipt_code: string; completed_on: string; state: 'pending' | 'issued' | 'void'
        issued_at: string | null; replaced_by_code: string | null; issue: { issue_id: string; issued_at: string } | null
    }[]
}

function fileHref(kind: 'purchase_order' | 'supplier_statement' | 'cod', issueId: string) {
    return `/portal/documents/file?kind=${kind}&id=${encodeURIComponent(issueId)}`
}

export default async function PortalDocumentsPage() {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_documents')
    if (error) {
        const { code, text } = await localizePortalError(error.message)
        if (code === 'PORTAL_ACCESS_REVOKED' || code === 'PORTAL_SESSION_ENDED' || code === 'PORTAL_ROLE_REQUIRED') {
            return (
                <div className="p-6 max-w-2xl" data-portal-refused={code}>
                    <h1 className="mb-3">{t('portal.documents.title')}</h1>
                    <p className="text-sm">{text}</p>
                </div>
            )
        }
        throw new Error(`查询失败(portal_documents): ${error.code ?? ''} ${error.message}`.trim())
    }
    const d = data as unknown as PortalDocuments

    const issueLinks = (kind: 'purchase_order' | 'supplier_statement', issues: Issue[]) =>
        issues.length === 0 ? (
            <span className="text-[color:var(--brand-muted-text)]" data-doc-state="not-issued">{t('portal.documents.notIssued')}</span>
        ) : (
            <span className="flex flex-col gap-1">
                {issues.map((i) => (
                    <span key={i.issue_id} className="flex flex-wrap gap-x-2">
                        <a href={fileHref(kind, i.issue_id)} className="app-link hover:underline" data-doc-file={i.issue_id}>
                            {i.current
                                ? t('portal.documents.downloadVersionCurrent', { v: String(i.version) })
                                : t('portal.documents.downloadVersion', { v: String(i.version) })}
                        </a>
                        <span className="text-xs text-[color:var(--brand-muted-text)]">{formatAuditStamp(i.issued_at)}</span>
                    </span>
                ))}
            </span>
        )

    const poState = (s: 'open' | 'closed' | 'cancelled') =>
        s === 'cancelled' ? t('portal.documents.stateCancelled') : s === 'closed' ? t('portal.documents.stateClosed') : t('portal.documents.stateOpen')

    return (
        <div className="p-6 max-w-4xl space-y-6" data-portal-documents={d.supplier_code}>
            <div>
                <p className="text-sm mb-2"><Link href="/portal" className="app-link hover:underline">{t('portal.backHome')}</Link></p>
                <h1 className="mb-2">{t('portal.documents.title')}</h1>
                <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('portal.documents.intro')}</p>
            </div>

            <section data-doc-section="purchase_orders">
                <h2 className="mb-2">{t('portal.documents.poTitle')}</h2>
                {d.purchase_orders.length === 0 ? <p className="text-sm">{t('portal.documents.none')}</p> : (
                    <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                        {d.purchase_orders.map((po) => (
                            <li key={po.id} className="py-2 flex flex-wrap gap-x-6 gap-y-1" data-doc-code={po.code}>
                                <span className="font-medium min-w-[9rem]">{po.code}</span>
                                <span className="min-w-[7rem]">{formatDate(po.order_date, locale)}</span>
                                <span className="min-w-[6rem]" data-doc-state={po.state}>{poState(po.state)}</span>
                                {issueLinks('purchase_order', po.issues)}
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            <section data-doc-section="statements">
                <h2 className="mb-2">{t('portal.documents.statementTitle')}</h2>
                {d.statements.length === 0 ? <p className="text-sm">{t('portal.documents.none')}</p> : (
                    <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                        {d.statements.map((st) => (
                            <li key={st.id} className="py-2 flex flex-wrap gap-x-6 gap-y-1" data-doc-code={st.code}>
                                <span className="font-medium min-w-[9rem]">{st.code}</span>
                                <span className="min-w-[7rem]">
                                    {t('portal.documents.period', { from: formatDate(st.period_start, locale), to: formatDate(st.period_end, locale) })}
                                </span>
                                <span className="min-w-[6rem]" data-doc-state={st.state}>
                                    {st.state === 'superseded'
                                        ? t('portal.documents.stSuperseded', { code: st.superseded_by_code ?? '—' })
                                        : t('portal.documents.stCurrent')}
                                </span>
                                {st.issues.length === 0
                                    ? <span className="text-[color:var(--brand-muted-text)]" data-doc-state="no-stored">{t('portal.documents.noStored')}</span>
                                    : issueLinks('supplier_statement', st.issues)}
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            <section data-doc-section="cods">
                <h2 className="mb-2">{t('portal.documents.codTitle')}</h2>
                {d.cods.length === 0 ? <p className="text-sm">{t('portal.documents.none')}</p> : (
                    <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                        {d.cods.map((c) => (
                            <li key={c.id} className="py-2 flex flex-wrap gap-x-6 gap-y-1" data-doc-code={c.code ?? ''}>
                                <span className="font-medium min-w-[9rem]">{c.code ?? t('portal.documents.codNoNumber')}</span>
                                <span className="min-w-[7rem]">{t('portal.documents.delivery', { code: c.receipt_code })}</span>
                                <span className="min-w-[6rem]" data-doc-state={c.state}>
                                    {c.state === 'issued' ? t('portal.documents.codIssued')
                                        : c.state === 'pending' ? t('portal.documents.codPending')
                                        : c.replaced_by_code ? t('portal.documents.codVoidReplaced', { code: c.replaced_by_code })
                                        : t('portal.documents.codVoid')}
                                </span>
                                {c.state === 'issued' && c.issue ? (
                                    <span className="flex flex-wrap gap-x-2">
                                        <a href={fileHref('cod', c.issue.issue_id)} className="app-link hover:underline" data-doc-file={c.issue.issue_id}>
                                            {t('portal.documents.download')}
                                        </a>
                                        <span className="text-xs text-[color:var(--brand-muted-text)]">{formatAuditStamp(c.issue.issued_at)}</span>
                                    </span>
                                ) : c.state === 'issued' ? (
                                    <span className="text-[color:var(--brand-muted-text)]" data-doc-state="no-stored">{t('portal.documents.noStored')}</span>
                                ) : null}
                            </li>
                        ))}
                    </ul>
                )}
            </section>
        </div>
    )
}
