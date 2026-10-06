'use client'

// app/operation/devices/DeviceControls.tsx
// MES-1(2026-10-06):设备页上的两个动作 —— 修改(打开那张表单)与停用(要理由,不删)。
//   两个钮都上 action.manage_devices 的闸(看得见、按不动、说出缺哪个码);修改那一块有「取消」,所以它自己不再套闸。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import DeviceForm, { type DeviceValues, type Option } from './DeviceForm'
import { retireDevice } from './actions'

export default function DeviceControls({ deviceId, code, initial, gateways, classes, equipment, canManage, retired }: {
    deviceId: string; code: string; initial: DeviceValues; gateways: Option[]; classes: Option[]; equipment: Option[]
    canManage: boolean; retired: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [editing, setEditing] = useState(false)
    const [error, setError] = useState<string | null>(null)

    if (retired) return null
    return (
        <div className="space-y-3">
            {!editing && (
                <PermissionGate code="action.manage_devices" allowed={canManage}>
                    <div className="flex flex-wrap gap-2">
                        <Button type="button" size="sm" variant="outline" onClick={() => setEditing(true)}>{t('devices.edit')}</Button>
                        <ConfirmButton
                            subject={code}
                            title={t('devices.retireTitle')}
                            body={t('devices.retireBody')}
                            confirmLabel={t('devices.retire')}
                            tier="destructive"
                            reason={{ placeholder: t('devices.retirePlaceholder') }}
                            triggerVariant="outline"
                            triggerSize="sm"
                            disabled={pending}
                            onConfirm={(reason) => {
                                setError(null)
                                start(async () => {
                                    const r = await retireDevice(deviceId, reason)
                                    if (r.error) { setError(r.error); return }
                                    router.refresh()
                                })
                            }}
                        >
                            {t('devices.retire')}
                        </ConfirmButton>
                    </div>
                </PermissionGate>
            )}
            {editing && (
                <DeviceForm deviceId={deviceId} initial={initial} gateways={gateways.filter((g) => g.id !== deviceId)}
                            classes={classes} equipment={equipment} onDone={() => setEditing(false)} />
            )}
            {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
        </div>
    )
}
