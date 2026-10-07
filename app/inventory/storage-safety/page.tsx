// app/inventory/storage-safety/page.tsx
// MES-3a(2026-10-06,MES-0 Q32 · Q35 · Q34;MES-3a Step 0 Q1 · Q13 · Q15 · Q20 · Q32,Tim):库存安全一页看全 ——
//   ① 库存上限(storage_ceiling_status):今天在效的 gwdf 执照下,每一类 NEA 废物的存量对着上限,外加一行总量。
//      没有在效执照 → 那一段说出来(收货照收、记 licence_not_in_force);一个类别都没有 → 说出来(V29),不画一张只剩总量的表当成"全在上限内"。
//   ② 滞留(safety_state_dwell):还在厂里的批身上每一条开着的安全状态,记下几天,对着它的提醒天数(V3;没给就照直说没给)。
//   ③ 隔离(quarantine_exposure):开着要隔离的状态、却还有货在非隔离库位的批;另说一句今天标成隔离的库位有几个
//      (一个都没有时,鼓包或漏液的货收不进来 —— 这是 Q19 的结果,页面替它说出来)。
//   门:module.inventory.view(Q32);每一段的行带它自己的谓词(上限:suppliers.view 或 inventory.view;批:进料 / 产出查看)。
//   只读,只提醒(Q13 · Q15):这里没有任何一颗按钮。
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'
import { ListPage } from '@/app/components/ui/list-page'
import { CeilingTable, DwellTable, ExposureTable, type CeilingRow, type DwellRow, type ExposureRow } from './StorageSafetyTables'

type Ceiling = {
    licence_id: string; cert_no: string | null; category_code: string | null; name_en: string; name_zh: string; sort_order: number
    limit_tonnes: number | null; on_hand_t: number; batches: number; unconvertible_batches: number; status: string
}
type Dwell = {
    batch_kind: string; state_row_id: string; batch_id: string; batch_code: string; safety_state_code: string; name_en: string; name_zh: string
    recorded_on: string; days_recorded: number; dwell_warning_days: number | null; dwell_status: string; on_site: boolean
}
type Exposure = {
    batch_kind: string; batch_id: string; batch_code: string; safety_state_code: string; name_en: string; name_zh: string
    recorded_on: string; location_id: string | null; location_code: string | null; qty: number
}

const t3 = (n: number | null) => (n === null ? '—' : String(Math.round(Number(n) * 1000) / 1000))
const hrefOf = (kind: string, id: string) => (kind === 'inbound' ? `/inbound/${id}/edit` : `/output/${id}/edit`)

export default async function StorageSafetyPage() {
    const denied = await requireModule(MOD.inventory)
    if (denied) return denied
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()
    const [ceilRes, dwellRes, expRes, catRes, quarRes] = await Promise.all([
        supabase.from('storage_ceiling_status')
            .select('licence_id, cert_no, category_code, name_en, name_zh, sort_order, limit_tonnes, on_hand_t, batches, unconvertible_batches, status')
            .order('sort_order').order('category_code'),
        supabase.from('safety_state_dwell')
            .select('batch_kind, state_row_id, batch_id, batch_code, safety_state_code, name_en, name_zh, recorded_on, days_recorded, dwell_warning_days, dwell_status, on_site')
            .eq('on_site', true).order('days_recorded', { ascending: false }),
        supabase.from('quarantine_exposure')
            .select('batch_kind, batch_id, batch_code, safety_state_code, name_en, name_zh, recorded_on, location_id, location_code, qty')
            .order('batch_code'),
        supabase.from('nea_waste_categories').select('code').eq('is_active', true),
        supabase.from('storage_locations').select('id').eq('is_quarantine', true).eq('is_active', true),
    ])
    const ceilings = mustRows(ceilRes, 'storage_ceiling_status') as Ceiling[]
    const dwell = mustRows(dwellRes, 'safety_state_dwell') as Dwell[]
    const exposure = mustRows(expRes, 'quarantine_exposure') as Exposure[]
    const categories = mustRows(catRes, 'nea_waste_categories') as { code: string }[]
    const quarantine = mustRows(quarRes, 'storage_locations') as { id: string }[]
    const nm = (r: { name_en: string; name_zh: string }) => (locale === 'zh' ? r.name_zh : r.name_en)

    // 四个判词各一句,写成字面键(不拼前缀:check-i18n 按字面量核对)
    const statusText = (s: string) => s === 'exceeded' ? t('storageSafety.page.statusExceeded')
        : s === 'within' ? t('storageSafety.page.statusWithin')
        : s === 'not_computable' ? t('storageSafety.page.statusNotComputable')
        : t('storageSafety.page.statusNotSet')
    const ceilingRows: CeilingRow[] = ceilings.map((r) => ({
        key: r.category_code ?? '*',
        category: r.category_code ? `${r.category_code} · ${nm(r)}` : t('storageSafety.page.totalRow'),
        onHand: t3(r.on_hand_t),
        limit: r.limit_tonnes === null ? t('storageSafety.page.notSet') : t3(r.limit_tonnes),
        batches: String(r.batches),
        status: r.status,
        statusText: statusText(r.status),
    }))
    const licence = ceilings[0]?.cert_no ?? null
    const dwellRows: DwellRow[] = dwell.map((r) => ({
        key: r.state_row_id, href: hrefOf(r.batch_kind, r.batch_id), batch: r.batch_code, state: nm(r),
        recorded: formatDate(r.recorded_on, locale), days: String(r.days_recorded),
        period: r.dwell_warning_days === null ? t('storageSafety.history.periodNotSet') : t('storageSafety.history.periodDays', { n: String(r.dwell_warning_days) }),
        past: r.dwell_status === 'past', status: r.dwell_status,
    }))
    const exposureRows: ExposureRow[] = exposure.map((r, i) => ({
        key: `${r.batch_id}|${r.location_id ?? '-'}|${r.safety_state_code}|${i}`, href: hrefOf(r.batch_kind, r.batch_id), batch: r.batch_code,
        state: nm(r), location: r.location_code ?? t('storageSafety.unspecified'), qty: String(r.qty), recorded: formatDate(r.recorded_on, locale),
    }))
    const pastCount = dwellRows.filter((r) => r.past).length

    return (
        <ListPage title={t('storageSafety.page.title')} intro={t('storageSafety.page.intro')} state={{ kind: 'ok' }}>
            <section className="mb-8" data-section="ceilings">
                <h2 className="mb-1">{t('storageSafety.page.ceilingsTitle')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">
                    {licence ? t('storageSafety.page.ceilingsLicence', { licence }) : t('storageSafety.page.noLicence')}
                </p>
                {licence && categories.length === 0 && (
                    <p className="text-sm border border-amber-300 bg-amber-50 text-amber-800 rounded px-3 py-2 mb-2" data-no-categories="1">
                        {t('storageSafety.page.noCategories')}
                    </p>
                )}
                {licence && <CeilingTable rows={ceilingRows} empty={t('storageSafety.page.noCeilingRows')} />}
            </section>

            <section className="mb-8" data-section="dwell">
                <h2 className="mb-1">{t('storageSafety.page.dwellTitle')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2">
                    {t('storageSafety.page.dwellIntro', { n: String(dwellRows.length), past: String(pastCount) })}
                </p>
                <DwellTable rows={dwellRows} empty={t('storageSafety.page.dwellNone')} />
            </section>

            <section className="mb-8" data-section="quarantine">
                <h2 className="mb-1">{t('storageSafety.page.quarantineTitle')}</h2>
                <p className="text-xs text-[color:var(--brand-muted-text)] mb-2" data-quarantine-locations={quarantine.length}>
                    {quarantine.length === 0 ? t('storageSafety.page.noQuarantineLocation') : t('storageSafety.page.quarantineLocations', { n: String(quarantine.length) })}
                </p>
                <ExposureTable rows={exposureRows} empty={t('storageSafety.page.quarantineNone')} />
            </section>
        </ListPage>
    )
}
