'use client'

// app/hr/attendance/OpenPeriodForm.tsx
// ATTEND-1:开一个月。月份【不预填】—— 预填就是奖励不看;函数侧也独立拒未来月份。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { openAttendancePeriod } from './actions'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'

export default function OpenPeriodForm() {
    const t = useTranslations()
    const router = useRouter()
    const [month, setMonth] = useState('')
    const [monthBad, setMonthBad] = useState(false)
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    return (
        <div className="mb-6 rounded border bg-gray-50 px-4 py-3">
            {error && (
                <div className="mb-2 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex flex-wrap items-end gap-3">
                <label className="">
                    <span className="block text-[color:var(--brand-muted-text)] mb-1">{t('attendance.openMonth')}</span>
                    <DatePicker
                        kind="month"
                        value={month}
                        onChange={setMonth}
                        onInvalidChange={setMonthBad}
                    />
                </label>
                <Button
                    type="button"
                    disabled={pending || month === '' || monthBad}
                    onClick={() =>
                        startTransition(async () => {
                            setError(null)
                            // 月份选择器给的是 YYYY-MM;函数要 date
                            const res = await openAttendancePeriod(month + '-01')
                            if (res.error) setError(res.error)
                            else if (res.periodId) router.push(`/hr/attendance/${res.periodId}`)
                        })
                    }>
                    {t('attendance.openBtn')}
                </Button>
                <p className="text-xs text-[color:var(--brand-muted-text)]">{t('attendance.openHint')}</p>
            </div>
        </div>
    )
}
