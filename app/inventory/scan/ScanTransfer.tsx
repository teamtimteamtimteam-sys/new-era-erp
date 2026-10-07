'use client'

// app/inventory/scan/ScanTransfer.tsx
// MES-3b(2026-10-07,MES-0 §8.2 MES-3b 行;MES-3b Step 0 Q22,Tim):【扫一批,搬去扫到的那个库位】。
//   ① 扫批次(或手敲批号)→ 它此刻在哪些库位、什么状态、多少(stock_by_status);一个"打开这一批"的链接。
//   ② 选一个来源桶 —— 或者扫来源库位:那个库位一点这批货都没有 → 当场说出来(服务端也照样按名拒 IOD_TRANSFER_EXCEEDS_BUCKET)。
//   ③ 扫目的库位 → 数量 → 转移。走的仍是 create_stock_transfer(transferStockAction),它的每一条拒绝一字未动:
//      停用的库位、桶里没那么多、分类不收、【MES-3a 的隔离闸】(开着要隔离的状态 → 只能进隔离库位)、在等审批的申请冻住这一批。
//   转移要 module.inventory.edit;没有的人看得见这几步,按钮是灰的并说要哪个码(DBLOCK-1)。
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import ScanField from '@/app/components/scan/ScanField'
import type { ScanResult } from '@/app/components/scan/actions'
import { transferStockAction } from '@/app/components/inventory/stockActions'
import { scannedBatchStock, type ScannedBatch, type ScanBucket } from './actions'

const keyOf = (b: ScanBucket) => `${b.location_id ?? ''}::${b.stock_status}`

export default function ScanTransfer({ canMove }: { canMove: boolean }) {
    const t = useTranslations()
    const [batch, setBatch] = useState<ScannedBatch | null>(null)
    const [from, setFrom] = useState('')
    const [fromMsg, setFromMsg] = useState('')
    const [dest, setDest] = useState<{ id: string; code: string } | null>(null)
    const [qty, setQty] = useState('')
    const [note, setNote] = useState('')
    const [error, setError] = useState('')
    const [done, setDone] = useState('')
    const [isPending, startTransition] = useTransition()

    const bucket = batch?.buckets.find((b) => keyOf(b) === from) ?? null
    const statusName = (s: string) => s === 'available' ? t('stock.available') : s === 'on_hold' ? t('stock.onHold') : t('stock.committed')
    const locName = (b: ScanBucket) => b.location_code ?? t('storageSafety.unspecified')

    function loadBatch(r: ScanResult) {
        if (!r.id || (r.kind !== 'inbound_batch' && r.kind !== 'output_batch')) return
        const kind = r.kind
        const id = r.id
        startTransition(async () => {
            const b = await scannedBatchStock(kind, id)
            setBatch(b); setFrom(b.buckets.length === 1 ? keyOf(b.buckets[0]) : ''); setFromMsg('')
            setDest(null); setQty(''); setNote(''); setError(''); setDone('')
        })
    }

    function pickSource(r: ScanResult) {
        if (!batch || !r.id) return
        const here = batch.buckets.filter((b) => b.location_id === r.id)
        if (here.length === 0) { setFrom(''); setFromMsg(t('scanPage.sourceHoldsNone', { loc: r.code ?? '', code: batch.code })); return }
        const pick = here.find((b) => b.stock_status === 'available') ?? here[0]
        setFrom(keyOf(pick)); setFromMsg('')
    }

    const qtyN = Number(qty)
    const blocked = !batch ? t('scanPage.needBatch')
        : !bucket ? t('scanPage.needSource')
        : !dest ? t('scanPage.needDest')
        : dest.id === bucket.location_id ? t('scanPage.sameLocation')
        : qty.trim() === '' || Number.isNaN(qtyN) || qtyN <= 0 ? t('stock.blockedNoQty')
        : qtyN > Number(bucket.qty) ? t('scanPage.overBucket', { have: String(bucket.qty) })
        : null

    function move() {
        if (!batch || !bucket || !dest) return
        setError(''); setDone('')
        startTransition(async () => {
            const res = await transferStockAction(batch.kind === 'inbound_batch' ? batch.id : null, batch.kind === 'output_batch' ? batch.id : null,
                bucket.location_id, dest.id, qty, bucket.stock_status, note)
            if (res.error) { setError(res.error); return }
            setDone(t('scanPage.moved', { qty, unit: batch.unit, code: batch.code, from: locName(bucket), to: dest.code }))
            const b = await scannedBatchStock(batch.kind, batch.id)
            setBatch(b); setFrom(''); setDest(null); setQty(''); setNote('')
        })
    }

    return (
        <div className="max-w-2xl" data-scan-transfer>
            <ScanField context="transfer" accept={['inbound_batch', 'output_batch']} onFound={loadBatch}
                       label={t('scanPage.step1')} autoFocus testId="scan-batch" />
            {batch && (
                <div className="mb-4 border border-gray-200 rounded p-3" data-scanned-batch={batch.code}>
                    <p className="mb-2">
                        <span className="font-mono font-semibold">{batch.code}</span>{' · '}
                        <Link className="app-link hover:underline" href={batch.kind === 'inbound_batch' ? `/inbound/${batch.id}/edit` : `/output/${batch.id}/edit`}>
                            {t('scanPage.open')}
                        </Link>
                    </p>
                    {batch.buckets.length === 0 ? (
                        <p className="text-sm text-[color:var(--brand-muted-text)]">{t('scanPage.noStock')}</p>
                    ) : (
                        <fieldset>
                            <legend className="text-sm mb-1">{t('scanPage.step2')}</legend>
                            {batch.buckets.map((b) => (
                                <label key={keyOf(b)} className="flex items-center gap-2 min-h-[44px] text-sm">
                                    <input type="radio" name="scan-source" checked={from === keyOf(b)} onChange={() => { setFrom(keyOf(b)); setFromMsg('') }} />
                                    <span>{locName(b)} · {statusName(b.stock_status)} · {b.qty} {batch.unit}</span>
                                </label>
                            ))}
                            <ScanField context="transfer" accept={['storage_location']} onFound={pickSource}
                                       label={t('scanPage.sourceScan')} compact testId="scan-source" />
                            {fromMsg && <p className="text-sm text-amber-700" data-source-holds-none>{fromMsg}</p>}
                        </fieldset>
                    )}
                </div>
            )}
            {batch && batch.buckets.length > 0 && (
                <PermissionGate code="module.inventory.edit" allowed={canMove}>
                    <ScanField context="transfer" accept={['storage_location']} label={t('scanPage.step3')} testId="scan-dest"
                               onFound={(r) => r.id && setDest({ id: r.id, code: r.code ?? '' })} />
                    {dest && <p className="text-sm mb-2" data-scan-dest={dest.code}>{t('scanPage.dest', { code: dest.code })}</p>}
                    <div className="flex flex-wrap items-end gap-2 mb-2">
                        <div className="w-40">
                            <label className="block mb-1">{t('scanPage.qty', { unit: batch.unit })}</label>
                            <input type="number" step="any" min="0" inputMode="decimal" value={qty} onChange={(e) => setQty(e.target.value)}
                                   className={`${CONTROL_INPUT} w-full`} data-scan-qty />
                        </div>
                        <div className="flex-1 min-w-[12rem]">
                            <label className="block mb-1">{t('scanPage.note')}</label>
                            <input value={note} onChange={(e) => setNote(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                        </div>
                        <Button type="button" size="touch" onClick={move} disabled={isPending || blocked !== null} data-scan-move>
                            {isPending ? t('common.saving') : t('scanPage.move')}
                        </Button>
                    </div>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{blocked ?? t('scanPage.consequence')}</p>
                </PermissionGate>
            )}
            {error && <p className="text-sm text-red-600 mt-2" role="alert">{error}</p>}
            {done && <p className="text-sm mt-2" data-scan-moved>{done}</p>}
        </div>
    )
}
