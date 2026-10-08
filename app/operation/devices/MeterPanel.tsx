'use client'

// MES-5a-2(2026-10-08,规格 §9 "Energy";MES-0 D4 · Q27;MES-5a Step 0 Q19 · Q20,Tim):一台电表的累计寄存器读数。
//   【读数是什么】表上显示的累计 kWh(不是那一段用了多少)。"比上一条多用了"由库里的视图算(meter_readings_current),页面不算。
//   【记】时刻(必填,不给默认 —— 它决定这条落在哪一段、也就决定一张电费单分给哪几炉)· 读数 · 寄存器清零(理由必填)· 备注。
//   比前一条小的读数库里拒,除非标成寄存器清零;跨过清零的那一段量不出来,不计。码:action.confirm_capture。
//   【更正】新的一行指着旧的(理由必填),旧的留着;【撤回】记在了错的表上 —— 新的一行把那一刻空出来。
//   设备转换器没有建(没有电表给过数据格式):今天每一条都是手工录入。
import { CONTROL_INPUT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { recordMeterReading, correctMeterReading, type ReadingInput } from './meterActions'

export type MeterReadingView = {
    id: number
    readAtIso: string
    readAt: string
    registerKwh: number
    delta: number | null
    reset: boolean
    resetReason: string | null
    source: string
    notes: string | null
    corrected: boolean
    correctionReason: string | null
}

const blank = (): ReadingInput => ({ readAt: '', registerKwh: '', reset: false, resetReason: '', notes: '' })

export default function MeterPanel({ deviceId, retired, canRecord, readings }: {
    deviceId: string
    retired: boolean
    canRecord: boolean
    readings: MeterReadingView[]
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const [f, setF] = useState<ReadingInput>(blank())
    const [fixing, setFixing] = useState<MeterReadingView | null>(null)
    const [withdraw, setWithdraw] = useState(false)
    const [why, setWhy] = useState('')
    const lbl = 'block text-xs font-medium text-[color:var(--brand-muted-text)] mb-1'
    const muted = 'text-sm text-[color:var(--brand-muted-text)]'

    const columns: Column<MeterReadingView>[] = [
        { key: 'at', header: t('energy.colReadAt'), priority: true, render: (r) => r.readAt },
        { key: 'kwh', header: t('energy.colRegister'), priority: true, align: 'right', render: (r) => `${r.registerKwh} kWh` },
        {
            key: 'delta', header: t('energy.colSincePrevious'), align: 'right',
            render: (r) => (r.reset ? <span className="text-amber-700" data-meter-reset="1">{t('energy.registerReset')}</span>
                : r.delta === null ? '—' : `${r.delta} kWh`),
        },
        {
            key: 'notes', header: '', className: 'text-[color:var(--brand-muted-text)]',
            render: (r) => [r.reset && r.resetReason ? t('energy.resetBecause', { reason: r.resetReason }) : null, r.notes,
                            r.corrected ? t('energy.correctedBecause', { reason: r.correctionReason ?? '' }) : null].filter(Boolean).join(' · '),
        },
        ...(!retired && canRecord ? [{
            key: 'actions', header: '', align: 'right' as const, priority: true,
            render: (r: MeterReadingView) => (
                <Button variant="secondary" size="inline" type="button" className="text-sm" disabled={pending}
                        onClick={() => {
                            setFixing(r); setWithdraw(false); setWhy(''); setError(null)
                            setF({ readAt: r.readAtIso, registerKwh: String(r.registerKwh), reset: r.reset, resetReason: r.resetReason ?? '', notes: r.notes ?? '' })
                        }}>
                    {t('energy.correct')}
                </Button>
            ),
        }] : []),
    ]

    function save() {
        setError(null)
        start(async () => {
            const r = fixing
                ? await correctMeterReading(deviceId, fixing.id, { ...f, withdraw }, why)
                : await recordMeterReading(deviceId, f)
            if (r.error) { setError(r.error); return }
            setFixing(null); setWithdraw(false); setWhy(''); setF(blank())
            router.refresh()
        })
    }
    const missing = fixing ? why.trim() === '' : f.readAt === '' || f.registerKwh.trim() === '' || (f.reset && f.resetReason.trim() === '')

    return (
        <section className="mt-8" data-section="meter-readings">
            <h2 className="mb-1">{t('energy.readingsTitle')}</h2>
            <p className={`${muted} mb-3`}>{t('energy.readingsIntro')}</p>
            <DataTable rows={readings} columns={columns} rowKey={(r) => String(r.id)} phone={{ mode: 'columns' }} empty={t('energy.noReadings')} />
            {error && <p className="mt-2 text-sm text-red-700" role="alert">{error}</p>}

            {!retired && (
                <PermissionGate code="action.confirm_capture" allowed={canRecord}>
                    <div className="mt-3 border border-gray-200 rounded p-3 space-y-3" data-meter-form={fixing ? fixing.id : 'new'}>
                        <p className="text-sm font-medium">{fixing ? t('energy.correctTitle', { at: fixing.readAt }) : t('energy.recordTitle')}</p>
                        {fixing && (
                            <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                <input type="checkbox" checked={withdraw} onChange={(e) => setWithdraw(e.target.checked)} />
                                {t('energy.withdraw')}
                            </label>
                        )}
                        {!withdraw && (
                            <div className="flex flex-wrap items-end gap-3">
                                <div className="min-w-0 max-w-full">
                                    <span className={lbl}>{t('energy.colReadAt')}</span>
                                    <DatePicker kind="datetime" value={f.readAt} onChange={(v) => setF({ ...f, readAt: v })} className="flex" />
                                </div>
                                <label className="block">
                                    <span className={lbl}>{t('energy.registerKwh')}</span>
                                    <input type="number" min="0" step="any" value={f.registerKwh} onChange={(e) => setF({ ...f, registerKwh: e.target.value })}
                                           className={`${CONTROL_INPUT} w-32`} />
                                </label>
                                <label className="inline-flex items-center gap-2 text-sm min-h-[44px]">
                                    <input type="checkbox" checked={f.reset} onChange={(e) => setF({ ...f, reset: e.target.checked })} />
                                    {t('energy.registerResetLabel')}
                                </label>
                            </div>
                        )}
                        {!withdraw && f.reset && (
                            <label className="block">
                                <span className={lbl}>{t('energy.resetReason')}</span>
                                <input type="text" value={f.resetReason} onChange={(e) => setF({ ...f, resetReason: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        )}
                        {!withdraw && (
                            <label className="block">
                                <span className={lbl}>{t('energy.notes')}</span>
                                <input type="text" value={f.notes} onChange={(e) => setF({ ...f, notes: e.target.value })} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        )}
                        {fixing && (
                            <label className="block">
                                <span className={lbl}>{t('energy.correctionReason')}</span>
                                <input type="text" value={why} onChange={(e) => setWhy(e.target.value)} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        )}
                        <div className="flex flex-wrap gap-2">
                            <Button type="button" disabled={pending || missing} onClick={save}>
                                {fixing ? (withdraw ? t('energy.withdrawSubmit') : t('energy.correctSubmit')) : t('energy.recordSubmit')}
                            </Button>
                            {fixing && (
                                <Button type="button" variant="ghost" disabled={pending} onClick={() => { setFixing(null); setWithdraw(false); setF(blank()); setError(null) }}>
                                    {t('common.cancel')}
                                </Button>
                            )}
                        </div>
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('energy.readingHint')}</p>
                    </div>
                </PermissionGate>
            )}
        </section>
    )
}
