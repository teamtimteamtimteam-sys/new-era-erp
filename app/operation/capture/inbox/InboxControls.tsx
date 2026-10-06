'use client'

// app/operation/capture/inbox/InboxControls.tsx
// MES-1(2026-10-06,MES-1 Step 0 Q11 · Q15):收件箱上的两种控件。
//   · ProcessReceivedButton —— "Process received":把收下的行交给分派器。门是 module.processing.view(Q11),
//     这一页本来就要它,所以这个钮不再套闸;没有 received 的行时它灰着,并说为什么。
//   · RowActions —— 失败 / 待转换的行:重试、带理由丢弃(action.manage_devices,看得见、按不动、说出缺哪个码)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { processReceived, retryInboxRow, discardInboxRow } from './actions'

export function ProcessReceivedButton({ received }: { received: number }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [note, setNote] = useState<string | null>(null)
    const [error, setError] = useState<string | null>(null)
    return (
        <div className="flex flex-wrap items-center gap-2 text-sm">
            <Button type="button" size="sm" disabled={pending || received === 0} data-inbox-process="1"
                    onClick={() => {
                        setError(null); setNote(null)
                        start(async () => {
                            const r = await processReceived()
                            if (r.error) { setError(r.error); return }
                            const c = r.counts
                            if (c) setNote(t('inbox.processed', { n: String(c.processed), ok: String(c.transformed),
                                                                    failed: String(c.failed), awaiting: String(c.awaiting) }))
                            router.refresh()
                        })
                    }}>
                {t('inbox.processReceived')}
            </Button>
            {received === 0 && <span className="text-xs text-[color:var(--brand-muted-text)]">{t('inbox.nothingReceived')}</span>}
            {note && <span className="text-xs" role="status">{note}</span>}
            {error && <span className="text-xs text-red-700" role="alert">{error}</span>}
        </div>
    )
}

export function RowActions({ id, label, canManage }: { id: number; label: string; canManage: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    const go = (fn: () => Promise<{ error?: string }>) => {
        setError(null)
        start(async () => {
            const r = await fn()
            if (r.error) { setError(r.error); return }
            router.refresh()
        })
    }
    return (
        <PermissionGate code="action.manage_devices" allowed={canManage} inline>
            <div className="flex flex-wrap items-center gap-1">
                <Button type="button" size="xs" variant="outline" disabled={pending} onClick={() => go(() => retryInboxRow(id))}>
                    {t('inbox.retry')}
                </Button>
                <ConfirmButton
                    subject={label}
                    title={t('inbox.discardTitle')}
                    body={t('inbox.discardBody')}
                    confirmLabel={t('inbox.discard')}
                    tier="destructive"
                    reason={{ placeholder: t('inbox.discardPlaceholder') }}
                    triggerVariant="outline"
                    triggerSize="xs"
                    disabled={pending}
                    onConfirm={(reason) => go(() => discardInboxRow(id, reason))}
                >
                    {t('inbox.discard')}
                </ConfirmButton>
                {error && <span className="text-xs text-red-700" role="alert">{error}</span>}
            </div>
        </PermissionGate>
    )
}
