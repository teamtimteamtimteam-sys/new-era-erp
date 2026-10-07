'use client'

// SO-3b 的发货控件,★ APR-5b 搬进仓库的发货队列(/logistics/shipping):一行一条预留,发它。
//
// 【发货日必填,永不默认】物理事件日,而且它决定收入落进哪个会计期间 ——
// 提交钮在日期空着时禁用【且】服务端按名独立拒(SHIP_DATE_REQUIRED)。
// UI 的 required 只是第三层,不是保护(AGENTS.md 的日期规矩)。
//
// 【后果写在按钮旁边,而且它是【不可撤】的那一种】货离开台账、发票从此作废不了。
// ★ 按按钮的人看不见价格:后果句只说"货离开了、收入由系统过账",不说金额。
//
// ★ MES-3b(2026-10-07,MES-3b Step 0 Q24,Tim):【一次可选的核对扫码】—— 扫手上那一箱的标签;对得上就说对得上,
//   对不上就说对不上。扫了的那个批号随发货一起送去 ship_order,对不上它按名拒 SHIP_SCAN_MISMATCH(判据只在函数里一处)。
//   不扫照常发(Q24:不必扫)。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { showActionMessage } from '@/app/components/ui/action-message'
import { shipFromQueue } from './actions'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import ScanField from '@/app/components/scan/ScanField'

export default function ShipQueueControl({
    orderId,
    reservationId,
    reservedQty,
    remainingQty,
    unit,
    subject,
    batchCode,
}: {
    orderId: string
    reservationId: string
    reservedQty: number
    /** 这一行还能发多少(放行数量 − 已发);发整条预留超过它时服务端按名拒 SO_SHIP_EXCEEDS_RELEASABLE */
    remainingQty: number
    unit: string
    /** CONFIRM-1:发的是【哪一张单的哪一条预留】 */
    subject: string
    /** MES-3b:这条预留的批号 —— 核对扫码拿它比(只用来在屏幕上先说一句;真正的判决在 ship_order) */
    batchCode: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [qty, setQty] = useState('')
    const [shipDate, setShipDate] = useState('')
    // 日期框里敲着一个不合法的日子:shipDate 还是上一个合法值,按钮靠这一位关上
    const [dateBad, setDateBad] = useState(false)
    const [scanned, setScanned] = useState('')
    const scanMatches = scanned !== '' && batchCode !== null && scanned.toUpperCase() === batchCode.toUpperCase()

    const qtyN = Number(qty)
    // 【数量留空 = 整条预留】—— 不是 0。
    const effective = qty.trim() === '' ? reservedQty : qtyN
    const qtyBad = qty.trim() !== '' && (Number.isNaN(qtyN) || qtyN <= 0 || qtyN > reservedQty)

    const blocked =
        shipDate.trim() === '' ? t('logistics.shipping.dateRequired')
        : qtyBad ? t('logistics.shipping.overReservation', { have: String(reservedQty) })
        : effective > remainingQty ? t('logistics.shipping.overRemaining', { left: String(remainingQty) })
        : null

    function go() {
        startTransition(async () => {
            const res = await shipFromQueue(orderId, reservationId, qty, shipDate, scanned)
            if (res.error) {
                showActionMessage({ subject, headline: t('common.actionMessage.headline.notShipped'), body: res.error })
                return
            }
            setQty(''); setShipDate(''); setScanned('')
            router.refresh()
        })
    }

    return (
        <div>
            <ScanField context="ship" accept={['output_batch']} compact label={t('logistics.shipping.verifyScan')}
                       onFound={(r) => setScanned(r.code ?? '')} testId={`scan-ship-${reservationId}`} />
            {scanned !== '' && (
                <p className={`text-sm mb-1 ${scanMatches ? '' : 'text-amber-700'}`} data-ship-scan={scanMatches ? 'match' : 'mismatch'}>
                    {scanMatches ? t('logistics.shipping.scanMatches', { code: scanned })
                                 : t('logistics.shipping.scanMismatch', { code: scanned, expected: batchCode ?? '—' })}
                    {' '}
                    <Button type="button" variant="link" size="inline" onClick={() => setScanned('')}>{t('logistics.shipping.scanClear')}</Button>
                </p>
            )}
            <div className="flex flex-wrap items-end gap-2">
                <div className="w-36">
                    <label className="block mb-1">{t('logistics.shipping.qtyLabel', { unit })}</label>
                    <input type="number" step="any" min="0" value={qty}
                           onChange={(e) => setQty(e.target.value)}
                           placeholder={String(reservedQty)}
                           className={`${CONTROL_INPUT} w-full`} />
                </div>
                <div>
                    <label className="block mb-1">{t('logistics.shipping.shipDate')}</label>
                    <DatePicker value={shipDate} onChange={setShipDate} onInvalidChange={setDateBad} />
                </div>
                <Button type="button" onClick={go} disabled={isPending || blocked !== null || dateBad} variant="secondary">
                    {isPending ? t('common.saving') : t('logistics.shipping.action')}
                </Button>
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{blocked ?? t('logistics.shipping.consequence')}</p>
        </div>
    )
}
