'use client'

// MES-9a(2026-10-19,MES-9 Step 0 Q6 · Q8 · Q20):供应商页「门户账号」那一块的三个动作 —— 开(挑一位有邮箱、还没有门户账号的联系人,
//   设一个初始密码,当面交;第一次登录必须换)、撤销(理由必填;下一次调用就拒)、匿名化(只对已撤销的;应请求)。
//   缺 action.manage_portal_users 时整块在 PermissionGate 里(看得见、按不动、说出码)。
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { createPortalAccount, revokePortalAccount, anonymisePortalContact } from './portalActions'

const CODE = 'action.manage_portal_users'

export default function PortalAccountForms(props: {
    mode: 'create' | 'row'
    supplierId: string
    canManage: boolean
    contacts?: { id: string; label: string }[]
    linkId?: string
    revoked?: boolean
    anonymised?: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [isPending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [done, setDone] = useState('')
    const [contactId, setContactId] = useState('')
    const [password, setPassword] = useState('')
    const [reason, setReason] = useState('')
    const [revoking, setRevoking] = useState(false)

    function run(fn: () => Promise<{ error?: string; success?: boolean; email?: string }>, okText: (email?: string) => string) {
        setError(''); setDone('')
        startTransition(async () => {
            const res = await fn()
            if (res.error) { setError(res.error); router.refresh(); return }
            setDone(okText(res.email)); setPassword(''); setReason(''); setContactId(''); setRevoking(false)
            router.refresh()
        })
    }

    if (props.mode === 'create') {
        const contacts = props.contacts ?? []
        return (
            <PermissionGate code={CODE} allowed={props.canManage}>
                <div className="space-y-2 max-w-3xl" data-form="portal-create">
                    <h3 className="text-sm font-medium">{t('portal.createTitle')}</h3>
                    {error && <p className="text-sm text-red-600" data-error="portal-create">{error}</p>}
                    {done && <p className="text-sm text-green-700" data-saved="portal-create">{done}</p>}
                    {contacts.length === 0 ? (
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('portal.noEligibleContact')}</p>
                    ) : (
                        <div className="flex flex-wrap gap-3 items-end">
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.contact')} <span className="text-red-600">*</span></span>
                                <select value={contactId} onChange={(e) => setContactId(e.target.value)} className={`${CONTROL_SELECT} w-full`} data-field="contact_id">
                                    <option value="">{t('portal.chooseContact')}</option>
                                    {contacts.map((c) => <option key={c.id} value={c.id}>{c.label}</option>)}
                                </select>
                            </label>
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.initialPassword')} <span className="text-red-600">*</span></span>
                                <input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)}
                                       className={`${CONTROL_INPUT} w-full`} data-field="initial_password" />
                            </label>
                            <Button type="button" disabled={!contactId || !password || isPending}
                                onClick={() => run(() => createPortalAccount({ supplierId: props.supplierId, contactId, password }),
                                                   (email) => t('portal.created', { email: email ?? '' }))}>
                                {isPending ? t('common.saving') : t('portal.create')}
                            </Button>
                        </div>
                    )}
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('portal.createHint')}</p>
                </div>
            </PermissionGate>
        )
    }

    if (props.anonymised) return null
    return (
        <PermissionGate code={CODE} allowed={props.canManage}>
            <div className="mt-2 space-y-2" data-form="portal-row">
                {error && <p className="text-sm text-red-600" data-error="portal-row">{error}</p>}
                {done && <p className="text-sm text-green-700" data-saved="portal-row">{done}</p>}
                {!props.revoked ? (
                    revoking ? (
                        <div className="flex flex-wrap gap-2 items-end">
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.revokeReason')} <span className="text-red-600">*</span></span>
                                <input value={reason} onChange={(e) => setReason(e.target.value)} className={`${CONTROL_INPUT} w-full`} data-field="revoke_reason" />
                            </label>
                            <Button type="button" variant="destructive" disabled={!reason.trim() || isPending}
                                onClick={() => run(() => revokePortalAccount({ supplierId: props.supplierId, linkId: props.linkId!, reason }),
                                                   () => t('portal.revoked'))}>
                                {isPending ? t('common.saving') : t('portal.revokeConfirm')}
                            </Button>
                            <Button type="button" variant="secondary" disabled={isPending} onClick={() => setRevoking(false)}>{t('common.cancel')}</Button>
                        </div>
                    ) : (
                        <Button type="button" variant="secondary" onClick={() => setRevoking(true)} data-action="portal-revoke">{t('portal.revoke')}</Button>
                    )
                ) : (
                    <Button type="button" variant="secondary" disabled={isPending} data-action="portal-anonymise"
                        onClick={() => run(() => anonymisePortalContact({ supplierId: props.supplierId, linkId: props.linkId! }),
                                           () => t('portal.anonymised'))}>
                        {isPending ? t('common.saving') : t('portal.anonymise')}
                    </Button>
                )}
            </div>
        </PermissionGate>
    )
}
