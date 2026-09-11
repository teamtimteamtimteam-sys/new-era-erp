'use client'

// app/hr/leave/holidays/HolidaysTable.tsx
// CONV-3 · 公共假期登记簿的那张表。见 docs/list-page-template.md 的 Kind-E 一节。
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'

export type HolidayRow = {
    id: string
    holiday_date: string
    name_en: string
    name_zh: string
    /** C-2:跨年份稳定的身份 —— 日期会动,这个不动。UI-1 的节日 logo 读它。 */
    holiday_key: string
    is_in_lieu: boolean
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
            render: (r) => (
                <>
                    {locale === 'zh' ? r.name_zh : r.name_en}
                    {/* ★ 补假要看得出来:它与被补的那天共用 holiday_key,
                        所以只看键分不出哪一行是补的 */}
                    {r.is_in_lieu && (
                        <span className="ml-1 text-[10px] text-[color:var(--brand-muted-text)]">
                            {t('leave.inLieuTag')}
                        </span>
                    )}
                </>
            ),
        },
        {
            key: 'holidayKey', header: t('leave.holidayKey'), className: 'font-mono text-xs',
            render: (r) => r.holiday_key,
        },
        {
            key: 'notes', header: t('leave.notes'),
            render: (r) => r.notes ?? <span className="text-[color:var(--brand-muted-text)]">—</span>,
        },
        {
            key: 'actions', header: '',
            // ★★ ALERT-2a:这一处【此前没有任何确认步骤,而它是一次硬删除】★★
            //   `deleteHoliday` → `app/hr/leave/types/actions.ts:59` →
            //   `public_holidays` 走 `.delete()`,行没了、没人记、恢复不了。
            //   而这张表是【承重】的:`calculate_leave_days` 与 `fx_rate_asof`
            //   都读它(见 AGENTS.md 的「public_holidays is load-bearing for two
            //   modules」),删错一天会安静地改掉请假天数与汇率回溯的边界。
            //   ☞ 动作一个字没改:同一个 `onDelete(r.id)`。
            render: (r) => (
                <ConfirmButton
                    subject={locale === 'zh' ? r.name_zh : r.name_en}
                    title={t('leave.holidayDeleteTitle')}
                    body={t('common.hardDeleteNote')}
                    details={
                        <p className="text-sm font-medium text-[color:var(--brand-text)]">
                            {t('leave.holidayDeleteConsequence')}
                        </p>
                    }
                    confirmLabel={t('common.delete')}
                    tier="destructive"
                    disabled={pending}
                    triggerVariant="destructive"
                    triggerSize="inline"
                    className="text-xs"
                    onConfirm={() => onDelete(r.id)}
                >
                    {t('common.delete')}
                </ConfirmButton>
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
