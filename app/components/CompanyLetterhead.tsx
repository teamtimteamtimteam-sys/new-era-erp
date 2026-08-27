// app/components/CompanyLetterhead.tsx
// STATEMENT-1:对外单据的【公司抬头】—— 一处实现,三个调用方。
//
// ★【为什么现在抽,而不是再抄一份】★
// `docs/known-issues.md`(EQP-1c-b-fu2)记着:全库只有【两处】渲染 company_profile,
// 而且是两份各自长出来的副本;六个对外单据里只有采购单与发票印我们自己的地址,
// 报价单、送货单、贷项凭证、销售订单【一个都不印】。那条记录的结尾写着:
// 「下一次要改抬头(加税号?加 GST 号?)的人,要改两个地方,而没有任何东西会提醒他。」
//
// **对账单是一份【要钱的文书】,它必须印抬头** —— 于是它会成为第三份副本,
// 而"三"正是"总有一份会被漏掉"从假设变成事实的那个数。Tim 2026-08-27 裁定:现在抽。
//
// ★【抽的是【内容与规则】,不是版式 —— 而这是一个实测出来的分寸】★
// 两份抬头【不是同一块砖换了层皮】:字段集不同(发票有 GST 号、电话、邮箱、网址,
// 采购单没有)、标签不同(`Reg. No.` / `Co. Reg. No:`)、版式不同
// (采购单一行逗号,发票逐行叠)、连样式对象都不同(`muted` / `small`)。
// 硬压成一个组件,只会得到一个包着两份实现的 switch。
//
// 所以这里的做法是:**版式由 variant 选,样式由调用方传进来** ——
// 两张既有单据因此【一个像素都没有动】,而"抬头由哪些部分组成、国家印不印、
// 城市与邮编怎么拼"这些【规则】从此只有一份。
// 加一个税号,改这一个文件。
//
// 【`countryIfDistinct` 仍然住在 lib/companyAddress.ts】那是一条【数据判断】
// (城邦不重复印国名),PDF 之外也可能有人要用;这里只是它的第三个调用方。
// 整块版式统一留给阶段 8 的「对外单据版式」那一刀 —— 它本来就要把六份摆在一起看。
import { Text } from '@react-pdf/renderer'
import { countryIfDistinct } from '@/lib/companyAddress'

export type LetterheadCompany = {
    legal_name: string
    address_lines?: string | null
    city?: string | null
    postal_code?: string | null
    country?: string | null
    registration_no?: string | null
    phone?: string | null
    email?: string | null
    website?: string | null
}

/** 地址的各段,按印刷顺序,已去空、已应用"城邦不重复印国名"。 */
export function companyAddressParts(company: LetterheadCompany): string[] {
    return [company.address_lines, company.city, company.postal_code, countryIfDistinct(company)]
        .map((x) => (x ?? '').trim())
        .filter(Boolean)
}

export default function CompanyLetterhead({
    company,
    styles,
    variant,
    gstRegistrationNo = null,
}: {
    company: LetterheadCompany
    /** 调用方自己的样式对象 —— 版式不由这个组件决定,所以两张老单据一个像素没动 */
    styles: { name: unknown; line: unknown }
    /** 'inline' = 采购单(地址一行逗号);'stacked' = 发票/对账单(逐行叠) */
    variant: 'inline' | 'stacked'
    /** 只有 stacked 用得上;传 null 就不印那一行 */
    gstRegistrationNo?: string | null
}) {
    const name = styles.name as never
    const line = styles.line as never

    if (variant === 'inline') {
        const addr = companyAddressParts(company).join(', ')
        return (
            <>
                <Text style={name}>{company.legal_name}</Text>
                {company.registration_no ? (
                    <Text style={line}>Reg. No. {company.registration_no}</Text>
                ) : null}
                {addr ? <Text style={line}>{addr}</Text> : null}
            </>
        )
    }

    // stacked:地址逐行,城市与邮编同一行,国家单独一行(相同就不印)
    const cityLine = [company.city, company.postal_code]
        .map((x) => (x ?? '').trim())
        .filter(Boolean)
        .join(' ')
    const country = countryIfDistinct(company)
    return (
        <>
            <Text style={name}>{company.legal_name}</Text>
            {company.address_lines
                ? company.address_lines
                      .split('\n')
                      .filter((l) => l.trim())
                      .map((l, i) => (
                          <Text key={i} style={line}>
                              {l}
                          </Text>
                      ))
                : null}
            {cityLine ? <Text style={line}>{cityLine}</Text> : null}
            {country ? <Text style={line}>{country}</Text> : null}
            {company.registration_no ? (
                <Text style={line}>Co. Reg. No: {company.registration_no}</Text>
            ) : null}
            {gstRegistrationNo ? <Text style={line}>GST Reg. No: {gstRegistrationNo}</Text> : null}
            {company.phone ? <Text style={line}>Tel: {company.phone}</Text> : null}
            {company.email ? <Text style={line}>{company.email}</Text> : null}
            {company.website ? <Text style={line}>{company.website}</Text> : null}
        </>
    )
}
