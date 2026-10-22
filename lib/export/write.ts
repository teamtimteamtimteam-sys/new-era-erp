// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(2026-10-22)· 把一张表写成 .xlsx / .csv —— 统一导出的唯一写法
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-22 的裁定(docs/table-export.md 逐条):
//   Q7  时刻按新加坡时间,写成真的 Excel 日期格
//   Q9  文件名 <英文表名>_<YYYY-MM-DD>_<HHmm>.xlsx / .csv,新加坡时间,只有 ASCII
//   Q12 不写合计行;Excel 多一张「About」表(表名 · 生效的筛选 · 谁导出 · 何时),CSV 只有数据
//   Q13 exceljs 4.4.0(MIT),【只在有人导出时才加载】—— 所以下面是 `await import('exceljs')`
//
// 本文件只有纯函数 + 一个下载动作;它不读库、不判权限。读什么由表自己的行决定 ——
// 那些行来自页面自己的读取(经 *_masked 视图),所以一份导出【按构造】不会比屏幕多。
// ════════════════════════════════════════════════════════════════════════════

import { csvRow, csvDocument } from '@/lib/csv'
import type { ExportCell, NumberKind } from '@/lib/export/cells'

export const SG_TZ = 'Asia/Singapore'

/** 一个时刻在新加坡的墙上时间。用 Intl 而不是 +8 —— 让时区规则由一份数据决定,不由一个字面量。 */
export function sgParts(d: Date) {
    const parts = new Intl.DateTimeFormat('en-GB', {
        timeZone: SG_TZ, year: 'numeric', month: '2-digit', day: '2-digit',
        hour: '2-digit', minute: '2-digit', second: '2-digit', hourCycle: 'h23',
    }).formatToParts(d)
    const get = (k: string) => Number(parts.find((p) => p.type === k)?.value)
    return { y: get('year'), mo: get('month'), d: get('day'), h: get('hour'), mi: get('minute'), s: get('second') }
}

const pad = (n: number, w = 2) => String(n).padStart(w, '0')

/** Q9 文件名。表名只许 [a-z0-9-],别的一律拒 —— 一个会被邮件或 Windows 弄坏的名字不该悄悄过关。 */
export function exportFileName(name: string, ext: 'xlsx' | 'csv', now: Date = new Date()): string {
    if (!/^[a-z0-9]+(-[a-z0-9]+)*$/.test(name)) {
        throw new Error(`TABLE_EXPORT_BAD_NAME|${name}|表名只许小写英文字母、数字与连字符(Tim Q9:只有 ASCII)`)
    }
    const p = sgParts(now)
    return `${name}_${p.y}-${pad(p.mo)}-${pad(p.d)}_${pad(p.h)}${pad(p.mi)}.${ext}`
}

/** 一个时刻 → 新加坡墙上时间 `YYYY-MM-DD HH:mm:ss`(CSV 用)。 */
export function sgStamp(iso: string): string {
    const p = sgParts(new Date(iso))
    return `${p.y}-${pad(p.mo)}-${pad(p.d)} ${pad(p.h)}:${pad(p.mi)}:${pad(p.s)}`
}

export type ExportTable = {
    /** Q9 文件名里的英文表名,例如 `materials`。 */
    name: string
    /** About 表与工作表名用的标题(界面语言)。 */
    title: string
    headers: string[]
    rows: ExportCell[][]
    /** Q12 About 表的内容,已按界面语言写好:[标签, 值]。 */
    about: Array<[string, string]>
    /** Q3 受限那一格写的字:`common.restricted` 的当前语言。 */
    restrictedText: string
}

function csvValue(c: ExportCell, restrictedText: string): string | number | null {
    switch (c.t) {
        case 'restricted': return restrictedText
        case 'text': return c.v
        // 带币种 / 单位的数:CSV 没有格式这一说,那个词只能跟着值走(屏幕上也是这么写的)
        case 'number': return c.v !== null && c.suffix ? `${c.v} ${c.suffix}` : c.v
        case 'date': return c.v
        case 'datetime': return c.v ? sgStamp(c.v) : null
    }
}

/** CSV:纯数据(Q12),BOM + CRLF(与 lib/csv.ts 同一份,Excel 打开中文不乱码)。 */
export function buildCsv(t: ExportTable): string {
    return csvDocument([csvRow(t.headers), ...t.rows.map((r) => csvRow(r.map((c) => csvValue(c, t.restrictedText))))])
}

const NUM_FMT: Record<NumberKind, string> = {
    money: '#,##0.00',
    qty: '#,##0.####',
    int: '#,##0',
    pct: '0.00',
    rate: '0.000000',
}

/**
 * 一个日历日 / 新加坡墙上时间 → JS Date,其 UTC 分量 = 要显示的那几个数。
 * exceljs 按 UTC 把 Date 换成 Excel 序列数,所以这样写出来的格子在任何时区打开都显示同一个日子
 * —— 而不会因为打开它的电脑在别的时区而前后差一天。
 */
function excelDate(c: Extract<ExportCell, { t: 'date' | 'datetime' }>): Date | null {
    if (!c.v) return null
    if (c.t === 'date') {
        const [y, m, d] = c.v.split('-').map(Number)
        return new Date(Date.UTC(y, m - 1, d))
    }
    const p = sgParts(new Date(c.v))
    return new Date(Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s))
}

/** Excel 工作表名:≤31 个字符,不许 `[]:*?/\`。 */
export function sheetName(s: string): string {
    const clean = s.replace(/[[\]:*?/\\]/g, ' ').trim() || 'Sheet1'
    return clean.slice(0, 31)
}

export async function buildXlsx(t: ExportTable): Promise<ArrayBuffer> {
    const ExcelJS = (await import('exceljs')).default
    const wb = new ExcelJS.Workbook()
    const ws = wb.addWorksheet(sheetName(t.title), { views: [{ state: 'frozen', ySplit: 1 }] })
    ws.addRow(t.headers).font = { bold: true }
    for (const r of t.rows) {
        const row = ws.addRow(r.map((c) => {
            switch (c.t) {
                case 'restricted': return t.restrictedText
                case 'text': return c.v
                case 'number': return c.v
                case 'date':
                case 'datetime': return excelDate(c)
            }
        }))
        r.forEach((c, i) => {
            const cell = row.getCell(i + 1)
            if (c.t === 'number' && c.v !== null) {
                // 币种 / 单位进数字格式:格子仍是一个能加总的数,显示时带着它自己的那个词
                cell.numFmt = c.suffix ? `${NUM_FMT[c.kind]} "${c.suffix.replace(/"/g, '')}"` : NUM_FMT[c.kind]
            }
            else if (c.t === 'date' && c.v) cell.numFmt = 'yyyy-mm-dd'
            else if (c.t === 'datetime' && c.v) cell.numFmt = 'yyyy-mm-dd hh:mm'
        })
    }
    t.headers.forEach((h, i) => {
        const widest = Math.max(h.length, ...t.rows.slice(0, 200).map((r) => {
            const c = r[i]
            return c?.t === 'text' && c.v ? c.v.length : c?.t === 'datetime' ? 16 : 12
        }))
        ws.getColumn(i + 1).width = Math.min(60, Math.max(8, widest + 2))
    })

    const about = wb.addWorksheet('About')
    for (const [k, v] of t.about) about.addRow([k, v])
    about.getColumn(1).font = { bold: true }
    about.getColumn(1).width = 24
    about.getColumn(2).width = 80
    return wb.xlsx.writeBuffer() as Promise<ArrayBuffer>
}

/** 浏览器里把一份内容交给人保存。 */
export function downloadBlob(data: BlobPart, type: string, filename: string): void {
    const url = URL.createObjectURL(new Blob([data], { type }))
    const a = document.createElement('a')
    a.href = url
    a.download = filename
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 10_000)
}

export const XLSX_MIME = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
export const CSV_MIME = 'text/csv;charset=utf-8'
