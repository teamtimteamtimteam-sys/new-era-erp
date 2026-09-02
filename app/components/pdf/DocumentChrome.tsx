// app/components/pdf/DocumentChrome.tsx
// PDF-1:对外单据的三个共享零件 —— 字标抬头、表格、页脚。(2026-09-02)
//
// 【为什么是三个零件而不是一个外壳】见 theme.ts 抬头:八份单据的骨架真的不同,
// 硬压成一个组件只会得到一个包着八份实现的 switch。这里共享的是"抬头由什么组成、
// 表格长什么样、页脚印什么",不是"这份单据有哪些段落"。
import React from 'react'
import { Text, View, StyleSheet } from '@react-pdf/renderer'
import { BRAND, PAGE } from './theme'
import { DOC_FONT_STACK } from './fonts'
import Wordmark from './Wordmark'
import CompanyLetterhead, { type LetterheadCompany } from '@/app/components/CompanyLetterhead'

export const docStyles = StyleSheet.create({
    // ★ fontFamily 放在 page 上,页内所有 Text 默认继承整个【字体栈】。
    //   任何一个文本节点都不该自己写 fontFamily —— 那正是对账单栽掉的地方。
    //   要加粗一律 fontWeight:'bold'(栈里两个家族都注册了 400 与 700)。
    page: {
        paddingTop: PAGE.top,
        paddingBottom: PAGE.bottom,
        paddingHorizontal: PAGE.horizontal,
        fontSize: 9,
        color: BRAND.text,
        fontFamily: DOC_FONT_STACK,
    },

    // ── 抬头 ───────────────────────────────────────────────────────────────
    header: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 22 },
    headerRight: { alignItems: 'flex-end', maxWidth: 240 },
    companyName: { fontSize: 10, fontWeight: 'bold', marginBottom: 2, color: BRAND.text },
    companyLine: { fontSize: 8, color: BRAND.muted, textAlign: 'right' },

    // ── 标题 ───────────────────────────────────────────────────────────────
    // 标题用 Ocean:18pt 粗体属于"大号文字",门槛 3:1,实测 3.75:1 通过。
    // 【小字不许用它】—— 见 theme.ts 抬头那段 ★★。
    title: { fontSize: 18, fontWeight: 'bold', letterSpacing: 1.5, color: BRAND.ocean },
    code: { fontSize: 11, marginBottom: 14 },

    // ── 元信息(标签 : 值)─────────────────────────────────────────────────
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { width: 100, color: BRAND.muted },
    metaBlock: {
        marginBottom: 14, paddingBottom: 10,
        borderBottomWidth: 1, borderBottomColor: BRAND.ocean,
    },

    // ── 表格 ───────────────────────────────────────────────────────────────
    tableHeader: {
        flexDirection: 'row',
        backgroundColor: BRAND.accent,
        borderBottomWidth: 1, borderBottomColor: BRAND.ocean,
        paddingVertical: 4, paddingHorizontal: 2,
        marginBottom: 1,
        fontWeight: 'bold',
    },
    row: {
        flexDirection: 'row',
        paddingVertical: 3.5, paddingHorizontal: 2,
        borderBottomWidth: 0.5, borderBottomColor: BRAND.hairline,
    },
    cell: { paddingRight: 6 },
    totalRow: {
        flexDirection: 'row', marginTop: 8, paddingTop: 6,
        borderTopWidth: 1, borderTopColor: BRAND.text,
    },

    // ── 段落 ───────────────────────────────────────────────────────────────
    block: { marginTop: 14 },
    label: { color: BRAND.muted, marginBottom: 2 },
    sectionHeading: {
        fontSize: 8, fontWeight: 'bold', color: BRAND.muted,
        letterSpacing: 1, marginBottom: 4,
    },

    // ── 页脚 ───────────────────────────────────────────────────────────────
    footer: {
        position: 'absolute',
        bottom: 28, left: PAGE.horizontal, right: PAGE.horizontal,
        borderTopWidth: 0.5, borderTopColor: BRAND.hairline,
        paddingTop: 6,
        flexDirection: 'row', justifyContent: 'space-between', alignItems: 'flex-end',
    },
    // 【note 与页码之间要有一条【留得住】的缝】实测:采购单的页脚说明长到占满整行时,
    // 它与页码【贴在一起】印成了 "…stated per line.PO-2026-0007 · Page 1 of 1"。
    // flex:1 的 paddingRight 不够 —— 页码那一侧也要 marginLeft,两边各出一半。
    footerNote: { fontSize: 7.5, color: BRAND.muted, flex: 1, paddingRight: 12 },
    footerPage: { fontSize: 7.5, color: BRAND.muted, marginLeft: 12 },
})

/**
 * ★ 抬头 —— 左边字标,右边法定名称与公司资料。★
 *
 * 【落地前:八份对外单据里只有三份印公司抬头】(采购单、发票、对账单),
 * 报价单、送货单、销售订单、贷项凭证【一个都不印】,可追溯报告也不印。
 * 也就是说客户手里那张报价单上,没有任何东西说明它是谁开的。
 * 字标此前【一份单据都没有】。
 *
 * 【R1:没有水印】螺旋球体只作为字标里那个 "O" 出现 —— 不做背景、不做装饰。
 *
 * 【内容规则仍然来自 CompanyLetterhead】那个组件管的是"抬头由哪些部分组成、
 * 城市与邮编怎么拼、国家印不印",PDF-1 【不动它】;这里管的是版式。
 * 两者的分工正是 CompanyLetterhead 抬头写下的那条分寸。
 */
export function DocumentLetterhead({
    company,
    gstRegistrationNo = null,
}: {
    company: LetterheadCompany
    gstRegistrationNo?: string | null
}) {
    return (
        <View style={docStyles.header}>
            {/* 字标宽 132pt ≈ 46mm —— A4 内容宽 515pt 的四分之一强,
                在纸上认得出,又不喧宾夺主。高度按原始比例算,不会被拉变形。 */}
            <Wordmark width={132} />
            <View style={docStyles.headerRight}>
                <CompanyLetterhead
                    company={company}
                    styles={{ name: docStyles.companyName, line: docStyles.companyLine }}
                    variant="stacked"
                    gstRegistrationNo={gstRegistrationNo}
                />
            </View>
        </View>
    )
}

/**
 * ★ 页脚 —— 一句该单据自己的说明,加【页码】。★
 *
 * 【落地前:八份里只有两份印页码】(发票、销售订单)。一份多页的对账单或采购单
 * 散落在收件人桌上时,没有任何办法知道少了哪一页 —— 而对账单正是最容易多页的
 * 那一份。所以页码在这里是【共享零件的一部分】,不是某份单据的选配。
 *
 * `note` 是各单据自己的正文(例如贷项凭证那句"这不是退款"),原样传进来;
 * PDF-1 【一个字都没有改】它们 —— R3。
 */
export function DocumentFooter({ note, code }: { note?: string; code?: string }) {
    return (
        <View style={docStyles.footer} fixed>
            <Text style={docStyles.footerNote}>{note ?? ''}</Text>
            <Text
                style={docStyles.footerPage}
                render={({ pageNumber, totalPages }) =>
                    `${code ? code + ' · ' : ''}Page ${pageNumber} of ${totalPages}`
                }
            />
        </View>
    )
}

/** 表头一行。列宽由调用方给 —— 每份单据的列不一样,而"表头长什么样"是共享的。 */
export function TableHeader({
    columns,
}: {
    columns: { header: string; width: number | string; align?: 'left' | 'right' }[]
}) {
    return (
        <View style={docStyles.tableHeader} fixed>
            {columns.map((c, i) => (
                <Text
                    key={i}
                    style={[docStyles.cell, { width: c.width, textAlign: c.align ?? 'left' }] as never}
                >
                    {c.header}
                </Text>
            ))}
        </View>
    )
}
