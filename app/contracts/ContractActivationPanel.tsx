'use client'

// ★ APR-8(Tim 2026-09-26,grilling Q2):合同只有 active 有效力,所以进入 active 的每一条路都经 CFO。
//   这一块逐份列出【还没生效 / 暂停着 / 正在生效】的合同,给 cco 两个动作:
//     · 草稿或暂停的 → 申请生效(要理由;CFO 看见此刻的条款与上一次批准时那一份的差别)
//     · 生效中的 → 暂停(一步 —— 只会让效力变少;暂停之后条款改得了,改完再申请生效)
//   挂着一张在等的申请时两个动作都按不动,说出是哪一张。码的那一半看得见、按不动、带理由(DBLOCK-1)。
import { useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { submitContractActivation, suspendContract } from '@/app/components/pricing/termsRequestActions'

export type ActivationRow = {
    id: string
    code: string
    title: string
    status: 'draft' | 'suspended' | 'active'
    statusLabel: string
    /** 挂着的那一张在等的申请的 label;null = 没有 */
    openLabel: string | null
}

export default function ContractActivationPanel({ rows, canWrite }: { rows: ActivationRow[]; canWrite: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()

    function run(subject: string, fn: () => Promise<{ error?: string; detail?: string }>) {
        start(async () => {
            const r = await fn()
            if (r?.error) {
                showActionMessage({ subject, headline: t('common.actionMessage.headline.notDecided'), body: r.error, detail: r.detail })
                return
            }
            router.refresh()
        })
    }

    if (rows.length === 0) return null
    return (
        <section className="space-y-2" aria-label={t('termsRequest.activationTitle')}>
            <h2 className="mb-1">{t('termsRequest.activationTitle')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('termsRequest.activationHint')}</p>
            <ul className="divide-y divide-[color:var(--brand-border)]">
                {rows.map((c) => (
                    <li key={c.id} className="py-2 flex flex-wrap items-center gap-3">
                        <span className="font-mono">{c.code}</span>
                        <span>{c.title}</span>
                        <span className="text-sm text-[color:var(--brand-muted-text)]">{c.statusLabel}</span>
                        {c.openLabel && (
                            <span className="text-sm font-medium text-amber-900">
                                {t('termsRequest.waitingOn', { label: c.openLabel })}
                            </span>
                        )}
                        <span className="ml-auto">
                            <PermissionGate code="action.contract_terms" allowed={canWrite}>
                                {c.status === 'active' ? (
                                    <ConfirmButton
                                        subject={c.code}
                                        title={t('termsRequest.suspendConfirm')}
                                        body={t('termsRequest.suspendBody')}
                                        confirmLabel={t('termsRequest.suspend')}
                                        tier="reversal"
                                        triggerVariant="outline"
                                        disabled={pending || Boolean(c.openLabel)}
                                        onConfirm={() => run(c.code, () => suspendContract(c.id))}
                                    >
                                        {t('termsRequest.suspend')}
                                    </ConfirmButton>
                                ) : (
                                    <ConfirmButton
                                        subject={c.code}
                                        title={t('termsRequest.activateConfirm')}
                                        body={t('termsRequest.activateBody')}
                                        confirmLabel={t('termsRequest.activateSubmit')}
                                        tier="destructive"
                                        triggerVariant="default"
                                        reason={{ placeholder: t('termsRequest.reasonPlaceholder') }}
                                        disabled={pending || Boolean(c.openLabel)}
                                        onConfirm={(reason) => run(c.code, () => submitContractActivation(c.id, reason))}
                                    >
                                        {t('termsRequest.activateSubmit')}
                                    </ConfirmButton>
                                )}
                            </PermissionGate>
                        </span>
                    </li>
                ))}
            </ul>
        </section>
    )
}
