'use server'
// app/tools/converter/actions.ts — 湿转干那一档【调数据库】,不在这里算。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这一档要走一趟服务器,而另外两档不用】
// 吨/公斤/磅与品位换算是【定义性的算术】,系统里没有第二份实现可以偏离
// (常数与出处写在 lib/convert.ts)。
// 而**湿转干决定钱** —— 它是结算重量与含金属量的算法,而那段算法今天
// 【已经存在】于 convert_weight_basis / convert_grade_basis 里(TOOLS-1 从
// sale_settlement_compute 提取)。在 TypeScript 里照抄一遍是 AGENTS.md
// 明令禁止的形状(预览规则:四次事故),所以这里【调它】。
//
// 代价是一次往返;收益是**这个工具算出来的数,与结算算出来的数不可能分开**。
// ════════════════════════════════════════════════════════════════════════════
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'

export type BasisResult =
    | { ok: true; weight: number | null; grade: number | null }
    | { ok: false; error: string }

export async function convertBasis(input: {
    weight: number | null
    gradePct: number | null
    moisturePct: number
    from: 'as_received' | 'dry'
    to: 'as_received' | 'dry'
}): Promise<BasisResult> {
    const t = await getTranslations()

    // ★【水分 = 100% 的守卫【加在这里】,不加在那两支函数里】★
    // 那两支是从结算里提取的,而本刀的承诺是"结算的输出一个字节都不变" ——
    // 在基元里把除零换成一句具名拒绝【会改变失败模式】,那也是一种改变。
    // 所以守卫住在换算器这一侧:结算路径一个字节都不因为这个新页面而变。
    if (input.moisturePct >= 100 && input.from !== input.to) {
        return { ok: false, error: t('converter.err.moistureFull') }
    }
    if (input.moisturePct < 0 || input.moisturePct > 100) {
        return { ok: false, error: t('converter.err.moistureRange') }
    }

    const supabase = await createClient()
    const [w, g] = await Promise.all([
        input.weight === null ? Promise.resolve(null) : supabase.rpc('convert_weight_basis', {
            p_weight: input.weight, p_from_basis: input.from,
            p_to_basis: input.to, p_moisture_pct: input.moisturePct,
        }),
        input.gradePct === null ? Promise.resolve(null) : supabase.rpc('convert_grade_basis', {
            p_content_pct: input.gradePct, p_from_basis: input.from,
            p_to_basis: input.to, p_moisture_pct: input.moisturePct,
        }),
    ])
    // 【查不到不是零】—— 一次失败的换算与一个 0 在屏幕上长得一模一样,
    // 而这是一个给人核对【钱】用的工具。失败必须说出来。
    if (w && w.error) return { ok: false, error: w.error.message }
    if (g && g.error) return { ok: false, error: g.error.message }
    return {
        ok: true,
        weight: w ? Number(w.data) : null,
        grade: g ? Number(g.data) : null,
    }
}
