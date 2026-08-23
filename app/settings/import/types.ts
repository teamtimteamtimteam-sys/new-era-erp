// app/settings/import/types.ts —— 预览与提交之间来回的那点形状,一处定义。
export type ImportIssue = {
    row: number | null
    column: string | null
    code: string
    detail?: string | null
    sqlstate?: string | null
}

export type NearDuplicateWarning = {
    row: number
    incoming: string
    existingName: string
    existingCode: string
}

export type PreviewResult = {
    ok: boolean
    table: string
    rowCount: number
    issues: ImportIssue[]
    nearDuplicates: NearDuplicateWarning[]
    /** 文件原样解析出来的行,提交时原样送回去 —— 不在客户端二次加工。 */
    rows: Record<string, string>[]
    fileName: string
}
