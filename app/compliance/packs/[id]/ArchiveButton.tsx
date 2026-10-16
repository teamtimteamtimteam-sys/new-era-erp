'use client'

// MES-8b-1(MES-8 Step 0 Q16):把这一份合规包从冻下来的 payload 渲染一次、存进私有桶、记下版本与 sha256(POST ./pdf)。
//   缺 action.compliance_pack 时看得见、按不动、说出码;被取代的那一份不再存档(库按名拒,这里不画按钮)。
import { useState, useTransition } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export default function ArchiveButton({ packId, canArchive }: { packId: string; canArchive: boolean }) {
    const t = useTranslations()
    const router = useRouter()
    const [pending, startTransition] = useTransition()
    const [error, setError] = useState('')
    const [saved, setSaved] = useState('')
    return (
        <PermissionGate code="action.compliance_pack" allowed={canArchive}>
            <div className="space-y-1" data-form="archive-compliance-pack">
                <Button type="button" disabled={pending} onClick={() => { setError(''); setSaved(''); startTransition(async () => {
                    const res = await fetch(`/compliance/packs/${packId}/pdf`, { method: 'POST' })
                    const body = await res.text()
                    if (!res.ok) { setError(body); return }
                    const v = (JSON.parse(body) as { version?: number }).version
                    setSaved(t('compliancePacks.archived', { version: String(v ?? '') }))
                    router.refresh()
                }) }}>
                    {pending ? t('common.saving') : t('compliancePacks.archive')}
                </Button>
                {error && <p className="text-sm text-red-600" data-error="archive">{error}</p>}
                {saved && <p className="text-sm text-green-700" data-saved="archive">{saved}</p>}
            </div>
        </PermissionGate>
    )
}
