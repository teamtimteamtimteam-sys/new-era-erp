'use client'

// app/hr/leave/LeaveForm.tsx
// 录入请假。HR 版本带【例外】开关;员工自助复用同一个组件但 allowException=false。
//
// 天数是【服务端算的】(previewLeaveDays → calculate_leave_days),不是前端自己数日历 ——
// 公共假期在数据库里,前端数不准;而且预览用的和提交时用的必须是同一个函数。
import { useState, useTransition, useEffect } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { submitLeave, previewLeaveDays } from './actions'

export type LeaveTypeOption = {
    code: string
    name_en: string
    name_zh: string
    is_accrued: boolean
    allows_half_day: boolean
    requires_certificate_after_days: number | null
    default_days_per_year: number | null
}
export type EmployeeOption = { id: string; code: string; legal_name: string }

export default function LeaveForm({
    types,
    employees,
    fixedEmployeeId,
    allowException = false,
    redirectTo,
}: {
    types: LeaveTypeOption[]
    employees?: EmployeeOption[]
    /** 自助时固定成本人,不给选别人 */
    fixedEmployeeId?: string
    allowException?: boolean
    redirectTo: string
}) {
    const t = useTranslations()
    const locale = useLocale()
    const router = useRouter()

    const [employeeId, setEmployeeId] = useState(fixedEmployeeId ?? '')
    const [typeCode, setTypeCode] = useState(types[0]?.code ?? '')
    const [start, setStart] = useState('')
    const [end, setEnd] = useState('')
    const [startHalf, setStartHalf] = useState(false)
    const [endHalf, setEndHalf] = useState(false)
    const [reason, setReason] = useState('')
    const [certRef, setCertRef] = useState('')
    const [isException, setIsException] = useState(false)
    const [exDays, setExDays] = useState('')
    const [exReason, setExReason] = useState('')
    const [days, setDays] = useState<number | null>(null)
    // 【第三个状态,不是第二个】days 为 null 的意思是「两头日期还没填全」;
    // 算不出来是另一件事,所以它有自己的格子。合成一个格子正是 CLEANUP-A 修掉的那件事。
    const [daysError, setDaysError] = useState<string | null>(null)
    const [error, setError] = useState<string | null>(null)
    const [ok, setOk] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const type = types.find((x) => x.code === typeCode)

    // 实时天数:两头日期都有就去服务端算一次
    useEffect(() => {
        if (!start || !end || end < start) { setDays(null); setDaysError(null); return }
        let cancelled = false
        previewLeaveDays(start, end, startHalf, endHalf)
            .then((r) => {
                if (cancelled) return
                // 【算不出来时把旧天数一起清掉】只挂一条红字、把上一次的天数留在屏幕上,
                // 会让人按着一个【不再对应当前日期】的数字做决定 —— 那比不显示更坏。
                if ('error' in r) { setDays(null); setDaysError(r.error) }
                else { setDays(r.days); setDaysError(null) }
            })
            // 【网络/传输层抛出来的那一支也要说话】catch 里只把加载状态关掉,
            // 屏幕上就只剩一个「—」,与"还没填完"一模一样。
            .catch((e) => {
                if (cancelled) return
                console.error('leave day preview failed', e)
                setDays(null); setDaysError(t('leave.errDaysPreviewFailed'))
            })
        return () => { cancelled = true }
    }, [start, end, startHalf, endHalf, t])

    function submit() {
        setError(null); setOk(null)
        startTransition(async () => {
            const r = await submitLeave({
                employeeId: fixedEmployeeId ?? employeeId,
                leaveTypeCode: typeCode,
                start, end, startHalf, endHalf,
                reason: reason || null,
                certificateRef: certRef || null,
                isException: allowException ? isException : false,
                exceptionDays: isException && exDays !== '' ? Number(exDays) : null,
                exceptionReason: isException ? exReason || null : null,
            })
            if (r.error) setError(r.error)
            else {
                setOk(r.code ?? '')
                router.push(redirectTo)
                router.refresh()
            }
        })
    }

    const field = 'mt-1 w-full border border-gray-300 rounded px-2 py-1 text-sm'

    return (
        <div className="rounded border border-gray-200 p-4 max-w-2xl">
            {error && (
                <div className="mb-3 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">
                    {error}
                </div>
            )}
            {ok && <p className="mb-3 text-sm text-green-700">{t('leave.submitted', { 0: ok })}</p>}

            <div className="grid gap-4 sm:grid-cols-2">
                {!fixedEmployeeId && employees && (
                    <label className="text-sm sm:col-span-2">
                        {t('leave.employee')}
                        <select value={employeeId} onChange={(e) => setEmployeeId(e.target.value)} className={field}>
                            <option value="">—</option>
                            {employees.map((e) => (
                                <option key={e.id} value={e.id}>{e.code} — {e.legal_name}</option>
                            ))}
                        </select>
                    </label>
                )}

                <label className="text-sm">
                    {t('leave.type')}
                    <select value={typeCode} onChange={(e) => setTypeCode(e.target.value)} className={field}>
                        {types.map((x) => (
                            <option key={x.code} value={x.code}>{locale === 'zh' ? x.name_zh : x.name_en}</option>
                        ))}
                    </select>
                    {/* 假别的配置【由数据说了算】,不写死在界面里 */}
                    {type?.default_days_per_year != null && (
                        <span className="mt-1 block text-xs text-gray-500">
                            {t('leave.standardDays', { 0: String(type.default_days_per_year) })}
                        </span>
                    )}
                </label>

                <div />

                <label className="text-sm">
                    {t('leave.startDate')}
                    <input type="date" value={start} onChange={(e) => setStart(e.target.value)} className={field} />
                    {type?.allows_half_day && (
                        <label className="mt-1 flex items-center gap-2 text-xs text-gray-600">
                            <input type="checkbox" checked={startHalf} onChange={(e) => setStartHalf(e.target.checked)} />
                            {t('leave.halfDayStart')}
                        </label>
                    )}
                </label>

                <label className="text-sm">
                    {t('leave.endDate')}
                    <input type="date" value={end} onChange={(e) => setEnd(e.target.value)} className={field} />
                    {type?.allows_half_day && (
                        <label className="mt-1 flex items-center gap-2 text-xs text-gray-600">
                            <input type="checkbox" checked={endHalf} onChange={(e) => setEndHalf(e.target.checked)} />
                            {t('leave.halfDayEnd')}
                        </label>
                    )}
                </label>

                <div className="sm:col-span-2 rounded bg-gray-50 px-3 py-2 text-sm">
                    {t('leave.computedDays')}:{' '}
                    <span className="font-mono font-medium">
                        {isException ? (exDays === '' ? '—' : exDays) : (days ?? '—')}
                    </span>
                    {isException && <span className="ml-2 text-xs text-purple-800">{t('leave.exceptionManual')}</span>}
                    {!isException && !daysError && <span className="ml-2 text-xs text-gray-500">{t('leave.computedHint')}</span>}
                    {!isException && daysError && (
                        <span className="ml-2 text-xs font-medium text-red-700">{daysError}</span>
                    )}
                </div>

                <label className="text-sm sm:col-span-2">
                    {t('leave.reason')}
                    <input value={reason} onChange={(e) => setReason(e.target.value)} className={field} />
                </label>

                {/* 证明要求【从假别配置动态显示】 */}
                {type?.requires_certificate_after_days != null && (
                    <label className="text-sm sm:col-span-2">
                        {t('leave.certificate')}
                        <input value={certRef} onChange={(e) => setCertRef(e.target.value)} className={field} />
                        <span className="mt-1 block text-xs text-gray-500">
                            {t('leave.certificateHint', { 0: String(type.requires_certificate_after_days) })}
                        </span>
                    </label>
                )}

                {allowException && (
                    <div className="sm:col-span-2 rounded border border-purple-200 bg-purple-50 px-3 py-2">
                        <label className="flex items-center gap-2 text-sm">
                            <input type="checkbox" checked={isException} onChange={(e) => setIsException(e.target.checked)} />
                            {t('leave.exceptionToggle')}
                        </label>
                        <p className="mt-1 text-xs text-gray-600">{t('leave.exceptionHint')}</p>
                        {isException && (
                            <div className="mt-3 grid gap-3 sm:grid-cols-2">
                                <label className="text-sm">
                                    {t('leave.exceptionDays')}
                                    <input type="number" step="0.5" min="0.5" value={exDays}
                                           onChange={(e) => setExDays(e.target.value)} className={field} />
                                </label>
                                <label className="text-sm">
                                    {t('leave.exceptionReason')}
                                    <input value={exReason} onChange={(e) => setExReason(e.target.value)} className={field} />
                                </label>
                                <p className="sm:col-span-2 text-xs text-gray-600">
                                    {t('leave.exceptionBalanceNote')}
                                </p>
                            </div>
                        )}
                    </div>
                )}
            </div>

            <button
                type="button"
                onClick={submit}
                disabled={pending || !start || !end || (!fixedEmployeeId && !employeeId)}
                className="mt-4 bg-gray-900 text-white px-4 py-1.5 rounded text-sm disabled:opacity-50"
            >
                {pending ? t('common.saving') : t('leave.submit')}
            </button>
        </div>
    )
}
