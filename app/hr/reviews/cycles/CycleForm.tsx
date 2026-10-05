'use client'

// 新建评估轮。period 原样抄进每一份评估,due_date 是 review_cycle_overdue 提醒的基准。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { createCycle } from '../actions'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'

const inp = `${CONTROL_INPUT} w-full`

export default function CycleForm() {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [name, setName] = useState('')
    const [start, setStart] = useState('')
    const [end, setEnd] = useState('')
    const [due, setDue] = useState('')
    const [startBad, setStartBad] = useState(false)
    const [endBad, setEndBad] = useState(false)
    const [dueBad, setDueBad] = useState(false)
    const [notes, setNotes] = useState('')

    function add() {
        setError(null)
        startTransition(async () => {
            const r = await createCycle({
                name: name.trim(),
                period_start: start,
                period_end: end,
                due_date: due,
                notes: notes.trim() || null,
            })
            if (r.error) setError(r.error)
            else {
                setName(''); setStart(''); setEnd(''); setDue(''); setNotes('')
                router.refresh()
            }
        })
    }

    return (
        <div className="rounded border border-gray-200 p-4 mb-6">
            <h3 className="mb-3">{t('reviews.newCycle')}</h3>
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex gap-2 flex-wrap items-end">
                <label className="">
                    {t('reviews.cycleName')}
                    <input value={name} onChange={(e) => setName(e.target.value)} className={`block ${inp}`} />
                </label>
                <label className="">
                    {t('leave.startDate')}
                    <DatePicker value={start} onChange={setStart} onInvalidChange={setStartBad} className="flex" />
                </label>
                <label className="">
                    {t('leave.endDate')}
                    <DatePicker value={end} onChange={setEnd} onInvalidChange={setEndBad} className="flex" />
                </label>
                <label className="">
                    {t('reviews.dueDate')}
                    <DatePicker value={due} onChange={setDue} onInvalidChange={setDueBad} className="flex" />
                </label>
                <label className="">
                    {t('leave.notes')}
                    <input value={notes} onChange={(e) => setNotes(e.target.value)} className={`block ${inp}`} />
                </label>
                <Button
                    type="button"
                    onClick={add}
                    disabled={pending || !name.trim() || !start || !end || !due || startBad || endBad || dueBad}
                >
                    {t('common.save')}
                </Button>
            </div>
        </div>
    )
}
