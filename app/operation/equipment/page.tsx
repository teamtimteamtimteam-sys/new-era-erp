// app/operation/equipment/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1(Tim 的 Q10 · Q22)· 设备清单 —— 加工的人读得到的那一份,只读
// ════════════════════════════════════════════════════════════════════════════
// 【为什么有它】一台机器唯一的页面原来是 /finance/assets/[id](财务的门),而保养与停机是加工的事;
//   持加工权限、不持财务权限的人(仓库)连"今天哪台机器到期要保养"那条提醒都点不进去。
// 【读的是什么】equipment_usage —— 属主权限视图,门就是 module.finance.view 或 module.processing.view,
//   只给编号、说明、状态、日期与加工量;【没有】成本、折旧、类别(那几样只在财务)。
//   它列出账上每一张资产卡(视图没有类别这一列可筛;这一页不去读 fixed_assets 本身,那是财务的表)。
// 【门】requireModule(MOD.processing) —— 与 /operation 下每一页同一道门。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { formatDate } from '@/lib/dates'
import CellsTable, { type CellRow } from './CellsTable'

const KG = new Intl.NumberFormat('en-US', { maximumFractionDigits: 2 })

export default async function EquipmentListPage() {
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const rows = mustRows(
        await supabase.from('equipment_usage')
            .select('equipment_id, equipment_code, equipment_description, equipment_status, run_count, input_kg, last_run_date')
            .order('equipment_code'),
        'equipment_usage') as {
            equipment_id: string; equipment_code: string; equipment_description: string | null; equipment_status: string
            run_count: number; input_kg: number; last_run_date: string | null }[]

    const tableRows: CellRow[] = rows.map((r) => ({
        id: r.equipment_id,
        cells: {
            code: <Link href={`/operation/equipment/${r.equipment_id}`} className="app-link hover:underline">{r.equipment_code}</Link>,
            description: r.equipment_description ?? '—',
            // 动态前缀 assets.status.,后缀集合接 fixed_assets 的 CHECK(check-i18n 的清单里已经登记)
            status: t('assets.status.' + r.equipment_status),
            runs: String(r.run_count),
            processed: `${KG.format(Number(r.input_kg))} kg`,
            lastRun: r.last_run_date ? formatDate(r.last_run_date, locale) : '—',
        },
    }))

    return (
        <ListPage title={t('equipment.page.listTitle')} intro={t('equipment.page.listIntro')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}>
            <CellsTable
                columns={[
                    { key: 'code', header: t('equipment.page.colCode'), priority: true },
                    { key: 'description', header: t('equipment.page.colDescription'), priority: true },
                    { key: 'status', header: t('equipment.page.colStatus') },
                    { key: 'runs', header: t('equipment.page.colRuns'), align: 'right' },
                    { key: 'processed', header: t('equipment.page.colProcessed'), align: 'right' },
                    { key: 'lastRun', header: t('equipment.page.colLastRun') },
                ]}
                rows={tableRows}
                empty={t('equipment.page.empty')}
            />
        </ListPage>
    )
}
