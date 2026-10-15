// app/operation/equipment/reliability.ts
// MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q5,Tim):可靠性那几句话 —— 机器页上那一行与 /operation/equipment/reliability 那张表共用。
//   【一个数都不在这里算】MTBF / MTTR / 运转小时 / 故障次数全部由 equipment_reliability() 算好(屏幕不许重新实现一条判定规则);
//   这里只把它们说成人话,并且【把分母说出来】:读数旁边永远有一句"这个小时数是怎么来的",
//   以及区间里有几张单没有机器、没有时刻 —— 今天线上 0 张单记了机器,而那正是读数为空的诚实理由。
//   零次故障与零运转小时【不是 0,也不是无穷大】:前者说"N 小时的运转里没有故障",后者说"没有记录到运转小时"。
//   不算可用率、不算 OEE(Q71 只回答了可靠性的分母)。
import type { getTranslations } from '@/lib/i18n/server'
import type { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'
import { formatAuditStamp } from '@/lib/dates'
import type { CauseOption } from './[id]/DowntimePanel'

type T = Awaited<ReturnType<typeof getTranslations>>
type Supa = Awaited<ReturnType<typeof createClient>>

export type ReliabilityRow = {
    equipment_id: string; equipment_code: string; equipment_description: string | null; equipment_status: string
    range_from: string; range_to: string
    operating_hours: number; runs_counted: number; runs_without_times: number; runs_without_machine: number
    failures: number; failures_open: number; mtbf_hours: number | null; mtbf_state: 'value' | 'no_failure' | 'no_hours'
    mttr_hours: number | null; repairs_closed: number
    planned_stops: number; external_stops: number; unclassified_stops: number
}

const H = new Intl.NumberFormat('en-US', { maximumFractionDigits: 2, minimumFractionDigits: 0 })
export const hours = (n: number | null | undefined) => (n === null || n === undefined ? '—' : H.format(Number(n)))

/** 停机原因字典(启用与停用的都读 —— 停用的那几种在旧行上仍要说得出名字),名字按界面语言选一个,类别的文案键是静态的三个。 */
export async function loadDowntimeCauses(supabase: Supa, locale: string, t: T): Promise<CauseOption[]> {
    const rows = mustRows(
        await supabase.from('downtime_causes').select('code, class, name_en, name_zh, is_active, sort_order').order('sort_order').order('code'),
        'downtime_causes') as { code: string; class: string; name_en: string; name_zh: string; is_active: boolean }[]
    const classLabel = (c: string) => c === 'failure' ? t('equipment.causeClass.failure')
        : c === 'planned' ? t('equipment.causeClass.planned') : c === 'external' ? t('equipment.causeClass.external') : c
    return rows.map((r) => ({ code: r.code, label: locale === 'zh' ? r.name_zh : r.name_en, classLabel: classLabel(r.class), isActive: r.is_active }))
}

/** 一台机器那一行说成四句:MTBF · MTTR · 分母 · 缺口(没有缺口时 gaps 为 null)。 */
export function reliabilityWords(r: ReliabilityRow, t: T): { mtbf: string; mttr: string; denominator: string; gaps: string | null } {
    const mtbf = r.mtbf_state === 'no_hours' ? t('equipment.rel.noHours')
        : r.mtbf_state === 'no_failure' ? t('equipment.rel.noFailure', { h: hours(r.operating_hours) })
        : t('equipment.rel.mtbfValue', { h: hours(r.mtbf_hours) })
    const mttr = r.mttr_hours === null
        ? (r.failures > 0 ? t('equipment.rel.mttrNoneClosed') : t('equipment.rel.mttrNone'))
        : t('equipment.rel.mttrValue', { h: hours(r.mttr_hours), n: String(r.repairs_closed) })
    const denominator = t('equipment.rel.denominator', {
        h: hours(r.operating_hours), runs: String(r.runs_counted), failures: String(r.failures), open: String(r.failures_open),
        from: formatAuditStamp(r.range_from), to: formatAuditStamp(r.range_to),
    })
    const parts: string[] = []
    if (r.runs_without_times > 0) parts.push(t('equipment.rel.gapNoTimes', { n: String(r.runs_without_times) }))
    if (r.runs_without_machine > 0) parts.push(t('equipment.rel.gapNoMachine', { n: String(r.runs_without_machine) }))
    if (r.unclassified_stops > 0) parts.push(t('equipment.rel.gapUnclassified', { n: String(r.unclassified_stops) }))
    return { mtbf, mttr, denominator, gaps: parts.length ? parts.join(' ') : null }
}
