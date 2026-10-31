// app/safety/training/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// ESG-2(Tim 2026-10-30 SYSTEM-MAP-4 Q1 · 2026-10-31 Q8)· ESG › 培训合规 —— 每一门必修培训适用几人、有效几人、快到期 / 已过期 / 没有记录几人,
//   以及逐人的状态;页底维护必修培训清单。
// 【一份实现】逐人的判定只在库里(esg_training_status:适用 = 全体 / 办公室 / 车间 / 点名的岗位;到期日 = 记录自己的,没写就按这一门的有效期;
//   快到期 = 90 天内,紧急 = 30 天内 —— 与 hr_alerts 同一组窗口);合计是 esg_training_coverage 数它。这一页不判任何事。
// 【没挂上的老记录】培训记录要在 HR › 培训里挂到一门必修培训上才算;没挂的照数出来、点名去处(Q8)。
// 【门】注册表 /safety/training = module.hr.view(培训记录的读码;两支函数都按它判);清单的增改停用要 action.manage_esg。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { formatDate } from '@/lib/dates'
import { readAll } from '@/lib/readAll'
import { ListPage } from '@/app/components/ui/list-page'
import CellsTable, { type CellRow } from '@/app/operation/equipment/CellsTable'
import { xText, xNum, xDate } from '@/lib/export/cells'
import RequiredTrainingsPanel, { type RequiredTrainingView, type PositionOption } from './RequiredTrainingsPanel'

type Coverage = {
    required_training_id: string; name: string; category: string | null; validity_months: number | null; applies_to: string; position_ids: string[]
    applicable: number; valid: number; expiring: number; expired: number; missing: number
}
type Status = {
    required_training_id: string; training_name: string; employee_id: string; employee_code: string; employee_name: string; status: string
    training_record_id: string | null; completed_date: string | null; expiry_date: string | null; days_remaining: number | null
}

export default async function TrainingCompliancePage() {
    const denied = await requireFunction(FN.esgTraining)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [covRes, stRes, posRes, unlinkedRes, canManage] = await Promise.all([
        readAll(() => supabase.rpc('esg_training_coverage'), { label: 'esg_training_coverage', key: 'required_training_id' }),
        readAll(() => supabase.rpc('esg_training_status'), { label: 'esg_training_status', key: ['required_training_id', 'employee_id'] }),
        readAll(() => supabase.from('positions').select('id, code, title').eq('is_active', true).order('sort_order').order('code'), { label: 'positions' }),
        supabase.from('training_records').select('id', { count: 'exact', head: true }).is('deleted_at', null).is('required_training_id', null),
        can('action.manage_esg'),
    ])
    const coverage = mustRows(covRes, 'esg_training_coverage') as unknown as Coverage[]
    const status = mustRows(stRes, 'esg_training_status') as unknown as Status[]
    const positions = mustRows(posRes, 'positions') as { id: string; code: string; title: string }[]
    const unlinked = mustCount(unlinkedRes, 'training_records')
    const posLabel = new Map(positions.map((p) => [p.id, `${p.code} · ${p.title}`]))
    const scopeLabel = (c: Coverage) => c.applies_to === 'positions'
        ? t('esg.training.applies.positions') + ': ' + c.position_ids.map((id) => posLabel.get(id) ?? '—').join(', ')
        : t('esg.training.applies.' + c.applies_to)
    const pct = (c: Coverage) => (c.applicable === 0 ? null : Math.round(((c.valid + c.expiring) / c.applicable) * 1000) / 10)

    const covRows: CellRow[] = coverage.map((c) => {
        const p = pct(c)
        return {
            id: c.required_training_id,
            cells: {
                name: c.name,
                scope: scopeLabel(c),
                applicable: String(c.applicable),
                valid: String(c.valid),
                expiring: c.expiring > 0 ? <span className="font-medium text-amber-900">{c.expiring}</span> : '0',
                expired: c.expired > 0 ? <span className="font-medium text-red-700">{c.expired}</span> : '0',
                missing: c.missing > 0 ? <span className="font-medium text-red-700">{c.missing}</span> : '0',
                coverage: p === null ? <span className="text-[color:var(--brand-muted-text)] italic">{t('esg.training.noneApplicable')}</span> : `${p}%`,
            },
            exports: {
                name: xText(c.name), scope: xText(scopeLabel(c)), applicable: xNum(c.applicable, 'qty'), valid: xNum(c.valid, 'qty'),
                expiring: xNum(c.expiring, 'qty'), expired: xNum(c.expired, 'qty'), missing: xNum(c.missing, 'qty'),
                coverage: p === null ? xText(t('esg.training.noneApplicable')) : xNum(p, 'qty'),
            },
        }
    })

    const statusText = (s: Status) => s.status === 'expiring' && s.days_remaining !== null && s.days_remaining <= 30
        ? t('esg.training.status.critical', { n: s.days_remaining })
        : t('esg.training.status.' + s.status)
    const peopleRows: CellRow[] = status.map((s) => ({
        id: `${s.required_training_id}:${s.employee_id}`,
        cells: {
            employee: <Link href={`/hr/employees/${s.employee_id}`} className="app-link hover:underline">{s.employee_code} · {s.employee_name}</Link>,
            training: s.training_name,
            status: <span data-training-status={s.status}
                          className={s.status === 'valid' ? '' : s.status === 'expiring' ? 'font-medium text-amber-900' : 'font-medium text-red-700'}>{statusText(s)}</span>,
            completed: s.completed_date ? formatDate(s.completed_date, locale) : '—',
            expiry: s.expiry_date ? formatDate(s.expiry_date, locale) : (s.training_record_id ? t('esg.training.noExpiry') : '—'),
        },
        exports: {
            employee: xText(`${s.employee_code} · ${s.employee_name}`), training: xText(s.training_name), status: xText(statusText(s)),
            completed: xDate(s.completed_date), expiry: s.expiry_date ? xDate(s.expiry_date) : xText(s.training_record_id ? t('esg.training.noExpiry') : ''),
        },
    }))

    const trainings: RequiredTrainingView[] = coverage.map((c) => ({
        id: c.required_training_id, name: c.name, category: c.category, validityMonths: c.validity_months, appliesTo: c.applies_to,
        positionIds: c.position_ids, notes: null, scopeLabel: scopeLabel(c),
    }))
    const positionOptions: PositionOption[] = positions.map((p) => ({ id: p.id, label: `${p.code} · ${p.title}` }))

    return (
        <ListPage title={t('esg.training.title')} intro={t('esg.training.intro')} maxWidth="max-w-6xl" state={{ kind: 'ok' }}>
            {unlinked > 0 && (
                <p className="text-sm mb-3" data-unlinked={unlinked}>
                    {t('esg.training.unlinked', { n: unlinked })}{' '}
                    <Link href="/hr/training" className="app-link hover:underline">{t('esg.training.unlinkedLink')}</Link>
                </p>
            )}
            <h2 className="mb-2">{t('esg.training.coverageTitle')}</h2>
            <CellsTable
                columns={[
                    { key: 'name', header: t('esg.training.colTraining'), priority: true },
                    { key: 'scope', header: t('esg.training.colAppliesTo') },
                    { key: 'applicable', header: t('esg.training.colApplicable'), align: 'right' },
                    { key: 'valid', header: t('esg.training.colValid'), align: 'right' },
                    { key: 'expiring', header: t('esg.training.colExpiring'), align: 'right' },
                    { key: 'expired', header: t('esg.training.colExpired'), align: 'right' },
                    { key: 'missing', header: t('esg.training.colMissing'), align: 'right' },
                    { key: 'coverage', header: t('esg.training.colCoverage'), align: 'right', priority: true },
                ]}
                rows={covRows}
                empty={t('esg.training.listNone')}
                sorting="client"
                exportSpec={{ name: 'esg-training-coverage', title: t('esg.training.coverageTitle') }}
            />
            <h2 className="mt-8 mb-2">{t('esg.training.peopleTitle')}</h2>
            <CellsTable
                columns={[
                    { key: 'employee', header: t('esg.training.colEmployee'), priority: true },
                    { key: 'training', header: t('esg.training.colTraining') },
                    { key: 'status', header: t('esg.training.colStatus'), priority: true },
                    { key: 'completed', header: t('esg.training.colCompleted') },
                    { key: 'expiry', header: t('esg.training.colExpiry') },
                ]}
                rows={peopleRows}
                empty={t('esg.training.peopleNone')}
                sorting="client"
                exportSpec={{ name: 'esg-training-status', title: t('esg.training.peopleTitle') }}
            />
            <p className="text-sm text-[color:var(--brand-muted-text)] mt-4 max-w-3xl">{t('esg.training.basis')}</p>
            <RequiredTrainingsPanel trainings={trainings} positions={positionOptions} canManage={canManage} />
        </ListPage>
    )
}
