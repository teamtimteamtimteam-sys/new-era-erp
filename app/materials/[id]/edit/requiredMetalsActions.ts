'use server'

// app/materials/[id]/edit/requiredMetalsActions.ts
// ASY-P2:把「这种物料要化验哪些金属」写回去。
//
// 【只有一条路】写入走 ASY-P1 的 set_material_required_metals(uuid, text[]) ——
// 基表 material_required_metals 上【没有】写策略,所以这不是"推荐做法",
// 是唯一过得了 RLS 的做法。整套替换,不存在改了一半的中间态。
//
// 【空集合是一个动作,不是"什么都没提交"】把所有勾都取消 = 这种物料不需要化验。
// 函数那一侧对 NULL 与空数组走同一条路,所以这里【永远】把数组传出去,
// 哪怕它是空的 —— 少传一次就是让"取消全部要求"这个动作静默失败。
import { createClient } from '@/lib/supabase/server'
import { revalidatePath } from 'next/cache'
import { loadSubstances } from '@/app/metal-prices/substanceQuery'
import { localizeMaterialPolicyError } from '../../materialPolicyErrorCodes'

export type RequiredMetalsState = { error?: string; ok?: boolean }

export async function saveRequiredMetals(
    materialId: string,
    _prev: RequiredMetalsState,
    formData: FormData
): Promise<RequiredMetalsState> {
    // 【客户端先过一遍,数据库仍然兜底】这里挡的是"表单里混进了不认识的值",
    // 而 METAL_UNKNOWN 那条具名拒绝在函数里。
// PROC-4:合法值不再来自一份写死的清单,而是来自 substances 那张字典。
// 【为什么这一侧还留着校验】外键才是权威(它对每一个写入者都成立,包括直连 psql);
// 这里做的是把"表单里混进了不认识的值"翻成一句人话,而不是第二份规则。
// **判据现读** —— 加一行字典之后,这里立刻认它,不必改代码。
    const picked = formData.getAll('metal').map((v) => String(v))

    const supabase = await createClient()
    const allowed = new Set((await loadSubstances(supabase)).map((r) => r.code))
    const unknown = picked.filter((m) => !allowed.has(m))
    if (unknown.length > 0) {
        return { error: await localizeMaterialPolicyError(`METAL_UNKNOWN|${unknown[0]}`) }
    }
    const { error } = await supabase.rpc('set_material_required_metals', {
        p_material_id: materialId,
        // 空数组照样传 —— 见抬头。
        p_metals: picked,
    })
    if (error) return { error: await localizeMaterialPolicyError(error.message) }

    // 物料页与列表页都印这个状态,两张都要刷新;首页那一支也跟着这条政策变,
    // 所以一并刷 —— 改完要求之后回首页看见旧的灯,会让人以为没保存上。
    revalidatePath(`/materials/${materialId}/edit`)
    revalidatePath('/materials')
    revalidatePath('/')
    return { ok: true }
}
