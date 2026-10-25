'use client'

// app/inventory/locations/LocationsTable.tsx
// CONV-5 · 库位主数据那张表。
// 【停用行整行发灰】走 CONV-4 建的 rowClassName,不再逐个 <td> 重复 class。

import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { xText, xBool } from '@/lib/export/cells'
import LocationActiveToggle from './LocationActiveToggle'

export type LocationRow = {
    id: string
    code: string
    name: string
    zone: string
    isActive: boolean
    /** MES-3a(Q17):隔离库位 */
    isQuarantine: boolean
    /** 【未配置 ≠ 无】零行的意思是还没有人决定过,服务端已经判好。 */
    unconfigured: boolean
    allowedLabels: string[]
}

export default function LocationsTable({ rows, empty }: { rows: LocationRow[]; empty: React.ReactNode }) {
    const t = useTranslations()

    // ★ 手机上留【库位号】与【可存放分类】—— 库位号是身份;而可存放分类是
    //   这张表存在的理由,页顶那句 recordsOnlyNotice 整段就是在说它。
    //   把它挤进展开区,等于让那句提醒在小屏上失去它指的东西。
    const columns: ExportableColumn<LocationRow>[] = [
        {
            key: 'code', header: t('locations.colCode'), priority: true, exportAs: (r) => xText(r.code),
            render: (r) => (
                <Link href={`/inventory/locations/${r.id}/edit`} className="hover:underline app-link">
                    {r.code}
                </Link>
            ),
        },
        { key: 'name', header: t('locations.colName'), render: (r) => r.name, exportAs: (r) => xText(r.name) },
        // zone 只是显示分组;没填就是没填
        { key: 'zone', header: t('locations.colZone'), render: (r) => r.zone, exportAs: (r) => xText(r.zone) },
        // MES-3a(Q17):隔离库位 —— 鼓包或漏液的料只能收进 / 移进这种库位
        { key: 'quarantine', header: t('locations.colQuarantine'),
          exportAs: (r) => xBool(r.isQuarantine, t('locations.quarantineYes'), '—'),
          render: (r) => (r.isQuarantine ? <span data-quarantine="1">{t('locations.quarantineYes')}</span> : '—') },
        {
            key: 'allowed', header: t('locations.colAllowed'), priority: true,
            // 【未配置】在导出里同样是那句话,不是空格
            exportAs: (r) => xText(r.unconfigured ? t('locations.notConfigured') : r.allowedLabels.join(', ')),
            render: (r) =>
                r.unconfigured ? (
                    // 【未配置,不是"无"、也不是空白】零行的意思是还没有人决定过 ——
                    // 将来的检查对它告警而绝不拒绝。画成空白或者「无」,
                    // 就是把"没人想过"演成"想过、结论是没有"。
                    <span
                        className="px-2 py-0.5 rounded text-xs bg-amber-100 text-amber-800"
                        title={t('locations.notConfiguredTitle')}
                    >
                        {t('locations.notConfigured')}
                    </span>
                ) : (
                    <span className="flex flex-wrap gap-1">
                        {r.allowedLabels.map((c) => (
                            <span key={c} className="px-2 py-0.5 rounded text-xs bg-gray-200 text-gray-700">
                                {c}
                            </span>
                        ))}
                    </span>
                ),
        },
        {
            key: 'status', header: t('locations.colStatus'),
            exportAs: (r) => xBool(r.isActive, t('locations.active'), t('locations.inactive')),
            render: (r) => (
                <span className={'px-2 py-0.5 rounded text-xs ' + (r.isActive ? 'bg-green-100 text-green-800' : 'bg-gray-200 text-gray-600')}>
                    {r.isActive ? t('locations.active') : t('locations.inactive')}
                </span>
            ),
        },
        {
            key: 'actions', header: t('locations.colActions'), exportAs: false,
            render: (r) => <LocationActiveToggle id={r.id} isActive={r.isActive} />,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            exportSpec={{ name: 'storage-locations', title: t('locations.listTitle') }}
            // TABLE-FEATURES-1 Q9:全部库位一次读完,在浏览器里排
            sorting={{ mode: 'client', coverage: 'complete' }}
            rowClassName={(r) => (r.isActive ? undefined : 'bg-gray-50 text-gray-500')}
        />
    )
}
