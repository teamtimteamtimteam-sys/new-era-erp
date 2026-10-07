'use client'

// SO-2:一行订单上的【预留】控件。
//
// 【后果写在按钮旁边】(与 TransitionPanel 同一条)—— 预留会把货挪进 committed,
// 从那一刻起销售与投料都动不了它。那句话必须在按下之前就在屏幕上,而不是等
// 某个人后来发现"这批货怎么卖不掉"。
//
// 【页面不做服务端会做的判断,只是不给人看见一个必然被拒的按钮】
// 数量超过桶里的可用、或超过这一行还能许的量时禁钮并说原因;真正的判决在
// reserve_stock 里(那里的数是现算的,这里的只是上一次渲染的快照)。
//
// ★ MES-3b(2026-10-07,MES-3b Step 0 Q24,Tim):【发哪一批是在预留这一步定的】—— 所以扫码在这里是"选":
//   扫到一批产出批 → 下拉只剩它的桶;只有一个桶就直接选上。这一批在这一行的候选里没有可用的货 → 说出来。
//   预留的拒绝一条都没有搬到这里(只认产出批、物料对得上、只取 available),照旧由 reserve_stock 判。
import { CONTROL_SELECT, CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { reserveForLine } from '../actions'
import { Button } from '@/app/components/ui/button'
import ScanField from '@/app/components/scan/ScanField'
import type { ScanResult } from '@/app/components/scan/actions'

export type BucketOption = {
    outputBatchId: string
    batchCode: string
    locationId: string | null
    locationLabel: string
    available: number
    unit: string
}

const bucketKey = (b: BucketOption) => `${b.outputBatchId}::${b.locationId ?? ''}`

export default function ReserveControl({
    orderId,
    lineId,
    room,
    unit,
    buckets,
}: {
    orderId: string
    lineId: string
    /** 这一行还能许出去多少(行数量 − 已许) */
    room: number
    unit: string
    buckets: BucketOption[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [pick, setPick] = useState('')
    const [qty, setQty] = useState('')
    const [scanOnly, setScanOnly] = useState<string | null>(null)
    const [scanMiss, setScanMiss] = useState('')
    const shown = scanOnly ? buckets.filter((b) => b.outputBatchId === scanOnly) : buckets

    function scanned(r: ScanResult) {
        const mine = buckets.filter((b) => b.outputBatchId === r.id)
        if (mine.length === 0) { setScanMiss(t('sales.reserve.scanNoBucket', { code: r.code ?? '' })); setScanOnly(null); return }
        setScanMiss('')
        setScanOnly(r.id)
        setPick(mine.length === 1 ? bucketKey(mine[0]) : '')
    }

    const chosen = buckets.find((b) => bucketKey(b) === pick) ?? null
    const qtyN = Number(qty)
    const qtyValid = qty.trim() !== '' && !Number.isNaN(qtyN) && qtyN > 0

    let blocked: string | null = null
    if (buckets.length === 0) blocked = t('sales.reserve.noCandidates')
    else if (room <= 0) blocked = t('sales.reserve.lineFull')
    else if (!chosen) blocked = t('sales.reserve.pickBucket')
    else if (!qtyValid) blocked = t('stock.blockedNoQty')
    else if (qtyN > chosen.available) blocked = t('sales.reserve.overBucket', { have: String(chosen.available) })
    else if (qtyN > room) blocked = t('sales.reserve.overLine', { room: String(room) })

    function go() {
        if (!chosen) return
        setError('')
        startTransition(async () => {
            const res = await reserveForLine(orderId, lineId, chosen.outputBatchId, chosen.locationId, qty)
            if (res.error) setError(res.error)
            else {
                setPick('')
                setQty('')
                router.refresh()
            }
        })
    }

    return (
        <div className="mt-2 border-t border-gray-200 pt-2">
            {error && <p className="text-sm text-red-600 mb-2">{error}</p>}
            {buckets.length > 0 && (
                <ScanField context="reserve" accept={['output_batch']} compact onFound={scanned} testId={`scan-reserve-${lineId}`} />
            )}
            {scanMiss && <p className="text-sm text-amber-700 mb-1">{scanMiss}</p>}
            <div className="flex flex-wrap items-end gap-2 mt-1">
                <div className="min-w-[18rem]">
                    <label className="block mb-1">{t('sales.reserve.batchLabel')}</label>
                    <select
                        value={pick}
                        onChange={(e) => setPick(e.target.value)}
                        className={`${CONTROL_SELECT} w-full`}
                    >
                        <option value="">{t('sales.reserve.pickBucket')}</option>
                        {shown.map((b) => (
                            <option key={bucketKey(b)} value={bucketKey(b)}>
                                {b.batchCode} · {b.locationLabel} · {b.available} {b.unit}
                            </option>
                        ))}
                    </select>
                </div>
                <div className="w-40">
                    <label className="block mb-1">
                        {t('sales.reserve.qtyLabel', { unit })}
                    </label>
                    <input
                        type="number"
                        step="any"
                        min="0"
                        value={qty}
                        onChange={(e) => setQty(e.target.value)}
                        className={`${CONTROL_INPUT} w-full`}
                    />
                </div>
                <Button
                    type="button"
                    onClick={go}
                    disabled={isPending || blocked !== null}
                    variant="secondary"
                >
                    {isPending ? t('common.saving') : t('sales.reserve.action')}
                </Button>
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{blocked ?? t('sales.reserve.consequence')}</p>
        </div>
    )
}
