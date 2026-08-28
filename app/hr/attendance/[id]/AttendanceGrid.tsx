'use client'

// app/hr/attendance/[id]/AttendanceGrid.tsx
// ATTEND-1:一个月的每人一行。
//
// ★【这张表最重要的一列是"记了没有",而不是任何一个数字】★
// 三个 0 是一句真话("这个月他没有加班"),空白是另一句("没人看过这一行")。
// 界面必须让两者看起来【不一样】—— 否则库里分得清也没用。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { recordAttendance, completeAttendancePeriod, reopenAttendancePeriod, syncAttendancePeriod } from '../actions'

type Row = {
    lineId: string; employeeCode: string; legalName: string
    normal: number; restDay: number; holiday: number
    note: string; recorded: boolean; unpaidDays: number | null
}

export default function AttendanceGrid({
    periodId, status, rows,
}: { periodId: string; status: string; rows: Row[] }) {
    const t = useTranslations()
    const router = useRouter()
    const [error, setError] = useState<string | null>(null)
    const [notice, setNotice] = useState<string | null>(null)
    const [reason, setReason] = useState('')
    const [pending, startTransition] = useTransition()
    const open = status === 'open'
    const unrecorded = rows.filter((r) => !r.recorded).length

    const run = (fn: () => Promise<{ error?: string; note?: string }>) =>
        startTransition(async () => {
            setError(null); setNotice(null)
            const res = await fn()
            if (res.error) setError(res.error)
            // 拒绝顺手把缺口补出来了 —— 说出来,否则刷新出来的新行像是凭空冒出来的
            if (res.note) setNotice(t('attendance.rosterSynced', { count: res.note }))
            router.refresh()
        })

    return (
        <>
            {error && <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>}
            {notice && <div className="mb-3 rounded border border-blue-300 bg-blue-50 px-3 py-2 text-sm text-blue-800">{notice}</div>}

            <table className="w-full text-sm border-collapse mb-4">
                <thead>
                    <tr className="border-b text-left text-gray-600">
                        <th className="py-2 pr-3">{t('attendance.colEmployee')}</th>
                        <th className="py-2 pr-3 text-right">{t('attendance.colOtNormal')}</th>
                        <th className="py-2 pr-3 text-right">{t('attendance.colOtRestDay')}</th>
                        <th className="py-2 pr-3 text-right">{t('attendance.colOtHoliday')}</th>
                        <th className="py-2 pr-3">{t('attendance.colNote')}</th>
                        <th className="py-2 pr-3 text-right">{t('attendance.colUnpaidDays')}</th>
                        <th className="py-2 pr-3">{t('attendance.colRecorded')}</th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <LineRow key={r.lineId} row={r} open={open} disabled={pending} onSaved={run} />
                    ))}
                </tbody>
            </table>

            {open ? (
                <div className="flex items-center gap-3">
                    <button
                        type="button"
                        disabled={pending}
                        onClick={() => run(() => completeAttendancePeriod(periodId))}
                        className="rounded bg-gray-900 px-3 py-1.5 text-sm text-white disabled:opacity-40"
                    >
                        {t('attendance.completeBtn')}
                    </button>
                    <button
                        type="button"
                        disabled={pending}
                        onClick={() => run(async () => {
                            const res = await syncAttendancePeriod(periodId)
                            return res.added ? { note: String(res.added) } : {}
                        })}
                        className="rounded border px-3 py-1.5 text-sm disabled:opacity-40"
                    >
                        {t('attendance.syncBtn')}
                    </button>
                    <p className="text-xs text-gray-500">
                        {unrecorded > 0
                            ? t('attendance.completeBlocked', { count: String(unrecorded) })
                            : t('attendance.completeHint')}
                    </p>
                </div>
            ) : (
                <div className="flex items-end gap-3">
                    <label className="text-sm flex-1 max-w-md">
                        <span className="block text-gray-600 mb-1">{t('attendance.reopenReason')}</span>
                        <input
                            value={reason}
                            onChange={(e) => setReason(e.target.value)}
                            className="w-full rounded border px-2 py-1"
                        />
                    </label>
                    <button
                        type="button"
                        disabled={pending || reason.trim() === ''}
                        onClick={() => run(() => reopenAttendancePeriod(periodId, reason))}
                        className="rounded border px-3 py-1.5 text-sm disabled:opacity-40"
                    >
                        {t('attendance.reopenBtn')}
                    </button>
                </div>
            )}
        </>
    )
}

function LineRow({
    row, open, disabled, onSaved,
}: {
    row: Row; open: boolean; disabled: boolean
    onSaved: (fn: () => Promise<{ error?: string; note?: string }>) => void
}) {
    const t = useTranslations()
    const [normal, setNormal] = useState(String(row.normal))
    const [restDay, setRestDay] = useState(String(row.restDay))
    const [holiday, setHoliday] = useState(String(row.holiday))
    const [note, setNote] = useState(row.note)

    const num = (v: string) => (v.trim() === '' ? 0 : Number(v))
    const cell = 'w-20 rounded border px-2 py-1 text-right'

    return (
        <tr className={'border-b ' + (row.recorded ? '' : 'bg-amber-50')}>
            <td className="py-2 pr-3">
                <div>{row.legalName}</div>
                <div className="text-xs text-gray-500">{row.employeeCode}</div>
            </td>
            <td className="py-2 pr-3 text-right">
                {open ? <input className={cell} value={normal} onChange={(e) => setNormal(e.target.value)} /> : row.normal}
            </td>
            <td className="py-2 pr-3 text-right">
                {open ? <input className={cell} value={restDay} onChange={(e) => setRestDay(e.target.value)} /> : row.restDay}
            </td>
            <td className="py-2 pr-3 text-right">
                {open ? <input className={cell} value={holiday} onChange={(e) => setHoliday(e.target.value)} /> : row.holiday}
            </td>
            <td className="py-2 pr-3">
                {open ? (
                    <input className="w-full rounded border px-2 py-1" value={note} onChange={(e) => setNote(e.target.value)} />
                ) : (
                    <span className="text-gray-600">{row.note || '—'}</span>
                )}
            </td>
            <td className="py-2 pr-3 text-right text-gray-600">
                {row.unpaidDays === null ? '—' : row.unpaidDays}
            </td>
            <td className="py-2 pr-3">
                {/* ★ 空白与三个 0 必须看起来不一样 ★ */}
                {row.recorded ? (
                    <span className="text-xs text-green-700">{t('attendance.recordedYes')}</span>
                ) : (
                    <span className="text-xs text-amber-700 font-medium">{t('attendance.recordedNo')}</span>
                )}
                {open && (
                    <button
                        type="button"
                        disabled={disabled}
                        onClick={() => onSaved(() => recordAttendance(row.lineId, num(normal), num(restDay), num(holiday), note.trim() || null))}
                        className="ml-2 rounded border px-2 py-0.5 text-xs disabled:opacity-40"
                    >
                        {t('attendance.saveLine')}
                    </button>
                )}
            </td>
        </tr>
    )
}
