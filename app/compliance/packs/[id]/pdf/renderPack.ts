// app/compliance/packs/[id]/pdf/renderPack.ts
// MES-8b-1(2026-10-17,MES-8 Step 0 Q16,Tim):【把冻下来的那一份 payload 渲染成一份合规包的 PDF】—— 路由的 GET 与 POST、以及线上证明脚本
//   (db/scripts/2026-10-17-mes8b1-live-proof.mjs,经 jiti 读本文件)都调这一支。入参只有 compliance_packs 的那一行 —— 没有数据库、
//   没有请求、没有此刻的公司资料:纸只可能来自那一行(renderStatement.ts 的同一个形状)。抬头取 payload 里冻下来的公司资料。
//   ★【一律英文】—— 措辞取 messages/en.ts 的 compliancePacks.doc.*(MESSAGES.en,显式),不调 getTranslations。
//   先过字体覆盖守卫(纸上会印的每一个从数据来的字符串;一个画不出来的字会被印成空白,而那是无声的),再渲染。
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import type { ReactElement } from 'react'
import { MESSAGES } from '@/lib/i18n/config'
import { noSignatureEn } from '@/app/components/pdf/noSignature'
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/pdfFontCoverage'
import { formatAuditStamp } from '@/lib/dates'
import type { CompliancePackPayload } from '../../packTypes'
import CompliancePackDocument, { type CompliancePackDocData } from './CompliancePackDocument'

/** compliance_packs 里渲染要用的那几列(路由 select 的就是这些)。 */
export type CompliancePackRow = {
    id: string; code: string; period_month: string; period_start: string; period_end: string; locked_before_at_freeze: string
    payload: CompliancePackPayload; frozen_at: string; superseded_at: string | null
}

/** 冻下来的那一行 → 纸上的数据。【抬头取冻下来的那一份公司资料】—— 公司换了地址,交出去的那一份照旧。 */
export function packDocFrom(pk: CompliancePackRow): CompliancePackDocData {
    const company = pk.payload.company
    if (!company || !company.legal_name) throw new Error(MESSAGES.en.compliancePacks.errors.COMPANY_PROFILE_INCOMPLETE)
    return {
        code: pk.code,
        month: pk.payload.month,
        period_start: pk.period_start,
        period_end: pk.period_end,
        frozen_at: formatAuditStamp(pk.frozen_at),
        locked_before: pk.locked_before_at_freeze,
        superseded: pk.superseded_at !== null,
        company,
        p: pk.payload,
        noSignature: noSignatureEn('compliancePack'),
        t: { ...(MESSAGES.en.compliancePacks.doc as Record<string, string>) },
    }
}

function collectStrings(d: CompliancePackDocData): PdfTextField[] {
    const p = d.p
    return [
        { where: 'company legal_name', text: d.company.legal_name },
        ...(p.licence.in_force ? [{ where: 'licence cert_no', text: p.licence.in_force.cert_no }, { where: 'licence issuing_body', text: p.licence.in_force.issuing_body ?? '' }] : []),
        ...p.licence.on_hand_by_category.map((c, i) => ({ where: `category ${i + 1}`, text: c.name_en })),
        ...p.incidents.map((x, i) => ({ where: `incident ${i + 1} kind`, text: x.kind_name_en ?? x.kind_code })),
        ...p.environmental.flatMap((x, i) => [{ where: `environmental ${i + 1} parameter`, text: x.parameter_name_en ?? x.parameter_code },
                                              { where: `environmental ${i + 1} point`, text: x.sample_point }, { where: `environmental ${i + 1} unit`, text: x.unit }]),
        ...p.inspections.done.map((x, i) => ({ where: `inspection ${i + 1} checklist`, text: x.template_name })),
        ...p.inspections.findings_open_at_month_end.flatMap((x, i) => [{ where: `finding ${i + 1} item`, text: x.item ?? '' },
                                                                         { where: `finding ${i + 1} action`, text: x.corrective_action }]),
        ...(p.nea_return.state === 'set' ? [{ where: 'V26 format', text: p.nea_return.format ?? '' }, { where: 'V26 frequency', text: p.nea_return.frequency ?? '' }] : []),
        ...(p.eu_efficiency.state === 'set' ? [{ where: 'V27 method', text: p.eu_efficiency.method ?? '' }, { where: 'V27 targets', text: p.eu_efficiency.targets ?? '' }] : []),
    ]
}

export async function renderCompliancePackPdf(d: CompliancePackDocData): Promise<Buffer> {
    const bad = findUnrenderableText(collectStrings(d))
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    const doc = CompliancePackDocument({ data: d }) as unknown as ReactElement<DocumentProps>
    return await renderToBuffer(doc)
}
