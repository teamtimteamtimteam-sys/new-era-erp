import { csvResponse, exportFailed } from '../../reportShared'
import { fetchViolations } from '../violationsQuery'

export async function GET() {
    try {
        const { violations, unconfigured, unclassified } = await fetchViolations()
        // 【一个 section 列,而不是三个文件】导出的是屏幕上那三段;把"未决定"
        // 混进违规行里而不标出来,正是这张报表在页面上拒绝做的事。
        return csvResponse('class-violations',
            ['Section', 'Location', 'Material', 'Class', 'Quantity', 'Unit'],
            [
                ...violations.map((v) => ['violation', v.location_code, v.material_code, v.class_code, v.qty, '']),
                ...unconfigured.map((r) => ['unconfigured_location', r.code, r.other, '', r.qty, r.unit]),
                ...unclassified.map((r) => ['unclassified_material', r.other, r.code, '', r.qty, r.unit]),
            ])
    } catch (e) { return exportFailed(e as { message: string }) }
}
