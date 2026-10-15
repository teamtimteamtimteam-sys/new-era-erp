// app/inbound/codPdf.ts
// MES-7a-1(2026-10-15,MES-7a Step 0 Q9 · Q25 · F10,Tim):销毁证书的纸上会印的每一个字符串 —— 交给字体覆盖守卫。
//   【为什么要有它】销毁证书的路由此前一道字体检查都没有(app/inbound 里没有 import 过守卫):一个裁剪范围外的字(例如供应商名里的「≤」)
//   会被印成空白,而渲染照样"成功"。分析证书那条路由有这一道(renderCoa.tsx);这里补上同一道,在签发之前(issue_cod 之前)与渲染之内各问一次 ——
//   画不出来就拒,绝不印一片空白(Q25)。
//   【漏掉的字段就是漏掉的守卫】(lib/pdfFontCoverage.ts 抬头那一句)所以这张清单与 CertificateDocument.tsx 里每一个 <Row> 逐个对着写;
//   抬头那几格(公司名、地址、注册号、电话、邮箱、网址)与 companyPdfStrings 同一组。
import { findUnrenderableText, coverageErrorMessage, type PdfTextField } from '@/lib/pdfFontCoverage'
import type { LetterheadCompany } from '@/app/components/CompanyLetterhead'
import type { CertificateData } from './CertificateDocument'

export function codPdfStrings(d: CertificateData, company: LetterheadCompany, verificationUrl: string | null = null): PdfTextField[] {
    const b = d.inbound_batch
    return [
        { where: 'Party delivering the waste', text: d.supplier?.name },
        { where: 'Their reference with us', text: d.supplier?.code },
        { where: 'Material code', text: b?.material_code },
        { where: 'Material name', text: b?.material_name },
        { where: 'Quantity received', text: b ? `${b.quantity} ${b.unit ?? ''}` : null },
        { where: 'Date received', text: b?.arrival_date },
        { where: 'Delivery reference', text: b?.code },
        { where: 'Purchase order', text: b?.purchase_order_code },
        { where: 'Date processing completed', text: d.processing?.completed_on },
        { where: 'Licence number', text: d.licence?.cert_no },
        { where: 'Licence issuing body', text: d.licence?.issuing_body },
        { where: 'Certificate number', text: d.certificate?.code },
        { where: 'Verification address', text: verificationUrl },
        { where: 'Company legal name', text: company.legal_name },
        { where: 'Company address', text: company.address_lines },
        { where: 'Company city', text: company.city },
        { where: 'Company postal code', text: company.postal_code },
        { where: 'Company country', text: company.country },
        { where: 'Company registration no.', text: company.registration_no },
        { where: 'Company phone', text: company.phone },
        { where: 'Company email', text: company.email },
        { where: 'Company website', text: company.website },
    ]
}

/** 纸上会印的字里有没有画不出来的 —— 有就返回那句说明(点名字段与字符),没有返回 null。 */
export function codUnrenderable(d: CertificateData, company: LetterheadCompany, verificationUrl: string | null = null): string | null {
    const bad = findUnrenderableText(codPdfStrings(d, company, verificationUrl))
    return bad.length > 0 ? coverageErrorMessage(bad) : null
}
