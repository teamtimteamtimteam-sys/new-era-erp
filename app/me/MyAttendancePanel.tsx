'use client'

// app/me/MyAttendancePanel.tsx
// ATTEND-1:自助那一半 —— 【只读】。
//
// 【为什么这里没有任何输入框】这张底稿是【公司报给薪资服务商的东西】,不是
// 一份自报工时。record_attendance 要 module.hr.edit,而员工在这里能看见自己
// 那一行,靠的是行级策略(employee_id = current_user_employee())。
// 让人看见自己被报了什么,是这块面板存在的全部理由 —— 报错了才有人说得出口。
//
// ★ TABLE-CONVERT-1(2026-09-10):手搓表格 → 组件。
//   【手机上留哪几列一个字没改】TABLE-PHONE-3 当时留的是:编号 · 平日加班 · 录入,
//   折起来的是:休息日加班 · 假日加班 · 无薪天数。转换把「留」写成 priority,
//   把「折」写成不带 priority —— **同一个判断,换了一种说法**。
//   叠在「编号」格里那一段手写的展开块【拿掉了】:组件自己画那一段,
//   留着就是同一个事实在同一行里画两遍。
//   ★ 「录入」那一列的 text-xs 也拿掉了 —— 列定义不许钉字号(Tim 的验收条件),
//     字号由 variant C 给。
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

type Row = {
    code: string; periodMonth: string; status: string
    normal: number; restDay: number; holiday: number
    note: string | null; recorded: boolean; unpaidDays: number | null
}

export default function MyAttendancePanel({ rows }: { rows: Row[] }) {
    const t = useTranslations()

    // ★ 手机上留三列:身份(编号)+ 那个要紧的数(平日加班)+ 状态(录入没录入)。
    //   R-Q4 的只读版判断,与转换之前逐列相同。
    const columns: Column<Row>[] = [
        { key: 'code', header: t('attendance.colCode'), priority: true, render: (r) => r.code },
        {
            key: 'otNormal', header: t('attendance.colOtNormal'), align: 'right', priority: true,
            render: (r) => r.normal,
        },
        {
            key: 'otRestDay', header: t('attendance.colOtRestDay'), align: 'right',
            render: (r) => r.restDay,
        },
        {
            key: 'otHoliday', header: t('attendance.colOtHoliday'), align: 'right',
            render: (r) => r.holiday,
        },
        {
            key: 'unpaidDays', header: t('attendance.colUnpaidDays'), align: 'right',
            render: (r) => (r.unpaidDays === null ? '—' : r.unpaidDays),
        },
        {
            key: 'recorded', header: t('attendance.colRecorded'), priority: true,
            render: (r) =>
                r.recorded ? (
                    <span className="text-green-700">{t('attendance.recordedYes')}</span>
                ) : (
                    <span className="text-amber-700">{t('attendance.recordedNo')}</span>
                ),
        },
    ]

    return (
        <section className="mb-8">
            <h2 className="mb-1">{t('attendance.myTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3">{t('attendance.myHint')}</p>
            <DataTable
                rows={rows}
                columns={columns}
                rowKey={(r) => r.code}
                phone={{ mode: 'columns' }}
                empty={t('attendance.myEmpty')}
            />
        </section>
    )
}
