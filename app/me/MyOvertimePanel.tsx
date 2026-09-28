'use client'

// app/me/MyOvertimePanel.tsx
// OVERTIME-1(Tim Q14):现场员工在 /me 上看见自己【已批准】的加班 —— 只读。
//
// 【数据从哪来】my_overtime_lines():属主权限,只给调用者自己的、已批准且没被冲销的行;
//   批的人显示成人(附加账号显示它主人的名字)。还在录、在等、被驳回的都不在这里 ——
//   那些是还没定下来的数,员工看见它们只会以为这就是要付的小时。
// 【小时,不是钱】OS 只报小时;乘以多少归薪资服务商(政策 7.1)。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

type Row = {
    id: string; workDate: string; hours: number; dayKind: string; note: string | null
    batchLabel: string; approvedLabel: string; approver: string | null
}

export default function MyOvertimePanel({ rows }: { rows: Row[] }) {
    const t = useTranslations()
    const columns: Column<Row>[] = [
        { key: 'date', header: t('overtime.colDate'), priority: true, render: (r) => r.workDate },
        { key: 'dayKind', header: t('overtime.colDayKind'), render: (r) => t('overtime.dayKind_' + r.dayKind) },
        { key: 'hours', header: t('overtime.colHours'), align: 'right', priority: true, render: (r) => r.hours.toFixed(2) },
        { key: 'note', header: t('overtime.colNote'), render: (r) => <span className="text-gray-600">{r.note ?? '—'}</span> },
        {
            key: 'approved', header: t('overtime.colApproved'),
            render: (r) => (
                <>
                    <span className="block">{t('overtime.approvedBy', { name: r.approver ?? t('me.deciderUnknown') })}</span>
                    <span className="block text-xs text-[color:var(--brand-muted-text)]">{r.approvedLabel} · {r.batchLabel}</span>
                </>
            ),
        },
    ]

    return (
        <section id="overtime" className="mb-8 scroll-mt-20">
            <h2 className="mb-1">{t('overtime.myTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('overtime.myHint')}</p>
            <DataTable
                rows={rows}
                columns={columns}
                rowKey={(r) => r.id}
                phone={{ mode: 'columns' }}
                empty={t('overtime.myEmpty')}
            />
        </section>
    )
}
