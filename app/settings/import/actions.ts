'use server'

// app/settings/import/actions.ts
// IMPORT-1:解析文件 → 预览 → 提交。三步,而【规则一条都不在这里】。
//
// 【这一层不判断对错】所有的拒绝都来自 `master_import_apply`,因为那是提交会走的
// 那一段。在这里再写一份校验,就是本仓库点名过很多次的"两份定义必然漂开" ——
// 而且更坏:预览与提交会各说各话,那正是预览存在要消灭的东西。
//
// 这一层只做三件 SQL 做不了的事:
//   ① 把 CSV 变成 jsonb(papaparse,理由见 package.json 那次提交与文档);
//   ② 近重复【警告】—— 它读的是 lib/nearDuplicate.ts,系统里唯一那份定义;
//   ③ 把机器码翻成人话(importErrorCodes.ts)。
import Papa from 'papaparse'
import { createClient } from '@/lib/supabase/server'
import { findNearDuplicate, foldForCompare } from '@/lib/nearDuplicate'
import { isImportTable } from '@/lib/importTables'
import { parseImportError } from './importErrorCodes'
import type { ImportIssue, NearDuplicateWarning, PreviewResult } from './types'

/** 名字那一列叫什么 —— 只有这两族有"公司名"可比。 */
const NAME_COLUMN: Record<string, string> = {
    suppliers: 'legal_name',
    customers: 'legal_name',
}

function fail(table: string, fileName: string, code: string, detail?: string): PreviewResult {
    return {
        ok: false, table, rowCount: 0, rows: [], nearDuplicates: [], fileName,
        issues: [{ row: null, column: null, code, detail: detail ?? null }],
    }
}

export async function previewImport(_prev: unknown, formData: FormData): Promise<PreviewResult> {
    const table = String(formData.get('table') ?? '')
    const file = formData.get('file')
    const fileName = file instanceof File ? file.name : ''

    if (!isImportTable(table)) return fail(table, fileName, 'IMPORT_TABLE_NOT_IMPORTABLE', table)
    if (!(file instanceof File) || file.size === 0) return fail(table, fileName, 'IMPORT_NO_FILE')
    if (!/\.csv$/i.test(file.name)) return fail(table, fileName, 'IMPORT_NOT_CSV', file.name)

    // 【BOM】Excel(Windows)写出来的 CSV 前面有一个 U+FEFF,不剥掉的话第一个表头
    // 会变成 "﻿code" —— 那一列于是【静默地】认不出来。papaparse 不管这个。
    const text = (await file.text()).replace(/^﻿/, '')

    const parsed = Papa.parse<Record<string, string>>(text, {
        header: true,
        skipEmptyLines: 'greedy',
        transformHeader: (h) => h.trim(),
    })
    if (parsed.errors.length > 0) {
        const e = parsed.errors[0]
        return fail(table, fileName, 'IMPORT_CSV_UNPARSEABLE',
            `${e.type}: ${e.message}${e.row != null ? ` (行 ${e.row + 1})` : ''}`)
    }

    // 模板的第二行是 required 标记行,不是数据。它只有 'required' 与空 —— 认出来就丢掉。
    let rows = parsed.data
    if (rows.length > 0) {
        const first = rows[0]
        const vals = Object.values(first).map((v) => (v ?? '').trim())
        if (vals.every((v) => v === '' || v === 'required')) rows = rows.slice(1)
    }
    if (rows.length === 0) return fail(table, fileName, 'IMPORT_FILE_EMPTY')

    const supabase = await createClient()

    // ── 预览:真的插一遍,再整支回滚(见 master_import_apply 的抬头) ─────────
    const { error } = await supabase.rpc('master_import_apply', {
        p_table: table, p_rows: rows, p_file_name: fileName, p_dry_run: true,
    })

    // 【预览【总是】以异常回来】—— 那正是它保证回滚的方式。
    // 没有异常反而是不对的:说明它没有走到 RAISE,也就是没有回滚。
    if (!error) {
        return fail(table, fileName, 'IMPORT_ROWS_NOT_AN_ARRAY',
            '预览没有按预期回滚 —— 请报告这一条,不要继续提交。')
    }

    let issues: ImportIssue[] = []
    const m = error.message.match(/IMPORT_PREVIEW (\{[\s\S]*\})/)
    if (m) {
        try {
            issues = (JSON.parse(m[1]).errors ?? []) as ImportIssue[]
        } catch {
            return fail(table, fileName, 'IMPORT_CSV_UNPARSEABLE', error.message.slice(0, 300))
        }
    } else {
        // 文件级的拒绝(编号撞车、文件为空…)在插入之前就抛了,没有报告体。
        const p = parseImportError(error.message)
        return {
            ok: false, table, rowCount: rows.length, rows, nearDuplicates: [], fileName,
            issues: [{
                row: null, column: null,
                code: p?.code ?? 'IMPORT_ROW_REFUSED',
                detail: p?.args.join(', ') ?? error.message.slice(0, 300),
            }],
        }
    }

    // ── 近重复:**警告,不拒绝**(3.6) ────────────────────────────────────
    // 比较用的是 lib/nearDuplicate.ts —— 系统里唯一那份定义。这里不新写一个折叠函数。
    const nearDuplicates: NearDuplicateWarning[] = []
    const nameCol = NAME_COLUMN[table]
    if (nameCol) {
        const { data: existing } = await supabase
            .from(table).select(`code, ${nameCol}`).is('deleted_at', null)
        const pool = (existing ?? []) as unknown as Record<string, string>[]
        rows.forEach((r, i) => {
            const candidate = (r[nameCol] ?? '').trim()
            if (!candidate) return
            const clash = findNearDuplicate(candidate, pool, (x) => x[nameCol] ?? '')
            if (clash === undefined) return
            // helper 只给【拼法】;编号要一并引出来(3.6),所以在同一份 pool 里回查。
            // **不改那个 helper** —— 它有三个既有调用方,行为必须一个字不动。
            const owner = pool.find((x) => foldForCompare(x[nameCol] ?? '') === foldForCompare(clash))
            nearDuplicates.push({
                row: i + 1, incoming: candidate,
                existingName: clash, existingCode: owner?.code ?? '—',
            })
        })
    }

    return {
        ok: issues.length === 0, table, rowCount: rows.length,
        issues, nearDuplicates, rows, fileName,
    }
}

export type CommitResult = { ok: boolean; issues: ImportIssue[]; imported?: number }

export async function commitImport(payload: {
    table: string
    rows: Record<string, string>[]
    fileName: string
    acknowledgedNearDuplicates: boolean
    hadNearDuplicates: boolean
}): Promise<CommitResult> {
    if (!isImportTable(payload.table)) {
        return { ok: false, issues: [{ row: null, column: null, code: 'IMPORT_TABLE_NOT_IMPORTABLE' }] }
    }
    // 【勾选必须在服务端也检查一次】—— 界面上的那个勾是给人看的,
    // 而"页面同意的事服务端也要同意"是本仓库的标准要求。
    if (payload.hadNearDuplicates && !payload.acknowledgedNearDuplicates) {
        return { ok: false, issues: [{ row: null, column: null, code: 'IMPORT_NEAR_DUPLICATE_NOT_ACKNOWLEDGED' }] }
    }

    const supabase = await createClient()
    const { error } = await supabase.rpc('master_import_apply', {
        p_table: payload.table, p_rows: payload.rows,
        p_file_name: payload.fileName, p_dry_run: false,
    })
    if (!error) return { ok: true, issues: [], imported: payload.rows.length }

    const m = error.message.match(/IMPORT_FAILED (\{[\s\S]*\})/)
    if (m) {
        try { return { ok: false, issues: (JSON.parse(m[1]).errors ?? []) as ImportIssue[] } }
        catch { /* 落到下面那一支 */ }
    }
    const p = parseImportError(error.message)
    return {
        ok: false,
        issues: [{
            row: null, column: null,
            code: p?.code ?? 'IMPORT_ROW_REFUSED',
            detail: p?.args.join(', ') ?? error.message.slice(0, 300),
        }],
    }
}
