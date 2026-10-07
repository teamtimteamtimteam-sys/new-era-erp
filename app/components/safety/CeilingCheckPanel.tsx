// app/components/safety/CeilingCheckPanel.tsx
// MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q10,Tim):这一批进厂那一刻,库存上限是怎么判的 —— 一句话。
//   读 receipt_ceiling_checks(一批一行,只追加;读策略跟着那一批:进料查看 / 产出查看)。
//   within / ceiling_not_set / category_not_set / licence_not_in_force / unit_not_convertible 各一句;
//   总上限给了的话再一句。MES-3a 之前进来的批没有这一行 —— 那也照直说,不画成"没超"。
//   执照号经 company_compliance 读(读策略:module.suppliers.view);读不到就不写号码,判法照样说得清。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'

type Check = {
    outcome: string; licence_id: string | null; category_code: string | null; quantity_t: number | null
    on_hand_before_t: number | null; limit_t: number | null; total_on_hand_before_t: number | null
    total_limit_t: number | null; checked_on: string
}

const t3 = (n: number | null) => (n === null ? '—' : String(Math.round(Number(n) * 1000) / 1000))

export default async function CeilingCheckPanel({ kind, batchId, locale }: {
    kind: 'inbound' | 'output'
    batchId: string
    locale: string
}) {
    const t = await getTranslations()
    const supabase = await createClient()
    const res = await supabase.from('receipt_ceiling_checks')
        .select('outcome, licence_id, category_code, quantity_t, on_hand_before_t, limit_t, total_on_hand_before_t, total_limit_t, checked_on')
        .eq(kind === 'inbound' ? 'inbound_batch_id' : 'output_batch_id', batchId).maybeSingle()
    const c = mustOne(res, 'receipt_ceiling_checks') as Check | null

    let licence = ''
    let category = c?.category_code ?? ''
    if (c?.licence_id) {
        const lic = mustRows(await supabase.from('company_compliance').select('cert_no').eq('id', c.licence_id), 'company_compliance') as { cert_no: string | null }[]
        licence = lic[0]?.cert_no ?? ''
    }
    if (c?.category_code) {
        const cat = mustRows(await supabase.from('nea_waste_categories').select('code, name_en, name_zh').eq('code', c.category_code), 'nea_waste_categories') as
            { code: string; name_en: string; name_zh: string }[]
        if (cat[0]) category = `${cat[0].code} · ${locale === 'zh' ? cat[0].name_zh : cat[0].name_en}`
    }
    const p = {
        licence: licence || t('storageSafety.ceiling.licenceUnreadable'), category,
        before: t3(c?.on_hand_before_t ?? null), qty: t3(c?.quantity_t ?? null), limit: t3(c?.limit_t ?? null),
        date: c ? formatDate(c.checked_on, locale) : '',
    }
    const line = !c ? t('storageSafety.ceiling.notChecked')
        : c.outcome === 'within' ? t('storageSafety.ceiling.within', p)
        : c.outcome === 'ceiling_not_set' ? t('storageSafety.ceiling.ceilingNotSet', p)
        : c.outcome === 'category_not_set' ? t('storageSafety.ceiling.categoryNotSet', p)
        : c.outcome === 'licence_not_in_force' ? t('storageSafety.ceiling.licenceNotInForce', p)
        : t('storageSafety.ceiling.unitNotConvertible', p)

    return (
        <section className="mb-8 max-w-2xl" data-ceiling-outcome={c?.outcome ?? 'none'}>
            <h2 className="mb-1">{t('storageSafety.ceiling.title')}</h2>
            <p className="text-sm">{line}</p>
            {c?.total_limit_t != null && (
                <p className="text-xs text-[color:var(--brand-muted-text)] mt-1">
                    {t('storageSafety.ceiling.total', { before: t3(c.total_on_hand_before_t), qty: t3(c.quantity_t), limit: t3(c.total_limit_t) })}
                </p>
            )}
        </section>
    )
}
