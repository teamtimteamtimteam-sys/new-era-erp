'use client'

// app/hr/leave/holidays/HolidaysTable.tsx
// CONV-3 · 公共假期登记簿的那张表。见 docs/list-page-template.md 的 Kind-E 一节。
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

export type HolidayRow = {
    id: string
    holiday_date: string
    name_en: string
    name_zh: string
    is_active: boolean
    notes: string | null
}

export default function HolidaysTable({
    rows, year, pending, onDelete,
}: {
    rows: HolidayRow[]
    year: number
    pending: boolean
    onDelete: (id: string) => void
}) {
    const t = useTranslations()
    const locale = useLocale()

    // ★【手机上留哪两列】日期与名称是身份 —— 没有它们,下面那一行是哪一天、
    // 叫什么都不知道。备注是读到那一天才要问的东西,进展开区。
    const columns: Column<HolidayRow>[] = [
        { key: 'date', header: t('leave.date'), priority: true, className: 'font-mono', render: (r) => r.holiday_date },
        {
            key: 'name', header: t('leave.holidayName'), priority: true,
            render: (r) => (locale === 'zh' ? r.name_zh : r.name_en),
        },
        {
            key: 'notes', header: t('leave.notes'),
            render: (r) => r.notes ?? <span className="text-[color:var(--brand-muted-text)]">—</span>,
        },
        {
            key: 'actions', header: '',
            render: (r) => (
                <button
                    type="button"
                    disabled={pending}
                    onClick={() => onDelete(r.id)}
                    className="text-xs text-red-700 hover:underline disabled:opacity-50"
                >
                    {t('common.delete')}
                </button>
            ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            // ★【空态走 DataTable 自己的 empty,不走 ListPage 的 empty 分支】
            //   下面那张「新增假期」的表单是这一页【唯一】能加第一行的地方,
            //   而它住在 children 里。ListPage 的 empty 分支只画 RefusalBlock、
            //   不画 children —— 用它会把这张表单一起藏起来。
            //   CONV-2 §⑥ 第 3 条撞过同一个缺陷,这里照那条判据走。
            empty={t('leave.noHolidays', { 0: String(year) })}
        />
    )
}
