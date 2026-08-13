// RPT-1:快照 CSV。与页面共用 snapshotQuery —— 导出的就是屏幕上那张表。
import { csvResponse, exportFailed } from '../../reportShared'
import { fetchSnapshot } from '../snapshotQuery'

export async function GET() {
    try {
        const rows = await fetchSnapshot()
        return csvResponse(
            'stock-snapshot',
            ['Material Code', 'Material', 'Location Code', 'Location', 'Stock Status', 'Quantity', 'Unit'],
            // 【导出规范存储值】stock_status 原样,不翻译 —— 机器可读(同进料导出)。
            // 未指定库位导出成空字符串:CSV 里"空"就是"未指定",而它在页面上有名字。
            rows.map((r) => [
                r.material_code, r.material_name,
                r.location_code ?? '', r.location_name ?? '',
                r.stock_status, r.qty, r.unit,
            ])
        )
    } catch (e) {
        return exportFailed(e as { message: string })
    }
}
