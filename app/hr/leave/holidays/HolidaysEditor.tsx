'use client'

// app/hr/leave/holidays/HolidaysEditor.tsx
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { saveHoliday, deleteHoliday } from '../types/actions'

export type HolidayRow = {
    id: string
    holiday_date: string
    name_en: string
    name_zh: string
    is_active: boolean
    notes: string | null
}

export default function HolidaysEditor({ rows, year }: { rows: HolidayRow[]; year: number }) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [date, setDate] = useState(`${year}-01-01`)
    const [en, setEn] = useState('')
    const [zh, setZh] = useState('')
    const [notes, setNotes] = useState('')

    function add() {
        setError(null)
        startTransition(async () => {
            const r = await saveHoliday(null, {
                holiday_date: date, name_en: en, name_zh: zh, is_active: true, notes: notes || null,
            })
            if (r.error) setError(r.error)
            else { setEn(''); setZh(''); setNotes(''); router.refresh() }
        })
    }

    function remove(id: string) {
        setError(null)
        startTransition(async () => {
            const r = await deleteHoliday(id)
            if (r.error) setError(r.error)
            else router.refresh()
        })
    }

    const inp = 'border border-gray-300 rounded px-2 py-1 text-sm'

    return (
        <div>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <table className="w-full border-collapse text-sm mb-6">
                <thead>
                    <tr className="bg-gray-50 text-left">
                        <th className="border border-gray-300 px-2 py-1">{t('leave.date')}</th>
                        <th className="border border-gray-300 px-2 py-1">{t('leave.holidayName')}</th>
                        <th className="border border-gray-300 px-2 py-1">{t('leave.notes')}</th>
                        <th className="border border-gray-300 px-2 py-1"></th>
                    </tr>
                </thead>
                <tbody>
                    {rows.map((r) => (
                        <tr key={r.id}>
                            <td className="border border-gray-300 px-2 py-1 font-mono">{r.holiday_date}</td>
                            <td className="border border-gray-300 px-2 py-1">{locale === 'zh' ? r.name_zh : r.name_en}</td>
                            <td className="border border-gray-300 px-2 py-1 text-xs text-gray-500">{r.notes ?? '—'}</td>
                            <td className="border border-gray-300 px-2 py-1">
                                <button type="button" disabled={pending} onClick={() => remove(r.id)}
                                        className="text-red-700 hover:underline text-xs">{t('common.delete')}</button>
                            </td>
                        </tr>
                    ))}
                    {rows.length === 0 && (
                        <tr><td colSpan={4} className="border border-gray-300 px-2 py-3 text-gray-500">
                            {t('leave.noHolidays', { 0: String(year) })}
                        </td></tr>
                    )}
                </tbody>
            </table>

            <div className="rounded border border-gray-200 p-4">
                <h3 className="font-bold mb-3 text-sm">{t('leave.addHoliday')}</h3>
                <div className="flex gap-2 flex-wrap items-end">
                    <label className="text-xs">{t('leave.date')}
                        <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={`block ${inp}`} /></label>
                    <label className="text-xs">{t('permissions.nameEn')}
                        <input value={en} onChange={(e) => setEn(e.target.value)} className={`block ${inp}`} /></label>
                    <label className="text-xs">{t('permissions.nameZh')}
                        <input value={zh} onChange={(e) => setZh(e.target.value)} className={`block ${inp}`} /></label>
                    <label className="text-xs">{t('leave.notes')}
                        <input value={notes} onChange={(e) => setNotes(e.target.value)} className={`block ${inp}`} /></label>
                    <button type="button" onClick={add} disabled={pending || !en || !zh}
                            className="bg-gray-900 text-white px-3 py-1.5 rounded text-sm disabled:opacity-50">
                        {t('common.save')}
                    </button>
                </div>
            </div>
        </div>
    )
}
