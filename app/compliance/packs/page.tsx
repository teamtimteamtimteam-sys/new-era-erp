// app/compliance/packs/page.tsx
// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q14 – Q18 · Q28,Tim):合规包 —— 一个日历月的监管记录。
//   上半:选一个月(默认上一个整月),看它【现算的】八节(compliance_pack_data —— 冻下来的那一份就是这个),关了账的月份可以冻下来(CPK-YYYY-MM;
//   已有一份在册时带理由重出 -2,旧的留着)。V26 / V27 那一块在最底下(给了也不算任何东西)。
//   下半:冻下来的每一份(被取代的灰掉)。
//   【门】requireFunction(FN.compliancePacks) = module.compliance.view;冻、重出与设 V26 / V27 要 action.compliance_pack(页内控件看得见、按不动、说出码)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { DatePicker } from '@/app/components/ui/date-picker'
import { Button } from '@/app/components/ui/button'
import { formatAuditStamp, addMonthsIso } from '@/lib/dates'
import { businessToday } from '@/lib/format'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import PackSections from './PackSections'
import FreezePanel from './FreezePanel'
import SettingsPanel, { type ComplianceSettings } from './SettingsPanel'
import PacksTable, { type PackRow } from './PacksTable'
import type { CompliancePackPayload } from './packTypes'

const YM = /^\d{4}-(0[1-9]|1[0-2])$/

export default async function CompliancePacksPage({ searchParams }: { searchParams: Promise<{ month?: string; trail?: string | string[] }> }) {
    const denied = await requireFunction(FN.compliancePacks)
    if (denied) return denied
    const t = await getTranslations()
    const sp = await searchParams
    // 默认上一个整月(新加坡日期)—— 一个月要过完、关了账,才冻得下来
    const month = sp.month && YM.test(sp.month) ? sp.month : addMonthsIso(businessToday().slice(0, 7) + '-01', -1).slice(0, 7)
    const supabase = await createClient()
    const [previewRes, listRes, settingsRes, canFreeze] = await Promise.all([
        supabase.rpc('compliance_pack_data', { p_month: `${month}-01` }),
        supabase.from('compliance_packs').select('id, code, period_month, frozen_at, superseded_at, superseded_by, superseded_reason')
            .order('period_month', { ascending: false }).order('frozen_at', { ascending: false }).limit(300),
        supabase.from('compliance_settings').select('nea_return_format, nea_return_frequency, eu_efficiency_method, eu_efficiency_targets').maybeSingle(),
        can('action.compliance_pack'),
    ])
    const preview = mustOne(previewRes as never, 'compliance_pack_data') as CompliancePackPayload
    const list = mustRows(listRes, 'compliance_packs') as { id: string; code: string; period_month: string; frozen_at: string
        superseded_at: string | null; superseded_by: string | null; superseded_reason: string | null }[]
    const settings = (mustOne(settingsRes, 'compliance_settings') ?? { nea_return_format: null, nea_return_frequency: null,
        eu_efficiency_method: null, eu_efficiency_targets: null }) as ComplianceSettings
    const issuesRes = list.length === 0 ? { data: [], error: null }
        : await supabase.from('compliance_pack_issues').select('pack_id, version').in('pack_id', list.map((r) => r.id))
    const issues = mustRows(issuesRes as never, 'compliance_pack_issues') as { pack_id: string; version: number }[]
    const codeById = new Map(list.map((r) => [r.id, r.code]))
    const live = list.find((r) => r.period_month.slice(0, 7) === month && r.superseded_at === null) ?? null
    const rows: PackRow[] = list.map((r) => {
        const v = issues.filter((i) => i.pack_id === r.id).map((i) => i.version)
        return {
            id: r.id, code: r.code, month: r.period_month.slice(0, 7), frozen: formatAuditStamp(r.frozen_at),
            superseded: r.superseded_at ? t('compliancePacks.supersededBy', { code: codeById.get(r.superseded_by ?? '') ?? '', reason: r.superseded_reason ?? '' }) : null,
            latestVersion: v.length ? `v${Math.max(...v)}` : t('compliancePacks.noPdfYet'),
        }
    })

    return (
        <ListPage title={t('compliancePacks.title')} intro={t('compliancePacks.intro')} state={{ kind: 'ok' }}>
            <form method="get" className="mb-4 flex flex-wrap items-end gap-2" data-form="pack-month">
                <label className="text-sm">
                    {t('compliancePacks.month')}
                    <DatePicker kind="month" name="month" defaultValue={month} className="mt-1 flex" />
                </label>
                <Button variant="secondary" type="submit">{t('compliancePacks.show')}</Button>
            </form>
            <FreezePanel month={month} locked={preview.month_locked} lockedBefore={preview.locked_before} liveCode={live?.code ?? null} canFreeze={canFreeze} />
            <section className="mb-8" data-section="pack-preview">
                <h2 className="mb-1">{t('compliancePacks.previewTitle', { month })}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-4">
                    {t('compliancePacks.previewIsLive')}
                    {live && <>{' '}<Link href={`/compliance/packs/${live.id}`} className="app-link hover:underline">{t('compliancePacks.openFrozen', { code: live.code })}</Link></>}
                </p>
                <PackSections p={preview} />
            </section>
            <section className="mb-8" data-section="compliance-packs">
                <h2 className="mb-2">{t('compliancePacks.listTitle')}</h2>
                <PacksTable rows={rows} empty={t('compliancePacks.noneFrozen')} />
            </section>
            <section className="mb-8" data-section="compliance-settings">
                <h2 className="mb-1">{t('compliancePacks.settings.title')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 max-w-3xl">{t('compliancePacks.settings.hint')}</p>
                <SettingsPanel settings={settings} canEdit={canFreeze} />
                <AuditTrail subject="compliance_settings" id="true" show={trailCount(sp.trail)} />
            </section>
        </ListPage>
    )
}
