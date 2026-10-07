// app/operation/operation-types/[code]/page.tsx
// ════════════════════════════════════════════════════════════════════════════
// MES-4a(2026-10-07,Step 0 Q9–Q17 · V1 · V36,Tim)· 一道工序的配置页
// ════════════════════════════════════════════════════════════════════════════
// 四块:平衡容差(V1;空 = 还没有人给,结算时每一炉都要写解释)· 参数与指标(字段;范围空 = V36 还没给)·
//   挂着的机器(只收设备类的资产卡,Q9)· 配方与版本(版本固定、带编号,Q16)。页底是这道工序的审计记录。
// 【门】进:module.processing.view(requireFunction(FN.operationTypes));改:module.processing.edit ——
//   控件看得见、按不动、说出缺哪个码(DBLOCK-1)。
// 【状态改变型的工序】(深度放电)没有物料平衡(Q22)—— 容差那一块说"不适用",不给输入框。
// ════════════════════════════════════════════════════════════════════════════
import Link from 'next/link'
import { notFound } from 'next/navigation'
import { createClient } from '@/lib/supabase/server'
import { getTranslations, getLocale } from '@/lib/i18n/server'
import { mustOne, mustRows } from '@/lib/db-helpers'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { can } from '@/lib/permissions'
import { ListPage } from '@/app/components/ui/list-page'
import AuditTrail, { trailCount } from '@/app/components/trail/AuditTrail'
import OperationTypeEditor, { type EditorField, type EditorMachine, type EditorRecipe } from './OperationTypeEditor'

export default async function OperationTypePage({
    params,
    searchParams,
}: {
    params: Promise<{ code: string }>
    searchParams: Promise<{ trail?: string | string[] }>
}) {
    const denied = await requireFunction(FN.operationTypes)
    if (denied) return denied

    const { code } = await params
    const t = await getTranslations()
    const locale = await getLocale()
    const supabase = await createClient()

    const op = mustOne(await supabase.from('operation_types')
        .select('code, name_en, name_zh, is_active, balance_tolerance_pct, electrolyte_loss_applies, electrolyte_share_pct, requires_cell_construction, operation_kinds ( produces_outputs )')
        .eq('code', code).maybeSingle(), 'operation_types') as unknown as {
            code: string; name_en: string; name_zh: string; is_active: boolean; balance_tolerance_pct: number | null
            electrolyte_loss_applies: boolean; electrolyte_share_pct: number | null; requires_cell_construction: boolean
            operation_kinds: { produces_outputs: boolean } | null
        } | null
    if (!op) notFound()

    const [fieldRes, linkRes, eqRes, recipeRes, versionRes, canEdit] = await Promise.all([
        supabase.from('operation_type_fields')
            .select('field_code, name_en, name_zh, kind, value_type, unit, is_required, has_range, range_min, range_max, is_active, sort_order, notes')
            .eq('operation_type_code', code).order('sort_order'),
        supabase.from('operation_type_equipment').select('fixed_asset_id').eq('operation_type_code', code),
        // 机器的标签经 equipment_usage 读(加工的人读不到 fixed_assets 基表,MES-1 Q29);只收设备类(Q9)
        supabase.from('equipment_usage')
            .select('equipment_id, equipment_code, equipment_description, equipment_status, equipment_category')
            .order('equipment_code'),
        supabase.from('process_recipes').select('id, code, name_en, name_zh, is_active, notes').eq('operation_type_code', code).order('code'),
        supabase.from('process_recipe_versions').select('id, recipe_id, version, param_values, notes, created_at').order('version', { ascending: false }),
        can('module.processing.edit'),
    ])
    const fields = mustRows(fieldRes, 'operation_type_fields')
    const linkIds = new Set(mustRows(linkRes, 'operation_type_equipment').map((l) => l.fixed_asset_id))
    const eq = mustRows(eqRes, 'equipment_usage')
    const recipes = mustRows(recipeRes, 'process_recipes')
    const versions = mustRows(versionRes, 'process_recipe_versions')

    const transforming = op.operation_kinds?.produces_outputs ?? true
    const name = (r: { name_en: string; name_zh: string }) => (locale === 'zh' ? r.name_zh : r.name_en)

    const editorFields: EditorField[] = fields.map((f) => ({
        field_code: f.field_code, name_en: f.name_en, name_zh: f.name_zh, name: name(f), kind: f.kind, value_type: f.value_type,
        unit: f.unit, is_required: f.is_required, has_range: f.has_range, range_min: f.range_min, range_max: f.range_max,
        is_active: f.is_active, sort_order: f.sort_order, notes: f.notes,
    }))
    const machines: EditorMachine[] = eq
        .filter((e) => e.equipment_category === 'equipment' || linkIds.has(e.equipment_id as string))
        .map((e) => ({
            id: e.equipment_id as string,
            label: `${e.equipment_code}${e.equipment_description ? ' — ' + e.equipment_description : ''}`,
            disposed: e.equipment_status === 'disposed',
            linked: linkIds.has(e.equipment_id as string),
        }))
    const editorRecipes: EditorRecipe[] = recipes.map((r) => ({
        id: r.id, code: r.code, name: name(r), is_active: r.is_active, notes: r.notes,
        versions: versions.filter((v) => v.recipe_id === r.id).map((v) => ({
            id: v.id, version: v.version, notes: v.notes,
            values: Object.entries((v.param_values ?? {}) as Record<string, unknown>).map(([k, val]) => {
                const f = fields.find((x) => x.field_code === k)
                const shown = typeof val === 'boolean' ? (val ? t('common.yes') : t('common.no')) : String(val)
                return `${f ? name(f) : k}: ${shown}${f?.unit ? ' ' + f.unit : ''}`
            }),
        })),
    }))

    return (
        <ListPage
            title={name(op)}
            intro={t('processing.opType.detailIntro')}
            breadcrumb={<Link href="/operation/operation-types" className="hover:underline text-sm app-link">{t('common.back')}</Link>}
            maxWidth="max-w-5xl"
            state={{ kind: 'ok' }}
        >
            <OperationTypeEditor
                code={op.code}
                transforming={transforming}
                tolerance={op.balance_tolerance_pct === null ? null : String(Number(op.balance_tolerance_pct))}
                electrolyteApplies={op.electrolyte_loss_applies}
                electrolyteShare={op.electrolyte_share_pct === null ? null : String(Number(op.electrolyte_share_pct))}
                requiresCellConstruction={op.requires_cell_construction}
                fields={editorFields}
                machines={machines}
                recipes={editorRecipes}
                canEdit={canEdit}
            />
            <AuditTrail subject="operation_type" id={op.code} show={trailCount((await searchParams).trail)} />
        </ListPage>
    )
}
