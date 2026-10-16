// app/finance/supplier-statements/[id]/pdf/renderStatement.ts
// MES-8a(2026-10-16,MES-8 Step 0 Q9,Tim):【把冻下来的那一行渲染成一张供应商对账单的 PDF】—— 路由的 GET 与 POST、以及线上证明脚本
//   (db/scripts/2026-10-16-mes8a-live-proof.mjs,经 jiti 读本文件)都调这一支。入参只有 supplier_statements 的那一行 —— 没有数据库、
//   没有请求、没有此刻的供应商与公司资料:纸只可能来自那一行(renderCoa.tsx 的同一个形状)。
//   ★【一律英文】—— 措辞取 messages/en.ts 的 supplierStatements.doc.*(MESSAGES.en,显式),不调 getTranslations。
//   先过字体覆盖守卫(纸上会印的每一个字符串;一个画不出来的字会被印成空白,而那是无声的),再渲染。
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import type { ReactElement } from 'react'
import { MESSAGES } from '@/lib/i18n/config'
import { noSignatureEn } from '@/app/components/pdf/noSignature'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/pdfFontCoverage'
import { formatAuditStamp, formatDocumentDate } from '@/lib/dates'
import SupplierStatementDocument, {
    type SupplierStatementDocData, type SstLine, type SstOpenItem, type SstOnAccount, type SstUnpriced,
} from './SupplierStatementDocument'

const EN = 'en'

/** supplier_statements 里渲染要用的那几列(路由 select 的就是这些)。 */
export type SupplierStatementRow = {
    id: string; code: string; supplier_id: string; supplier_code: string; supplier_name: string
    company: SupplierStatementDocData['company']; period_start: string; period_end: string; base_currency: string
    opening_base: number; charges_base: number; credits_base: number; payments_base: number; prepayments_base: number; closing_base: number
    list_base: number; on_account_base: number; residue_base: number
    lines: SstLine[]; open_items: SstOpenItem[]; on_account: SstOnAccount[]; unpriced: SstUnpriced[]
    issued_at: string; superseded_at: string | null
}

function docText(at: string, ccy: string): Record<string, string> {
    const src = MESSAGES.en.supplierStatements.doc as Record<string, string>
    return Object.fromEntries(Object.entries(src).map(([k, v]) => [k, v.replace('{at}', at).replace('{ccy}', ccy)]))
}

/** 冻下来的那一行 → 纸上的数据。【收件人与抬头都取冻下来的那一份】(Q9)—— 供应商改名、公司换地址,寄出去的那一份照旧。 */
export function statementDocFrom(st: SupplierStatementRow): SupplierStatementDocData {
    const company = st.company
    if (!company || !company.legal_name) throw new Error(MESSAGES.en.supplierStatements.errors.COMPANY_PROFILE_INCOMPLETE)
    const issuedAt = formatAuditStamp(st.issued_at)
    return {
        code: st.code,
        supplier: { code: st.supplier_code, legal_name: st.supplier_name },
        period_start: formatDocumentDate(st.period_start, EN),
        period_end: formatDocumentDate(st.period_end, EN),
        base_currency: st.base_currency,
        opening_base: Number(st.opening_base), charges_base: Number(st.charges_base), credits_base: Number(st.credits_base),
        payments_base: Number(st.payments_base), prepayments_base: Number(st.prepayments_base), closing_base: Number(st.closing_base),
        list_base: Number(st.list_base), on_account_base: Number(st.on_account_base), residue_base: Number(st.residue_base),
        lines: (st.lines ?? []).map((l) => ({ ...l, date: formatDocumentDate(l.date, EN) })),
        open_items: (st.open_items ?? []).map((x) => ({ ...x, doc_date: formatDocumentDate(x.doc_date, EN) })),
        on_account: (st.on_account ?? []).map((p) => ({ ...p, payment_date: formatDocumentDate(p.payment_date, EN) })),
        unpriced: (st.unpriced ?? []).map((u) => ({ ...u, arrival_date: formatDocumentDate(u.arrival_date, EN) })),
        issued_at: issuedAt,
        superseded: st.superseded_at !== null,
        company,
        noSignature: noSignatureEn('supplierStatement'),
        t: docText(issuedAt, st.base_currency),
    }
}

function collectStrings(d: SupplierStatementDocData): PdfTextField[] {
    return [
        { where: 'supplier legal_name', text: d.supplier.legal_name },
        { where: 'company legal_name', text: d.company.legal_name },
        ...d.lines.map((l, i) => ({ where: `line ${i + 1} doc_code`, text: l.doc_code })),
        ...d.open_items.map((l, i) => ({ where: `open item ${i + 1} doc_code`, text: l.doc_code })),
        ...d.unpriced.map((l, i) => ({ where: `unpriced ${i + 1} material`, text: l.material_code })),
    ]
}

export async function renderSupplierStatementPdf(d: SupplierStatementDocData): Promise<Buffer> {
    const bad = findUnrenderableText(collectStrings(d))
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    const doc = SupplierStatementDocument({ data: d }) as unknown as ReactElement<DocumentProps>
    return await renderToBuffer(doc)
}
