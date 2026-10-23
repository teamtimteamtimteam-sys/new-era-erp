// app/compliance/packs/page.tsx
// MES-8b-1(2026-10-17,MES-0 Q82 · MES-8 Step 0 Q14 – Q18 · Q28,Tim):合规包 —— 一个日历月的监管记录。
//   上半:选一个月(默认上一个整月),看它【现算的】八节(compliance_pack_data —— 冻下来的那一份就是这个),关了账的月份可以冻下来(CPK-YYYY-MM;
//   已有一份在册时带理由重出 -2,旧的留着)。V26 / V27 那一块在最底下(给了也不算任何东西)。
//   下半:冻下来的每一份(被取代的灰掉)。
//   【门】requireFunction(FN.compliancePacks) = module.compliance.view;冻、重出与设 V26 / V27 要 action.compliance_pack(页内控件看得见、按不动、说出码)。
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows, mustCount } from '@/lib/db-helpers'
import { RowCapNotice } from '@/app/components/ui/row-cap-notice'
import { PACKS_SHOWN, packsCount, packsPage, shapePackRows } from './packsRows'
import { can } from '@/lib/permissions'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import { DatePicker } from '@/app/components/ui/date-picker'
import { Button } from '@/app/components/ui/button'
import { addMonthsIso } from '@/lib/dates'
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
    // ★ TABLE-EXPORT-2b-1(Tim Q2):清单的读取与映射搬进 packsRows.ts,与导出路由共用;只画最新 PACKS_SHOWN 份,而且说出来。
    //   「这个月在册的那一份」单独问一次 —— 不从截过的那一批里找(那一份可能在第 300 份之后)。
    const [previewRes, listRes, totalRes, liveRes, settingsRes, canFreeze] = await Promise.all([
        supabase.rpc('compliance_pack_data', { p_month: `${month}-01` }),
        packsPage(supabase, 0, PACKS_SHOWN - 1),
        packsCount(supabase),
        supabase.from('compliance_packs').select('id, code').eq('period_month', `${month}-01`).is('superseded_at', null).maybeSingle(),
        supabase.from('compliance_settings').select('nea_return_format, nea_return_frequency, eu_efficiency_method, eu_efficiency_targets').maybeSingle(),
        can('action.compliance_pack'),
    ])
    const preview = mustOne(previewRes as never, 'compliance_pack_data') as CompliancePackPayload
    const list = mustRows(listRes, 'compliance_packs')
    const total = mustCount(totalRes, 'compliance_packs count')
    const live = mustOne(liveRes, 'compliance_packs live') as { id: string; code: string } | null
    const settings = (mustOne(settingsRes, 'compliance_settings') ?? { nea_return_format: null, nea_return_frequency: null,
        eu_efficiency_method: null, eu_efficiency_targets: null }) as ComplianceSettings
    const rows: PackRow[] = await shapePackRows(supabase, list)

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
                <RowCapNotice shown={rows.length} total={total} />
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
