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
// 超出范围的字由 lib/invoiceFontCoverage 在渲染前【大声报错】,不会静默印空白。
import { Document, Page, Text, View, StyleSheet } from '@react-pdf/renderer'
import { INVOICE_FONT_FAMILY } from '@/app/finance/invoices/[id]/pdf/InvoiceDocument'

const styles = StyleSheet.create({
    page: { fontFamily: INVOICE_FONT_FAMILY, fontSize: 8, padding: 28, color: '#111827' },
    title: { fontSize: 14, fontWeight: 'bold', marginBottom: 6 },
    metaRow: { flexDirection: 'row', marginBottom: 1 },
    metaLabel: { width: 70, color: '#6b7280' },
    metaValue: { flex: 1 },
    metaBlock: { marginBottom: 10, paddingBottom: 8, borderBottomWidth: 1, borderBottomColor: '#111827' },
    tableHeader: {
        flexDirection: 'row',
        borderBottomWidth: 1,
        borderBottomColor: '#111827',
        paddingBottom: 3,
        marginBottom: 2,
        fontWeight: 'bold',
    },
    row: { flexDirection: 'row', paddingVertical: 3, borderBottomWidth: 0.5, borderBottomColor: '#e5e7eb' },
    cell: { paddingRight: 6 },
    empty: { marginTop: 12, color: '#6b7280' },
    footer: { position: 'absolute', bottom: 14, left: 28, right: 28, fontSize: 7, color: '#9ca3af' },
})

export type ReportColumn = { header: string; width: number; align?: 'left' | 'right' }

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
}) {
    return (
        <Document>
            <Page size="A4" orientation="landscape" style={styles.page}>
                {/* 【表头块每页都在】—— 一份被翻到第三页的报表,读的人同样要知道
                    它是什么、什么时候生成的、过滤条件是什么。 */}
                <View fixed>
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

                <Text
                    style={styles.footer}
                    render={({ pageNumber, totalPages }) => `${pageLabel} ${pageNumber} / ${totalPages}`}
                    fixed
                />
            </Page>
        </Document>
    )
}
