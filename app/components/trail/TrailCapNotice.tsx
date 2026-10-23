// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-2b-2(Tim 2026-10-23,TABLE-EXPORT-2b-2 Step 0 Q1)· 清单页底部那段历史只读最新 N 条记录时,【说出来】
// ════════════════════════════════════════════════════════════════════════════
// /hr/leave/grants 与 /hr/reviews/cycles 只把最新的 200 条记录交给 <ListTrail>(每一条各读一次 record_trail),
// 第 201 条起的历史在那一段里一个字都不出现。Tim 的裁定:只加一句「History below covers the latest N of M」,不导出
// —— 与 change-history、通知同一种处置(TABLE-EXPORT-2 Q4 · 2b Q2)。
// ★ `total` 必须是与那 N 条【同一条筛选】的 count(exact);小于等于 `shown` 时什么都不画。
// ════════════════════════════════════════════════════════════════════════════
import { getTranslations } from '@/lib/i18n/server'

/** 两页各交给 <ListTrail> 多少条记录 —— 与转换之前同一个数。 */
export const TRAIL_RECORDS = 200

const COUNT = new Intl.NumberFormat('en-US')

export default async function TrailCapNotice({ shown, total }: { shown: number; total: number }) {
    if (total <= shown) return null
    const t = await getTranslations()
    return (
        <p role="status" data-trail-cap-notice="" className="mt-8 mb-2 text-sm text-amber-800">
            {t('table.export.trailCapNotice', { shown: COUNT.format(shown), total: COUNT.format(total) })}
        </p>
    )
}
