// lib/importTables.ts
// IMPORT-1 建的这个文件,IMPORT-2 换掉了它的【来源】。
//
// ════════════════════════════════════════════════════════════════════════════
// 【模板的列来自【线上目录】,在【请求时】取 —— 不是 lib/database.types.ts】
//
// IMPORT-1 从 `database.types.ts` 的 Insert 块推列。**走查证明那不够**,
// 而问题不是解析得不好 —— **那些事实根本不在那份类型里**:
//
//     supplies_goods?: boolean | null    ← 一个 GENERATED 列。数据库会【拒收】一个
//                                          供给的值,而它在类型里与任何普通可选列
//                                          【一模一样】。模板于是发出了一列,
//                                          填了它的文件必被拒。
//     counterparty_type: string          ← 一个 CHECK 闭集(三个值),类型里只是 string。
//                                          操作员无从知道该填什么 —— 走查里那三个值
//                                          是【口头】告诉走查人的。
//
// 只有 `pg_attribute.attgenerated` + `pg_constraint` 同时拥有这三件事实
// (接不接受供给的值 / 必不必填 / 接不接受任意值),所以来源换成
// `master_import_template_columns(p_table)`。
//
// **【这【不是】推翻"不要在构建时查库"那条裁定 —— 别把它"改回去"】**
// 那条裁定的理由是:**构建期查库意味着库够不着的时候构建就失败**。
// 这里是**请求时**,而且模板路由**本来就为权限判断打了一次 Supabase 往返** ——
// 所以它既没有新增依赖,也没有新增失败模式。那条裁定的理由在这里不适用,
// 而不是被推翻了。下一个想"恢复"成读类型文件的人,请先读完上面那两行类型。
// ════════════════════════════════════════════════════════════════════════════

export const IMPORT_TABLES = [
    'materials',
    'suppliers',
    'customers',
    'departments',
    'employees',
    'storage_locations',
] as const

export type ImportTable = (typeof IMPORT_TABLES)[number]

export function isImportTable(v: unknown): v is ImportTable {
    return typeof v === 'string' && (IMPORT_TABLES as readonly string[]).includes(v)
}

export type TemplateColumn = {
    column_name: string
    is_required: boolean
    accepted_values: string[] | null
}

/**
 * 【引用列按【编号】给,不按 uuid】—— 一个操作员不可能手打一个 uuid。
 * 模板里印左边那个名字;库里那一列是右边那个。换算在 `master_import_apply` 里做。
 */
export const REFERENCE_COLUMNS: Record<string, string> = {
    department_id: 'department_code',
    manager_id: 'manager_code',
    manager_employee_id: 'manager_employee_code',
    parent_department_id: 'parent_department_code',
}

/** 模板里印出来的列名(引用列换成 *_code)。 */
export function templateName(dbColumn: string): string {
    return REFERENCE_COLUMNS[dbColumn] ?? dbColumn
}

/** 注释行的前缀 —— 导入时按它跳过,所以只定义一次。 */
export const TEMPLATE_COMMENT_PREFIX = '#'

/**
 * 三行模板:表头 · 必填标记 · 闭集取值的说明。
 *
 * 【第三行为什么在文件里,而不只在屏幕上】操作员是**离开屏幕**去填这个文件的。
 * 一个只写在页面上的取值清单,在他打开表格软件的那一刻就不在了 ——
 * 而 `counterparty_type` 那三个值在走查里正是被【口头】补上的。
 *
 * 【它必须能被原样传回来】一份下载下来【一个字没改】就重新上传的文件,
 * 必须走得通(它会得到"文件里没有数据行"那句话,而不是一个解析错误)。
 * 跳过的判据在 `app/settings/import/actions.ts`,与这里的前缀同一个常量。
 */
export function templateCsv(cols: TemplateColumn[]): string {
    const names = cols.map((c) => templateName(c.column_name))
    const header = names.join(',')
    const marks = cols.map((c) => (c.is_required ? 'required' : '')).join(',')
    const sets = cols
        .filter((c) => c.accepted_values && c.accepted_values.length > 0)
        .map((c) => `${templateName(c.column_name)}: ${c.accepted_values!.join(' | ')}`)
    const note = sets.length
        ? `${TEMPLATE_COMMENT_PREFIX} 只接受这些取值 / accepted values —— ${sets.join('  ·  ')}`
        : `${TEMPLATE_COMMENT_PREFIX} 这张表没有取值受限的列 / no closed value sets on this table`
    return `${header}\n${marks}\n${note}\n`
}
