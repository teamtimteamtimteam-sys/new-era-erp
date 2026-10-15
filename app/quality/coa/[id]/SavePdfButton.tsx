'use client'

// app/quality/coa/[id]/SavePdfButton.tsx
// MES-7a-1(2026-10-15,MES-7a Step 0 Q24,Tim):【存 PDF】—— 一张已签发、却没有存下字节的证书(签发时上传或记哈希失败留下的那一种)。
//   照它【存下的那一份快照】再渲染一遍、存进私有桶、记下哈希(路由的 POST {storeFor},经 record_coa_issue)。不铸号、不改快照。
//   只画在【已签发且没有字节】的证书上(记录状态,不画就是不画);权限由 PermissionGate 点名 action.issue_coa(看得见、按不动、说出码)。
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function SavePdfButton({ batchId, coaId, canIssue }: { batchId: string; coaId: string; canIssue: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [busy, setBusy] = useState(false)
    const [error, setError] = useState<string | null>(null)

    async function onSave() {
        setBusy(true); setError(null)
        const res = await fetch(`/output/${batchId}/coa/pdf`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ storeFor: coaId }),
        })
        setBusy(false)
        if (!res.ok) { setError(await res.text()); return }
        router.refresh()
    }

    return (
        <span className="inline-flex flex-col gap-1" data-control="coa-save-pdf">
            <PermissionGate code="action.issue_coa" allowed={canIssue} inline>
                <Button variant="secondary" onClick={onSave} disabled={busy}>{busy ? t('common.saving') : t('coa.savePdf')}</Button>
            </PermissionGate>
            <span className="text-xs text-[color:var(--brand-muted-text)]">{t('coa.savePdfHint')}</span>
            {error && <span className="text-sm text-red-700 whitespace-pre-line">{error}</span>}
        </span>
    )
}
