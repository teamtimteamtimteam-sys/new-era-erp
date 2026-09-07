// RPT-1:安全库存总览。
// 【两种"空"必须分开说】没有任何物料被监控 ≠ 所有物料都在阈值之上。
//
// ★★ CONV-5:这一页是本刀里【唯一真正用上 ListPage empty 分支】的一张 ★★
// 其余 40 张的空态都由 DataTable 自己的 empty 说(因为它们的出口 —— 筛选栏、
// 新建按钮 —— 一旦落进 empty 分支就会被吞掉)。这一页不一样:它的两个出口
// (CSV / PDF 导出)是【抬头动作】,住在 ListPage 的 actions 里,而 actions 画在
// 状态分支【之前】。于是 monitored === 0 可以如实走 empty 分支,
// 那句「没有人设过任何阈值」正是 RefusalBlock 这个形状要说的话 ——
// 而它与「所有物料都在阈值之上」是两件不同的事,页面原本就把它们分开说,
// 本刀没有把这个区别压平。
import { getTranslations } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { fetchSafety } from './safetyQuery'
import { ListPage } from '@/app/components/ui/list-page'
import SafetyTable, { type SafetyRow } from './SafetyTable'
import { Button } from '@/app/components/ui/button'

export default async function SafetyPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const { rows, monitored, below } = await fetchSafety()

    const tableRows: SafetyRow[] = rows.map((r) => {
        const short = (r.safety_stock_qty ?? 0) - r.available_qty
        const isBelow = short > 0
        return {
            materialId: r.material_id,
            code: r.code,
            name: r.name,
            availableQty: `${r.available_qty} ${r.unit}`,
            thresholdQty: `${r.safety_stock_qty} ${r.unit}`,
            shortfall: isBelow ? `${short} ${r.unit}` : '—',
            isBelow,
        }
    })

    return (
        <ListPage
            title={t('reports.safety.title')}
            intro={t('reports.safety.desc')}
            actions={
                <div className="flex gap-2">
                    <Button asChild variant="outline" size="sm">
                        <a href="/inventory/reports/safety/export">{t('reports.csv')}</a>
                    </Button>
                    <Button asChild variant="outline" size="sm">
                        <a href="/inventory/reports/safety/pdf" target="_blank" rel="noopener noreferrer">{t('reports.pdf')}</a>
                    </Button>
                </div>
            }
            // 【不是"一切正常"】—— 没有人设过任何阈值
            state={monitored === 0 ? { kind: 'empty', noRows: t('reports.safety.noneMonitored') } : { kind: 'ok' }}
        >
            <p className="text-sm mb-6">
                {below === 0
                    ? t('reports.safety.allAbove', { n: String(monitored) })
                    : t('reports.safety.someBelow', { below: String(below), n: String(monitored) })}
            </p>
            <SafetyTable rows={tableRows} />
        </ListPage>
    )
}
