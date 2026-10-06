'use client'

// app/operation/weighbridge/[id]/TicketControls.tsx
// MES-2(2026-10-06,MES-0 Q19 · Q20;MES-2 Step 0 Q16–Q21):一张地磅单上的客户端控件。
//   · ShareForm      —— 分一份给收货单(进厂单)或发货行(出厂单);公斤数默认 = 还没分出去的那部分
//   · VoidTicket     —— 作废(理由必填;分出去过就按不动 —— 库里按名拒,这里先说)
//   · PhotoPanel     —— 传照片(直传私有桶,再落登记行)、点开(60 秒签名链接)、撤下(理由必填)
// 控件看得见、按不动、说出缺哪个码(DBLOCK-1)。
import { useRef, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { createClient } from '@/lib/supabase/client'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { CONTROL_FILE_BUTTON, CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { shareTicket, voidTicket, recordTicketPhoto, withdrawTicketPhoto, ticketPhotoUrl } from '../actions'
import { PHOTO_BUCKET, PHOTO_MAX_BYTES, PHOTO_TYPES } from '../ticketFields'
import type { Option } from '@/app/operation/capture/captureFields'

export function ShareForm({ ticketId, direction, targets, defaultKg, allowed, code }: {
    ticketId: string; direction: string; targets: Option[]; defaultKg: number; allowed: boolean; code: string
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [target, setTarget] = useState(targets[0]?.id ?? '')
    const [kg, setKg] = useState(defaultKg > 0 ? String(defaultKg) : '')
    const [error, setError] = useState<string | null>(null)
    const kind = direction === 'inbound' ? 'receipt' : 'line'
    return (
        <PermissionGate code={kind === 'receipt' ? 'action.receive_goods' : 'action.ship_goods'} allowed={allowed}>
            <div className="max-w-xl space-y-2 text-sm">
                <div className="flex flex-wrap gap-2">
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">
                            {kind === 'receipt' ? t('weighbridge.shareToReceipt') : t('weighbridge.shareToLine')}
                        </span>
                        <select className={`${CONTROL_SELECT} w-full`} value={target} onChange={(e) => setTarget(e.target.value)} data-ticket-share-target="1">
                            {targets.length === 0 && <option value="">{t('weighbridge.noTargets')}</option>}
                            {targets.map((o) => <option key={o.id} value={o.id}>{o.label}</option>)}
                        </select>
                    </label>
                    <label className="block min-w-0 flex-1">
                        <span className="block text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.shareKg')}</span>
                        <input inputMode="decimal" className={`${CONTROL_INPUT} w-full`} value={kg} onChange={(e) => setKg(e.target.value)} />
                    </label>
                </div>
                <p className="text-xs text-[color:var(--brand-muted-text)]">
                    {kind === 'receipt' ? t('weighbridge.shareReceiptHint') : t('weighbridge.shareLineHint')}
                </p>
                <Button type="button" size="sm" disabled={pending || target === '' || kg.trim() === ''} data-ticket-share="1"
                        onClick={() => {
                            setError(null)
                            start(async () => {
                                const r = await shareTicket(ticketId, { kind, id: target }, kg)
                                if (r.error) { setError(r.error); return }
                                router.refresh()
                            })
                        }}>
                    {t('weighbridge.share', { code })}
                </Button>
                {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
            </div>
        </PermissionGate>
    )
}

export function VoidTicket({ ticketId, code, allowed, hasShares }: { ticketId: string; code: string; allowed: boolean; hasShares: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    return (
        <PermissionGate code="action.confirm_capture" allowed={allowed} inline>
            <div className="space-y-1">
                <ConfirmButton
                    subject={code}
                    title={t('weighbridge.voidTitle')}
                    body={t('weighbridge.voidBody')}
                    confirmLabel={t('weighbridge.void')}
                    tier="destructive"
                    reason={{ placeholder: t('weighbridge.voidPlaceholder') }}
                    triggerVariant="outline"
                    triggerSize="sm"
                    disabled={pending || hasShares}
                    onConfirm={(reason) => {
                        setError(null)
                        start(async () => {
                            const r = await voidTicket(ticketId, reason)
                            if (r.error) { setError(r.error); return }
                            router.refresh()
                        })
                    }}
                >
                    {t('weighbridge.void')}
                </ConfirmButton>
                {hasShares && <p className="text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.voidHasShares')}</p>}
                {error && <p className="text-xs text-red-700" role="alert">{error}</p>}
            </div>
        </PermissionGate>
    )
}

type Photo = { id: string; file_path: string; file_name: string; uploaded_at: string; withdrawn_at: string | null; withdraw_reason: string | null }

/** 存储键里只留安全的字符;原始文件名另存登记行用于显示。 */
function storageSafe(name: string): string {
    const s = name.normalize('NFKD').replace(/[^A-Za-z0-9._-]+/g, '_').replace(/_+/g, '_')
    return s.slice(-80) || 'photo'
}

export function PhotoPanel({ ticketId, photos, canUpload, voided }: { ticketId: string; photos: (Photo & { at: string })[]; canUpload: boolean; voided: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const fileRef = useRef<HTMLInputElement>(null)
    const [pending, start] = useTransition()
    const [error, setError] = useState<string | null>(null)
    function upload() {
        const file = fileRef.current?.files?.[0]
        if (!file) return
        if (!(PHOTO_TYPES as readonly string[]).includes(file.type)) { setError(t('weighbridge.photoType')); return }
        if (file.size > PHOTO_MAX_BYTES) { setError(t('weighbridge.photoTooLarge')); return }
        setError(null)
        start(async () => {
            const path = `${ticketId}/${crypto.randomUUID()}-${storageSafe(file.name)}`
            const { error: upErr } = await createClient().storage.from(PHOTO_BUCKET).upload(path, file, { contentType: file.type, upsert: false })
            if (upErr) { setError(t('weighbridge.photoUploadError', { message: upErr.message })); return }
            const r = await recordTicketPhoto(ticketId, path, file.name, file.type, file.size)
            if (r.error) { setError(r.error); return }
            if (fileRef.current) fileRef.current.value = ''
            router.refresh()
        })
    }
    function openPhoto(p: Photo) {
        start(async () => {
            const r = await ticketPhotoUrl(p.file_path)
            if (r.error || !r.url) { setError(r.error ?? t('weighbridge.photoOpenError')); return }
            window.open(r.url, '_blank', 'noopener')
        })
    }
    return (
        <div className="space-y-3 text-sm">
            {photos.length === 0 && <p className="text-[color:var(--brand-muted-text)]">{t('weighbridge.noPhotos')}</p>}
            <ul className="space-y-1">
                {photos.map((p) => (
                    <li key={p.id} className="flex flex-wrap items-center gap-2" data-ticket-photo={p.withdrawn_at ? 'withdrawn' : 'shown'}>
                        <Button type="button" size="xs" variant="ghost" className={p.withdrawn_at ? 'line-through' : ''}
                                onClick={() => openPhoto(p)} disabled={pending}>{p.file_name}</Button>
                        <span className="text-xs text-[color:var(--brand-muted-text)]">{p.at}</span>
                        {p.withdrawn_at
                            ? <span className="text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.photoWithdrawn', { reason: p.withdraw_reason ?? '' })}</span>
                            : (
                                <PermissionGate code="action.confirm_capture" allowed={canUpload} inline>
                                    <ConfirmButton
                                        subject={p.file_name}
                                        title={t('weighbridge.photoWithdrawTitle')}
                                        body={t('weighbridge.photoWithdrawBody')}
                                        confirmLabel={t('weighbridge.photoWithdraw')}
                                        tier="destructive"
                                        reason={{ placeholder: t('weighbridge.photoWithdrawPlaceholder') }}
                                        triggerVariant="outline"
                                        triggerSize="xs"
                                        disabled={pending}
                                        onConfirm={(reason) => start(async () => {
                                            const r = await withdrawTicketPhoto(ticketId, p.id, reason)
                                            if (r.error) { setError(r.error); return }
                                            router.refresh()
                                        })}
                                    >
                                        {t('weighbridge.photoWithdraw')}
                                    </ConfirmButton>
                                </PermissionGate>
                            )}
                    </li>
                ))}
            </ul>
            {!voided && (
                <PermissionGate code="action.confirm_capture" allowed={canUpload}>
                    <div className="flex flex-wrap items-center gap-2">
                        <input ref={fileRef} type="file" accept={PHOTO_TYPES.join(',')} className={CONTROL_FILE_BUTTON}
                               aria-label={t('weighbridge.photoChoose')} data-ticket-photo-input="1" />
                        <Button type="button" size="sm" disabled={pending} onClick={upload}>{t('weighbridge.photoUpload')}</Button>
                    </div>
                    <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">{t('weighbridge.photoHint')}</p>
                </PermissionGate>
            )}
            {error && <p className="text-sm text-red-700" role="alert">{error}</p>}
        </div>
    )
}
