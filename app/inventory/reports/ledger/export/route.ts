import type { NextRequest } from 'next/server'
import { csvResponse, exportFailed } from '../../reportShared'
import { fetchLedger, parseLedgerParams, flatten } from '../ledgerQuery'

export async function GET(request: NextRequest) {
    try {
        // 与页面共用同一份解析 —— 导出的就是当前过滤后的【全部】行,不分页
        const params = parseLedgerParams(Object.fromEntries(request.nextUrl.searchParams))
        const rows = await fetchLedger(params)
        return csvResponse('stock-ledger',
            ['Business Date', 'Batch', 'Material', 'Location', 'Movement Type', 'Stock Status', 'Qty Delta', 'Notes'],
            rows.map((r) => {
                const f = flatten(r)
                // 类型与状态导出【存储值】,不翻译(机器可读,同进料导出)
                return [f.date, f.batch, f.material, f.location, f.type, f.status, f.qty, f.notes]
            }))
    } catch (e) { return exportFailed(e as { message: string }) }
}
