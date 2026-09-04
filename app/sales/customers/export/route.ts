// app/sales/customers/export/route.ts
// 客户列表的 CSV 导出(Next 16 Route Handler)。端口自 suppliers 导出。
// 复用列表页同一套过滤逻辑(customerQuery),所以导出的就是用户当前 搜索 / 排序 后的结果;
// 不分页,导出全部匹配行。读取了 request 上的查询参数,因此本路由按请求动态执行(不缓存)。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { parseCustomerListParams, applyCustomerFilters } from '../customerQuery'

// 导出列(比表格多 —— 导出文件是给 Excel 用的)。顺序即 CSV 列顺序,与下方表头一一对应。
// 即便不按 status 筛选,导出里仍保留 status —— 它也是数据。
const EXPORT_COLUMNS =
    'code, legal_name, short_name, country, customer_types, status, tax_id, payment_terms, incoterm, credit_rating, address, created_at'

// CSV 表头:用稳定、机器可读的英文。
const CSV_HEADERS = [
    'Code',
    'Legal Name',
    'Short Name',
    'Country',
    'Customer Types',
    'Status',
    'Tax ID',
    'Payment Terms',
    'Incoterm',
    'Credit Rating',
    'Address',
    'Created At',
]

// 把任意值转成安全的 CSV 字段:一律加双引号,内部双引号翻倍 ——
// 这样字段里的逗号 / 换行 / 引号(如地址、备注)都不会破坏 CSV。
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

// 文件名里的日期戳:customers-YYYY-MM-DD.csv(本地日期)
function todayStamp(): string {
    const d = new Date()
    const pad = (n: number) => String(n).padStart(2, '0')
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}`
}

export async function GET(request: NextRequest) {
    const sp = Object.fromEntries(request.nextUrl.searchParams)
    const params = parseCustomerListParams(sp)

    const supabase = await createClient()
    const baseQuery = supabase.from('customers').select(EXPORT_COLUMNS)
    const { data, error } = await applyCustomerFilters(baseQuery, params)

    if (error) {
        return new Response(`Export failed: ${error.message}`, { status: 500 })
    }

    const rows = data ?? []

    const lines: string[] = []
    lines.push(CSV_HEADERS.map(csvCell).join(','))
    for (const r of rows) {
        lines.push(
            [
                csvCell(r.code),
                csvCell(r.legal_name),
                csvCell(r.short_name),
                csvCell(r.country),
                // 数组用 "; " 连接,避免和 CSV 的逗号分隔混淆
                csvCell(r.customer_types?.join('; ') ?? ''),
                csvCell(r.status),
                csvCell(r.tax_id),
                csvCell(r.payment_terms),
                csvCell(r.incoterm),
                csvCell(r.credit_rating),
                csvCell(r.address),
                csvCell(formatDate(r.created_at)),
            ].join(',')
        )
    }

    // CRLF 行尾 + UTF-8 BOM:让 Excel 正确按行分割并识别中文(legal_name 可能是中文)。
    const csv = '\uFEFF' + lines.join('\r\n') + '\r\n'

    return new Response(csv, {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            // attachment 强制下载;filename 决定下载文件名
            'Content-Disposition': `attachment; filename="customers-${todayStamp()}.csv"`,
        },
    })
}
