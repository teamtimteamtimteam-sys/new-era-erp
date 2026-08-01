// app/inbound/export/route.ts
// 进料批次的 CSV 导出(Next 16 Route Handler)。端口自 materials 导出。
// 复用列表页同一套过滤逻辑(inboundQuery),所以导出的就是用户当前 搜索/阶段/供应商/物料/排序 后的结果;
// 不分页,导出全部匹配行。读取了 request 查询参数,因此按请求动态执行(不缓存)。
//
// 与主数据导出的不同:这里【保留嵌入 select】(materials(name) / suppliers(legal_name)),
// 把关联方名字摊平成 CSV 列;过滤逻辑同列表页(applyInboundFilters)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import {
    parseInboundListParams,
    applyInboundFilters,
    resolveInboundSearchIds,
    buildInboundSearchOr,
} from '../inboundQuery'

// 带嵌入的导出行类型(FK 嵌入运行时是对象,显式锁住)。
type ExportRow = {
    code: string
    quantity: number
    unit: string
    unit_price: number | null
    remaining_qty: number
    arrival_date: string | null
    stage: string
    status: string
    notes: string | null
    created_at: string
    materials: { name: string } | null
    suppliers: { legal_name: string } | null
}

// CSV 表头:用稳定、机器可读的英文。关联方名字摊平成 Material / Supplier 列。
const CSV_HEADERS = [
    'Code',
    'Material',
    'Supplier',
    'Quantity',
    'Unit',
    'Unit Price',
    'Remaining Qty',
    'Arrival Date',
    'Stage',
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

// 文件名里的日期戳:inbound-YYYY-MM-DD.csv(本地日期)
function todayStamp(): string {
    const d = new Date()
    const pad = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export async function GET(request: NextRequest) {
    const sp = Object.fromEntries(request.nextUrl.searchParams)
    const params = parseInboundListParams(sp)

    const supabase = await createClient()
    // 搜索同列表页:先解析关联方 id,再拼 OR(导出也要反映搜索)
    const searchIds = await resolveInboundSearchIds(supabase, params.q)
    const searchOr = buildInboundSearchOr(params.q, searchIds)
    // 保留嵌入:把 materials.name / suppliers.legal_name 摊平进 CSV
    const baseQuery = supabase.from('inbound_batches_masked').select(`
        code, quantity, unit, unit_price, remaining_qty, arrival_date, stage, status, notes, created_at,
        materials ( name ),
        suppliers ( legal_name )
    `)
    const { data, error } = await applyInboundFilters(baseQuery, params, searchOr)

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
                csvCell(r.suppliers?.legal_name ?? ''),
                csvCell(r.quantity),
                csvCell(r.unit),
                csvCell(r.unit_price),
                csvCell(r.remaining_qty),
                csvCell(r.arrival_date),
                // stage 导出规范存储值(机器可读),与 suppliers 导出 status 一致
                csvCell(r.stage),
                csvCell(r.status),
                csvCell(r.notes),
                csvCell(formatDate(r.created_at)),
            ].join(',')
        )
    }

    // CRLF 行尾 + UTF-8 BOM:让 Excel 正确按行分割并识别中文(名称/阶段可能是中文)。
    const csv = '\uFEFF' + lines.join('\r\n') + '\r\n'

    return new Response(csv, {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            'Content-Disposition': `attachment; filename="inbound-${todayStamp()}.csv"`,
        },
    })
}
