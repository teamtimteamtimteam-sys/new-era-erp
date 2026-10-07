// app/operation/operation-types/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-4a(2026-10-07,Step 0 Q1 · Q9–Q17,Tim)· 工序
// ════════════════════════════════════════════════════════════════════════════
// 【这一页是什么】每一道工序一行:它产不产批、平衡容差(空 = 还没有人给,V1)、记多少个参数与指标、挂着几台机器、
//   有几个配方。点进去是那一道工序自己的配置页。
// 【为什么不放在字典编辑器里】字典那张通用屏幕按 code 一行一行编辑(registry.ts),装不下"一道工序底下的一串字段 /
//   一串机器 / 一串配方"这种子清单 —— Step 0 §2 的那一句。
// 【门】requireFunction(FN.operationTypes) = module.processing.view;改在详情页,要 module.processing.edit。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { ListPage } from '@/app/components/ui/list-page'
import OperationTypesTable, { type OpTypeRow } from './OperationTypesTable'

export default async function OperationTypesPage() {
    const denied = await requireFunction(FN.operationTypes)
    if (denied) return denied

    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const [opRes, fieldRes, linkRes, recipeRes] = await Promise.all([
        supabase.from('operation_types')
            .select('code, name_en, name_zh, is_active, balance_tolerance_pct, operation_kinds ( produces_outputs )')
            .order('sort_order'),
        supabase.from('operation_type_fields').select('operation_type_code, is_active'),
        supabase.from('operation_type_equipment').select('operation_type_code'),
        supabase.from('process_recipes').select('operation_type_code, is_active'),
    ])
    const ops = mustRows(opRes, 'operation_types') as unknown as {
        code: string; name_en: string; name_zh: string; is_active: boolean; balance_tolerance_pct: number | null
        operation_kinds: { produces_outputs: boolean } | null
    }[]
    const fields = mustRows(fieldRes, 'operation_type_fields')
    const links = mustRows(linkRes, 'operation_type_equipment')
    const recipes = mustRows(recipeRes, 'process_recipes')

    const rows: OpTypeRow[] = ops.map((o) => {
        const transforming = o.operation_kinds?.produces_outputs ?? true
        return {
            code: o.code,
            name: locale === 'zh' ? o.name_zh : o.name_en,
            href: `/operation/operation-types/${o.code}`,
            active: o.is_active,
            kindText: transforming ? t('processing.opType.transforming') : t('processing.opType.stateChanging'),
            // 状态改变型的工序没有平衡可结(Q22),容差对它没有意义 —— 写"不适用",不写"还没给"。
            tolerance: !transforming ? 'na' : o.balance_tolerance_pct === null ? 'unset' : String(Number(o.balance_tolerance_pct)) + '%',
            fields: fields.filter((f) => f.operation_type_code === o.code && f.is_active).length,
            machines: links.filter((l) => l.operation_type_code === o.code).length,
            recipes: recipes.filter((r) => r.operation_type_code === o.code && r.is_active).length,
        }
    })

    return (
        <ListPage
            title={t('processing.opType.title')}
            intro={t('processing.opType.intro')}
            breadcrumb={<Link href="/operation" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <OperationTypesTable rows={rows} />
        </ListPage>
    )
}
