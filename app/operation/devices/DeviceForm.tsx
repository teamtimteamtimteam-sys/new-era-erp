'use client'

// app/operation/devices/DeviceForm.tsx
// MES-1(2026-10-06):登记一台设备 / 改一台设备 —— 同一张表单,两种用法。
//   · 新登记(/operation/devices):名字、种类、带它的网关、数据类、工位、机器、网关的心跳间隔。其余在设备页上补。
//   · 修改(/operation/devices/[id]):种类与编号不动(库里的守卫按名拒),其余每一格都在这里,包括采购合同的六条数据接口条款。
// 【闸归闸、开合归开合】(DBLOCK-1):调用方把整块包在 <PermissionGate code="action.manage_devices"> 里;
//   修改那一块有「取消」,所以修改的那一块由一个已上了闸的「修改」钮打开,自己不再套闸(DowntimePanel 同一条理由)。
// 【每一个禁用条件各一句】(FIX-2(F))—— 名字为空、种类没选,各自说出来。
import { useState, useTransition, type ReactNode } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { saveDevice, type DeviceFields } from './actions'
import { DEVICE_KINDS, INTERFACE_STATUSES, TERM_KEYS, TERM_VALUES, type DeviceValues, type Option } from './deviceFields'

export type { DeviceValues, Option } from './deviceFields'

export default function DeviceForm({
    deviceId, initial, gateways, classes, equipment, onDone,
}: {
    /** 为空 = 新登记 */
    deviceId: string | null
    initial: DeviceValues
    gateways: Option[]
    classes: Option[]
    equipment: Option[]
    /** 修改那一块的「取消」/ 存好之后合上 */
    onDone?: () => void
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [v, setV] = useState<DeviceValues>(initial)
    const [error, setError] = useState<string | null>(null)
    const creating = deviceId === null
    const isGateway = v.kind === 'gateway'
    const set = (k: keyof DeviceValues) => (e: { target: { value: string } }) => setV({ ...v, [k]: e.target.value })

    function submit() {
        setError(null)
        const fields: DeviceFields = {
            name: v.name, gateway_id: isGateway ? null : v.gateway_id || null, data_class: isGateway ? null : v.data_class || null,
            equipment_id: v.equipment_id || null, station: v.station, heartbeat_interval_s: isGateway ? v.heartbeat_interval_s : null,
        }
        if (creating) fields.kind = v.kind
        if (!creating) {
            Object.assign(fields, {
                capacity: v.capacity, resolution: v.resolution, unit: v.unit, protection_rating: v.protection_rating,
                interface_status: v.interface_status, notes: v.notes,
            })
            for (const k of TERM_KEYS) fields[k] = v[k]
        }
        start(async () => {
            const r = await saveDevice(deviceId, fields)
            if (r.error) { setError(r.error); return }
            if (creating && r.id) { router.push(`/operation/devices/${r.id}`); return }
            onDone?.()
            router.refresh()
        })
    }

    const field = (label: string, control: ReactNode, hint?: string) => (
        <label className="block">
            <span className="block text-xs text-[color:var(--brand-muted-text)]">{label}</span>
            {control}
            {hint && <span className="mt-1 block text-xs text-[color:var(--brand-muted-text)]">{hint}</span>}
        </label>
    )

    return (
        <div className="max-w-xl space-y-3 rounded border border-[color:var(--brand-border)] p-4 text-sm" data-device-form={creating ? 'new' : deviceId ?? ''}>
            {field(t('devices.form.name'), <input value={v.name} onChange={set('name')} className={`${CONTROL_INPUT} w-full`} />,
                t('devices.form.nameHint'))}
            {creating
                ? field(t('devices.form.kind'), (
                    <select value={v.kind} onChange={set('kind')} className={`${CONTROL_SELECT} w-full`}>
                        <option value="">{t('devices.form.kindChoose')}</option>
                        {DEVICE_KINDS.map((k) => <option key={k} value={k}>{t('devices.kind.' + k)}</option>)}
                    </select>))
                : field(t('devices.form.kind'), <span className="block py-1">{t('devices.kind.' + v.kind)}</span>, t('devices.form.kindFixed'))}
            {isGateway
                ? field(t('devices.form.heartbeat'), (
                    <input inputMode="numeric" value={v.heartbeat_interval_s} onChange={set('heartbeat_interval_s')}
                           className={`${CONTROL_INPUT} w-full`} placeholder={t('devices.notYetSet')} />), t('devices.form.heartbeatHint'))
                : (
                    <>
                        {field(t('devices.form.gateway'), (
                            <select value={v.gateway_id} onChange={set('gateway_id')} className={`${CONTROL_SELECT} w-full`}>
                                <option value="">{t('devices.form.gatewayNone')}</option>
                                {gateways.map((g) => <option key={g.id} value={g.id}>{g.label}</option>)}
                            </select>), t('devices.form.gatewayHint'))}
                        {field(t('devices.form.dataClass'), (
                            <select value={v.data_class} onChange={set('data_class')} className={`${CONTROL_SELECT} w-full`}>
                                <option value="">{t('devices.form.dataClassNone')}</option>
                                {classes.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
                            </select>))}
                    </>
                )}
            {field(t('devices.form.station'), <input value={v.station} onChange={set('station')} className={`${CONTROL_INPUT} w-full`} />)}
            {field(t('devices.form.machine'), (
                <select value={v.equipment_id} onChange={set('equipment_id')} className={`${CONTROL_SELECT} w-full`}>
                    <option value="">{t('devices.form.machineNone')}</option>
                    {equipment.map((m) => <option key={m.id} value={m.id}>{m.label}</option>)}
                </select>), t('devices.form.machineHint'))}
            {!creating && (
                <>
                    {field(t('devices.form.interfaceStatus'), (
                        <select value={v.interface_status} onChange={set('interface_status')} className={`${CONTROL_SELECT} w-full`}>
                            {INTERFACE_STATUSES.map((s) => <option key={s} value={s}>{t('devices.interface.' + s)}</option>)}
                        </select>))}
                    {!isGateway && (
                        <>
                            {field(t('devices.form.capacity'), <input inputMode="decimal" value={v.capacity} onChange={set('capacity')} className={`${CONTROL_INPUT} w-full`} />)}
                            {field(t('devices.form.resolution'), <input inputMode="decimal" value={v.resolution} onChange={set('resolution')} className={`${CONTROL_INPUT} w-full`} />)}
                            {field(t('devices.form.unit'), <input value={v.unit} onChange={set('unit')} className={`${CONTROL_INPUT} w-full`} />)}
                        </>
                    )}
                    {field(t('devices.form.protection'), <input value={v.protection_rating} onChange={set('protection_rating')} className={`${CONTROL_INPUT} w-full`} />)}
                    <fieldset className="space-y-2">
                        <legend className="text-xs font-medium">{t('devices.terms.title')}</legend>
                        {TERM_KEYS.map((k) => field(t('devices.terms.' + k), (
                            <select key={k} value={v[k]} onChange={set(k)} className={`${CONTROL_SELECT} w-full`}>
                                {TERM_VALUES.map((s) => <option key={s} value={s}>{t('devices.termState.' + s)}</option>)}
                            </select>)))}
                    </fieldset>
                    {field(t('devices.form.notes'), <input value={v.notes} onChange={set('notes')} className={`${CONTROL_INPUT} w-full`} />)}
                </>
            )}
            <div className="flex flex-wrap items-center gap-2">
                <Button type="button" size="sm" disabled={pending || !v.name.trim() || (creating && !v.kind)} onClick={submit}>
                    {creating ? t('devices.form.register') : t('common.save')}
                </Button>
                {!v.name.trim() && <span className="text-xs text-amber-700">{t('devices.form.needName')}</span>}
                {creating && !v.kind && <span className="text-xs text-amber-700">{t('devices.form.needKind')}</span>}
                {!creating && onDone && (
                    <Button type="button" size="sm" variant="secondary" disabled={pending} onClick={onDone}>{t('common.cancel')}</Button>
                )}
            </div>
            {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
        </div>
    )
}
