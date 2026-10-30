'use client'

// CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 A · D · E · F · Q1 · Q7 · Q8 · Q10):合同页上「合同文件」那一块 ——
//   ① 每一个版本一行(未签 · 签过 · 对方签回;在用 · 已替换 · 作废),带文件名(点开取存下的字节)、大小、谁在何时传 / 签、sha256 全文;
//      签过的那一行说出签署人、职衔、时刻、盖没盖章、哪一页;作废的那一行说出理由与谁(Q7:作废的照样列出来)。
//   ② 传未签文件(草稿 / 生效中,没被签 —— Q1 · D)与对方签回件(我方签过之后 —— Q10):字节从浏览器直传(GOLIVE-2 第 9 行的形状),
//      不经过 Vercel 的函数;按文件头认 PDF;25 MB(Q12)。
//   ③ 去签字(签字页);作废(签署人或 admin,要理由)。
//   按不动的控件都看得见、说出理由(DBLOCK-1):缺码的说码,状态不对的说状态。读不到文件的人(Q8)整块是「受限」与理由,由页面画。
import { useState, useTransition } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { createClient } from '@/lib/supabase/client'
import { sniffFileType } from '@/lib/sniffFileType'
import { Button } from '@/app/components/ui/button'
import { ConfirmButton } from '@/app/components/ui/confirm-dialog'
import { showActionMessage } from '@/app/components/ui/action-message'
import { PermissionGate } from '@/app/components/ui/permission-gate'
import { Refusal } from '@/app/components/ui/refusal'
import { abandonContractFile, beginContractFile, finishContractFile, voidContractFile } from './actions'

export type FileVersionView = {
    id: string
    kind: 'original' | 'signed' | 'countersigned'
    status: 'current' | 'superseded' | 'void'
    href: string
    fileName: string
    sizeLabel: string
    sha256: string
    uploadedLine: string
    signedLine: string | null
    voidLine: string | null
    voidable: boolean
}

export type UploadSlot = { allowed: boolean; code: string; blockedReason: string | null }

export default function ContractFilesPanel({
    contractId, contractCode, versions, original, countersigned, sign, voidAllowed,
}: {
    contractId: string
    contractCode: string
    versions: FileVersionView[]
    original: UploadSlot
    countersigned: UploadSlot
    sign: { href: string; blockedReason: string | null }
    voidAllowed: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [busy, setBusy] = useState<null | 'original' | 'countersigned'>(null)
    const [pending, start] = useTransition()

    function fail(body: string, detail?: string) {
        showActionMessage({ subject: contractCode, headline: t('contractFiles.headlineNotDone'), body, detail })
    }

    async function upload(kind: 'original' | 'countersigned', file: File | null) {
        if (!file || file.size === 0) return fail(t('contractFiles.noFile'))
        setBusy(kind)
        try {
            const head = new Uint8Array(await file.slice(0, 16).arrayBuffer())
            const type = sniffFileType(head) ?? 'application/octet-stream'
            const slot = await beginContractFile({ contractId, kind, fileName: file.name || 'contract.pdf', fileType: type, fileSize: file.size })
            if (slot.error || !slot.id || !slot.path) return fail(slot.error ?? t('contractFiles.uploadFailed'), slot.detail)
            const up = await createClient().storage.from('contract-files').upload(slot.path, file, { contentType: type, upsert: false })
            if (up.error) {
                await abandonContractFile(slot.id)
                return fail(t('contractFiles.uploadFailed'))
            }
            const done = await finishContractFile(slot.id)
            if (done.error) return fail(done.error, done.detail)
            router.refresh()
        } catch {
            fail(t('contractFiles.uploadFailed'))
        } finally {
            setBusy(null)
        }
    }

    function voidIt(v: FileVersionView, reason: string) {
        start(async () => {
            const r = await voidContractFile(v.id, reason)
            if (r.error) return fail(r.error, r.detail)
            router.refresh()
        })
    }

    const kindLabel = (k: FileVersionView['kind']) => t(`contractFiles.kind.${k}`)
    const statusLabel = (s: FileVersionView['status']) => t(`contractFiles.status.${s}`)

    return (
        <section className="space-y-3" aria-label={t('contractFiles.title')} data-contract-files={contractCode}>
            <h2 className="mb-1">{t('contractFiles.title')}</h2>
            <p className="text-sm text-[color:var(--brand-muted-text)] max-w-4xl">{t('contractFiles.intro')}</p>

            {versions.length === 0 ? (
                <p className="text-sm text-[color:var(--brand-muted-text)]" data-contract-files-empty="1">{t('contractFiles.none')}</p>
            ) : (
                <ul className="divide-y divide-[color:var(--brand-border)] border-y border-[color:var(--brand-border)]">
                    {versions.map((v) => (
                        <li key={v.id} className="py-3 space-y-1 min-w-0" data-file-version={v.id} data-file-kind={v.kind} data-file-status={v.status}>
                            <div className="flex flex-wrap items-center gap-x-3 gap-y-1">
                                <span className="font-medium">{kindLabel(v.kind)}</span>
                                <span className={v.status === 'void' ? 'text-sm font-medium text-red-800' : 'text-sm text-[color:var(--brand-muted-text)]'}>
                                    {statusLabel(v.status)}
                                </span>
                                <a href={v.href} target="_blank" rel="noopener" className="app-link hover:underline break-all">{v.fileName}</a>
                                <span className="text-sm text-[color:var(--brand-muted-text)]">{v.sizeLabel}</span>
                            </div>
                            <p className="text-sm text-[color:var(--brand-muted-text)]">{v.uploadedLine}</p>
                            {v.signedLine && <p className="text-sm">{v.signedLine}</p>}
                            {v.voidLine && <p className="text-sm text-red-800">{v.voidLine}</p>}
                            <p className="text-xs text-[color:var(--brand-muted-text)]">
                                {t('contractFiles.sha256')}{' '}
                                <span className="font-mono break-all" data-file-sha256={v.sha256}>{v.sha256}</span>
                            </p>
                            {v.voidable && (
                                <PermissionGate code="action.manage_signatories" allowed={voidAllowed} inline wrap>
                                    <ConfirmButton
                                        subject={contractCode}
                                        title={t('contractFiles.voidConfirm')}
                                        body={t('contractFiles.voidBody')}
                                        confirmLabel={t('contractFiles.void')}
                                        tier="destructive"
                                        triggerVariant="outline"
                                        reason={{ placeholder: t('contractFiles.voidReasonPlaceholder') }}
                                        disabled={pending}
                                        onConfirm={(reason) => voidIt(v, reason)}
                                    >
                                        {t('contractFiles.void')}
                                    </ConfirmButton>
                                </PermissionGate>
                            )}
                        </li>
                    ))}
                </ul>
            )}

            <div className="flex flex-wrap items-start gap-x-8 gap-y-4">
                <UploadControl
                    label={t('contractFiles.uploadOriginal')} hint={t('contractFiles.uploadOriginalHint')} slot={original}
                    busy={busy === 'original'} disabled={busy !== null} busyText={t('contractFiles.uploading')} kind="original"
                    onFile={(f) => upload('original', f)} buttonLabel={t('contractFiles.upload')}
                />
                <div className="space-y-1 max-w-sm">
                    <p className="text-sm font-medium">{t('contractFiles.signTitle')}</p>
                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('contractFiles.signHint')}</p>
                    {sign.blockedReason ? (
                        <span className="inline-flex flex-col items-start gap-1">
                            <Button type="button" disabled>{t('contractFiles.sign')}</Button>
                            <Refusal className="whitespace-normal text-left" data-sign-blocked={contractCode}>{sign.blockedReason}</Refusal>
                        </span>
                    ) : (
                        <Link href={sign.href} className="app-link hover:underline font-medium" data-sign-link={contractCode}>{t('contractFiles.sign')}</Link>
                    )}
                </div>
                <UploadControl
                    label={t('contractFiles.uploadCountersigned')} hint={t('contractFiles.uploadCountersignedHint')} slot={countersigned}
                    busy={busy === 'countersigned'} disabled={busy !== null} busyText={t('contractFiles.uploading')} kind="countersigned"
                    onFile={(f) => upload('countersigned', f)} buttonLabel={t('contractFiles.upload')}
                />
            </div>
        </section>
    )
}

function UploadControl({ label, hint, slot, busy, disabled, busyText, onFile, buttonLabel, kind }: {
    label: string; hint: string; slot: UploadSlot; busy: boolean; disabled: boolean; busyText: string
    onFile: (f: File | null) => void; buttonLabel: string; kind: string
}) {
    const [file, setFile] = useState<File | null>(null)
    return (
        <div className="space-y-1 max-w-sm min-w-0" data-upload-kind={kind}>
            <p className="text-sm font-medium">{label}</p>
            <p className="text-xs text-[color:var(--brand-muted-text)]">{hint}</p>
            <PermissionGate code={slot.code} allowed={slot.allowed} wrap>
                <div className="flex flex-wrap items-center gap-2">
                    <input
                        type="file" accept="application/pdf,.pdf" className="text-sm max-w-full"
                        disabled={disabled || slot.blockedReason !== null} data-file-input={kind}
                        onChange={(e) => setFile(e.currentTarget.files?.[0] ?? null)}
                    />
                    <Button type="button" variant="outline" disabled={disabled || !file || slot.blockedReason !== null}
                            onClick={() => onFile(file)} data-upload-button={kind}>
                        {buttonLabel}
                    </Button>
                </div>
            </PermissionGate>
            {slot.allowed && slot.blockedReason && <Refusal className="whitespace-normal text-left">{slot.blockedReason}</Refusal>}
            {busy && <p className="text-sm" role="status" data-upload-busy={kind}>{busyText}</p>}
        </div>
    )
}
