'use client'

// app/operation/handovers/HandoversTable.tsx
// CONV-5 · 交接班那张表。
// ★ 未签收的整行发琥珀,走 CONV-4 建的 rowClassName —— 这一页的抬头写着
//   「未签收的必须一眼看得出来」,整行底色就是那个"一眼"。

import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import AcknowledgeButton from './AcknowledgeButton'

export type HandoverRow = {
    id: string
    handoverDate: string
    shiftLabel: string
    fromName: string
    toName: string
    acknowledged: boolean
    /** 已签收时:签收人 + 时刻,已在服务端按本地格式拼好。 */
    acknowledgedLabel: string | null
}

export default function HandoversTable({
    rows, empty, canEdit,
}: { rows: HandoverRow[]; empty: React.ReactNode; canEdit: boolean }) {
    const t = useTranslations()

    // ★ 手机上留【日期】与【签收】—— 日期是身份,而签收状态是这一页存在的理由
    //   (抬头第一句:未签收的必须一眼看得出来)。交接双方进展开区。
    const columns: Column<HandoverRow>[] = [
        { key: 'date', header: t('processing.handover.colDate'), priority: true, render: (r) => r.handoverDate },
        { key: 'shift', header: t('processing.handover.colShift'), render: (r) => r.shiftLabel },
        { key: 'from', header: t('processing.handover.colFrom'), render: (r) => r.fromName },
        { key: 'to', header: t('processing.handover.colTo'), render: (r) => r.toName },
        {
            // ★【未签收 vs 已签收:一个【具名的状态】,不是一个空格】★
            //   空格读起来像"这一栏不重要";而未签收的意思是
            //   【下一个班的人还没说他看过这些话】。
            key: 'ack', header: t('processing.handover.colAck'), priority: true,
            render: (r) =>
                r.acknowledged ? (
                    <span className="inline-block px-2 py-0.5 rounded bg-green-100 text-green-800 text-xs">
                        {r.acknowledgedLabel}
                    </span>
                ) : (
                    <span className="flex items-center gap-2">
                        <span className="inline-block px-2 py-0.5 rounded bg-amber-200 text-amber-900 text-xs font-medium">
                            {t('processing.handover.pending')}
                        </span>
                        {canEdit && <AcknowledgeButton handoverId={r.id} />}
                    </span>
                ),
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.id}
            phone={{ mode: 'columns' }}
            empty={empty}
            rowClassName={(r) => (r.acknowledged ? undefined : 'bg-amber-50')}
        />
    )
}
