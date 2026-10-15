'use client'

// app/output/[id]/edit/CoaIssueForm.tsx
// MES-6b-2(MES-6b Step 0 Q10 · Q29):签发一张分析证书 —— 选"不点名"或一张销售单;那一项此刻的拒绝(服务端已经说成人话)一句一行;
//   预览(照此刻的数据,带水印 —— 不是证书)与签发钮。签发走路由的 POST:它铸号、渲染、存桶、记哈希,一条路。
//   ☞ 有拒绝时签发钮看得见、按不动,旁边就是拒绝本身(库里同样会按名拒 —— 这里只是先说);缺码时 PermissionGate 点名 action.issue_coa。
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export type CoaChoice = { id: string | null; label: string; blockers: string[] }

export default function CoaIssueForm({ batchId, choices, canIssue }: {
    batchId: string
    choices: CoaChoice[]
    canIssue: boolean
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pick, setPick] = useState(0)
    const [busy, setBusy] = useState(false)
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState<string | null>(null)
    const c = choices[pick] ?? choices[0]
    const blocked = c.blockers.length > 0

    async function onIssue() {
        setBusy(true); setError(null); setDone(null)
        const res = await fetch(`/output/${batchId}/coa/pdf`, {
            method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ salesOrderId: c.id }),
        })
        setBusy(false)
        if (!res.ok) { setError(await res.text()); return }
        const j = (await res.json()) as { code: string }
        setDone(t('coa.issued', { code: j.code }))
        router.refresh()
    }

    return (
        <div className="rounded border p-4" data-form="coa-issue">
            <div className="flex flex-wrap items-end gap-3">
                <label className="text-sm flex flex-col gap-1">
                    <span className="text-[color:var(--brand-muted-text)]">{t('coa.panel.forOrder')}</span>
                    <select className="border rounded px-2 py-1 bg-[color:var(--surface)]" value={pick}
                        onChange={(e) => { setPick(Number(e.target.value)); setError(null); setDone(null) }}>
                        {choices.map((x, i) => <option key={x.id ?? 'none'} value={i}>{x.label}</option>)}
                    </select>
                </label>
                <a className="app-link underline text-sm pb-1.5" target="_blank" rel="noopener noreferrer"
                   href={`/output/${batchId}/coa/pdf${c.id ? `?so=${c.id}` : ''}`}>{t('coa.preview')}</a>
                <PermissionGate code="action.issue_coa" allowed={canIssue} inline>
                    <Button onClick={onIssue} disabled={busy || blocked}>{busy ? t('common.saving') : t('coa.issueButton')}</Button>
                </PermissionGate>
            </div>
            {blocked ? (
                <div className="mt-3 text-sm" data-state-note="coa-blocked">
                    <p className="font-medium">{t('coa.panel.blockedTitle')}</p>
                    <ul className="list-disc pl-5">
                        {c.blockers.map((b, i) => <li key={i} className="whitespace-pre-line">{b}</li>)}
                    </ul>
                </div>
            ) : (
                <p className="mt-3 text-xs text-[color:var(--brand-muted-text)]">{t('coa.panel.issueHint')}</p>
            )}
            {done && <p className="mt-2 text-sm" role="status">{done}</p>}
            {error && <p className="mt-2 text-sm text-red-700 whitespace-pre-line">{error}</p>}
        </div>
    )
}
