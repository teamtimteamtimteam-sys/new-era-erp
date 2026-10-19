// MES-9a(2026-10-19,MES-0 Q87 · MES-9 Step 0 Q5 · Q6 · Q7 · Q24,Tim):供应商页上的「门户账号」一块。
//   读 module.suppliers.view(页面的门本来就是它,Q7):这一家的每一个门户账号 —— 挂在哪位联系人上、登录邮箱、开的时刻与人、
//   还没换掉初始密码、最近一次登录、撤销(时刻 · 人 · 理由)、匿名化。V38 没给时照直说「初始密码不会过期」(Q24)。
//   开 / 撤销 / 匿名化 action.manage_portal_users(admin · cco)—— 控件看得见、按不动、说出码(PermissionGate)。
//   一个门户账号只看得见这一家自己的记录、看不见公司的任何内部页面(判词八 · fixture 275);那句话就写在这一块的说明里。
// MES-9b(2026-10-19,MES-9 Step 0 Q22):下面多一块【经门户下载的单据】—— 这一家的门户账号要走过的每一份签发档(谁 · 哪一份 · 什么时候),
//   读 portal_document_downloads(只追加;读策略 module.suppliers.view,与这一块同一个码);最近 50 次。
import { getTranslations } from '@/lib/i18n/server'
import { createClient } from '@/lib/supabase/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { formatAuditStamp } from '@/lib/dates'
import ActorName, { loadActorNames } from '@/app/components/ActorName'
import PortalAccountForms from './PortalAccountForms'

type DownloadRow = {
    id: string
    portal_user_id: string
    document_kind: 'purchase_order' | 'supplier_statement' | 'cod'
    document_code: string
    version: number | null
    downloaded_at: string
}

const DOWNLOADS_SHOWN = 50

type PortalAccountRow = {
    id: string
    contact_id: string
    contact_name: string
    account_email: string | null
    created_at: string
    created_by: string | null
    revoked_at: string | null
    revoked_by: string | null
    revoked_reason: string | null
    anonymised_at: string | null
    last_sign_in_at: string | null
    must_change_password: boolean
    banned: boolean
}

export default async function PortalAccountsPanel({ supplierId, contacts }: {
    supplierId: string
    contacts: { id: string; name: string; email: string | null }[]
}) {
    const t = await getTranslations()
    const supabase = await createClient()
    const [accRes, setRes, dlRes] = await Promise.all([
        supabase.from('supplier_portal_accounts')
            .select('id, contact_id, contact_name, account_email, created_at, created_by, revoked_at, revoked_by, revoked_reason, anonymised_at, last_sign_in_at, must_change_password, banned')
            .eq('supplier_id', supplierId).order('created_at', { ascending: false }),
        supabase.from('account_settings').select('initial_password_valid_days').limit(1).maybeSingle(),
        supabase.from('portal_document_downloads')
            .select('id, portal_user_id, document_kind, document_code, version, downloaded_at')
            .eq('supplier_id', supplierId).order('downloaded_at', { ascending: false }).limit(DOWNLOADS_SHOWN),
    ])
    const rows = mustRows(accRes, 'supplier_portal_accounts') as unknown as PortalAccountRow[]
    const settings = mustOne(setRes, 'account_settings')
    const downloads = mustRows(dlRes, 'portal_document_downloads') as unknown as DownloadRow[]
    const accountOf = new Map(rows.map((r) => [r.id, `${r.contact_name} · ${r.account_email ?? '—'}`]))
    const docLabel = (d: DownloadRow) =>
        d.document_kind === 'purchase_order' ? t('portal.kindPurchaseOrder', { code: d.document_code, v: String(d.version ?? '') })
        : d.document_kind === 'supplier_statement' ? t('portal.kindStatement', { code: d.document_code, v: String(d.version ?? '') })
        : t('portal.kindCod', { code: d.document_code })
    const canManage = await can('action.manage_portal_users')
    const names = await loadActorNames(supabase, rows.flatMap((r) => [r.created_by, r.revoked_by]))
    const live = new Set(rows.filter((r) => !r.revoked_at).map((r) => r.contact_id))
    const eligible = contacts.filter((c) => !!c.email && !live.has(c.id)).map((c) => ({ id: c.id, label: `${c.name} · ${c.email}` }))
    const days = settings?.initial_password_valid_days ?? null

    return (
        <section className="mt-6" data-section="supplier-portal-accounts">
            <h2 className="mb-1">{t('portal.panelTitle')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-2 max-w-3xl">{t('portal.panelWhat')}</p>
            <p className="text-xs mb-3 max-w-3xl" data-value="v38">
                {days == null ? t('portal.v38NotSet') : t('portal.v38Set', { days: String(days) })}
            </p>
            {rows.length === 0 ? (
                <p className="text-sm mb-3" data-empty="portal-accounts">{t('portal.noAccounts')}</p>
            ) : (
                <ul className="space-y-2 mb-4">
                    {rows.map((r) => (
                        <li key={r.id} className="border border-gray-200 rounded px-3 py-2 text-sm" data-portal-account={r.id}
                            data-state={r.anonymised_at ? 'anonymised' : r.revoked_at ? 'revoked' : 'active'}>
                            <div className="flex flex-wrap gap-x-3 gap-y-1">
                                <span className="font-medium">{r.contact_name}</span>
                                <span className="break-all">{r.account_email ?? '—'}</span>
                                <span className="text-xs px-2 py-0.5 rounded bg-gray-100">
                                    {r.anonymised_at ? t('portal.stateAnonymised') : r.revoked_at ? t('portal.stateRevoked') : t('portal.stateActive')}
                                </span>
                                {!r.revoked_at && r.must_change_password && (
                                    <span className="text-xs text-amber-800" data-flag="initial-password">{t('portal.initialPasswordPending')}</span>
                                )}
                            </div>
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                                {t('portal.createdLine', { at: formatAuditStamp(r.created_at) })}{' '}
                                <ActorName userId={r.created_by} names={names} />
                                {' · '}
                                {r.last_sign_in_at ? t('portal.lastSignIn', { at: formatAuditStamp(r.last_sign_in_at) }) : t('portal.neverSignedIn')}
                            </p>
                            {r.revoked_at && (
                                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                                    {t('portal.revokedLine', { at: formatAuditStamp(r.revoked_at), reason: r.revoked_reason ?? '' })}{' '}
                                    <ActorName userId={r.revoked_by} names={names} />
                                </p>
                            )}
                            <PortalAccountForms mode="row" supplierId={supplierId} canManage={canManage}
                                linkId={r.id} revoked={!!r.revoked_at} anonymised={!!r.anonymised_at} />
                        </li>
                    ))}
                </ul>
            )}
            <PortalAccountForms mode="create" supplierId={supplierId} canManage={canManage} contacts={eligible} />
            <div className="mt-5" data-section="supplier-portal-downloads">
                <h3 className="mb-1 font-medium">{t('portal.downloadsTitle')}</h3>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2 max-w-3xl">{t('portal.downloadsWhat')}</p>
                {downloads.length === 0 ? (
                    <p className="text-sm" data-empty="portal-downloads">{t('portal.downloadsNone')}</p>
                ) : (
                    <>
                        <ul className="divide-y divide-gray-200 border-y border-gray-200 text-sm">
                            {downloads.map((d) => (
                                <li key={d.id} className="py-1.5 flex flex-wrap gap-x-4 gap-y-0.5" data-portal-download={d.id}>
                                    <span className="min-w-[10rem]" title={t('portal.downloadsColWhen')}>{formatAuditStamp(d.downloaded_at)}</span>
                                    <span className="break-all" title={t('portal.downloadsColWho')}>{accountOf.get(d.portal_user_id) ?? '—'}</span>
                                    <span title={t('portal.downloadsColDocument')}>{docLabel(d)}</span>
                                </li>
                            ))}
                        </ul>
                        {downloads.length === DOWNLOADS_SHOWN && (
                            <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">{t('portal.downloadsShowing', { n: String(DOWNLOADS_SHOWN) })}</p>
                        )}
                    </>
                )}
            </div>
        </section>
    )
}
