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
import { fallbackForRawError } from '@/lib/machine-text'
import { formatCsvTimestamp } from '@/lib/dates'

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
    // MANUAL-FIX-1 E:状态字典的英文名(state 是它的外键)。可空 —— 一个
    // 对不上字典的历史值不该让整份导出崩掉,那时退回存储值本身。
    output_batch_states: { name_en: string } | null
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
        customers ( legal_name ),
        output_batch_states ( name_en )
    `)
    const { data, error } = await applyOutputFilters(baseQuery, params, searchOr)

    if (error) {
        // ★ BUGFIX-1b:报错原文不再拼进 HTTP 正文(它会原样出现在浏览器窗口里)。
        return new Response(`Export failed: ${await fallbackForRawError(error.message, 'output/export')}`, { status: 500 })
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
                // ★★【MANUAL-FIX-1 E:这里此前导出的是【存储值】,而存储值是中文】★★
                //   output_batches.state 存的是 output_batch_states 的主键,
                //   而那些主键是 `库存中` / `部分售出` / `已售罄`。屏幕上这一列
                //   走 output.state.* 显示成英文,于是【同一块屏幕上的下载按钮】
                //   给出的文件,英文读者一个字也读不懂。
                //   ★ 旧注释写着「规范存储值(机器可读)」—— 那句话现在是错的,
                //     所以它没有留下:**没有任何东西再把这份文件读回去**
                //     (lib/importTables.ts 不收产出批次),它唯一的读者是人。
                //     一条不再成立的理由留在注释里,比留在代码里更坏 ——
                //     下一个人会相信它。
                //   取的是字典表自己的 name_en,不是在这里手抄一份英文对照:
                //   与 finance/gst 那份导出取 label_en 是同一条路子。
                csvCell(r.output_batch_states?.name_en ?? r.state),
                csvCell(r.status),
                csvCell(r.notes),
                csvCell(formatCsvTimestamp(r.created_at)),
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
