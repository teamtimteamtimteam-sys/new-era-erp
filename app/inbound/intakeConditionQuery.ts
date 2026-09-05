// PROC-2c:两本字典的读取 —— 一份实现,三个页面共用(批次页 + 建批次两条路)。
//
// 【为什么不是三处各写一遍 select】它们要读的是同一件事,而"同一件事写三遍"
// 在这个仓库里已经付过账:漏掉 order 的那一处顺序不同、漏掉 is_active 的那一处
// 多列一行。**读取条件本身就是一条规则**,它该有一个住处。
//
// 【S2:遮蔽表的读法不在这里】inbound_batches 是遮蔽表,读它必须走
// inbound_batches_masked;而这两本【字典】实测是普通表(表级 SELECT 授权),
// 直读。两者的区别写在这里,免得下一个人照着这支去读批次本身。
import type { SupabaseClient } from '@supabase/supabase-js'
import { mustRows } from '@/lib/db-helpers'
import type { SafetyState, Certainty } from './IntakeConditionFields'
import type { MaterialAxis } from './IntakeConditionFormSection'

export type IntakeConditionOptions = { states: SafetyState[]; certainties: Certainty[] }

export async function loadIntakeConditionOptions(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>
): Promise<IntakeConditionOptions> {
    const [statesRes, certRes] = await Promise.all([
        supabase.from('inbound_safety_states')
            .select('code, name_en, name_zh, may_be_fed').eq('is_active', true).order('sort_order'),
        supabase.from('inbound_chemistry_certainties')
            .select('code, name_en, name_zh, may_be_fed').eq('is_active', true).order('sort_order'),
    ])
    return {
        states: mustRows(statesRes, 'inbound_safety_states') as unknown as SafetyState[],
        certainties: mustRows(certRes, 'inbound_chemistry_certainties') as unknown as Certainty[],
    }
}

/**
 * 每个物料的种类【说不说得上】这两条轴。
 *
 * 【键上没有这个物料 = 没有人记过它的种类,而那【不是】"不适用"】
 * PROC-1 的 kind_code 允许留空,留空的意思是"没有人决定过"。库那一侧的
 * guard_inbound_condition_applicable 对这种行【放行】(查不到就 RETURN NEW),
 * 所以页面也必须放行 —— 两边给同一个答案,是"不摆一个服务端保证会拒的控件"
 * 这条规矩的另一半:也不要拦一个服务端会放行的动作。
 *
 * 【读的是 materials + material_kinds 两张普通表】都没有 _masked 伴生。
 */
export async function loadMaterialAxes(
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    supabase: SupabaseClient<any, any, any>
): Promise<Record<string, MaterialAxis>> {
    const [matRes, kindRes] = await Promise.all([
        supabase.from('material_lookup').select('id, kind_code').is('deleted_at', null),
        supabase.from('material_kinds').select('code, has_condition_axes, name_en, name_zh'),
    ])
    const mats = mustRows(matRes, 'materials') as unknown as { id: string; kind_code: string | null }[]
    const kinds = mustRows(kindRes, 'material_kinds') as unknown as
        { code: string; has_condition_axes: boolean; name_en: string; name_zh: string }[]
    const byCode = new Map(kinds.map((k) => [k.code, k]))

    const out: Record<string, MaterialAxis> = {}
    for (const m of mats) {
        if (!m.kind_code) continue        // ← 没有人记过种类:整条不进这张表
        const k = byCode.get(m.kind_code)
        if (!k) continue                  // ← 字典里查不到:同样不是"不适用"
        out[m.id] = { has_axes: k.has_condition_axes, kind_en: k.name_en, kind_zh: k.name_zh }
    }
    return out
}
