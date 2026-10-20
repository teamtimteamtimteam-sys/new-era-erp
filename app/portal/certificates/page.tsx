// app/portal/certificates/page.tsx
// MES-9c(2026-10-20,MES-9 Step 0 §4 · §5 · Q19 · V39,Tim):【门户的证书】—— 调用者自己那一家在册的合规证书,它自己交上来的每一份与状态
//   (等审核 · 已接受 · 已驳回与理由),以及交一份新的。
//   读的只有 portal_certificates()(只授 supplier_portal;先过 portal_require_link)。交 = 一张 multipart 表单 POST 到
//   /portal/certificates/upload(那条路由先按 V39 问库、库按名拒,过了才以这个会话自己的令牌把字节传进 portal-uploads)。
//   【一份上传只是一份等审核的申请】—— 这一页照直说:员工接受之前,它什么都不改。
//   路由回来时带 ?submitted=1 或 ?error=<码>[&p=<参数>],这里把码说成人话(portal.errors.*)。
//   门户函数按名拒的三种(撤销了 · 会话结束了 · 令牌不是门户角色)各说一句人话;别的失败照常抛(失败不是空集)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { formatAuditStamp, formatDate } from '@/lib/dates'
import { CONTROL_INPUT, CONTROL_SELECT } from '@/app/components/ui/control-style'
import { Button } from '@/app/components/ui/button'
import { DatePicker } from '@/app/components/ui/date-picker'
import { localizePortalError, PORTAL_ERROR_CODES } from '../portalErrorCodes'

type Named = { name_en: string; name_zh: string }
type PortalCertificates = {
    supplier_code: string
    compliance: ({ cert_type_code: string; type_name_en: string; type_name_zh: string; cert_no: string | null; valid_until: string | null })[]
    submissions: {
        id: string; cert_type_code: string; type_name_en: string; type_name_zh: string; cert_no: string | null
        valid_from: string | null; valid_until: string | null; file_name: string; submitted_at: string
        state: 'waiting' | 'accepted' | 'rejected'; reject_reason: string | null; decided_at: string | null
    }[]
    types: (Named & { code: string })[]
    limits: { set: boolean; max_bytes: number | null; types: string[] | null }
}

const TYPE_LABEL: Record<string, string> = { 'application/pdf': 'PDF', 'image/jpeg': 'JPEG', 'image/png': 'PNG' }

export default async function PortalCertificatesPage({ searchParams }: { searchParams: Promise<{ submitted?: string; error?: string; p?: string }> }) {
    const t = await getTranslations()
    const locale = await getLocale()
    const sp = await searchParams
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_certificates')
    if (error) {
        const { code, text } = await localizePortalError(error.message)
        if (code === 'PORTAL_ACCESS_REVOKED' || code === 'PORTAL_SESSION_ENDED' || code === 'PORTAL_ROLE_REQUIRED') {
            return (
                <div className="p-6 max-w-2xl" data-portal-refused={code}>
                    <h1 className="mb-3">{t('portal.certificates.title')}</h1>
                    <p className="text-sm">{text}</p>
                </div>
            )
        }
        throw new Error(`查询失败(portal_certificates): ${error.code ?? ''} ${error.message}`.trim())
    }
    const d = data as unknown as PortalCertificates
    const zh = locale === 'zh'
    const typeName = (r: { type_name_en: string; type_name_zh: string }) => (zh ? r.type_name_zh : r.type_name_en)
    const maxMb = d.limits.max_bytes != null ? String(Math.round((d.limits.max_bytes / 1048576) * 10) / 10) : ''
    const typesText = (d.limits.types ?? []).map((x) => TYPE_LABEL[x] ?? x).join(' · ')

    // 路由带回来的结果:码只认门户那一族;认不出就不印(查询串是访客可改的,不把任意字符串印上屏)
    let notice: { kind: 'ok' | 'error'; text: string } | null = null
    if (sp.submitted === '1') notice = { kind: 'ok', text: t('portal.certificates.submitted') }
    else if (sp.error && PORTAL_ERROR_CODES.has(sp.error)) {
        notice = { kind: 'error', text: (await localizePortalError(sp.p ? `${sp.error}|${sp.p}` : sp.error)).text }
    } else if (sp.error === 'UPLOAD_FAILED') notice = { kind: 'error', text: t('portal.certificates.uploadFailed') }
    else if (sp.error === 'NO_FILE') notice = { kind: 'error', text: t('portal.certificates.noFile') }

    const stateText = (s: 'waiting' | 'accepted' | 'rejected') =>
        s === 'waiting' ? t('portal.certificates.stateWaiting') : s === 'accepted' ? t('portal.certificates.stateAccepted') : t('portal.certificates.stateRejected')

    return (
        <div className="p-6 max-w-4xl space-y-6" data-portal-certificates={d.supplier_code}>
            <div>
                <p className="text-sm mb-2"><Link href="/portal" className="app-link hover:underline">{t('portal.backHome')}</Link></p>
                <h1 className="mb-2">{t('portal.certificates.title')}</h1>
                <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('portal.certificates.intro')}</p>
            </div>

            {notice && (
                <p className={`text-sm max-w-3xl ${notice.kind === 'ok' ? 'text-green-700' : 'text-red-600'}`}
                   data-upload-notice={notice.kind} data-upload-code={notice.kind === 'error' ? sp.error : 'submitted'}>
                    {notice.text}
                </p>
            )}

            <section data-cert-section="on-file">
                <h2 className="mb-2">{t('portal.certificates.onFileTitle')}</h2>
                {d.compliance.length === 0 ? <p className="text-sm">{t('portal.certificates.none')}</p> : (
                    <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                        {d.compliance.map((c, i) => (
                            <li key={i} className="py-2 flex flex-wrap gap-x-6 gap-y-1">
                                <span className="font-medium min-w-[10rem]">{typeName(c)}</span>
                                <span className="min-w-[8rem] break-all">{c.cert_no ?? t('portal.certificates.noNumber')}</span>
                                <span>{c.valid_until ? t('portal.certificates.validUntil', { date: formatDate(c.valid_until, locale) }) : t('portal.certificates.noExpiry')}</span>
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            <section data-cert-section="submissions">
                <h2 className="mb-2">{t('portal.certificates.submissionsTitle')}</h2>
                {d.submissions.length === 0 ? <p className="text-sm">{t('portal.certificates.noSubmissions')}</p> : (
                    <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                        {d.submissions.map((s) => (
                            <li key={s.id} className="py-2 space-y-1" data-submission={s.id} data-state={s.state}>
                                <div className="flex flex-wrap gap-x-6 gap-y-1">
                                    <span className="font-medium min-w-[10rem]">{typeName(s)}</span>
                                    <span className="min-w-[8rem] break-all">{s.cert_no ?? t('portal.certificates.noNumber')}</span>
                                    <span className="break-all">{s.file_name}</span>
                                    <span className="text-xs text-[color:var(--brand-muted-text)]">{t('portal.certificates.submittedAt', { at: formatAuditStamp(s.submitted_at) })}</span>
                                    <span className="text-xs px-2 py-0.5 rounded bg-gray-100">{stateText(s.state)}</span>
                                </div>
                                {s.state === 'rejected' && (
                                    <p className="text-sm" data-reject-reason="1">{t('portal.certificates.rejectedBecause', { reason: s.reject_reason ?? '' })}</p>
                                )}
                                {s.state !== 'waiting' && s.decided_at && (
                                    <p className="text-xs text-[color:var(--brand-muted-text)]">{t('portal.certificates.decidedAt', { at: formatAuditStamp(s.decided_at) })}</p>
                                )}
                            </li>
                        ))}
                    </ul>
                )}
            </section>

            <section data-cert-section="upload" className="max-w-3xl">
                <h2 className="mb-1">{t('portal.certificates.uploadTitle')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-2">{t('portal.certificates.uploadWhat')}</p>
                {!d.limits.set ? (
                    <p className="text-sm" data-limits="not-set">{t('portal.errors.PORTAL_UPLOAD_LIMITS_NOT_SET')}</p>
                ) : (
                    <form action="/portal/certificates/upload" method="post" encType="multipart/form-data" className="space-y-3" data-form="portal-upload">
                        <p className="text-xs" data-limits="set">{t('portal.certificates.limits', { mb: maxMb, types: typesText })}</p>
                        <div className="flex flex-wrap gap-3">
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.certificates.type')} <span className="text-red-600">*</span></span>
                                <select name="cert_type" required defaultValue="" className={`${CONTROL_SELECT} w-full max-w-full`}>
                                    <option value="" disabled>{t('portal.certificates.chooseType')}</option>
                                    {d.types.map((ct) => <option key={ct.code} value={ct.code}>{zh ? ct.name_zh : ct.name_en}</option>)}
                                </select>
                            </label>
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.certificates.number')}</span>
                                <input name="cert_no" maxLength={120} className={`${CONTROL_INPUT} w-full`} />
                            </label>
                        </div>
                        <div className="flex flex-wrap gap-3">
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.certificates.validFrom')}</span>
                                <DatePicker name="valid_from" />
                            </label>
                            <label className="block text-sm min-w-0 basis-full sm:basis-0 flex-1">
                                <span className="block mb-1">{t('portal.certificates.validUntilLabel')}</span>
                                <DatePicker name="valid_until" />
                            </label>
                        </div>
                        <label className="block text-sm">
                            <span className="block mb-1">{t('portal.certificates.file')} <span className="text-red-600">*</span></span>
                            <input type="file" name="file" required accept=".pdf,.jpg,.jpeg,.png,application/pdf,image/jpeg,image/png"
                                   className="block w-full max-w-full text-sm" />
                        </label>
                        <Button type="submit">{t('portal.certificates.submit')}</Button>
                        <p className="text-xs text-[color:var(--brand-muted-text)]">{t('portal.certificates.reviewNote')}</p>
                    </form>
                )}
            </section>
        </div>
    )
}
