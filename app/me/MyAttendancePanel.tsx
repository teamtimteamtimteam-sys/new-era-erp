'use client'

// app/me/MyAttendancePanel.tsx
// ATTEND-1:自助那一半 —— 【只读】。
//
// 【为什么这里没有任何输入框】这张底稿是【公司报给薪资服务商的东西】,不是
// 一份自报工时。record_attendance 要 module.hr.edit,而员工在这里能看见自己
// 那一行,靠的是行级策略(employee_id = current_user_employee())。
// 让人看见自己被报了什么,是这块面板存在的全部理由 —— 报错了才有人说得出口。
import { useTranslations } from '@/lib/i18n/client'

type Row = {
    code: string; periodMonth: string; status: string
    normal: number; restDay: number; holiday: number
    note: string | null; recorded: boolean; unpaidDays: number | null
}

export default function MyAttendancePanel({ rows }: { rows: Row[] }) {
    const t = useTranslations()

    return (
        <section className="mb-8">
            <h2 className="text-lg font-semibold mb-1">{t('attendance.myTitle')}</h2>
            <p className="text-xs text-gray-500 mb-3">{t('attendance.myHint')}</p>
            {rows.length === 0 ? (
                <p className="text-sm text-gray-500">{t('attendance.myEmpty')}</p>
            ) : (
                <table className="w-full text-sm border-collapse">
                    <thead>
                        <tr className="border-b text-left text-gray-600">
                            <th className="py-2 pr-3">{t('attendance.colCode')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colOtNormal')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colOtRestDay')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colOtHoliday')}</th>
                            <th className="py-2 pr-3 text-right">{t('attendance.colUnpaidDays')}</th>
                            <th className="py-2 pr-3">{t('attendance.colRecorded')}</th>
                        </tr>
                    </thead>
                    <tbody>
                        {rows.map((r) => (
                            <tr key={r.code} className="border-b">
                                <td className="py-2 pr-3">{r.code}</td>
                                <td className="py-2 pr-3 text-right">{r.normal}</td>
                                <td className="py-2 pr-3 text-right">{r.restDay}</td>
                                <td className="py-2 pr-3 text-right">{r.holiday}</td>
                                <td className="py-2 pr-3 text-right">{r.unpaidDays === null ? '—' : r.unpaidDays}</td>
                                <td className="py-2 pr-3 text-xs">
                                    {r.recorded ? (
                                        <span className="text-green-700">{t('attendance.recordedYes')}</span>
                                    ) : (
                                        <span className="text-amber-700">{t('attendance.recordedNo')}</span>
                                    )}
                                </td>
                            </tr>
                        ))}
                    </tbody>
                </table>
            )}
        </section>
    )
}
