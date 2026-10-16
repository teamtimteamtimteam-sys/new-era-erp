'use client'

// MES-8a(MES-8 Step 0 Q9):把这一份对账单从冻下来的那一行渲染一次、存进私有桶、记下版本与 sha256(POST ./pdf)。
//   缺 module.finance.edit 时看得见、按不动、说出码(DBLOCK-1);被取代的那一份不再存档(库按名拒,这里不画按钮)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function ArchiveButton({ statementId, canArchive }: { statementId: string; canArchive: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState('')
    return (
        <PermissionGate code="module.finance.edit" allowed={canArchive}>
            <div className="space-y-1" data-form="archive-supplier-statement">
                <Button type="button" disabled={pending} onClick={() => { setError(''); setSaved(''); startTransition(async () => {
                    const res = await fetch(`/finance/supplier-statements/${statementId}/pdf`, { method: 'POST' })
                    const body = await res.text()
                    if (!res.ok) { setError(body); return }
                    const v = (JSON.parse(body) as { version?: number }).version
                    setSaved(t('supplierStatements.archived', { version: String(v ?? '') }))
                    router.refresh()
                }) }}>
                    {pending ? t('common.saving') : t('supplierStatements.archive')}
                </Button>
                {error && <p className="text-sm text-red-600" data-error="archive">{error}</p>}
                {saved && <p className="text-sm text-green-700" data-saved="archive">{saved}</p>}
            </div>
        </PermissionGate>
    )
}
