// app/finance/price-exposure/InventoryExposureSection.tsx
// MES-8b-1(2026-10-17,MES-0 Q81;MES-8 Step 0 Q12 · Q13,Tim):还在库的料里,可计价金属按最新的价值多少 —— 这一页的第二节。
//   【算术一个字都不在这里】读 inventory_metal_exposure():每一个可计价金属一行 —— 在库 kg × 含量 % × 今天或之前最新的一条价(美元 / 吨,带那条价的日子);
//   没有含量的批「Not measured」(列 kg,不估值);没有价的金属「No price」;同一天几条价「Price ambiguous」;不折算、不设阈值。
//   ★ MES-8b-2 F18:物料【种类没说】的在库批单列一栏「Kind not stated」(代码与 kg,单位不是 kg 的照列数量与单位)—— 不估值,
//     只要有一批,合计就标「Incomplete」。种类说了而不可投料的(备件、耗材、包装)照旧不进这一节(那是一个决定,不是缺席)。
//   【门】AGENTS.md 常设决定 2(与 /margin 同一份判据 FN.margin.permission);不满足的读者看到「Restricted」与要的码,不调用那支函数。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne } from '@/lib/db-helpers'
import { getMyPermissions } from '@/lib/permissions'
import { allows, FN } from '@/lib/modules'
import { formatMoneyBare } from '@/lib/format'
import { fmtKg } from '@/lib/massFormat'
import ExposureTable, { type ExposureLine } from './ExposureTable'

type Exposure = {
    as_of: string; metals: ExposureLine[]; value_usd_priced: number; complete: boolean
    not_measured: { kind: string; code: string; kg: number }[]; not_measured_kg: number
    unit_not_kg: { kind: string; code: string; qty: number; unit: string }[]
    kind_not_stated: { kind: string; code: string; kg: number | null; qty: number; unit: string }[]; kind_not_stated_kg: number
}

export default async function InventoryExposureSection() {
    const t = await getTranslations()
    if (!allows(FN.margin.permission, await getMyPermissions())) {
        return (
            <section className="mt-10" data-section="inventory-exposure">
                <h2 className="mb-1">{t('inventoryExposure.title')}</h2>
                <p className="text-sm text-[color:var(--brand-muted-text)]" data-access-restricted="inventory-exposure">
                    {t('common.restricted')} · <code className="text-[0.95em]">data.view_prices</code> + <code className="text-[0.95em]">module.finance.view</code> / <code className="text-[0.95em]">module.processing.view</code>
                </p>
            </section>
        )
    }
    const supabase = await createClient()
    const e = mustOne(await supabase.rpc('inventory_metal_exposure') as never, 'inventory_metal_exposure') as Exposure
    return (
        <section className="mt-10" data-section="inventory-exposure">
            <h2 className="mb-1">{t('inventoryExposure.title')}</h2>
            <p className="text-xs text-[color:var(--brand-muted-text)] mb-3 max-w-3xl">{t('inventoryExposure.intro', { asOf: e.as_of })}</p>
            <ExposureTable lines={e.metals} />
            <p className="text-sm mt-3" data-value="exposure-total">
                {t('inventoryExposure.total', { value: formatMoneyBare(Number(e.value_usd_priced), 'the sentence names USD') })}
                {!e.complete && <span className="text-amber-800">{' '}{t('inventoryExposure.incomplete')}</span>}
            </p>
            <div className="mt-4 text-sm max-w-3xl" data-section="exposure-not-measured">
                <h3 className="font-medium mb-1">{t('inventoryExposure.notMeasuredTitle', { kg: fmtKg(e.not_measured_kg) })}</h3>
                {e.not_measured.length === 0 ? <p className="text-[color:var(--brand-muted-text)]">{t('inventoryExposure.allMeasured')}</p>
                    : <p className="text-[color:var(--brand-muted-text)]">{e.not_measured.map((b) => `${b.code} ${fmtKg(b.kg)} kg`).join(' · ')}</p>}
                {e.unit_not_kg.length > 0 && (
                    <p className="text-[color:var(--brand-muted-text)] mt-2">{t('inventoryExposure.unitNotKg')} {e.unit_not_kg.map((b) => `${b.code} ${b.qty} ${b.unit}`).join(' · ')}</p>
                )}
            </div>
            <div className="mt-4 text-sm max-w-3xl" data-section="exposure-kind-not-stated">
                <h3 className="font-medium mb-1">{t('inventoryExposure.kindNotStatedTitle', { kg: fmtKg(e.kind_not_stated_kg), n: String(e.kind_not_stated.length) })}</h3>
                {e.kind_not_stated.length === 0 ? <p className="text-[color:var(--brand-muted-text)]">{t('inventoryExposure.allKindsStated')}</p>
                    : <>
                        <p className="text-[color:var(--brand-muted-text)]">{t('inventoryExposure.kindNotStatedWhy')}</p>
                        <p className="text-[color:var(--brand-muted-text)] mt-1 break-words" data-value="exposure-kind-not-stated-list">
                            {e.kind_not_stated.map((b) => b.kg !== null ? `${b.code} ${fmtKg(b.kg)} kg` : `${b.code} ${b.qty} ${b.unit}`).join(' · ')}
                        </p>
                    </>}
            </div>
            <p className="text-xs text-[color:var(--brand-muted-text)] mt-3 max-w-3xl">{t('inventoryExposure.noConversion')}</p>
        </section>
    )
}
