// MES-9c(2026-10-20,MES-9 Step 0 §5 · Q19,Tim):供应商页上的「门户交上来的证书」一块 —— 这一家的门户账号交上来的每一份证书。
//   读 module.suppliers.view(页面的门本来就是它;表的读策略同一个码)。等审核的排在前面,每一份底下:看文件 · 接受 · 驳回
//   (PortalSubmissionForms;接受与驳回 module.suppliers.edit —— Q19,看得见、按不动、说出码)。审过的照直写:谁、什么时候、驳回的理由、
//   接受时建的那张证书在上面的合规证书那一块里。传到一半(uploading)与没传成的(abandoned)不列 —— 那不是一份申请。
//   【一份申请在被接受之前什么都不改】这句话就写在这一块的说明里。
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import ActorName, { loadActorNames } from '@/app/components/ActorName'
import PortalSubmissionForms from './PortalSubmissionForms'

type SubmissionRow = {
    id: string
    user_id: string
    cert_type_code: string
    cert_no: string | null
    valid_from: string | null
    valid_until: string | null
    file_name: string
    file_size: number
    status: 'submitted' | 'accepted' | 'rejected'
    submitted_at: string
    decided_at: string | null
    decided_by: string | null
    reject_reason: string | null
}

export default async function PortalSubmissionsPanel({ supplierId }: { supplierId: string }) {
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [subRes, typeRes] = await Promise.all([
        supabase.from('portal_certificate_submissions')
            .select('id, user_id, cert_type_code, cert_no, valid_from, valid_until, file_name, file_size, status, submitted_at, decided_at, decided_by, reject_reason')
            .eq('supplier_id', supplierId).in('status', ['submitted', 'accepted', 'rejected'])
            .order('submitted_at', { ascending: false }),
        supabase.from('certificate_types').select('code, name_en, name_zh'),
    ])
    const rows = mustRows(subRes, 'portal_certificate_submissions') as unknown as SubmissionRow[]
    const types = mustRows(typeRes, 'certificate_types') as unknown as { code: string; name_en: string; name_zh: string }[]
    const typeName = new Map(types.map((x) => [x.code, locale === 'zh' ? x.name_zh : x.name_en]))
    const canReview = await can('module.suppliers.edit')
    const names = await loadActorNames(supabase, rows.flatMap((r) => [r.user_id, r.decided_by]))
    const ordered = [...rows.filter((r) => r.status === 'submitted'), ...rows.filter((r) => r.status !== 'submitted')]
    const kb = (n: number) => `${Math.max(1, Math.round(n / 1024))} KB`

    return (
        <section className="mt-6" data-section="supplier-portal-submissions">
            <h2 className="mb-1">{t('portal.review.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2 max-w-3xl">{t('portal.review.what')}</p>
            {ordered.length === 0 ? (
                <p className="text-sm" data-empty="portal-submissions">{t('portal.review.none')}</p>
            ) : (
                <ul className="space-y-2">
                    {ordered.map((r) => (
                        <li key={r.id} className="border border-gray-200 rounded px-3 py-2 text-sm" data-portal-submission={r.id} data-state={r.status}>
                            <div className="flex flex-wrap gap-x-3 gap-y-1">
                                <span className="font-medium">{typeName.get(r.cert_type_code) ?? r.cert_type_code}</span>
                                <span className="break-all">{r.cert_no ?? t('portal.review.noNumber')}</span>
                                <span className="text-xs px-2 py-0.5 rounded bg-gray-100">
                                    {r.status === 'submitted' ? t('portal.review.stateWaiting') : r.status === 'accepted' ? t('portal.review.stateAccepted') : t('portal.review.stateRejected')}
                                </span>
                            </div>
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1 break-all">
                                {r.file_name} · {kb(r.file_size)}
                                {(r.valid_from || r.valid_until) && ` · ${t('portal.review.validity', { from: r.valid_from ? formatDate(r.valid_from, locale) : '—', to: r.valid_until ? formatDate(r.valid_until, locale) : '—' })}`}
                            </p>
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                                {t('portal.review.submittedLine', { at: formatAuditStamp(r.submitted_at) })}{' '}
                                <ActorName userId={r.user_id} names={names} />
                            </p>
                            {r.status !== 'submitted' && r.decided_at && (
                                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                                    {r.status === 'accepted'
                                        ? t('portal.review.acceptedLine', { at: formatAuditStamp(r.decided_at) })
                                        : t('portal.review.rejectedLine', { at: formatAuditStamp(r.decided_at), reason: r.reject_reason ?? '' })}{' '}
                                    <ActorName userId={r.decided_by} names={names} />
                                </p>
                            )}
                            <PortalSubmissionForms supplierId={supplierId} submissionId={r.id} canReview={canReview} waiting={r.status === 'submitted'}
                                certNo={r.cert_no} validFrom={r.valid_from} validUntil={r.valid_until} />
                        </li>
                    ))}
                </ul>
            )}
        </section>
    )
}
