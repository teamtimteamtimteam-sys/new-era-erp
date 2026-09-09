'use client'

// app/finance/packs/PackControls.tsx
// GLEXPORT-1:月份选择 + 存档控件。**禁用一律说出为什么**(CMP-2 的规矩)。
import { useState, useTransition } from 'react'
import { useRouter, usePathname } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { producePack } from './actions'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export function PackMonthPicker({ month }: { month: string }) {
    const t = useTranslations()
    const router = useRouter()
    const pathname = usePathname()
    return (
        <div>
            <label className="block text-sm font-medium mb-1">{t('pack.colMonth')}</label>
            <input type="month" defaultValue={month} name="month"
                   onChange={(e) => { if (e.target.value) router.push(`${pathname}?month=${e.target.value}`) }}
                   className="border border-gray-300 px-3 py-2 rounded" />
        </div>
    )
}

export function ProducePackControl({
    month, canProduce, canEdit, hasLive,
}: {
    month: string
    /** 【状态,不是权限】= `preview.month_locked`:这个月锁了没有。 */
    canProduce: boolean
    /** 【权限,不是状态】= module.finance.edit。两者混用会说出一句假话 ——
     *  DBLOCK-1 的探针在 YearClosePanel 上抓到过同一次混用,详见那份抬头。 */
    canEdit: boolean
    hasLive: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [notes, setNotes] = useState('')
    const [reason, setReason] = useState('')
    const [err, setErr] = useState('')
    const [ok, setOk] = useState('')
    const [busy, start] = useTransition()

    // 【禁用要说出理由,而不是把控件藏起来】问题适用、只是被挡住了 ——
    // 藏起来会让人以为这个功能不存在。
    if (!canProduce) {
        return (
            <div className="inline-flex flex-col items-start">
                <Button type="button" disabled
                        variant="secondary">
                    {t('pack.produce')}
                </Button>
                <span className="text-xs text-amber-700 mt-1 max-w-2xl">{t('pack.produceBlockedNotLocked')}</span>
            </div>
        )
    }

    return (
        <div className="border border-gray-300 rounded p-4">
            <div className="flex flex-wrap items-end gap-3">
                <div className="grow">
                    <label className="block text-sm font-medium mb-1">{t('pack.colCode')}</label>
                    <input value={notes} onChange={(e) => setNotes(e.target.value)}
                           className="border border-gray-300 px-3 py-2 rounded w-full" />
                </div>
                {hasLive && (
                    <div className="grow">
                        <label className="block text-sm font-medium mb-1">{t('pack.supersedeReason')}</label>
                        <input value={reason} onChange={(e) => setReason(e.target.value)}
                               className="border border-gray-300 px-3 py-2 rounded w-full" />
                    </div>
                )}
                <PermissionGate code="module.finance.edit" allowed={canEdit}>
                <Button type="button" disabled={busy || (hasLive && !reason.trim())}
                        onClick={() => start(async () => {
                            const r = await producePack(month, notes, reason)
                            if (r.error) { setErr(r.error); setOk('') }
                            else { setErr(''); setOk(t('pack.produced', { code: r.code ?? '' })); setNotes(''); setReason(''); router.refresh() }
                        })}
                        variant="default" size="default">
                    {busy ? t('common.saving') : t('pack.produce')}
                </Button>
                </PermissionGate>
            </div>
            {hasLive && !reason.trim() && (
                <p className="text-xs text-amber-700 mt-2">{t('pack.supersedeNeeded')}</p>
            )}
            {err && <p className="text-sm text-red-700 mt-2">{err}</p>}
            {ok && <p className="text-sm text-green-700 mt-2">{ok}</p>}
        </div>
    )
}
