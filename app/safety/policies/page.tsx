// app/safety/policies/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// ESG-2(Tim 2026-10-30 SYSTEM-MAP-4 Q1 · 2026-10-31 Q9 · Q10)· ESG › 制度登记簿 —— 公司的每一份制度:现行的版本、负责人、生效日、复审日、
//   文件在哪里;复审逾期的标出来;被取代的旧版本列在下面。
// 【门】每一位登录的员工都读得到(注册表门恒真;行由 company_policy_rows 的行谓词裁:有员工档案,或持 action.manage_esg)。
//   登记与新版本要 action.manage_esg(admin · cco · cfo)。复审逾期、谁是现行版本都是库里的答案(那张视图),这一页不判。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { readAll } from '@/lib/readAll'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText, xDate } from '@/lib/export/cells'
import PolicyForm, { type CurrentPolicy, type OwnerOption } from './PolicyForm'

type P = {
    id: string; title: string; version: string; owner_employee_id: string; owner_label: string; effective_date: string; review_date: string
    document_ref: string; supersedes_id: string | null; superseded_at: string | null; is_current: boolean; review_overdue: boolean
}

export default async function PolicyRegisterPage() {
    const denied = await requireFunction(FN.esgPolicies)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const canManage = await can('action.manage_esg')

    const [polRes, empRes] = await Promise.all([
        readAll(() => supabase.from('company_policy_rows')
            .select('id, title, version, owner_employee_id, owner_label, effective_date, review_date, document_ref, supersedes_id, superseded_at, is_current, review_overdue')
            .order('title').order('effective_date', { ascending: false }), { label: 'company_policy_rows' }),
        canManage
            ? readAll(() => supabase.from('employees_masked').select('id, code, legal_name').is('deleted_at', null).order('code'), { label: 'employees_masked' })
            : Promise.resolve({ data: [], error: null }),
    ])
    const rows = mustRows(polRes, 'company_policy_rows') as P[]
    const owners: OwnerOption[] = (mustRows(empRes as never, 'employees_masked') as { id: string; code: string; legal_name: string }[])
        .map((e) => ({ id: e.id, label: `${e.code} · ${e.legal_name}` }))
    const current = rows.filter((r) => r.is_current)
    const old = rows.filter((r) => !r.is_current)
    const versionsOf = new Map<string, number>()
    // 一份制度的版本链:从现行那一版沿 supersedes_id 往回数
    const byId = new Map(rows.map((r) => [r.id, r]))
    for (const c of current) {
        let n = 1, p = c.supersedes_id
        while (p && byId.has(p)) { n++; p = byId.get(p)!.supersedes_id }
        versionsOf.set(c.id, n)
    }
    const overdue = current.filter((r) => r.review_overdue).length

    const curRows: CellRow[] = current.map((r) => ({
        id: r.id,
        cells: {
            title: r.title,
            version: r.version,
            owner: r.owner_label,
            effective: formatDate(r.effective_date, locale),
            review: r.review_overdue
                ? <span className="font-medium text-red-700" data-review-overdue="1">{formatDate(r.review_date, locale)} · {t('esg.policies.overdue')}</span>
                : formatDate(r.review_date, locale),
            document: <span className="break-words">{r.document_ref}</span>,
            versions: String(versionsOf.get(r.id) ?? 1),
        },
        exports: {
            title: xText(r.title), version: xText(r.version), owner: xText(r.owner_label), effective: xDate(r.effective_date),
            review: xDate(r.review_date), document: xText(r.document_ref), versions: xText(String(versionsOf.get(r.id) ?? 1)),
        },
    }))
    const oldRows: CellRow[] = old.map((r) => ({
        id: r.id,
        cells: {
            title: r.title, version: r.version, owner: r.owner_label, effective: formatDate(r.effective_date, locale),
            superseded: r.superseded_at ? formatDate(r.superseded_at.slice(0, 10), locale) : '—', document: <span className="break-words">{r.document_ref}</span>,
        },
        exports: {
            title: xText(r.title), version: xText(r.version), owner: xText(r.owner_label), effective: xDate(r.effective_date),
            superseded: xDate(r.superseded_at ? r.superseded_at.slice(0, 10) : null), document: xText(r.document_ref),
        },
    }))
    const currentForForm: CurrentPolicy[] = current.map((r) => ({ id: r.id, title: r.title, version: r.version, ownerId: r.owner_employee_id }))

    return (
        <ListPage title={t('esg.policies.title')} intro={t('esg.policies.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            {overdue > 0 && <p className="text-sm font-medium text-red-700 mb-3" data-overdue-count={overdue}>{t('esg.policies.overdueCount', { n: overdue })}</p>}
            <CellsTable
                columns={[
                    { key: 'title', header: t('esg.policies.colTitle'), priority: true },
                    { key: 'version', header: t('esg.policies.colVersion') },
                    { key: 'owner', header: t('esg.policies.colOwner') },
                    { key: 'effective', header: t('esg.policies.colEffective') },
                    { key: 'review', header: t('esg.policies.colReview'), priority: true },
                    { key: 'document', header: t('esg.policies.colDocument') },
                    { key: 'versions', header: t('esg.policies.colVersions'), align: 'right' },
                ]}
                rows={curRows}
                empty={t('esg.policies.none')}
                sorting="client"
                exportSpec={{ name: 'esg-policy-register', title: t('esg.policies.title') }}
            />
            {old.length > 0 && (
                <>
                    <h2 className="mt-8 mb-2">{t('esg.policies.historyTitle')}</h2>
                    <CellsTable
                        columns={[
                            { key: 'title', header: t('esg.policies.colTitle'), priority: true },
                            { key: 'version', header: t('esg.policies.colVersion'), priority: true },
                            { key: 'owner', header: t('esg.policies.colOwner') },
                            { key: 'effective', header: t('esg.policies.colEffective') },
                            { key: 'superseded', header: t('esg.policies.colSuperseded') },
                            { key: 'document', header: t('esg.policies.colDocument') },
                        ]}
                        rows={oldRows}
                        empty={t('esg.policies.none')}
                        sorting="client"
                        exportSpec={{ name: 'esg-policy-history', title: t('esg.policies.historyTitle') }}
                    />
                </>
            )}
            <PolicyForm current={currentForForm} owners={owners} canManage={canManage} />
        </ListPage>
    )
}
