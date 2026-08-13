import { csvResponse, exportFailed } from '../../reportShared'
import { fetchSafety } from '../safetyQuery'

export async function GET() {
    try {
        const { rows } = await fetchSafety()
        return csvResponse('safety-stock',
            ['Material Code', 'Material', 'Available', 'Threshold', 'Shortfall', 'Unit'],
            rows.map((r) => {
                const short = (r.safety_stock_qty ?? 0) - r.available_qty
                return [r.code, r.name, r.available_qty, r.safety_stock_qty, short > 0 ? short : '', r.unit]
            }))
    } catch (e) { return exportFailed(e as { message: string }) }
}
