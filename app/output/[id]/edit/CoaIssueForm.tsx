'use client'

// app/output/[id]/edit/CoaIssueForm.tsx
// MES-6b-2(MES-6b Step 0 Q10 · Q29):签发一张分析证书 —— 选"不点名"或一张销售单;那一项此刻的拒绝(服务端已经说成人话)一句一行;
//   预览(照此刻的数据,带水印 —— 不是证书)与签发钮。签发走路由的 POST:它铸号、渲染、存桶、记哈希,一条路。
//   ☞ 有拒绝时签发钮看得见、按不动,旁边就是拒绝本身(库里同样会按名拒 —— 这里只是先说);缺码时 PermissionGate 点名 action.issue_coa。
// ★ MES-7a-1(F9,MES-7a Step 0 Q8):签发之前说出纸上会印成谁 —— "You will be named as <名字>, <职位>"(coa_issuer(),与快照同一份解析);
//   解析不出来(不是员工 / 没有职位)时那一句拒绝摆在这里、签发钮按不动;名字或职位里有纸上的字体画不出来的字,那一句随这一项的拒绝一起摆出来。
import { useState } from 'react'
import { useRouter } from 'next/navigation'
import { useTranslations } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { PermissionGate } from '@/app/components/ui/permission-gate'

export type CoaChoice = { id: string | null; label: string; blockers: string[] }

export default function CoaIssueForm({ batchId, choices, canIssue, issuer, issuerProblem }: {
    batchId: string
    choices: CoaChoice[]
    canIssue: boolean
    /** 持码时由 coa_issuer() 解析出的签发人;不持码 = null(那时 issuerProblem 也是 null) */
    issuer: { name: string; position: string } | null
    issuerProblem: string | null
}) {
    const t = useTranslations()
    const router = useRouter()
    const [pick, setPick] = useState(0)
    const [busy, setBusy] = useState(false)
    const [error, setError] = useState<string | null>(null)
    const [done, setDone] = useState<string | null>(null)
    const c = choices[pick] ?? choices[0]
    const blocked = c.blockers.length > 0 || issuerProblem !== null

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
            {issuer && (
                <p className="mt-3 text-sm" data-field="coa-issuer">{t('coa.panel.namedAs', { name: issuer.name, position: issuer.position })}</p>
            )}
            {issuerProblem && (
                <p className="mt-3 text-sm whitespace-pre-line" data-state-note="coa-issuer-refused">{issuerProblem}</p>
            )}
            {c.blockers.length > 0 ? (
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
