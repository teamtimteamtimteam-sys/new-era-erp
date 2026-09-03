'use client'

// app/hr/leave/holidays/HolidaysEditor.tsx
// CONV-3 · 表 + 「新增假期」的表单,两半各自的组件。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { saveHoliday, deleteHoliday } from '../types/actions'
import { AddRowPanel } from '@/app/components/ui/add-row-panel'
import HolidaysTable, { type HolidayRow } from './HolidaysTable'

export default function HolidaysEditor({ rows, year }: { rows: HolidayRow[]; year: number }) {
    const t = useTranslations()
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

    const inp = 'rounded border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] px-2 py-1 text-sm'

    return (
        <div>
            <div className="mb-6">
                <HolidaysTable rows={rows} year={year} pending={pending} onDelete={remove} />
            </div>

            <AddRowPanel
                title={t('leave.addHoliday')}
                error={error}
                actions={
                    <button type="button" onClick={add} disabled={pending || !en || !zh}
                            className="rounded bg-[color:var(--brand-text)] px-3 py-1.5 text-sm text-white disabled:opacity-50">
                        {t('common.save')}
                    </button>
                }
            >
                <label className="text-xs">{t('leave.date')}
                    <input type="date" value={date} onChange={(e) => setDate(e.target.value)} className={`block ${inp}`} /></label>
                <label className="text-xs">{t('permissions.nameEn')}
                    <input value={en} onChange={(e) => setEn(e.target.value)} className={`block ${inp}`} /></label>
                <label className="text-xs">{t('permissions.nameZh')}
                    <input value={zh} onChange={(e) => setZh(e.target.value)} className={`block ${inp}`} /></label>
                <label className="text-xs">{t('leave.notes')}
                    <input value={notes} onChange={(e) => setNotes(e.target.value)} className={`block ${inp}`} /></label>
            </AddRowPanel>
        </div>
    )
}
