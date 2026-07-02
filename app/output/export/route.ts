// app/output/export/route.ts
// 产出批次的 CSV 导出(Next 16 Route Handler)。端口自 inbound 导出。
// 复用列表页同一套过滤逻辑(outputQuery),所以导出的就是用户当前 搜索/状态/客户/物料/排序 后的结果;
// 不分页,导出全部匹配行。读取了 request 查询参数,因此按请求动态执行(不缓存)。
//
// 保留嵌入 select(materials(name) / customers(legal_name)),把关联方名字摊平成 CSV 列。
// 注意:customer 可空(未售出批次)—— 那一列留空。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import {
    parseOutputListParams,
    applyOutputFilters,
    resolveOutputSearchIds,
    buildOutputSearchOr,
} from '../outputQuery'

// 带嵌入的导出行类型(FK 嵌入运行时是对象,显式锁住)。customers 可空。
type ExportRow = {
    code: string
    quantity: number
    unit: string
    remaining_qty: number
    output_date: string | null
    purity: string | null
    state: string
    status: string
    notes: string | null
    created_at: string
    materials: { name: string } | null
    customers: { legal_name: string } | null
}

// CSV 表头:用稳定、机器可读的英文。关联方名字摊平成 Material / Customer 列。
const CSV_HEADERS = [
    'Code',
    'Material',
    'Customer',
    'Quantity',
    'Unit',
    'Remaining Qty',
    'Output Date',
    'Purity',
    'State',
    'Status',
    'Notes',
    'Created At',
]

// 把任意值转成安全的 CSV 字段:一律加双引号,内部双引号翻倍 ——
// 这样字段里的逗号 / 换行 / 引号(如 notes)都不会破坏 CSV。
function csvCell(value: unknown): string {
    if (value === null || value === undefined) return '""'
    return '"' + String(value).replace(/"/g, '""') + '"'
}

// created_at 转成稳定、Excel 友好的格式(UTC,避免服务器时区歧义)。
function formatDate(value: string | null): string {
    if (!value) return ''
    const d = new Date(value)
    if (Number.isNaN(d.getTime())) return value
    const pad = (n: number) => String(n).padStart(2, '0')
    return (
        `${d.getUTCFullYear()}-${pad(d.getUTCMonth() + 1)}-${pad(d.getUTCDate())}` +
        ` ${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`
    )
}

// 文件名里的日期戳:output-YYYY-MM-DD.csv(本地日期)
function todayStamp(): string {
    const d = new Date()
    const pad = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export async function GET(request: NextRequest) {
    const sp = Object.fromEntries(request.nextUrl.searchParams)
    const params = parseOutputListParams(sp)

    const supabase = await createClient()
    // 搜索同列表页:先解析关联方 id,再拼 OR(导出也要反映搜索)
    const searchIds = await resolveOutputSearchIds(supabase, params.q)
    const searchOr = buildOutputSearchOr(params.q, searchIds)
    // 保留嵌入:把 materials.name / customers.legal_name 摊平进 CSV
    const baseQuery = supabase.from('output_batches').select(`
        code, quantity, unit, remaining_qty, output_date, purity, state, status, notes, created_at,
        materials ( name ),
        customers ( legal_name )
    `)
    const { data, error } = await applyOutputFilters(baseQuery, params, searchOr)

    if (error) {
        return new Response(`Export failed: ${error.message}`, { status: 500 })
    }

    const rows = (data as unknown as ExportRow[]) ?? []

    const lines: string[] = []
    lines.push(CSV_HEADERS.map(csvCell).join(','))
    for (const r of rows) {
        lines.push(
            [
                csvCell(r.code),
                csvCell(r.materials?.name ?? ''),
                // 客户可空(未售出批次)—— 留空
                csvCell(r.customers?.legal_name ?? ''),
                csvCell(r.quantity),
                csvCell(r.unit),
                csvCell(r.remaining_qty),
                csvCell(r.output_date),
                csvCell(r.purity),
                // state 导出规范存储值(机器可读),与 suppliers 导出 status 一致
                csvCell(r.state),
                csvCell(r.status),
                csvCell(r.notes),
                csvCell(formatDate(r.created_at)),
            ].join(',')
        )
    }

    // CRLF 行尾 + UTF-8 BOM:让 Excel 正确按行分割并识别中文(名称/状态可能是中文)。
    const csv = '\uFEFF' + lines.join('\r\n') + '\r\n'

    return new Response(csv, {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            'Content-Disposition': `attachment; filename="output-${todayStamp()}.csv"`,
        },
    })
}
