// app/components/safety/SafetyStateHistory.tsx
// MES-3a(2026-10-06,MES-0 Q35 · Q36 · Q34;MES-3a Step 0 Q15 · Q16 · Q20 · Q22,Tim):一批货身上的安全状态 ——
//   ① 隔离横幅:身上开着一条要隔离的状态(鼓包或漏液),却还有货放在非隔离库位(quarantine_exposure)。
//      记下一个状态永远不拒(一个危险必须永远记得下来),所以它在这里被说出来,而它的下一次移动只能进隔离。
//   ② 开着的每一条:记下的那一天、在厂里待了几天、它的滞留提醒天数(没给 → "not yet set",V3);到了就琥珀色。
//      时钟从记下的那一刻起算(safety_state_dwell,新加坡日历天),保存不会让它重来 —— 没变的那一条一个字节都不动。
//   ③ 结束了的每一条:从哪天到哪天、为什么结束(加工解决掉的写着是哪一炉;回滚撤回的写着是哪一次回滚)。
//      状态从此被【结束】,不被删(谁结束的,在页面最下面的审计记录里)。
//   服务端组件。读的是两张状态表本身(读策略:进料查看 / 产出查看)与两张带同一对谓词的属主视图。
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { formatDate } from '@/lib/dates'

type StateRow = { id: string; safety_state_code: string; created_at: string; ended_at: string | null; end_reason: string | null }
type DwellRow = { state_row_id: string; days_recorded: number; dwell_warning_days: number | null; dwell_status: string }
type ExposureRow = { safety_state_code: string; location_code: string | null; qty: number }
type Dict = { code: string; name_en: string; name_zh: string }

export default async function SafetyStateHistory({ kind, batchId, unit, locale }: {
    kind: 'inbound' | 'output'
    batchId: string
    unit: string
    locale: string
}) {
    const t = await getTranslations()
    const supabase = await createClient()
    const table = kind === 'inbound' ? 'inbound_batch_safety_states' : 'output_batch_safety_states'
    const cols = 'id, safety_state_code, created_at, ended_at, end_reason'
    const [stateRes, dwellRes, expRes, dictRes] = await Promise.all([
        kind === 'inbound'
            ? supabase.from('inbound_batch_safety_states').select(cols).eq('inbound_batch_id', batchId).order('created_at')
            : supabase.from('output_batch_safety_states').select(cols).eq('output_batch_id', batchId).order('created_at'),
        supabase.from('safety_state_dwell').select('state_row_id, days_recorded, dwell_warning_days, dwell_status')
            .eq('batch_kind', kind).eq('batch_id', batchId),
        supabase.from('quarantine_exposure').select('safety_state_code, location_code, qty').eq('batch_kind', kind).eq('batch_id', batchId),
        supabase.from('inbound_safety_states').select('code, name_en, name_zh'),
    ])
    const states = mustRows(stateRes, table) as StateRow[]
    const dwell = new Map((mustRows(dwellRes, 'safety_state_dwell') as DwellRow[]).map((d) => [d.state_row_id, d]))
    const exposure = mustRows(expRes, 'quarantine_exposure') as ExposureRow[]
    const names = new Map((mustRows(dictRes, 'inbound_safety_states') as Dict[]).map((d) => [d.code, locale === 'zh' ? d.name_zh : d.name_en]))
    const name = (code: string) => names.get(code) ?? code
    const open = states.filter((s) => s.ended_at === null)
    const ended = states.filter((s) => s.ended_at !== null).reverse()
    if (states.length === 0 && exposure.length === 0) return null

    const exposedQty = exposure.reduce((a, e) => a + Number(e.qty), 0)
    const exposedAt = [...new Set(exposure.map((e) => e.location_code ?? t('storageSafety.unspecified')))].join(', ')

    return (
        <section className="mb-8 max-w-2xl" data-safety-history={kind}>
            {exposure.length > 0 && (
                <div className="mb-3 border border-amber-300 bg-amber-50 text-amber-800 rounded px-3 py-2 text-sm" data-quarantine-exposed="1">
                    {t('storageSafety.banner', {
                        state: name(exposure[0].safety_state_code), qty: String(exposedQty), unit, locations: exposedAt,
                    })}
                </div>
            )}
            <h3 className="text-sm font-medium mb-1">{t('storageSafety.history.title')}</h3>
            {open.length > 0 && (
                <ul className="text-sm space-y-1 mb-2">
                    {open.map((s) => {
                        const d = dwell.get(s.id)
                        const past = d?.dwell_status === 'past'
                        return (
                            <li key={s.id} data-dwell-status={d?.dwell_status ?? 'unknown'}
                                className={past ? 'text-amber-700' : undefined}>
                                <span className="font-medium">{name(s.safety_state_code)}</span>
                                {' · '}{t('storageSafety.history.recorded', { date: formatDate(s.created_at, locale), days: String(d?.days_recorded ?? 0) })}
                                {' · '}{d?.dwell_warning_days != null
                                    ? t('storageSafety.history.periodDays', { n: String(d.dwell_warning_days) })
                                    : t('storageSafety.history.periodNotSet')}
                                {past && <> {' · '}<strong>{t('storageSafety.history.past')}</strong></>}
                            </li>
                        )
                    })}
                </ul>
            )}
            {ended.length > 0 && (
                <>
                    <p className="text-xs text-[color:var(--brand-muted-text)] mb-1">{t('storageSafety.history.endedTitle')}</p>
                    <ul className="text-xs text-[color:var(--brand-muted-text)] space-y-1" data-safety-ended={ended.length}>
                        {ended.map((s) => (
                            <li key={s.id}>
                                <span className="font-medium">{name(s.safety_state_code)}</span>
                                {' · '}{t('storageSafety.history.ended', {
                                    from: formatDate(s.created_at, locale), to: s.ended_at ? formatDate(s.ended_at, locale) : '—', reason: s.end_reason ?? '',
                                })}
                            </li>
                        ))}
                    </ul>
                </>
            )}
        </section>
    )
}
