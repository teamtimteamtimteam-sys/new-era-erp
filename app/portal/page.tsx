// app/portal/page.tsx
// MES-9a(2026-10-19,MES-9 Step 0 §2 · Q10 · Q20,Tim):【供应商门户的首页】—— 你是谁(哪一家、哪一位联系人、登录的邮箱)、
//   你的个人资料(下载一份系统里关于你的一切 —— PDPA 的访问请求)。
// MES-9c(2026-10-20,Q19):第三个入口 —— /portal/certificates(在册证书、自己交上来的每一份与状态、交一份新的)。
// MES-9b(2026-10-19,Q14):两个入口 —— /portal/documents(签发档,只以存下的 PDF)与 /portal/deliveries(收货与地磅单,按今天的记录,没有价钱)。
//   读的只有 portal_me()(只授 supplier_portal;先过 portal_require_link:角色 · 链接 · 撤销 · 会话)。
//   门户函数按名拒的三种(撤销了 · 会话结束了 · 令牌不是门户角色)各说一句人话;别的失败照常抛(失败不是空集)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { formatAuditStamp } from '@/lib/dates'
import { localizePortalError } from './portalErrorCodes'

type PortalMe = {
    supplier: { code: string; name: string }
    contact: { name: string; role: string | null }
    account_email: string
    linked_at: string
}

export default async function PortalHomePage() {
    const t = await getTranslations()
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('portal_me')
    if (error) {
        const { code, text } = await localizePortalError(error.message)
        if (code === 'PORTAL_ACCESS_REVOKED' || code === 'PORTAL_SESSION_ENDED' || code === 'PORTAL_ROLE_REQUIRED') {
            return (
                <div className="p-6 max-w-2xl" data-portal-refused={code}>
                    <h1 className="mb-3">{t('portal.title')}</h1>
                    <p className="text-sm">{text}</p>
                </div>
            )
        }
        throw new Error(`查询失败(portal_me): ${error.code ?? ''} ${error.message}`.trim())
    }
    const me = data as unknown as PortalMe
    return (
        <div className="p-6 max-w-3xl space-y-6" data-portal-home="1">
            <div>
                <h1 className="mb-2">{t('portal.title')}</h1>
                <p className="text-sm" data-portal-supplier={me.supplier.code}>
                    {t('portal.signedInAs', { contact: me.contact.name, supplier: me.supplier.name, code: me.supplier.code })}
                </p>
                <p className="text-xs text-[color:var(--brand-muted-text)]">
                    {t('portal.accountLine', { email: me.account_email, since: formatAuditStamp(me.linked_at) })}
                </p>
            </div>
            <section data-portal-section="documents">
                <h2 className="mb-1">{t('portal.homeDocumentsTitle')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-2 max-w-2xl">{t('portal.homeDocumentsBody')}</p>
                <Link href="/portal/documents" className="text-sm app-link hover:underline">{t('portal.homeDocumentsLink')}</Link>
            </section>
            <section data-portal-section="deliveries">
                <h2 className="mb-1">{t('portal.homeDeliveriesTitle')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-2 max-w-2xl">{t('portal.homeDeliveriesBody')}</p>
                <Link href="/portal/deliveries" className="text-sm app-link hover:underline">{t('portal.homeDeliveriesLink')}</Link>
            </section>
            <section data-portal-section="certificates">
                <h2 className="mb-1">{t('portal.homeCertificatesTitle')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-2 max-w-2xl">{t('portal.homeCertificatesBody')}</p>
                <Link href="/portal/certificates" className="text-sm app-link hover:underline">{t('portal.homeCertificatesLink')}</Link>
            </section>
            <p className="text-xs text-[color:var(--brand-muted-text)] max-w-2xl">{t('portal.homeOnlyYours')}</p>
            <section>
                <h2 className="mb-1">{t('portal.myDataTitle')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)] mb-2 max-w-2xl">{t('portal.myDataBody')}</p>
                {/* 一个普通的下载链接:路由在服务端以这个会话自己的身份调 portal_export_my_data() */}
                <a href="/portal/my-data" download className="text-sm app-link hover:underline" data-portal-export="1">
                    {t('portal.myDataDownload')}
                </a>
            </section>
        </div>
    )
}
