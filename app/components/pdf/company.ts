// app/components/pdf/company.ts
// PDF-1:对外单据取【公司抬头】的一处实现。(2026-09-02)
//
// 【为什么加这一支】落地前八份对外单据里,只有三份印公司抬头(采购单、发票、
// 对账单),而那三份各自写了一遍"查 company_profile_masked、检查法定名称、
// 把 logo 从私有桶下下来内嵌"。另外四份(报价单、销售订单、送货单、贷项凭证)
// 【一份都不印】—— 客户手里那张报价单上,没有任何东西说明它是谁开的。
//
// PDF-1 给全部八份都加上抬头,于是"怎么取抬头"必须先只有一份实现,
// 否则这一刀本身就会把三份副本变成八份。
//
// 【refuse 的门槛与发票【逐字相同】,这是刻意的】
// 发票路由此前就拒绝在没有法定名称时出 PDF。一张【不知道是谁开的】对外单据
// 比没有这张纸更糟:客户无从入账,审计师无从溯源。所以这条规矩推广到全部八份,
// 而不是让新加抬头的那四份在缺数据时印一片空白 —— 那正是 R4 点名的那种空白。
import { createClient } from '@/lib/supabase/server'
import { mustOne } from '@/lib/db-helpers'
import type { LetterheadCompany } from '@/app/components/CompanyLetterhead'

export type DocumentCompany = LetterheadCompany & {
    logo_path: string | null
    invoice_footer_text?: string | null
}

/** 取不到抬头时给的那份【说得出下一步】的拒绝,不是一个 500。 */
export const COMPANY_MISSING_MESSAGE =
    `This document cannot be issued without your company's legal name and address.\n` +
    `A document that leaves the company must say who issued it — a customer cannot book it,\n` +
    `and an auditor cannot trace it.\n\n` +
    `Please fill them in at:  /finance/company\n`

/**
 * 公司抬头 + 已内嵌成 data URI 的 logo。
 *
 * 【logo 从私有桶把字节下下来内嵌,不给渲染器一个 URL】—— 渲染中途发网络请求,
 * 一旦超时或对端挂了,拿到的就是一份【缺图的 PDF】,而且失败是静默的。
 * 与字体"绝不从远程 URL 读"是同一条理由。
 *
 * 【SVG 不收】@react-pdf/renderer 的 Image 不支持 SVG;收下只会得到一份缺图的单据
 * (app/finance/company/actions.ts 在上传那一端也拒收,两端一致)。
 * ★ 字标【不走这条路】★ —— 它是矢量的,由 Wordmark.tsx 直接画,见那个文件。
 */
export async function loadDocumentCompany(): Promise<
    { ok: true; company: DocumentCompany; logo: string | null } | { ok: false }
> {
    const supabase = await createClient()
    const company = mustOne(
        await supabase.from('company_profile_masked').select('*').limit(1).maybeSingle(),
        'company_profile_masked'
    ) as DocumentCompany | null

    if (!company || !company.legal_name?.trim()) return { ok: false }

    let logo: string | null = null
    if (company.logo_path) {
        const ext = company.logo_path.split('.').pop()?.toLowerCase() ?? ''
        const mime = ext === 'png' ? 'image/png' : ext === 'jpg' || ext === 'jpeg' ? 'image/jpeg' : null
        if (mime) {
            const { data: blob } = await supabase.storage.from('company-assets').download(company.logo_path)
            if (blob) {
                const bytes = Buffer.from(await blob.arrayBuffer())
                logo = `data:${mime};base64,${bytes.toString('base64')}`
            }
        }
    }
    return { ok: true, company, logo }
}

/**
 * 抬头会印出去的每一个字符串,交给字体覆盖守卫。
 *
 * ★【为什么这一支必须存在】★ PDF-1 给四份此前不印抬头的单据加上了抬头 ——
 * 那一刻,这些字段【第一次】会被印到那几张纸上。守卫只检查交给它的字段,
 * 所以不把它们加进来,等于给这四份单据开了一个洞:公司名里有一个裁剪范围外的字,
 * 印出来就是空白,而守卫会说没问题。
 * `lib/pdfFontCoverage.ts` 里那句「漏掉的字段就是漏掉的守卫」说的就是这件事,
 * 这里把它做成一处实现,免得八份路由各抄一遍、其中一份抄漏。
 */
export function companyPdfStrings(
    company: DocumentCompany,
    gstRegistrationNo: string | null = null
): { where: string; text: string | null | undefined }[] {
    return [
        { where: 'Company legal name', text: company.legal_name },
        { where: 'Company address', text: company.address_lines },
        { where: 'Company city', text: company.city },
        { where: 'Company postal code', text: company.postal_code },
        { where: 'Company country', text: company.country },
        { where: 'Company registration no.', text: company.registration_no },
        { where: 'GST registration no.', text: gstRegistrationNo },
        { where: 'Company phone', text: company.phone },
        { where: 'Company email', text: company.email },
        { where: 'Company website', text: company.website },
    ]
}
