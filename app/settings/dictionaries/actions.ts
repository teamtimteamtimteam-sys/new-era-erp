'use server'

// DICT-ADMIN:四个动作 —— 加一个值、改它的名字、设它的顺序、停用它。**就这四个。**
//
// 【没有删除,而这是一个【结论】不是一处遗漏 —— D3】
// 实测:指着这五张字典的 12 条外键【全部是 NO ACTION】,也就是说
// **一个在用的值,数据库本来就删不掉,也永远不可能把哪一行变成孤儿。**
// 那剩下的就只有"删一个从没被用过的值",而【停用已经覆盖了它】:
// 停用之后它不再出现在任何选单里,而那一行本身留着 —— 没有任何东西被丢掉。
// 于是删除只在一种情形下"能用",恰恰是最不需要它的那一种;
// 而一个只对没人用过的值有效的删除按钮,会让人对着真正想删的那个反复点。
// **所以不建删除。**
import { createClient } from '@/lib/supabase/server'
import { normaliseIdentityText, findNearDuplicate } from '@/lib/nearDuplicate'
import { getTranslations } from '@/lib/i18n/server'
import { revalidatePath } from 'next/cache'
import { DICTIONARIES } from './registry'

export type DictState = { error?: string; success?: boolean }

function spec(table: string) {
    const s = DICTIONARIES.find((d) => d.table === table)
    if (!s) throw new Error('unknown dictionary: ' + table)   // 不在声明里 = 调用方错了,不能静默
    return s
}

/**
 * 【D6:code 是外键指着的那个东西,所以它【不能】随便打】
 * 一个人当然得把新 code 打出来 —— 那正是这扇门。但要防住的是
 * **同一个东西长出第二种拼法**(materials.category 长过四种,那是整批 PROC 的起因)。
 * 三道:
 *   ① 去掉首尾空白、压掉内部连续空白;
 *   ② 与既有 code【不分大小写】比一遍,近重复当场按名拒;
 *   ③ **建好之后 code 不可改** —— 改它就是改外键指向,那是一次数据迁移,不是一次编辑。
 */
// GO-4:规范化与比较搬进 lib/nearDuplicate.ts,与 suppliers / customers 共用一份。
// **处置留在这里,而且刻意与那边相反** —— 见下方 ② 的注释。
const normaliseCode = normaliseIdentityText

export async function addDictValue(input: {
    table: string; code: string; nameEn: string; nameZh: string
    sortOrder: string; notes: string; extras: Record<string, string>
}): Promise<DictState> {
    const t = await getTranslations()
    const sp = spec(input.table)
    const supabase = await createClient()

    const code = normaliseCode(input.code)
    if (!code) return { error: t('dict.errCodeRequired') }
    if (!input.nameEn.trim() || !input.nameZh.trim()) return { error: t('dict.errBothNames') }

    // ② 近重复:不分大小写比一遍。**这一步是 D6 的核心** ——
    // 库里那条主键只挡逐字相同,挡不住 NMC / nmc / Nmc。
    const existing = await supabase.from(sp.table).select('code')
    // 【查不到【不是】"没有重复"】—— 这一步失败而被读成空集,近重复检查就静静失效了,
    // 而它正是 D6 的核心。所以不写 `?? []`:错误当场变成一句拒绝。
    if (existing.error || !existing.data) {
        return { error: await dictError(existing.error?.message ?? 'dictionary read failed') }
    }
    // 【这里【拒绝】,而 suppliers / customers 那边只【警告】—— 差别是有理由的】
    // code 是外键指着的那个东西:同一个东西长出第二种拼法,就是把一部分行挂到了
    // 一个新的、意义相同的键上。这里没有"两个都对"的情形,所以拦。
    // 公司名相反 —— 两家真正不同的公司可以同名,见 lib/nearDuplicate.ts 的抬头。
    const clash = findNearDuplicate(code, existing.data, (r: { code: string }) => r.code)
    if (clash) return { error: t('dict.errNearDuplicate', { 0: clash }) }

    const row: Record<string, unknown> = {
        code, name_en: input.nameEn.trim(), name_zh: input.nameZh.trim(),
        sort_order: Number(input.sortOrder) || 0,
        notes: input.notes.trim() || null,
    }
    for (const f of sp.extras) {
        const v = input.extras[f.column]
        if (f.kind === 'boolean') {
            // 【必填的布尔不许靠"没勾就是 false"】—— 那是把"没人决定过"读成"决定了不"。
            if (f.required && v !== 'true' && v !== 'false') {
                return { error: t('dict.errRuleUnset', { 0: t(f.labelKey) }) }
            }
            row[f.column] = v === 'true'
        } else {
            row[f.column] = (v ?? '').trim() || null
        }
    }

    const { error } = await supabase.from(sp.table).insert(row as never)
    if (error) return { error: await dictError(error.message) }
    revalidatePath('/settings/dictionaries')
    return { success: true }
}

/** 改名字 / 改顺序 / 改 notes / 改额外字段。**code 不在其中(D6 第三道)。** */
export async function updateDictValue(input: {
    table: string; code: string; nameEn: string; nameZh: string
    sortOrder: string; notes: string; extras: Record<string, string>
}): Promise<DictState> {
    const t = await getTranslations()
    const sp = spec(input.table)
    const supabase = await createClient()
    if (!input.nameEn.trim() || !input.nameZh.trim()) return { error: t('dict.errBothNames') }

    const patch: Record<string, unknown> = {
        name_en: input.nameEn.trim(), name_zh: input.nameZh.trim(),
        sort_order: Number(input.sortOrder) || 0,
        notes: input.notes.trim() || null,
    }
    for (const f of sp.extras) {
        const v = input.extras[f.column]
        if (f.kind === 'boolean') {
            if (f.required && v !== 'true' && v !== 'false') {
                return { error: t('dict.errRuleUnset', { 0: t(f.labelKey) }) }
            }
            patch[f.column] = v === 'true'
        } else {
            patch[f.column] = (v ?? '').trim() || null
        }
    }
    const { error } = await supabase.from(sp.table).update(patch as never).eq('code', input.code)
    if (error) return { error: await dictError(error.message) }
    revalidatePath('/settings/dictionaries')
    return { success: true }
}

/**
 * 停用 / 重新启用。
 * 【D2:停用【不是】删除,而这句话必须在屏幕上,不只在这里】
 * is_active 管的是"今天还能不能【新选】这个值";它【绝不】让已经记下来的事实失效。
 * PROC-3 定死过:一个被停用的安全状态【照样拦住一车货】。
 */
export async function setDictActive(input: {
    table: string; code: string; active: boolean
}): Promise<DictState> {
    const sp = spec(input.table)
    const supabase = await createClient()
    const { error } = await supabase.from(sp.table)
        .update({ is_active: input.active } as never).eq('code', input.code)
    if (error) return { error: await dictError(error.message) }
    revalidatePath('/settings/dictionaries')
    return { success: true }
}

/** 把库里的拒绝翻成人话。认不出的原样返回(与其余各支同一条)。 */
async function dictError(msg: string): Promise<string> {
    const t = await getTranslations()
    const raw = (msg ?? '').trim()
    // RLS 拒绝:PostgREST 给的是 42501 / "violates row-level security policy"。
    // **D7:这必须是一句"你不能做这件事",不是一张空列表。**
    if (/row-level security|42501|permission denied/i.test(raw)) {
        return t('dict.errNoPermission')
    }
    if (/duplicate key/i.test(raw)) return t('dict.errDuplicate')
    return raw
}
