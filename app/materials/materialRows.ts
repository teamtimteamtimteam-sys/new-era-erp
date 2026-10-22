import 'server-only'

// TABLE-EXPORT-1(Tim 2026-10-22 Q2):物料列表的【一份】读取 —— 页面与导出路由共用。
// 页面取一页(.range),导出路由翻页取全(lib/export/serverRows.ts);两者走同一个 select、同一套筛选、
// 同一个「库里的行 → 表的行」映射,于是导出不可能比屏幕多一列或多一种口径。
// 排序在页面自己的排序列之后补一个 id —— 翻页取全要求一个【唯一】的次序(同一刻建的两行不再随机互换)。

import type { SupabaseClient } from '@supabase/supabase-js'
import type { Database } from '@/lib/database.types'
import { mustRows } from '@/lib/db-helpers'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { loadBatteryChemistries, toDictOptions, dictLabeller } from '@/app/components/dictionaries/dictionaryQuery'
import { formatAuditStamp } from '@/lib/dates'
import { UNIT_OPTIONS, labelKeyForValue, type MaterialSelectOption } from './options'
import { applyMaterialFilters, type MaterialListParams } from './materialQuery'
import type { MaterialTableRow } from './MaterialsTable'

type Client = SupabaseClient<Database>

export const MATERIAL_LIST_SELECT =
    'id, code, name, kind_code, may_be_processed, chemistry, unit, status, created_at, safety_stock_qty, waste_classification_code, dg_code, hs_code, material_kinds ( name_en, name_zh ), waste_classifications ( name_en, name_zh, is_controlled )'

export function materialCount(supabase: Client, params: MaterialListParams) {
    return applyMaterialFilters(supabase.from('materials').select('id', { count: 'exact', head: true }), params)
}

export function materialPage(supabase: Client, params: MaterialListParams, from: number, to: number) {
    return applyMaterialFilters(supabase.from('materials').select(MATERIAL_LIST_SELECT), params)
        .order('id', { ascending: true })
        .range(from, to)
}

type MaterialDbRow = NonNullable<Awaited<ReturnType<typeof materialPage>>['data']>[number]

export async function shapeMaterialRows(supabase: Client, materials: MaterialDbRow[]): Promise<MaterialTableRow[]> {
    const t = await getTranslations()
    const locale = await getLocale()
    // PROC-5:化学体系显示名来自字典。**连停用的一起读** —— 一条记着已停用
    // 取值的历史行必须照样显示得出名字,否则看起来像数据坏了。
    const chemistryLabel = dictLabeller(toDictOptions(await loadBatteryChemistries(supabase), locale))
    // 把存储值反查成本地化文案;自定义自由文本(无 key)原样显示
    const display = (options: MaterialSelectOption[], value: string | null) => {
        const key = labelKeyForValue(options, value)
        return key ? t(key) : value ?? '—'
    }

    // ── ASY-P2:每一个物料都要把自己的化验要求说出来,包括"没有" ────────────
    // 【为什么列表页也要有这一列】ASY-P1 的模型是「没有行 = 没有要求」,而那是一个
    // 假设:它读作"这种物料不需要化验",同时也是"还没有人想过这件事"的样子。
    // 只在编辑页说,就要求人一个一个点进去才知道自己有没有漏掉谁 —— 而这份政策
    // 是【逐个物料】做的决定,列表正是看见"还有谁没决定"的那张屏。
    // 【失败必须失败】不 `?? []`:读不出来会把每一行都画成"无化验要求"。
    const ids = materials.map((m) => m.id)
    const requiredByMaterial = new Map<string, string[]>()
    // 按 id 分批 —— 一个 .in() 里塞几万个 id 会把 URL 撑破;每批 200 个 id,结果行同样受 max_rows 管,所以每批再翻页。
    for (let i = 0; i < ids.length; i += 200) {
        const chunk = ids.slice(i, i + 200)
        for (let from = 0; ; from += 1000) {
            const got = mustRows(
                await supabase
                    .from('material_required_metals')
                    .select('material_id, metal')
                    .in('material_id', chunk)
                    .order('material_id')
                    .order('metal')
                    .range(from, from + 999),
                'material_required_metals',
            )
            for (const r of got) requiredByMaterial.set(r.material_id, [...(requiredByMaterial.get(r.material_id) ?? []), r.metal])
            if (got.length === 0) break
        }
    }

    return materials.map((m) => {
        const mk = m.material_kinds as { name_en: string; name_zh: string } | null
        const wc = m.waste_classifications
        return {
            id: m.id,
            code: m.code,
            name: m.name,
            // 语言在服务端选好 —— locale 不过 RSC 边界
            kindLabel: mk ? (locale === 'zh' ? mk.name_zh : mk.name_en) : null,
            chemistry: m.chemistry ? chemistryLabel(m.chemistry) : '—',
            wasteClassLabel: wc ? (locale === 'zh' ? wc.name_zh : wc.name_en) : null,
            wasteControlled: Boolean(wc?.is_controlled),
            assayMetals: requiredByMaterial.get(m.id) ?? [],
            unitLabel: display(UNIT_OPTIONS, m.unit),
            safetyStockLabel:
                m.safety_stock_qty === null ? null : `${m.safety_stock_qty} ${display(UNIT_OPTIONS, m.unit)}`,
            safetyStockQty: m.safety_stock_qty,
            // MES-3b(Q17):UN 编号与 HS 编码(都可以没有 —— 没有就是没人给过)
            dgCode: m.dg_code ?? null,
            hsCode: m.hs_code ?? null,
            status: m.status,
            createdLabel: formatAuditStamp(m.created_at),
            createdAt: m.created_at,
        }
    })
}
