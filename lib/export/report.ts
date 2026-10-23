// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-3a(Tim 2026-10-23)· 把一张【报表】写成 .xlsx / .csv —— 带着报表自己的版式
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-23 TABLE-EXPORT-3 Step 0 的裁定(docs/table-export.md):
//   Q2  财务报表:Excel 照报表自己的版式 —— 分节抬头、小计、合计、一级缩进;
//       CSV 是一张平表,多一列说明每一行是抬头、科目(明细)还是小计 / 合计。
//   Q3  报表【自己算出来】的行(小计、毛利与净利、合计、预览的合计)照导出。
//       TABLE-EXPORT-1 Q12「不写合计行」仍然管普通的列表 —— 所以这是【另一个】写法,不是给 write.ts 开一个口子。
//   Q5  现金预测的周表:一种币种一张工作表。
//
// ★ 为什么是一个新文件而不是给 ExportTable 加一个字段:ExportTable 是【列表】的形状(一行一条记录,Q12 不许合计行)。
//   报表的一行可以是一个抬头、一个科目、或一条报表自己算出来的小计 —— 那是一种不同的东西,类型上就分开,
//   一张列表不可能"顺手"带上一条合计行。
// ★ 一格怎么写(受限 / 数字格式 / 日期)与列表【同一份】(write.ts 的 csvValue · xlsxValue · xlsxFormat)。
// ★ 行是页面自己已经读到、算好的(报表的数全部来自库:pnl_statement · balance_sheet · …),这里不算任何数。
// ════════════════════════════════════════════════════════════════════════════

import { csvRow, csvDocument } from '@/lib/csv'
import type { ExportCell } from '@/lib/export/cells'
import { csvValue, xlsxValue, xlsxFormat, sheetName } from '@/lib/export/write'

/** 一行在报表里是什么。`line` = 一条明细(一个科目、一个周的数……)。 */
export type ReportLineKind = 'heading' | 'line' | 'subtotal' | 'total'
export const REPORT_LINE_KINDS: readonly ReportLineKind[] = ['heading', 'line', 'subtotal', 'total']

export type ReportLine = {
    kind: ReportLineKind
    /** 0 = 顶格,1 = 缩一级(Q2:一级缩进)。抬头与合计通常是 0,明细是 1。 */
    level?: 0 | 1
    /** 与 headers 一一对应。抬头行只有第一格有字,其余给 xText(null)。 */
    cells: ExportCell[]
}

export type ReportSheet = {
    /** 工作表名(多张时,例如币种);CSV 里写进「表」那一列。 */
    title: string
    lines: ReportLine[]
}

export type ExportReport = {
    /** Q9 文件名里的英文名(小写、连字符)。 */
    name: string
    /** About 表的标题(界面语言)。 */
    title: string
    headers: string[]
    sheets: ReportSheet[]
    about: Array<[string, string]>
    restrictedText: string
    /** CSV 那一列的列头与四种行的叫法(界面语言)。 */
    kindHeader: string
    kindLabels: Record<ReportLineKind, string>
    /** 多张工作表时 CSV 多出来的那一列的列头(例如「币种」)。只有一张时不写这一列。 */
    sheetHeader?: string
}

function assertShape(r: ExportReport): void {
    if (r.sheets.length === 0) throw new Error(`REPORT_EXPORT_NO_SHEET|${r.name}`)
    if (r.sheets.length > 1 && !r.sheetHeader) throw new Error(`REPORT_EXPORT_SHEET_HEADER_MISSING|${r.name}`)
    for (const s of r.sheets) for (const l of s.lines) {
        if (l.cells.length !== r.headers.length) {
            throw new Error(`REPORT_EXPORT_WIDTH|${r.name}|${s.title}|${l.cells.length} cells vs ${r.headers.length} headers`)
        }
    }
}

/** CSV:一张平表(Q2)。第一列是行的种类;多张工作表时再前面一列是表名。 */
export function buildReportCsv(r: ExportReport): string {
    assertShape(r)
    const multi = r.sheets.length > 1
    const head = [...(multi ? [r.sheetHeader!] : []), r.kindHeader, ...r.headers]
    const lines = r.sheets.flatMap((s) => s.lines.map((l) => csvRow([
        ...(multi ? [s.title] : []),
        r.kindLabels[l.kind],
        ...l.cells.map((c) => csvValue(c, r.restrictedText)),
    ])))
    return csvDocument([csvRow(head), ...lines])
}

/** Excel:一张(或每种币种一张)工作表,照报表的版式 —— 抬头与小计 / 合计加粗,合计上方一条线,明细缩一级。 */
export async function buildReportXlsx(r: ExportReport): Promise<ArrayBuffer> {
    assertShape(r)
    const ExcelJS = (await import('exceljs')).default
    const wb = new ExcelJS.Workbook()
    const used = new Set<string>(['about'])   // 最后那张「About」也算一个名字
    for (const s of r.sheets) {
        // 工作表名在一本里不许重复(Excel 的规矩);截到 31 字之后撞名就加序号
        let name = sheetName(s.title)
        for (let i = 2; used.has(name.toLowerCase()); i++) name = sheetName(`${s.title.slice(0, 27)} (${i})`)
        used.add(name.toLowerCase())
        const ws = wb.addWorksheet(name, { views: [{ state: 'frozen', ySplit: 1 }] })
        ws.addRow(r.headers).font = { bold: true }
        for (const l of s.lines) {
            const row = ws.addRow(l.cells.map((c) => xlsxValue(c, r.restrictedText)))
            l.cells.forEach((c, i) => xlsxFormat(row.getCell(i + 1), c))
            if (l.kind !== 'line') row.font = { bold: true }
            if (l.kind === 'heading') row.getCell(1).fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FFF3F4F6' } }
            if (l.kind === 'total') row.eachCell({ includeEmpty: true }, (cell) => { cell.border = { top: { style: 'thin' } } })
            if ((l.level ?? 0) === 1) row.getCell(1).alignment = { indent: 1 }
        }
        r.headers.forEach((h, i) => {
            const widest = Math.max(h.length, ...s.lines.slice(0, 300).map((l) => {
                const c = l.cells[i]
                return c?.t === 'text' && c.v ? c.v.length + (l.level ? 2 : 0) : 14
            }))
            ws.getColumn(i + 1).width = Math.min(60, Math.max(8, widest + 2))
        })
    }
    const about = wb.addWorksheet('About')
    for (const [k, v] of r.about) about.addRow([k, v])
    about.getColumn(1).font = { bold: true }
    about.getColumn(1).width = 24
    about.getColumn(2).width = 80
    return wb.xlsx.writeBuffer() as Promise<ArrayBuffer>
}
