import { getTranslations } from '@/lib/i18n/server'

// PROC-2b:物料与进料状态轴的拒绝 → 人话。
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么现在才有这一支,以及它接的是两种形状】
//
// PROC-1 与 PROC-2 建的守卫至今【一句人话都没有】—— 而那不是疏忽,是还没到时候:
// 在这一刀之前,没有任何屏幕填得了那几列,所以没有人撞得上它们。**到了。**
//
// 【实测 PROC-1 留下的两条也在这里】materials 的动作今天走的是
//     t('materials.form.saveError', { message: error.message })
// —— **它把 Postgres 的原文直接印出去**。于是 materials_kind_stated 与
// MATERIAL_KIND_NOT_PROCESSABLE 至今都是机器话。一并接上。
//
// 【两种形状,与 equipmentErrorCodes.ts 同一支里的两半】
//   * **具名码**(守卫抛的):`MATERIAL_CONDITION_AXES_REQUIRED|battery_material`
//   * **约束名**(外键/主键/CHECK 直接抛的):
//     `violates foreign key constraint "materials_form_code_fkey"`
//   一个只解析 `CODE|args` 的实现,对后者只会原样吐回去。
//
// 【加一条守卫或一条约束 = 来这里加一个名字】check-i18n 的
// materials.errors.* 后缀集合现读下面这个 Set,漏了句子 npm run build 当场红。
// ════════════════════════════════════════════════════════════════════════════
const MATERIAL_ERROR_CODES = new Set([
    // ── 具名码:PROC-2 的四条状态轴守卫 ────────────────────────────────────
    'MATERIAL_CONDITION_AXES_REQUIRED',
    'MATERIAL_KIND_HAS_NO_CONDITION_AXES',
    'MATERIAL_SIZE_FORMAT_REQUIRED',
    'MATERIAL_SIZE_FORMAT_NOT_APPLICABLE',
    // ── 具名码:PROC-1 的两条,**至今没有句子** ────────────────────────────
    'MATERIAL_KIND_NOT_PROCESSABLE',
    'MATERIAL_KIND_NOT_FOUND',
    // ── 约束名:PROC-1 的那条 CHECK,同样至今没有句子 ──────────────────────
    'materials_kind_stated',
    // ── 约束名:五条轴的外键 —— 它们是这些轴做成字典换来的东西 ─────────────
    'materials_kind_code_fkey',
    'materials_form_code_fkey',
    'materials_source_code_fkey',
    'materials_size_format_code_fkey',
    'inbound_batches_chemistry_certainty_code_fkey',
    'inbound_batch_safety_states_safety_state_code_fkey',
    // ── 主键:多值那一条的"同一个状态只记一次" ────────────────────────────
    'inbound_batch_safety_states_pkey',
])

const CODE_RE = /([A-Z_]+)(?:\|(.*))?$/

export async function localizeMaterialError(message: string): Promise<string> {
    const raw = (message ?? '').trim()
    const t = await getTranslations()

    // ① 约束名先查 —— Postgres 的约束违反消息尾巴上常有大写串,先跑 CODE_RE 会误判。
    for (const name of MATERIAL_ERROR_CODES) {
        if (name === name.toLowerCase() && raw.includes(name)) {
            return t('materials.errors.' + name)
        }
    }

    // ② 具名码
    const match = raw.match(CODE_RE)
    if (match && MATERIAL_ERROR_CODES.has(match[1])) {
        const params: Record<string, string> = {}
        if (match[2]) match[2].split('|').forEach((v, i) => { params[String(i)] = v })
        return t('materials.errors.' + match[1], params)
    }

    // ③ 认不出的原样返回 —— 一个看不见的错比一个丑陋的错坏得多。
    return raw
}
