// app/processing/handovers/new/page.tsx
// PROC-SUPPORT-1(R4):新建一次交接班。
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireModule } from '@/app/components/moduleGuard'
import { MOD } from '@/lib/modules'
import Subnav from '../../Subnav'
import NewHandoverForm from './NewHandoverForm'

export default async function NewHandoverPage() {
    // 与 /processing/orders/new 同一形状:模块把关在这里,
    // 【写权限的权威在数据库那一侧】(submit_shift_handover 头一行
    // require_permission('module.processing.edit'))—— 界面不复述它。
    const denied = await requireModule(MOD.processing)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const shifts = mustRows(
        await supabase.from('shifts').select('code, name_en, name_zh, starts_at, ends_at')
            .eq('is_active', true).order('sort_order'),
        'shifts') as { code: string; name_en: string; name_zh: string
                       starts_at: string | null; ends_at: string | null }[]

    // 【名字走 handover_people】理由见该视图的注释:employees 要 module.hr.view,
    // 而这一屏的使用者是车间技师 —— 直读会让两个下拉框静默地空掉。
    const people = mustRows(
        await supabase.from('handover_people').select('id, code, preferred_name').order('code'),
        'handover_people') as { id: string; code: string; preferred_name: string | null }[]

    const itemTypes = mustRows(
        await supabase.from('handover_item_types').select('code, name_en, name_zh, is_required')
            .eq('is_active', true).order('sort_order'),
        'handover_item_types') as { code: string; name_en: string; name_zh: string; is_required: boolean }[]

    // R5:设备状态是一条【引用】—— 这里列的是 equipment_downtime 的行,
    // 交接班挂过去的是它的 id,不是它的 reason 的一份抄写。
    const downtime = mustRows(
        await supabase.from('equipment_downtime')
            .select('id, equipment_id, started_at, ended_at, reason')
            .order('started_at', { ascending: false }).limit(50),
        'equipment_downtime') as {
            id: string; equipment_id: string; started_at: string
            ended_at: string | null; reason: string }[]

    return (
        <>
            <Subnav />
            <NewHandoverForm
                shifts={shifts.map((s) => ({
                    code: s.code,
                    label: (locale === 'zh' ? s.name_zh : s.name_en)
                        + (s.starts_at && s.ends_at
                            ? ` ${s.starts_at.slice(0, 5)}–${s.ends_at.slice(0, 5)}`
                            : ` (${t('processing.handover.hoursUnstated')})`),
                }))}
                people={people.map((p) => ({ id: p.id, label: p.preferred_name ? `${p.code} — ${p.preferred_name}` : p.code }))}
                itemTypes={itemTypes.map((i) => ({
                    code: i.code,
                    label: locale === 'zh' ? i.name_zh : i.name_en,
                    required: i.is_required,
                }))}
                downtime={downtime.map((d) => ({
                    id: d.id,
                    label: `${new Date(d.started_at).toLocaleDateString(locale === 'zh' ? 'zh-CN' : 'en-US')} — ${d.reason}`
                        + (d.ended_at ? '' : ` (${t('processing.handover.downtimeOngoing')})`),
                }))}
            />
        </>
    )
}
