// app/materials/export/route.ts
// 物料列表的 CSV 导出(Next 16 Route Handler)。端口自 suppliers 导出。
// 复用列表页同一套过滤逻辑(materialQuery),所以导出的就是用户当前 搜索 / 分类 / 排序 后的结果;
// 不分页,导出全部匹配行。读取了 request 上的查询参数,因此本路由按请求动态执行(不缓存)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { parseMaterialListParams, applyMaterialFilters } from '../materialQuery'
import { fallbackForRawError } from '@/lib/machine-text'
import { formatCsvTimestamp } from '@/lib/dates'

// 导出列。顺序即 CSV 列顺序,与下方表头一一对应。
// kind_code / chemistry / unit 导出【规范存储值】(而非翻译标签)—— 稳定、机器可读,
// 与 suppliers 导出 status 规范值一致。
const EXPORT_COLUMNS =
    'code, name, kind_code, may_be_processed, chemistry, unit, spec, status, notes, created_at'

// CSV 表头:用稳定、机器可读的英文。
const CSV_HEADERS = [
    'Code',
    'Name',
    'Kind',
    'May Be Processed',
    'Chemistry',
    'Unit',
    'Spec',
    'Status',
    'Notes',
    'Created At',
]

// 把任意值转成安全的 CSV 字段:一律加双引号,内部双引号翻倍 ——
// 这样字段里的逗号 / 换行 / 引号(如 spec、notes)都不会破坏 CSV。
function csvCell(value: unknown): string {
    if (value === null || value === undefined) return '""'
    return '"' + String(value).replace(/"/g, '""') + '"'
}

// created_at 转成稳定、Excel 友好的格式(UTC,避免服务器时区歧义)。
// ════════════════════════════════════════════════════════════════════════════
// ★★★【导出里的日期【不跟】屏幕改 —— Tim 的裁定 D3,理由写在这里】★★★
// ════════════════════════════════════════════════════════════════════════════
// > **Excel 把 `2026-09-01` 认成【日期】(可排序、可算差);
// > 把 `01 Sep 2026` 认成【一串文字】,而文字是按字母排的:Apr < Aug < Dec …**
// >
// > **导出的用途是【再算一次】,不是【读】。屏幕跟人走,导出跟机器走。**
//
// ☞ 这**不是**一处"还没改到的地方",是一条裁定。下一刀看见屏幕上是
//   `01 Sep 2026` 而这里是 `2026-09-01`,那不是不一致 —— **那是两个读者。**
// ☞ DATE-1 把从前那【五份逐字节相同的本地 formatDate】合并成了
//   `lib/dates.ts` 的 `formatCsvTimestamp()`,而它**逐字节吐与从前相同的串**。
//   合并是为了只剩一份,**不是为了顺手把它改好看**。
//   ⚠ 它用的是 **UTC**(那五份复制从第一天起就是),而屏幕走业务时区 ——
//     这件事立案在 docs/known-issues.md 的 DATE1-CSV-UTC,**本刀不动它**:
//     动它就是动导出的字节,而那正是 D3 裁的东西。
// ════════════════════════════════════════════════════════════════════════════

// 文件名里的日期戳:materials-YYYY-MM-DD.csv(本地日期)
function todayStamp(): string {
    const d = new Date()
    const pad = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export async function GET(request: NextRequest) {
    const sp = Object.fromEntries(request.nextUrl.searchParams)
    const params = parseMaterialListParams(sp)

    const supabase = await createClient()
    const baseQuery = supabase.from('materials').select(EXPORT_COLUMNS)
    const { data, error } = await applyMaterialFilters(baseQuery, params)

    if (error) {
        // ★ BUGFIX-1b:报错原文不再拼进 HTTP 正文(它会原样出现在浏览器窗口里)。
        return new Response(`Export failed: ${await fallbackForRawError(error.message, 'materials/export')}`, { status: 500 })
    }

    const rows = data ?? []

    const lines: string[] = []
    lines.push(CSV_HEADERS.map(csvCell).join(','))
    for (const r of rows) {
        lines.push(
            [
                csvCell(r.code),
                csvCell(r.name),
                csvCell(r.kind_code),
                csvCell(r.may_be_processed === null ? '' : String(r.may_be_processed)),
                csvCell(r.chemistry),
                csvCell(r.unit),
                csvCell(r.spec),
                csvCell(r.status),
                csvCell(r.notes),
                csvCell(formatCsvTimestamp(r.created_at)),
            ].join(',')
        )
    }

    // CRLF 行尾 + UTF-8 BOM:让 Excel 正确按行分割并识别中文(name 等可能是中文)。
    const csv = '\uFEFF' + lines.join('\r\n') + '\r\n'

    return new Response(csv, {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            // attachment 强制下载;filename 决定下载文件名
            'Content-Disposition': `attachment; filename="materials-${todayStamp()}.csv"`,
        },
    })
}
