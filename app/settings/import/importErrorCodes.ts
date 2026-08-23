// app/settings/import/importErrorCodes.ts
// IMPORT-1:把导入这条路上的每一条拒绝翻成一句人话。
//
// 【枚举,不是"碰到哪条写哪条"】(5.2)本仓库反复付账的形状是:只给自己撞见过的
// 那几条配句子,于是第一个撞上第七条的人看见一串 ALL_CAPS。下面这张表是照着
// `master_import_apply` 的函数体逐条抄下来的 —— 加一条拒绝而不加一句话,
// check-i18n 会当场红(后缀集合现读本文件的 Set)。
import type { ImportIssue } from './types'

export const IMPORT_ERROR_CODES = new Set([
    // ── 整份文件级 ──────────────────────────────────────────────────────
    'IMPORT_TABLE_NOT_IMPORTABLE',
    'IMPORT_ROWS_NOT_AN_ARRAY',
    'IMPORT_FILE_EMPTY',
    'IMPORT_CODE_DUPLICATED_IN_FILE',
    'IMPORT_CODE_ALREADY_EXISTS',
    'IMPORT_CODE_NUMBER_TOO_HIGH',
    // ── 逐行 ────────────────────────────────────────────────────────────
    'IMPORT_CODE_REQUIRED',
    'IMPORT_EMPLOYEE_CODE_SHAPE',
    'IMPORT_REFERENCE_NOT_FOUND',
    'IMPORT_TAX_ID_REQUIRED',
    'IMPORT_COLUMN_FORBIDDEN',
    'IMPORT_COLUMN_UNKNOWN',
    'IMPORT_ROW_EMPTY',
    'IMPORT_ROW_REFUSED',
    // ── app 侧(文件还没到数据库就被拦下的) ──────────────────────────────
    'IMPORT_NO_FILE',
    'IMPORT_NOT_CSV',
    'IMPORT_CSV_UNPARSEABLE',
    'IMPORT_NEAR_DUPLICATE_NOT_ACKNOWLEDGED',
])

export type ImportErrorCode = string

/** `CODE|arg1|arg2` → { code, args }。认不出的原样返回,绝不吞。 */
export function parseImportError(message: string): { code: string; args: string[] } | null {
    // Postgres 会把 RAISE 的消息包在一堆前缀里,取最后一段最像码的东西。
    const m = message.match(/(IMPORT_[A-Z_]+)((?:\|[^|]*)*)/)
    if (!m) return null
    return { code: m[1], args: m[2] ? m[2].slice(1).split('|') : [] }
}

/**
 * 逐行问题 → 一句话。
 * **永远带上行号与列名** —— 一个操作员面对 500 行,"哪一行"是他唯一能用的东西。
 */
export function issueSentence(
    t: (k: string, p?: Record<string, string | number>) => string,
    issue: ImportIssue
): string {
    const col = issue.column ?? '—'
    const base = (IMPORT_ERROR_CODES as ReadonlySet<string>).has(issue.code)
        ? t(`import.errors.${issue.code}`, {
              row: issue.row ?? 0,
              column: col,
              detail: issue.detail ?? '',
          })
        : // 认不出的码:**原样端出去,并说明它没有句子** ——
          // 假装它是别的什么,比一串机器码更坏。
          t('import.errors.UNMAPPED', { row: issue.row ?? 0, code: issue.code })
    return base
}
