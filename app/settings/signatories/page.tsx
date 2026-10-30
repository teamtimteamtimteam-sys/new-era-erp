// CONTRACT-ESIGN(Tim 2026-10-29 · 2026-10-30 Q3 · Q4 · Q7):设置 · 合同签署人 —— 谁可以代表公司在系统里签合同(具名的人,不是角色),
//   与公司印章。门:action.manage_signatories(只授 admin;判据来自注册表 FN.signatories)。
//   ① 名单:在册的人(名字 · 员工号 · 职衔 · 有没有画好签名 · 谁在何时加的)+ 移出过的人(谁在何时移的)。移出不作废他签过的(Q7)。
//      加人只从【有登录账号、还不在册】的员工里选(签字要他以自己的账号登录)。签名由本人在 /me 上画,这里设不了(Q4)。
//   ② 公司印章:在用的那一张(预览)+ 换过的历史;上传一张新的,旧的留着。只有签署人能把它盖到合同上。
//   名单与印章的每一次改动都进变更记录(/settings/change-history)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getLocale, getTranslations } from '@/lib/i18n/server'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { mustRows } from '@/lib/db-helpers'
import { readAll } from '@/lib/readAll'
import { formatDateTime } from '@/lib/dates'
import { loadActorNames } from '@/app/components/ActorName'
import { SIGNING_ASSETS_BUCKET, readStored } from '@/lib/contractFiles'
import SignatoriesPanel, { type SignatoryView, type EmployeeOption, type StampView } from './SignatoriesPanel'

export default async function SignatoriesSettingsPage() {
    const denied = await requireFunction(FN.signatories)
    if (denied) return denied
    const supabase = await createClient()
    const t = await getTranslations()
    const locale = await getLocale()

    const [sigRows, empRows, accRows, specRows, stampRows] = await Promise.all([
        readAll(() => supabase.from('contract_signatories').select('id, employee_id, title, added_at, added_by, removed_at, removed_by')
            .order('added_at', { ascending: false }), { label: 'contract_signatories' }),
        readAll(() => supabase.from('employees_masked').select('id, code, legal_name, user_id').is('deleted_at', null).order('code'), { label: 'employees' }),
        readAll(() => supabase.from('employee_accounts').select('employee_id').order('employee_id'), { label: 'employee_accounts' }),
        readAll(() => supabase.from('signature_specimens').select('employee_id').is('superseded_at', null).order('employee_id'), { label: 'signature_specimens' }),
        readAll(() => supabase.from('company_stamps').select('id, file_path, sha256, created_at, created_by, superseded_at')
            .order('created_at', { ascending: false }), { label: 'company_stamps' }),
    ])
    const sigs = mustRows(sigRows, 'contract_signatories') as { id: string; employee_id: string; title: string; added_at: string; added_by: string; removed_at: string | null; removed_by: string | null }[]
    const emps = mustRows(empRows, 'employees') as { id: string; code: string; legal_name: string; user_id: string | null }[]
    const linked = new Set((mustRows(accRows, 'employee_accounts') as { employee_id: string }[]).map((r) => r.employee_id))
    const withSpecimen = new Set((mustRows(specRows, 'signature_specimens') as { employee_id: string }[]).map((r) => r.employee_id))
    const stamps = mustRows(stampRows, 'company_stamps') as { id: string; file_path: string; sha256: string; created_at: string; created_by: string; superseded_at: string | null }[]

    const empById = new Map(emps.map((e) => [e.id, e]))
    const names = await loadActorNames(supabase, [...sigs.flatMap((s) => [s.added_by, s.removed_by]), ...stamps.map((s) => s.created_by)])
    const who = (u: string | null) => (u && names.names.get(u)) || (names.restricted ? t('common.restricted') : t('contractFiles.someone'))
    const view = (s: (typeof sigs)[number]): SignatoryView => {
        const e = empById.get(s.employee_id)
        return {
            id: s.id, name: e?.legal_name ?? '—', code: e?.code ?? '', title: s.title,
            hasSpecimen: withSpecimen.has(s.employee_id),
            addedLine: t('signatories.addedBy', { who: who(s.added_by), at: formatDateTime(s.added_at, locale) }),
            removedLine: s.removed_at ? t('signatories.removedBy', { who: who(s.removed_by), at: formatDateTime(s.removed_at, locale) }) : null,
        }
    }
    const active = sigs.filter((s) => !s.removed_at).map(view)
    const removed = sigs.filter((s) => s.removed_at).map(view)
    const listed = new Set(sigs.filter((s) => !s.removed_at).map((s) => s.employee_id))
    const candidates: EmployeeOption[] = emps
        .filter((e) => (e.user_id !== null || linked.has(e.id)) && !listed.has(e.id))
        .map((e) => ({ id: e.id, label: `${e.code} — ${e.legal_name}` }))

    const current = stamps.find((s) => !s.superseded_at) ?? null
    let currentUri: string | null = null
    if (current) {
        const got = await readStored(supabase, SIGNING_ASSETS_BUCKET, current.file_path, current.sha256)
        currentUri = got.ok ? `data:image/png;base64,${Buffer.from(got.bytes).toString('base64')}` : null
    }
    const stampHistory: StampView[] = stamps.map((s) => ({
        id: s.id, current: !s.superseded_at, sha256: s.sha256,
        line: t('signatories.stampBy', { who: who(s.created_by), at: formatDateTime(s.created_at, locale) }),
    }))

    return (
        <div className="p-4 sm:p-8 max-w-5xl space-y-6">
            <div>
                <h1 className="mb-2">{t('signatories.title')}</h1>
                <p className="text-sm text-[color:var(--brand-muted-text)] max-w-3xl">{t('signatories.intro')}</p>
                <p className="text-sm mt-1"><Link href="/settings/change-history" className="app-link hover:underline">{t('signatories.historyLink')}</Link></p>
            </div>
            <SignatoriesPanel active={active} removed={removed} candidates={candidates} stampUri={currentUri} stamps={stampHistory} />
        </div>
    )
}
