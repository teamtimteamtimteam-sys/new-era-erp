// app/operation/orders/page.tsx
// WO-1c:工单列表 —— 计划这一侧的入口。
//
// CONV-5:套 CONV-1 的两文件模板。state 恒为 'ok' —— WoThresholdPanel 与
// 「计划外的加工不是这一页的事」那段说明都要在空态下照画,它们走 notices。
//
// 【完成度是【读】出来的,不是存下来的】那一列取自 work_order_fulfilment 的投入侧
// (已耗 ÷ 计划,按物料汇总),而不是工单上的某一列 —— 工单表里刻意没有
// "in_progress" 或 "完成度" 这种字段(见 db/tables/work_orders.sql 的列注释:
// 存一份就等于给同一件事留了第二处实现,而那两处会漂开)。
//
// 【计划外的加工不是这一页的事】work_order_id 为空的加工单属于【加工单列表】,
// 而不是这里的一行"没有计划的工单" —— 它们是一个具名的类别,不是这张表的缺席。
import { Button } from '@/app/components/ui/button'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustOne } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { workOrderStatusKey } from './woTypes'
import WoThresholdPanel from './WoThresholdPanel'
import { ListPage } from '@/app/components/ui/list-page'
import WorkOrdersTable, { type WorkOrderRow } from './WorkOrdersTable'

export default async function WorkOrdersPage() {
    // OPS-15:进不去的页面要【说出来】,不能渲染成空的。放在任何查询之前。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const dl = locale === 'zh' ? 'zh-CN' : 'en-US'
    const supabase = await createClient()

    const orders = mustRows(
        await supabase.from('work_orders')
            .select('id, code, status, scheduled_date, notes, created_at')
            .order('created_at', { ascending: false }),
        'work_orders') as {
            id: string; code: string; status: string
            scheduled_date: string | null; notes: string | null; created_at: string }[]

    // 【完成度按物料读,再在这里汇总成一个百分比】视图给的是每种物料一行;
    // 列表要的是一个可扫的数,所以在这里加总 —— 而【加总的是视图的数】,
    // 不是重新算一遍(AGENTS.md:一处推导,N 个消费者)。
    const rows = orders.length === 0 ? [] : mustRows(
        await supabase.from('work_order_fulfilment')
            .select('work_order_id, side, planned_or_expected_qty, actual_qty, has_plan')
            .eq('side', 'input'),
        'work_order_fulfilment') as {
            work_order_id: string; side: string
            planned_or_expected_qty: number | null; actual_qty: number; has_plan: boolean }[]

    const progress = new Map<string, { planned: number; consumed: number; unplannedMaterials: number }>()
    for (const r of rows) {
        const cur = progress.get(r.work_order_id) ?? { planned: 0, consumed: 0, unplannedMaterials: 0 }
        // 【没有计划行的那些不进分母】它们是"吃了没人计划过的料",算进分母会把
        // 完成度稀释成一个没人能解释的数;它们单独计数,由详情页逐行说清楚。
        if (r.has_plan) cur.planned += Number(r.planned_or_expected_qty ?? 0)
        else cur.unplannedMaterials += 1
        cur.consumed += Number(r.actual_qty ?? 0)
        progress.set(r.work_order_id, cur)
    }

    const canEdit = await can('module.processing.edit')

    // EXEC-3b:两个阈值 —— 看板那两块牌子现读它们,所以改它们的人就是看这块屏的人。
    const settings = mustOne(
        await supabase.from('processing_settings')
            .select('wo_input_overrun_pct, wo_output_shortfall_pct').maybeSingle(),
        'processing_settings') as
        { wo_input_overrun_pct: number; wo_output_shortfall_pct: number } | null

    const tableRows: WorkOrderRow[] = orders.map((o) => {
        const p = progress.get(o.id)
        return {
            id: o.id,
            code: o.code,
            statusLabel: t(workOrderStatusKey(o.status)),
            // 日期按 locale 格式化在服务端做完 —— dl 不过 RSC 边界
            scheduledLabel: o.scheduled_date ? new Date(o.scheduled_date).toLocaleDateString(dl) : null,
            progressLabel: !p || p.planned === 0 ? null : `${p.consumed} / ${p.planned}`,
            unplannedMaterials: p?.unplannedMaterials ?? 0,
            notes: o.notes ?? '—',
        }
    })

    return (
        <ListPage
            title={t('processing.wo.listTitle')}
            intro={t('processing.wo.listNote')}
            actions={
                canEdit ? (
                    <Button asChild>
                        <Link href="/operation/orders/new">{t('processing.wo.addButton')}</Link>
                    </Button>
                ) : undefined
            }
            notices={
                /* EXEC-3b:差异阈值面板。人人看得见(看板上那盏灯亮不亮就取决于它),
                   持 module.processing.edit 的人改得动。它是一个【设置】,
                   一行工单都没有的时候照样要能改 —— 所以它在状态分支之前。 */
                settings ? (
                    <WoThresholdPanel
                        inputPct={Number(settings.wo_input_overrun_pct)}
                        outputPct={Number(settings.wo_output_shortfall_pct)}
                        canEdit={canEdit} />
                ) : undefined
            }
            state={{ kind: 'ok' }}
        >
            <WorkOrdersTable rows={tableRows} empty={t('processing.wo.empty')} />
        </ListPage>
    )
}
