// RPT-1:快照 CSV。与页面共用 snapshotQuery —— 导出的就是屏幕上那张表。
//
// ★【受限的金额导出成 RESTRICTED,不是空、更不是 0】★ 一个空格子在 CSV 里
// 读起来像"这一格没有数",而真相是"你不被允许看这一格"。两者在电子表格里
// 会被同一个 SUM() 当成 0 —— 那正是本仓库付过三次账的形状。
import { csvResponse, exportFailed } from '../../reportShared'
import { fetchValuation } from '../snapshotQuery'

export async function GET() {
    try {
        const v = await fetchValuation()
        const cell = (n: number | null) => (n === null ? 'RESTRICTED' : n)
        return csvResponse(
            'stock-snapshot',
            ['Material Code', 'Material', 'Location Code', 'Location', 'Stock Status',
             'Batch Kind', 'Quantity', 'Unit', 'Value (base)', 'Uncosted Qty'],
            // 【导出规范存储值】stock_status / batch_kind 原样,不翻译 —— 机器可读。
            // 未指定库位导出成空字符串:CSV 里"空"就是"未指定",而它在页面上有名字。
            v.rows.map((r) => [
                r.material_code, r.material_name,
                r.location_code ?? '', r.location_name ?? '',
                r.stock_status, r.batch_kind, r.qty, r.unit,
                cell(r.value_base), r.uncosted_qty,
            ])
        )
    } catch (e) {
        return exportFailed(e as { message: string })
    }
}
