'use client'

// app/operation/equipment/[id]/SparePartsPanel.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-7a-2(2026-10-16,MES-0 Q70;MES-7a Step 0 Q12–Q15 · Q20,Tim):【这台机器的保养记录上出了哪些备件 —— 出一件、退一件】
//   出库:选一条保养记录、选一批备件、数量、日期 → issue_spare_parts(借 6800 Repairs & Maintenance / 贷 1200,按那一批的落地单价)。
//   退回:在一行出库上填数量、日期与理由 → return_spare_parts(反过来)。码 module.inventory.edit(没有审批,Q10)。
//   【按不动的要说为什么】(DBLOCK-1):不持码 → PermissionGate 按不动并说出码;一条资本化了的记录、一批没定价 / 在暂扣里 / 没有可用的备件,
//   在下拉里看得见、选不了,并说出原因(issue_spare_parts 会按名拒的,这里不给一颗按得下去的钮)。
//   【金额只给持 data.view_prices 的人】而且是照【今天】的落地单价现算的(批次改过价,出给保养那一份的价差已经进了 6800 —— 所以与账一致);
//   不持的人在那一格看见「受限」,不是一个空格子、也不是 0(lib/permissions.ts 那一条)。
//   ★ TABLE-EXPORT-3c(Tim 2026-10-25 Q1):金额这一列【对每一位读者都留着】—— 不持价格码的人在格子里看见「受限」
//     (<MaskedValue>),导出写 Restricted。此前是整列拿掉 + 表上方一句"金额只给看得见价格的人":
//     一列消失,读者分不出"这张表没有金额"与"金额你看不到"(lib/permissions.ts 存在的理由),那一句与那个筛子都已拿掉。
// ════════════════════════════════════════════════════════════════════════════
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type ExportableColumn } from '@/app/components/ui/data-table'
import { MaskedValue } from '@/app/components/MaskedValue'
import { xDate, xMoney, xNum, xRestricted, xText } from '@/lib/export/cells'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { DatePicker } from '@/app/components/ui/date-picker'
import { issueSpareParts, returnSpareParts } from './actions'

export type PartRecord = { id: string; label: string; capitalised: boolean }
export type PartStock = {
    batchId: string; label: string; unit: string; available: number; priced: boolean; holdNcr: string | null
}
export type PartIssueRow = {
    id: string
    issuedOn: string
    record: string
    batch: string
    unit: string
    quantity: number
    returned: number
    outstanding: number
    returns: string[]
    /** 持 data.view_prices 时是 还挂着的数量 × 今天的落地单价;不持 = null(一个权限答复,不是 0) */
    value: string | null
    // ── TABLE-EXPORT-3c(Tim 2026-10-25):导出读的原始值 ──
    /** YYYY-MM-DD 原值(issuedOn 是格式化好的字) */
    issuedOnRaw: string
    /** 批次表这位读者读不到 —— batch 那一格屏幕上是「受限」 */
    batchRestricted: boolean
    /** 金额(本位币)的数;null = 受限(value 也是 null)或这一批没有落地单价(value 是那句「没有成本」) */
    valueAmount: number | null
    valueCurrency: string
}

const QTY = new Intl.NumberFormat('en-US', { maximumFractionDigits: 4 })

export default function SparePartsPanel({
    assetId, records, stock, rows, canIssue, canSeeValue, equipmentCode,
}: {
    assetId: string
    records: PartRecord[]
    /** null = 读不到备件库存(不持 module.inventory.view)—— 一个权限答复,不是"没有备件" */
    stock: PartStock[] | null
    rows: PartIssueRow[]
    canIssue: boolean
    canSeeValue: boolean
    /** TABLE-EXPORT-3c:导出的 About 表说明这份文件出自哪台机器 */
    equipmentCode: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [open, setOpen] = useState(false)
    const [f, setF] = useState({ maintenanceId: '', batchId: '', quantity: '', issuedOn: '' })
    const [dateBad, setDateBad] = useState(false)
    const [ret, setRet] = useState<{ issueId: string; quantity: string; returnedOn: string; reason: string } | null>(null)
    const [retDateBad, setRetDateBad] = useState(false)

    const picked = stock?.find((s) => s.batchId === f.batchId)
    const qty = Number(f.quantity)
    // 【提交钮的禁用条件与理由一起算】只挡表单自己确定得了的;其余由函数按名拒
    const why = !f.maintenanceId ? t('equipment.parts.needRecord')
        : !f.batchId ? t('equipment.parts.needBatch')
        : !f.quantity.trim() || !Number.isFinite(qty) || qty <= 0 ? t('equipment.parts.needQty')
        : picked && qty > picked.available ? t('equipment.parts.overAvailable', { available: QTY.format(picked.available), unit: picked.unit })
        : !f.issuedOn || dateBad ? t('equipment.parts.needDate')
        : ''

    const stockBlocked = (s: PartStock) =>
        !s.priced ? t('equipment.parts.unpriced')
        : s.holdNcr ? t('equipment.parts.onHold', { ncr: s.holdNcr })
        : s.available <= 0 ? t('equipment.parts.noneAvailable')
        : ''

    function submit() {
        setError(null)
        start(async () => {
            const r = await issueSpareParts({ assetId, maintenanceId: f.maintenanceId, issuedOn: f.issuedOn,
                                               lines: [{ batchId: f.batchId, quantity: f.quantity }] })
            if (r.error) { setError(r.error); return }
            setOpen(false)
            setF({ maintenanceId: '', batchId: '', quantity: '', issuedOn: '' })
            router.refresh()
        })
    }

    const retQty = ret ? Number(ret.quantity) : NaN
    const retRow = ret ? rows.find((r) => r.id === ret.issueId) : undefined
    const retWhy = !ret ? ''
        : !ret.quantity.trim() || !Number.isFinite(retQty) || retQty <= 0 ? t('equipment.parts.needQty')
        : retRow && retQty > retRow.outstanding ? t('equipment.parts.overOutstanding', { left: QTY.format(retRow.outstanding), unit: retRow.unit })
        : !ret.returnedOn || retDateBad ? t('equipment.parts.needDate')
        : !ret.reason.trim() ? t('equipment.parts.needReason')
        : ''

    function submitReturn() {
        if (!ret) return
        setError(null)
        start(async () => {
            const r = await returnSpareParts({ assetId, ...ret })
            if (r.error) { setError(r.error); return }
            setRet(null)
            router.refresh()
        })
    }

    const columns: ExportableColumn<PartIssueRow>[] = [
        { key: 'date', header: t('equipment.parts.colDate'), priority: true, render: (r) => r.issuedOn, exportAs: (r) => xDate(r.issuedOnRaw) },
        { key: 'record', header: t('equipment.parts.colRecord'), render: (r) => r.record,
          exportAs: (r) => xText(r.record === '—' ? null : r.record) },
        { key: 'batch', header: t('equipment.parts.colBatch'), priority: true, render: (r) => r.batch,
          exportAs: (r) => r.batchRestricted ? xRestricted : xText(r.batch) },
        // 屏幕上数旁边带着单位(「12 pcs」)—— 一列里各批单位可以不同,单位跟着数走
        { key: 'qty', header: t('equipment.parts.colQty'), align: 'right', render: (r) => `${QTY.format(r.quantity)} ${r.unit}`,
          exportAs: (r) => xNum(r.quantity, 'qty', r.unit) },
        // 退回的那几次(日期 · 数量 · 理由)只在悬停提示里 —— 导出写主值:退回的合计;一次没退过屏幕是「—」→ 空格
        { key: 'returned', header: t('equipment.parts.colReturned'), align: 'right',
          render: (r) => (
              <span title={r.returns.join('\n') || undefined}>{r.returned ? `${QTY.format(r.returned)} ${r.unit}` : '—'}</span>
          ),
          exportAs: (r) => r.returned ? xNum(r.returned, 'qty', r.unit) : xText(null) },
        // Q1:不持价格码 → 「受限」(MaskedValue 同一条判据:没有码且值为 NULL);这一批没有落地单价 → 屏幕上那句话(不是 0)
        { key: 'value', header: t('equipment.parts.colValue'), align: 'right',
          render: (r) => !canSeeValue ? <MaskedValue value={null} canView={false} /> : r.value,
          exportAs: (r) => !canSeeValue ? xRestricted
              : r.valueAmount === null ? xText(r.value) : xMoney(r.valueAmount, r.valueCurrency) },
        { key: 'action', header: '', priority: true, exportAs: false,
          render: (r) => r.outstanding > 0 ? (
              <PermissionGate code="module.inventory.edit" allowed={canIssue} inline className="flex-wrap">
                  <Button variant="secondary" size="xs" type="button" disabled={pending}
                          onClick={() => setRet({ issueId: r.id, quantity: '', returnedOn: '', reason: '' })}>
                      {t('equipment.parts.return')}
                  </Button>
              </PermissionGate>
          ) : <span className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.parts.allReturned')}</span> },
    ]

    return (
        <div className="mb-8" data-section="spare-parts">
            <div className="flex flex-wrap items-baseline gap-3 mb-2">
                <h2 className="">{t('equipment.parts.title')}</h2>
                <PermissionGate code="module.inventory.edit" allowed={canIssue} inline className="flex-wrap">
                    <Button variant="secondary" size="xs" type="button" onClick={() => setOpen(!open)} disabled={pending}>
                        {t('equipment.parts.add')}
                    </Button>
                </PermissionGate>
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">{t('equipment.parts.intro')}</p>
            {error && <p className="text-red-600 text-xs mb-2">{error}</p>}

            {open && (
                <div className="border border-gray-200 rounded p-3 mb-3 text-sm space-y-2" data-form="part-issue">
                    {stock === null ? (
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.parts.stockRestricted')}</p>
                    ) : (
                        <div className="flex flex-wrap gap-3 items-end">
                            <label className="block min-w-0">
                                <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.parts.record')}</span>
                                <select className={CONTROL_SELECT} value={f.maintenanceId}
                                        onChange={(e) => setF({ ...f, maintenanceId: e.target.value })}>
                                    <option value="">{t('equipment.parts.pickRecord')}</option>
                                    {records.map((r) => (
                                        <option key={r.id} value={r.id} disabled={r.capitalised}>
                                            {r.capitalised ? `${r.label} — ${t('equipment.parts.capitalisedRecord')}` : r.label}
                                        </option>
                                    ))}
                                </select>
                            </label>
                            <label className="block min-w-0">
                                <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.parts.batch')}</span>
                                <select className={CONTROL_SELECT} value={f.batchId}
                                        onChange={(e) => setF({ ...f, batchId: e.target.value })}>
                                    <option value="">{stock.length ? t('equipment.parts.pickBatch') : t('equipment.parts.noStock')}</option>
                                    {stock.map((s) => {
                                        const blocked = stockBlocked(s)
                                        return (
                                            <option key={s.batchId} value={s.batchId} disabled={!!blocked}>
                                                {`${s.label} · ${QTY.format(s.available)} ${s.unit}${blocked ? ` — ${blocked}` : ''}`}
                                            </option>
                                        )
                                    })}
                                </select>
                            </label>
                            <label className="block">
                                <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.parts.quantity')}{picked ? ` (${picked.unit})` : ''}</span>
                                <input className={CONTROL_INPUT} inputMode="decimal" value={f.quantity}
                                       onChange={(e) => setF({ ...f, quantity: e.target.value })} />
                            </label>
                            <label className="block">
                                <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.parts.issuedOn')}</span>
                                <DatePicker value={f.issuedOn} onChange={(v) => setF({ ...f, issuedOn: v })} onInvalidChange={setDateBad} />
                            </label>
                            <Button size="xs" type="button" disabled={pending || !!why} onClick={submit}>{t('equipment.parts.submit')}</Button>
                            <Button variant="secondary" size="xs" type="button" onClick={() => setOpen(false)}>{t('common.cancel')}</Button>
                            {why && <span className="text-xs text-[color:var(--brand-muted-text)]">{why}</span>}
                        </div>
                    )}
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('equipment.parts.postingNote')}</p>
                </div>
            )}

            {ret && retRow && (
                <div className="border border-gray-200 rounded p-3 mb-3 text-sm space-y-2" data-form="part-return">
                    <p className="font-medium">{t('equipment.parts.returnTitle', { batch: retRow.batch, left: QTY.format(retRow.outstanding), unit: retRow.unit })}</p>
                    <div className="flex flex-wrap gap-3 items-end">
                        <label className="block">
                            <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.parts.quantity')} ({retRow.unit})</span>
                            <input className={CONTROL_INPUT} inputMode="decimal" value={ret.quantity}
                                   onChange={(e) => setRet({ ...ret, quantity: e.target.value })} />
                        </label>
                        <label className="block">
                            <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.parts.returnedOn')}</span>
                            <DatePicker value={ret.returnedOn} onChange={(v) => setRet({ ...ret, returnedOn: v })} onInvalidChange={setRetDateBad} />
                        </label>
                        <label className="block min-w-0 flex-1">
                            <span className="text-xs text-[color:var(--brand-muted-text)] block">{t('equipment.parts.reason')}</span>
                            <input className={CONTROL_INPUT} value={ret.reason} onChange={(e) => setRet({ ...ret, reason: e.target.value })} />
                        </label>
                        <Button size="xs" type="button" disabled={pending || !!retWhy} onClick={submitReturn}>{t('equipment.parts.returnSubmit')}</Button>
                        <Button variant="secondary" size="xs" type="button" onClick={() => setRet(null)}>{t('common.cancel')}</Button>
                        {retWhy && <span className="text-xs text-[color:var(--brand-muted-text)]">{retWhy}</span>}
                    </div>
                </div>
            )}

            <DataTable
                rows={rows}
                columns={columns}
                rowKey={(r) => r.id}
                phone={{ mode: 'columns' }}
                empty={t('equipment.parts.none')}
                exportSpec={{ name: 'equipment-spare-parts', title: t('equipment.parts.title'),
                              aboutExtra: [[t('equipment.page.colCode'), equipmentCode]] }}
            />
        </div>
    )
}
