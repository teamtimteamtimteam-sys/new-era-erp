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
import { mustRows } from '@/lib/db-helpers'
import { fallbackForRawError } from '@/lib/machine-text'
import { formatCsvTimestamp } from '@/lib/dates'

// FIX-2b:内嵌拿掉之后,这里只剩本表自己的列 + 两个 FK。
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
    material_id: string | null
    supplier_id: string | null
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
    // ★★【FIX-2b:内嵌拿掉 —— 与列表页那一处是同一条缺陷的同一半】★★
    //   `materials ( name )` / `suppliers ( legal_name )` 读的是基表,对 warehouse
    //   与 operations 一律解析成 null,于是导出的 CSV 里那两列【整列是空的】——
    //   而一个空单元格在电子表格里读起来就是「这条记录没有供应商」。
    //   页面已经改成在 TS 里拼,导出必须跟着改,否则同一份数据两个说法。
    const baseQuery = supabase.from('inbound_batches_masked').select(`
        code, quantity, unit, unit_price, remaining_qty, arrival_date, stage, status, notes, created_at,
        material_id, supplier_id
    `)
    const { data, error } = await applyInboundFilters(baseQuery, params, searchOr)

    if (error) {
        // ★ BUGFIX-1b:报错原文不再拼进 HTTP 正文(它会原样出现在浏览器窗口里)。
        return new Response(`Export failed: ${await fallbackForRawError(error.message, 'inbound/export')}`, { status: 500 })
    }

    const rows = (data as unknown as ExportRow[]) ?? []
    // 名字表:两张查名视图,谓词都含 module.inbound.view(见列表页的注释)。
    const [matNameRes, supNameRes] = await Promise.all([
        supabase.from('material_lookup').select('id, name').is('deleted_at', null),
        supabase.from('supplier_lookup').select('id, legal_name').is('deleted_at', null),
    ])
    const materialName = new Map((mustRows(matNameRes) as unknown as
        { id: string; name: string }[]).map((m) => [m.id, m.name]))
    const supplierName = new Map((mustRows(supNameRes) as unknown as
        { id: string; legal_name: string }[]).map((s) => [s.id, s.legal_name]))

    const lines: string[] = []
    lines.push(CSV_HEADERS.map(csvCell).join(','))
    for (const r of rows) {
        lines.push(
            [
                csvCell(r.code),
                csvCell((r.material_id ? materialName.get(r.material_id) : null) ?? ''),
                csvCell((r.supplier_id ? supplierName.get(r.supplier_id) : null) ?? ''),
                csvCell(r.quantity),
                csvCell(r.unit),
                csvCell(r.unit_price),
                csvCell(r.remaining_qty),
                csvCell(r.arrival_date),
                // stage 导出规范存储值(机器可读),与 suppliers 导出 status 一致
                csvCell(r.stage),
                csvCell(r.status),
                csvCell(r.notes),
                csvCell(formatCsvTimestamp(r.created_at)),
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
