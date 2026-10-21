'use client'

// app/me/ClaimReceipts.tsx
// CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q2 · Q5 · Q6 · Q9 · Q12):一笔明细的收据 —— 列出来、点开(60 秒的链接)、拿掉(Q5)、再加(Q9 · Q12)。
//   /me(报销人自己)、/finance/claims(审批的人;替人提单的人也在这里传)与费用详情页(Q8,只读)共用这一块。
//   【能不能传 / 拿掉】由页面按 Q4 告诉它(单还是 submitted、看的人是这张单的人);库照样自己判(claim_receipt_begin / _remove)。
//   【手机】(Q2)一个普通的文件选择框,不强制相机 —— iPhone 与 Android 都给「拍照 · 照片图库 · 文件」。
import { useRef, useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { CONTROL_FILE_BUTTON } from '@/app/components/ui/control-style'
import { receiptLink, removeReceipt } from './claimReceiptActions'
import { prepareReceipt, uploadReceipt, RECEIPT_ACCEPT, type ReceiptLimits, type PrepareFailure } from './uploadClaimReceipt'

export type ReceiptRow = { id: string; item_id: string; file_name: string }

// 准备失败的每一种原因一句话(静态键,check-i18n 逐条认得出)
export const PREPARE_FAILURE_KEYS: Record<PrepareFailure, string> = {
    heicUnreadable: 'expenseClaims.receipts.prepareHeicUnreadable',
    wordExcel: 'expenseClaims.receipts.prepareWordExcel',
    typeNotAccepted: 'expenseClaims.receipts.prepareTypeNotAccepted',
    tooLarge: 'expenseClaims.receipts.prepareTooLarge',
    imageUnreadable: 'expenseClaims.receipts.prepareImageUnreadable',
    limitsNotSet: 'expenseClaims.receipts.prepareLimitsNotSet',
}

export default function ClaimReceipts({
    itemId, receipts, canUpload, limits,
}: { itemId: string; receipts: ReceiptRow[]; canUpload: boolean; limits: ReceiptLimits | null }) {
    const t = useTranslations()
    const router = useRouter()
    const fileRef = useRef<HTMLInputElement>(null)
    const [error, setError] = useState<string | null>(null)
    const [pending, startTransition] = useTransition()

    const open = (id: string) => {
        // 先同步开一个窗口(手机浏览器只放行用户手势里开的窗口),拿到链接再把它指过去
        const w = window.open('', '_blank')
        setError(null)
        startTransition(async () => {
            const r = await receiptLink(id)
            if (r.url && w) { w.opener = null; w.location.href = r.url }
            else { w?.close(); setError(r.error ?? t('expenseClaims.receipts.openFailed')) }
        })
    }

    const add = () => {
        const files = Array.from(fileRef.current?.files ?? [])
        if (!files.length || !limits) return
        setError(null)
        startTransition(async () => {
            const problems: string[] = []
            for (const f of files) {
                const p = await prepareReceipt(f, limits)
                if (!p.ok) { problems.push(`${f.name}: ${t(PREPARE_FAILURE_KEYS[p.why])}`); continue }
                const e = await uploadReceipt(itemId, p)
                if (e) problems.push(`${f.name}: ${e}`)
            }
            if (fileRef.current) fileRef.current.value = ''
            if (problems.length) setError(problems.join(' · '))
            router.refresh()
        })
    }

    return (
        <span className="block text-xs">
            {receipts.length === 0 && !canUpload && <span className="text-[color:var(--brand-muted-text)]">{t('expenseClaims.receipts.none')}</span>}
            {receipts.map((r) => (
                <span key={r.id} className="mr-2 inline-flex flex-wrap items-center gap-1">
                    <Button variant="link" size="inline" type="button" className="text-left break-all" disabled={pending}
                        onClick={() => open(r.id)} title={t('expenseClaims.receipts.openHint')}>
                        {r.file_name}
                    </Button>
                    {canUpload && (
                        <Button variant="secondary" size="xs" type="button" disabled={pending}
                            aria-label={t('expenseClaims.receipts.removeAria', { name: r.file_name })}
                            onClick={() => {
                                setError(null)
                                startTransition(async () => {
                                    const x = await removeReceipt(r.id)
                                    if (x.error) setError(x.error)
                                    router.refresh()
                                })
                            }}>
                            {t('expenseClaims.receipts.remove')}
                        </Button>
                    )}
                </span>
            ))}
            {canUpload && limits && (
                <span className="mt-1 flex flex-wrap items-center gap-2">
                    <input ref={fileRef} type="file" multiple accept={RECEIPT_ACCEPT}
                        aria-label={t('expenseClaims.receipts.addAria')}
                        className={`${CONTROL_FILE_BUTTON} max-w-full`} disabled={pending} />
                    <Button variant="secondary" size="xs" type="button" disabled={pending} onClick={add}>
                        {pending ? t('expenseClaims.receipts.uploading') : t('expenseClaims.receipts.add')}
                    </Button>
                </span>
            )}
            {error && <span className="mt-1 block text-red-700">{error}</span>}
        </span>
    )
}
