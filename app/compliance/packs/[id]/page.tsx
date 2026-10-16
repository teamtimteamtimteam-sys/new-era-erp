// app/compliance/packs/[id]/page.tsx
// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q14 · Q16,Tim):一份合规包 —— 【冻下来的 payload】原样画出来(八节,与预览同一个组件)。
//   PDF:看一眼(从 payload 渲染,不落档)· 存档(渲染、存桶、记 sha256 —— action.compliance_pack)· 每一版存下的字节(取的时候重算哈希,对不上 409)。
//   被取代的那一份说出被谁取代、为什么,它的 payload 与字节一个字不动。
//   【门】requireFunction(FN.compliancePacks) = module.compliance.view。最底是它的审计记录(主语 compliance_pack)。
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { formatAuditStamp } from '@/lib/dates'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import PackSections from '../PackSections'
import type { CompliancePackPayload } from '../packTypes'
import ArchiveButton from './ArchiveButton'

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

export default async function CompliancePackPage({ params, searchParams }: {
    params: Promise<{ id: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.compliancePacks)
    if (denied) return denied
    const { id } = await params
    if (!UUID.test(id)) notFound()
    const t = await getTranslations()
    const sp = await searchParams
    const supabase = await createClient()
    const pk = mustOne(await supabase.from('compliance_packs')
        .select('id, code, period_month, period_end, locked_before_at_freeze, payload, notes, frozen_at, superseded_at, superseded_by, superseded_reason')
        .eq('id', id).maybeSingle(), 'compliance_packs') as unknown as {
            id: string; code: string; period_month: string; period_end: string; locked_before_at_freeze: string; payload: CompliancePackPayload
            notes: string | null; frozen_at: string; superseded_at: string | null; superseded_by: string | null; superseded_reason: string | null } | null
    if (!pk) notFound()
    const [issuesRes, byRes, canArchive] = await Promise.all([
        supabase.from('compliance_pack_issues').select('version, sha256, issued_at').eq('pack_id', id).order('version', { ascending: false }),
        pk.superseded_by ? supabase.from('compliance_packs').select('id, code').eq('id', pk.superseded_by).maybeSingle()
                         : Promise.resolve({ data: null, error: null }),
        can('action.compliance_pack'),
    ])
    const issues = mustRows(issuesRes, 'compliance_pack_issues') as { version: number; sha256: string; issued_at: string }[]
    const by = mustOne(byRes as never, 'compliance_packs superseded_by') as { id: string; code: string } | null

    return (
        <div className="p-4 sm:p-8 max-w-5xl">
            <div className="mb-6"><Link href="/compliance/packs" className="hover:underline text-sm app-link">{t('common.back')}</Link></div>
            <h1 className="mb-2">{pk.code}</h1>
            <p className="text-sm text-[color:var(--brand-muted-text)] mb-4">
                {t('compliancePacks.packMeta', { month: pk.period_month.slice(0, 7), at: formatAuditStamp(pk.frozen_at), locked: pk.locked_before_at_freeze })}
                {pk.notes && <>{' · '}{pk.notes}</>}
            </p>
            {pk.superseded_at && (
                <div className="bg-amber-50 border border-amber-300 px-4 py-3 rounded mb-4 text-sm" data-notice="superseded">
                    {t('compliancePacks.supersededNotice', { code: by?.code ?? '', reason: pk.superseded_reason ?? '' })}
                    {by && <>{' '}<Link href={`/compliance/packs/${by.id}`} className="app-link hover:underline">{by.code}</Link></>}
                </div>
            )}
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">{t('compliancePacks.frozenHint')}</p>

            <PackSections p={pk.payload} />

            <section className="mt-8" data-section="pdf">
                <h2 className="mb-2">{t('compliancePacks.pdfTitle')}</h2>
                <p className="text-sm mb-3">
                    <a href={`/compliance/packs/${pk.id}/pdf`} target="_blank" rel="noopener noreferrer" className="app-link hover:underline">{t('compliancePacks.viewPdf')}</a>
                    <span className="text-xs text-[color:var(--brand-muted-text)] ml-2">{t('compliancePacks.viewPdfHint')}</span>
                </p>
                {!pk.superseded_at && <ArchiveButton packId={pk.id} canArchive={canArchive} />}
                <ul className="mt-3 text-sm space-y-1" data-section="versions">
                    {issues.length === 0 ? <li className="text-[color:var(--brand-muted-text)]">{t('compliancePacks.noPdfYet')}</li> : issues.map((i) => (
                        <li key={i.version}>
                            <a href={`/compliance/packs/${pk.id}/pdf?version=${i.version}`} target="_blank" rel="noopener noreferrer" className="app-link hover:underline">
                                {t('compliancePacks.versionLink', { version: String(i.version) })}
                            </a>
                            <span className="text-xs text-[color:var(--brand-muted-text)] ml-2">{formatAuditStamp(i.issued_at)} · sha256 {i.sha256.slice(0, 12)}…</span>
                        </li>
                    ))}
                </ul>
            </section>

            <AuditTrail subject="compliance_pack" id={pk.id} show={trailCount(sp.trail)} />
        </div>
    )
}
