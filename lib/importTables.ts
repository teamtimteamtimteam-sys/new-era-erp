// lib/importTables.ts
// IMPORT-1:批量导入认识哪六张表,以及每张表的模板列从哪来。
//
// ════════════════════════════════════════════════════════════════════════════
// 【模板的列从 lib/database.types.ts 读出来,在【请求时】读,不在构建时读】
//
// 为什么不是一份手写的模板文件:它会漂。加一列、改一个必填,模板不跟着变,
// 而没有任何东西会说 —— 操作员照着一份过时的表头填,预览再把整份文件拒掉。
//
// 为什么不是构建时查线上:一次构建期的数据库查询,意味着**数据库够不着的时候
// 构建就失败**。这个仓库一直在拆掉这种形状(check_mirrors 推过连接池、
// --reach 曾经是默认、一条静态问题被放在走查中途问)。
//
// 为什么 `lib/database.types.ts` 是对的那一份:它**是这套 schema 的另一份镜像**,
// 由 `npm run types:gen` 生成,而且 **db/gate.py 逐字节把它与线上比对**
// (AGENTS.md:「lib/database.types.ts 是 schema 的 OTHER mirror …它落后时,
// TypeScript 会对着一个数据库已经没有的形状做校验」)。也就是说
// **它漂了闸门就红** —— 这正是这条规则要的保证,而且不花任何构建期代价。
//
// 【它在 Vercel 上读得到吗 —— 查过了,而且这个仓库已经有先例】
// 运行时用 fs 读一个源文件,打包器的静态分析看不见,serverless 部署会把它 trace 掉。
// `next.config.ts` 里已经为发票 PDF 的中文字体做过同一件事,连注释都写着为什么。
// 模板路由因此也进了 `outputFileTracingIncludes`。**漏掉那一行,这条路由会在
// 线上炸而本地全绿** —— 与字体那次是同一个坑。
// ════════════════════════════════════════════════════════════════════════════
import { readFileSync } from 'node:fs'
import { join } from 'node:path'

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

/**
 * 【引用列按【编号】给,不按 uuid】—— 一个操作员不可能手打一个 uuid。
 *
 * 模板里出现的是左边那个名字;库里那一列是右边那个。换算在
 * `master_import_apply` 里做(SQL 那一侧),因为**换不到就是一条具名拒绝**,
 * 而拒绝必须与其它拒绝走同一条路。这里只负责让模板把正确的表头印出来。
 */
export const REFERENCE_COLUMNS: Record<string, string> = {
    department_id: 'department_code',
    manager_id: 'manager_code',
    manager_employee_id: 'manager_employee_code',
    parent_department_id: 'parent_department_code',
}

/**
 * 【安全下限的 app 侧副本 —— 而它与 SQL 那一份【职责不同】,不是两份定义】
 *
 * SQL 的 `master_import_forbidden_columns()` 管的是「无论模板摆了什么,这几列
 * 都不许进」。这里管的是「模板要不要把它摆出来」。两者【可以】不一致而系统仍然
 * 是安全的:模板多摆一列,预览会按名报 `IMPORT_COLUMN_FORBIDDEN` ——
 * **那是一次看得见的分歧,不是一次静默接受。**
 *
 * 之所以不做成"app 去问 SQL 要这份清单":那会让下载一个模板变成一次数据库往返,
 * 而模板的全部意义是它随时拿得到。代价是这一份要跟着那一份改,而分歧【会被预览
 * 抓住并点名】—— 这是本仓库对"两份清单"一贯的处置:要么合成一份,要么让分歧响。
 */
const NOT_IN_TEMPLATE = new Set([
    'id',
    'created_at', 'updated_at', 'created_by', 'updated_by',
    'deleted_at', 'deleted_by', 'deletion_reason', 'owner_id',
    'user_id',
    'status',
    'default_payment_term_template_id',
])

export type TemplateColumn = { name: string; required: boolean }

let cache: Partial<Record<ImportTable, TemplateColumn[]>> = {}

/**
 * 从 `lib/database.types.ts` 的 `Insert:` 块里读出这张表接受哪些列。
 * 必填 = 那一行【没有】问号(`code: string` 必填,`notes?: string | null` 可选)。
 *
 * 【解析出 0 列不是"这张表没有列"】—— 与 check-i18n 的后缀解析、
 * check-masked-reads 的 `_masked` 清单同一条规矩:解析不出来要**响**,
 * 不要安静地返回一个空集合,否则模板会变成一张空表头而没有人知道为什么。
 */
export function templateColumns(table: ImportTable): TemplateColumn[] {
    const hit = cache[table]
    if (hit) return hit

    const src = readFileSync(join(process.cwd(), 'lib/database.types.ts'), 'utf8')
    // 定位这张表的 Insert 块。表名在 Tables 下,块内第一处 `Insert: {`。
    const at = src.indexOf(`      ${table}: {`)
    if (at === -1) throw new Error(`importTables: 在 database.types.ts 里找不到表 ${table}`)
    const insAt = src.indexOf('Insert: {', at)
    if (insAt === -1) throw new Error(`importTables: ${table} 没有 Insert 块`)
    const end = src.indexOf('\n        }', insAt)
    if (end === -1) throw new Error(`importTables: ${table} 的 Insert 块没有结尾`)

    const cols: TemplateColumn[] = []
    for (const line of src.slice(insAt, end).split('\n').slice(1)) {
        const m = line.match(/^\s{10}([a-z_0-9]+)(\??):/)
        if (!m) continue
        const [, name, opt] = m
        if (NOT_IN_TEMPLATE.has(name)) continue
        cols.push({ name: REFERENCE_COLUMNS[name] ?? name, required: opt !== '?' })
    }
    if (cols.length === 0) {
        throw new Error(
            `importTables: 从 database.types.ts 解析 ${table} 得到 0 列。` +
            `解析不出来【不是】空集合 —— 先确认 npm run types:gen 跑过、文件格式没变。`
        )
    }
    cache = { ...cache, [table]: cols }
    return cols
}

/** 模板的两行:表头,以及一行说明哪些是必填的注释行。 */
export function templateCsv(table: ImportTable): string {
    const cols = templateColumns(table)
    const header = cols.map((c) => c.name).join(',')
    const marks = cols.map((c) => (c.required ? 'required' : '')).join(',')
    return `${header}\n${marks}\n`
}
