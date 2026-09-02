// app/inventory/reports/ReportDocument.tsx
// RPT-1:四张报表共用的 PDF 版式 —— 一个通用的"表头块 + 表格"文档。
//
// 【字体与 CJK 断词从发票文档继承】import 它就完成了 Noto Sans SC 的注册与
// registerHyphenationCallback(textkit 只按空格断词,中文不写空格)。
//
// 【与发票的"一律英文"政策【刻意不同】,理由写在这里】
// 发票与采购单是【签发给外部的商业单据】,既定决策是无论界面语言一律英文 ——
// 收件人不是这套系统的用户。报表不是:它只给【打开这个系统的这个人】看,
// 而他此刻的界面语言就是他读得懂的那一种。把一张内部报表强行印成英文,
// 是把一条对外单据的规矩套到一件内部的事情上。所以这里跟随请求方的界面语言。
// 【前提】Noto Sans SC 的裁剪范围覆盖 GB2312(6763 汉字)+ 拉丁 + 标点;
// 超出范围的字由 lib/pdfFontCoverage 在渲染前【大声报错】,不会静默印空白。
// ── PDF-1(2026-09-02):这一份版式服务【两种受众】,而现在它说得出是哪一种 ───
// ★ 判据只有一条:**这份东西离不离开这栋楼。** ★
//   * 四张库存报表(snapshot / ledger / safety / violations)只给【打开这个系统
//     的这个人】看 —— 内部。不印抬头:自己给自己看的东西不需要自我介绍。
//   * 可追溯报告【交到客户与审计师手里】—— 对外。必须印字标与法定名称,
//     否则那张纸上没有任何东西说明它是谁出的,审计师无从溯源。
// 传 `company` = 对外(画抬头);不传 = 内部。**下一个加报表的人:先问它去哪儿。**
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { DOC_FONT_STACK } from '@/app/components/pdf/fonts'
import { BRAND } from '@/app/components/pdf/theme'
import { DocumentLetterhead } from '@/app/components/pdf/DocumentChrome'
import type { DocumentCompany } from '@/app/components/pdf/company'

const styles = StyleSheet.create({
    page: { fontFamily: DOC_FONT_STACK, fontSize: 8, padding: 28, color: BRAND.text },
    title: { fontSize: 14, fontWeight: 'bold', marginBottom: 6, color: BRAND.ocean },
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { width: 70, color: BRAND.muted },
    metaValue: { flex: 1 },
    metaBlock: { marginBottom: 10, paddingBottom: 8, borderBottomWidth: 1, borderBottomColor: BRAND.ocean },
    tableHeader: {
        flexDirection: 'row',
        backgroundColor: BRAND.accent,
        borderBottomWidth: 1,
        borderBottomColor: BRAND.ocean,
        paddingVertical: 3,
        marginBottom: 2,
        fontWeight: 'bold',
    },
    row: { flexDirection: 'row', paddingVertical: 3, borderBottomWidth: 0.5, borderBottomColor: BRAND.hairline },
    cell: { paddingRight: 6 },
    empty: { marginTop: 12, color: BRAND.muted },
    // AUD-2:第二张(及以后)表格的小标题,以及正文说明段
    sectionHeading: { fontSize: 10, fontWeight: 'bold', marginTop: 14, marginBottom: 4 },
    note: { marginTop: 14, paddingTop: 8, borderTopWidth: 0.5, borderTopColor: BRAND.muted, color: BRAND.muted },
    footer: { position: 'absolute', bottom: 14, left: 28, right: 28, fontSize: 7, color: BRAND.muted },
})

export type ReportColumn = { header: string; width: number; align?: 'left' | 'right' }

// AUD-2:一份报表可以有【不止一张表】(可追溯报告是"血缘链 + 回收率"两张)。
// 【纯追加】—— 不传 sections / note 时,渲染出的字节与 RPT-1 那四条路由此前
// 逐字相同:四条路由一个字都没改。
export type ReportSection = { heading: string; columns: ReportColumn[]; rows: string[][] }

export default function ReportDocument({
    title,
    generatedAtLabel,
    generatedAt,
    filtersLabel,
    filters,
    localeLabel,
    locale,
    columns,
    rows,
    emptyText,
    pageLabel,
    sections = [],
    note,
    company,
}: {
    title: string
    generatedAtLabel: string
    generatedAt: string
    filtersLabel: string
    filters: string
    localeLabel: string
    locale: string
    columns: ReportColumn[]
    rows: string[][]
    emptyText: string
    pageLabel: string
    /** 追加的表格,画在主表之后(AUD-2)。不传 = 与此前逐字相同。 */
    sections?: ReportSection[]
    /** 正文末尾的一段说明。可追溯报告用它说清"回收率是估算,不是审定 KPI"——
     *  【一个只拿到 PDF 的客户,不能只看见一个光秃秃的百分比】。 */
    note?: string
    /** ★ 传了就是【对外】文档,画字标抬头;不传就是内部报表。见文件抬头。 */
    company?: DocumentCompany
}) {
    return (
        <Document>
            <Page size="A4" orientation="landscape" style={styles.page}>
                {/* 【表头块每页都在】—— 一份被翻到第三页的报表,读的人同样要知道
                    它是什么、什么时候生成的、过滤条件是什么。 */}
                <View fixed>
                    {/* 对外的那一份先自我介绍;内部四张不画 —— 见文件抬头的判据 */}
                    {company ? <DocumentLetterhead company={company} /> : null}
                    <Text style={styles.title}>{title}</Text>
                    <View style={styles.metaBlock}>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>{generatedAtLabel}</Text>
                            <Text style={styles.metaValue}>{generatedAt}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>{filtersLabel}</Text>
                            <Text style={styles.metaValue}>{filters}</Text>
                        </View>
                        <View style={styles.metaRow}>
                            <Text style={styles.metaLabel}>{localeLabel}</Text>
                            <Text style={styles.metaValue}>{locale}</Text>
                        </View>
                    </View>
                </View>

                {/* 表头随页重复(fixed)—— 与发票明细同一条 */}
                <View style={styles.tableHeader} fixed>
                    {columns.map((c, i) => (
                        <Text
                            key={i}
                            style={[styles.cell, { width: c.width, textAlign: c.align ?? 'left' }]}
                        >
                            {c.header}
                        </Text>
                    ))}
                </View>

                {rows.length === 0 ? (
                    <Text style={styles.empty}>{emptyText}</Text>
                ) : (
                    rows.map((r, ri) => (
                        // wrap={false}:一行不许被分页切成两半
                        <View key={ri} style={styles.row} wrap={false}>
                            {r.map((cell, ci) => (
                                <Text
                                    key={ci}
                                    style={[
                                        styles.cell,
                                        { width: columns[ci]?.width ?? 60, textAlign: columns[ci]?.align ?? 'left' },
                                    ]}
                                >
                                    {cell}
                                </Text>
                            ))}
                        </View>
                    ))
                )}

                {/* AUD-2:追加表格。每一张自带小标题 —— 一份有两张表的报表,
                    读的人必须知道自己在看哪一张。 */}
                {sections.map((sec, si) => (
                    <View key={si}>
                        <Text style={styles.sectionHeading}>{sec.heading}</Text>
                        <View style={styles.tableHeader}>
                            {sec.columns.map((c, i) => (
                                <Text key={i} style={[styles.cell, { width: c.width, textAlign: c.align ?? 'left' }]}>
                                    {c.header}
                                </Text>
                            ))}
                        </View>
                        {sec.rows.length === 0 ? (
                            <Text style={styles.empty}>{emptyText}</Text>
                        ) : (
                            sec.rows.map((r, ri) => (
                                <View key={ri} style={styles.row} wrap={false}>
                                    {r.map((cell, ci) => (
                                        <Text
                                            key={ci}
                                            style={[
                                                styles.cell,
                                                { width: sec.columns[ci]?.width ?? 60,
                                                  textAlign: sec.columns[ci]?.align ?? 'left' },
                                            ]}
                                        >
                                            {cell}
                                        </Text>
                                    ))}
                                </View>
                            ))
                        )}
                    </View>
                ))}

                {note && <Text style={styles.note}>{note}</Text>}

                <Text
                    style={styles.footer}
                    render={({ pageNumber, totalPages }) => `${pageLabel} ${pageNumber} / ${totalPages}`}
                    fixed
                />
            </Page>
        </Document>
    )
}
