// app/operation/equipment/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// AUDIT-TRAIL-1b-1(Tim 的 Q10 · Q22)· 设备清单 —— 加工的人读得到的那一份,只读
// ════════════════════════════════════════════════════════════════════════════
// 【为什么有它】一台机器唯一的页面原来是 /finance/assets/[id](财务的门),而保养与停机是加工的事;
//   持加工权限、不持财务权限的人(仓库)连"今天哪台机器到期要保养"那条提醒都点不进去。
// 【读的是什么】equipment_usage —— 属主权限视图,门就是 module.finance.view 或 module.processing.view,
//   只给编号、说明、状态、日期、加工量与类别;【没有】成本、折旧(那几样只在财务)。
//   ★ MES-7a-1 更正(MES-7a Step 0 Q7):原文"它列出账上每一张资产卡(视图没有类别这一列可筛)"自 MES-4a 起已不成立 ——
//     equipment_usage.equipment_category 在(一个不带金额的列);这一页从此【只列设备类】(车、办公电脑不是机器),
//     关掉 known-issues AT1B-EQUIPMENT-LIST-EVERY-ASSET。
//   ★ MES-7a-1(Q7):多一栏「有没有在盯」—— 现读 equipment_service_status.monitored(任何一条间隔在监控 = 在盯),不另算一份;
//     关掉 known-issues「全库没有一处看得见哪些机器没人在盯」。上面一个链接去可靠性那张表(MTBF / MTTR)。
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
import { xText, xInt, xNum, xDate } from '@/lib/export/cells'

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
            .eq('equipment_category', 'equipment')
            .order('equipment_code'),
        'equipment_usage') as {
            equipment_id: string; equipment_code: string; equipment_description: string | null; equipment_status: string
            run_count: number; input_kg: number; last_run_date: string | null }[]

    // 有没有在盯:一台机器在 equipment_service_status 里至少一行(没有间隔时也有一行,monitored = false)
    const monitoredRes = mustRows(
        await supabase.from('equipment_service_status').select('equipment_id, monitored'),
        'equipment_service_status') as { equipment_id: string; monitored: boolean }[]
    const monitored = new Set(monitoredRes.filter((m) => m.monitored).map((m) => m.equipment_id))

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
            monitored: monitored.has(r.equipment_id)
                ? <span data-monitored="yes">{t('equipment.page.monitoredYes')}</span>
                : <span className="rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-700" data-monitored="no">{t('equipment.intervals.notMonitored')}</span>,
        },
        // TABLE-EXPORT-1:导出读【原始值】—— 次数是整数、加工量是公斤数、最后一次是真日期;「—」是没有值,导出成空格;「没在盯」照屏幕写成那句话
        exports: {
            code: xText(r.equipment_code),
            description: xText(r.equipment_description),
            status: xText(t('assets.status.' + r.equipment_status)),
            runs: xInt(r.run_count),
            processed: xNum(r.input_kg, 'qty', t('units.kg')), // TABLE-EXPORT-1:屏幕上是「1,234 kg」,单位一起写
            lastRun: xDate(r.last_run_date),
            monitored: xText(monitored.has(r.equipment_id) ? t('equipment.page.monitoredYes') : t('equipment.intervals.notMonitored')),
        },
    }))

    return (
        <ListPage title={t('equipment.page.listTitle')} intro={t('equipment.page.listIntro')} maxWidth="max-w-5xl" state={{ kind: 'ok' }}
            actions={<Link href="/operation/equipment/reliability" className="app-link hover:underline text-sm">{t('equipment.rel.pageTitle')}</Link>}>
            <CellsTable
                columns={[
                    { key: 'code', header: t('equipment.page.colCode'), priority: true },
                    { key: 'description', header: t('equipment.page.colDescription'), priority: true },
                    { key: 'status', header: t('equipment.page.colStatus') },
                    { key: 'runs', header: t('equipment.page.colRuns'), align: 'right' },
                    { key: 'processed', header: t('equipment.page.colProcessed'), align: 'right' },
                    { key: 'lastRun', header: t('equipment.page.colLastRun') },
                    { key: 'monitored', header: t('equipment.page.colMonitored'), priority: true },
                ]}
                rows={tableRows}
                empty={t('equipment.page.empty')}
                exportSpec={{ name: 'operation-equipment', title: t('equipment.page.listTitle') }}
                // TABLE-FEATURES-1 Q9:一次读取拿到全体 —— 在浏览器里排
                sorting="client"
            />
        </ListPage>
    )
}
