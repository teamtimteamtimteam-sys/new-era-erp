'use client'

// app/operation/devices/KeysPanel.tsx
// MES-1(2026-10-06,MES-0 Q5 · §3.4):一台网关的钥匙 —— 发、看(只看前缀)、撤。
//   · 发:密钥只在这一次显示(从动作的返回值来,只活在这个组件的 state 里)—— 关掉这一块它就没了;库里只有哈希。
//   · 撤:要理由;下一次调用就生效。轮换 = 发第二把 → 网关换上 → 撤第一把,线不停(最多两把有效)。
//   · 哈希:哪里都不显示(Q20)—— 这一块读的是 gateway_keys_masked 的前缀那几列。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { issueGatewayKey, revokeGatewayKey } from './actions'

/** 时刻由页面在服务端排好(审计戳那一族);这里只摆。 */
export type KeyRow = {
    id: string; prefix: string; issued_at: string; revoked_at: string | null
    revoked_by: string | null; revoke_reason: string | null
}

export default function KeysPanel({ gatewayId, gatewayCode, rows, canManage, retired }: {
    gatewayId: string; gatewayCode: string; rows: KeyRow[]; canManage: boolean; retired: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [secret, setSecret] = useState<string | null>(null)
    const [error, setError] = useState<string | null>(null)
    const active = rows.filter((r) => !r.revoked_at).length

    function issue() {
        setError(null)
        start(async () => {
            const r = await issueGatewayKey(gatewayId)
            if (r.error) { setError(r.error); return }
            setSecret(r.secret ?? null)
            router.refresh()
        })
    }
    function revoke(id: string, reason: string) {
        setError(null)
        start(async () => {
            const r = await revokeGatewayKey(gatewayId, id, reason)
            if (r.error) { setError(r.error); return }
            router.refresh()
        })
    }

    const columns: Column<KeyRow>[] = [
        { key: 'prefix', header: t('devices.keys.colKey'), priority: true,
          render: (r) => <span className="font-mono">{`ngk_${r.prefix}…`}</span> },
        { key: 'state', header: t('devices.keys.colState'), priority: true,
          render: (r) => r.revoked_at ? t('devices.keys.revoked') : t('devices.keys.active') },
        { key: 'issued', header: t('devices.keys.colIssued'), render: (r) => r.issued_at },
        { key: 'revoked', header: t('devices.keys.colRevoked'),
          render: (r) => r.revoked_at ? `${r.revoked_at} · ${r.revoke_reason ?? ''}` : '—' },
        { key: 'actions', header: '', priority: true, className: 'whitespace-nowrap',
          render: (r) => r.revoked_at ? null : (
              <PermissionGate code="action.manage_devices" allowed={canManage} inline>
                  <ConfirmButton
                      subject={`ngk_${r.prefix}… · ${gatewayCode}`}
                      title={t('devices.keys.revokeTitle')}
                      body={t('devices.keys.revokeBody')}
                      confirmLabel={t('devices.keys.revoke')}
                      tier="destructive"
                      reason={{ placeholder: t('devices.keys.revokePlaceholder') }}
                      triggerVariant="outline"
                      triggerSize="xs"
                      disabled={pending}
                      onConfirm={(reason) => revoke(r.id, reason)}
                  >
                      {t('devices.keys.revoke')}
                  </ConfirmButton>
              </PermissionGate>
          ) },
    ]

    return (
        <div className="space-y-3 text-sm">
            <DataTable rows={rows} columns={columns} rowKey={(r) => r.id} phone={{ mode: 'columns' }} empty={t('devices.keys.none')} />
            <p className="text-xs text-[color:var(--brand-muted-text)]">{t('devices.keys.rotateHint')}</p>
            {!retired && (
                <PermissionGate code="action.manage_devices" allowed={canManage}>
                    <Button type="button" size="sm" variant="outline" disabled={pending || active >= 2} onClick={issue}>
                        {t('devices.keys.issue')}
                    </Button>
                    {active >= 2 && <span className="ml-2 text-xs text-amber-700">{t('devices.keys.twoActive')}</span>}
                </PermissionGate>
            )}
            {secret && (
                <div className="max-w-full rounded border border-amber-400 bg-amber-50 p-3" data-gateway-secret-shown="1">
                    <p className="font-medium">{t('devices.keys.secretTitle')}</p>
                    <p className="mt-1 break-all font-mono text-xs">{secret}</p>
                    <p className="mt-1 text-xs">{t('devices.keys.secretOnce')}</p>
                    <Button type="button" size="xs" variant="secondary" className="mt-2" onClick={() => setSecret(null)}>
                        {t('devices.keys.secretDone')}
                    </Button>
                </div>
            )}
            {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
        </div>
    )
}
