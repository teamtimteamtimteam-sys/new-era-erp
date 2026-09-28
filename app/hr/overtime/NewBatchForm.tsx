'use client'

// app/hr/overtime/NewBatchForm.tsx
// OVERTIME-1:开一个月的加班批。月份【不预填】—— 与开考勤期同一条(预填就是奖励不看);库里独立拒未来月份。
// 月份是一个下拉(本月与前 11 个月,服务端用 lib/dates 算好),不是原生月份框 —— 原生日期控件只许减少。
//
// ★ 三种样子,各自有一个机器标记(冒烟认它,不认句子):
//   data-overtime-state="no-site-staff" —— 没有人被标为现场员工:钮看得见、按不动,旁边一行说去哪里标(Tim Q17);
//   data-overtime-state="ready"         —— 可以开批;
//   没有录入码的人 —— 同一颗钮包在 <PermissionGate> 里(看得见、按不动、说出码),标记仍是上面两者之一。
import { CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { createOvertimeBatch } from './actions'

export default function NewBatchForm({ canEnter, siteStaffCount, monthOptions }: {
    canEnter: boolean; siteStaffCount: number; monthOptions: { value: string; label: string }[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [month, setMonth] = useState('')
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()
    const noStaff = siteStaffCount === 0

    return (
        <div className="mb-6 rounded border bg-gray-50 px-4 py-3"
             data-overtime-state={noStaff ? 'no-site-staff' : 'ready'}>
            {error && (
                <div role="alert" className="mb-2 rounded border border-red-300 bg-red-50 px-3 py-2 text-sm text-red-800">{error}</div>
            )}
            <div className="flex flex-wrap items-end gap-3">
                <label>
                    <span className="block text-[color:var(--brand-muted-text)] mb-1">{t('overtime.month')}</span>
                    <select
                        value={month}
                        onChange={(e) => setMonth(e.target.value)}
                        disabled={noStaff || !canEnter}
                        className={CONTROL_SELECT}
                    >
                        <option value="">{t('overtime.pickMonth')}</option>
                        {monthOptions.map((o) => (
                            <option key={o.value} value={o.value}>{o.label}</option>
                        ))}
                    </select>
                </label>
                <PermissionGate code="action.overtime_enter" allowed={canEnter} inline>
                    <Button
                        type="button"
                        disabled={pending || noStaff || month === ''}
                        onClick={() =>
                            startTransition(async () => {
                                setError(null)
                                // 下拉给的是 YYYY-MM(toYearMonth);函数要 date
                                const res = await createOvertimeBatch(month + '-01')
                                if (res.error) setError(res.error)
                                else if (res.batchId) router.push(`/hr/overtime/${res.batchId}`)
                            })
                        }>
                        {t('overtime.newBatch')}
                    </Button>
                </PermissionGate>
                {noStaff ? (
                    <p className="text-sm text-amber-800 max-w-xl">{t('overtime.noSiteStaff')}</p>
                ) : (
                    <p className="text-xs text-[color:var(--brand-muted-text)] max-w-xl">
                        {t('overtime.newBatchHint', { n: siteStaffCount })}
                    </p>
                )}
            </div>
        </div>
    )
}
