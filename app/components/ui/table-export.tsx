'use client'

// ════════════════════════════════════════════════════════════════════════════
// TABLE-EXPORT-1(2026-10-22)· 表上方那两颗「Excel / CSV」—— 统一导出挂在共享的表上
// ════════════════════════════════════════════════════════════════════════════
// Tim 2026-10-20 / 2026-10-22:每一张表都有 Excel 与 CSV 导出,做成【一个】功能,挂在共享的表层上,
// 不是一页一页加。逐条裁定见 docs/table-export.md;下面只写这个组件自己的几个决定。
//
// ★ 行从哪里来(Q2:按当前的筛选与排序,全部的页,表定义的每一列 —— 含手机上收起来的列;勾选不收窄):
//   * 表手里已经是【全体】的(大多数):用 DataTable 排过、筛过、【没分页】的那一份 —— 与屏幕同序;
//   * 服务端分页的(spec.serverRows):向那条 JSON 路由要。它跑的是页面【自己】的读取与映射,
//     翻页取全,上限 50,000(Q8)。
//   两条路得到的是【同一个类型】的行,交给【同一份】列定义去写 —— 列只有一份。
// ★ 为什么一份导出不可能比屏幕多(硬规矩):行是页面自己读的(*_masked 视图 + 同一个守卫),
//   列是表自己的列(Q11);受限的格子由各列的 exportAs 按 MaskedValue 同一条判据写成「受限」(Q3)。
// ★ 不设单独的导出权限(Q10):看得见这张表的人就能导出它。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { useTranslations, useLocale } from '@/lib/i18n/client'
import { Button } from '@/app/components/ui/button'
import { Refusal } from '@/app/components/ui/refusal'
import { createClient } from '@/lib/supabase/client'
import type { ExportCell } from '@/lib/export/cells'
import {
    buildCsv, buildXlsx, downloadBlob, exportFileName, sgStamp,
    CSV_MIME, XLSX_MIME, type ExportTable,
} from '@/lib/export/write'

export type ExportColumnDef<T> = {
    key: string
    header: string
    exportAs: (row: T) => ExportCell
}

export type TableExportSpec<T> = {
    /** Q9 文件名里的英文表名(小写、连字符)。 */
    name: string
    /** About 表与工作表名(界面语言)。 */
    title: string
    /**
     * 服务端分页的表:那条 JSON 路由的地址,【带上当前页面的查询参数】(去掉 page)。
     * 不给 = 表手里已经是全体。
     */
    serverRows?: string
    /**
     * ★ Q5 / Q11 的唯一例外:供应商与客户两张表【声明】的扩展列(税号 · 付款条件 · 地址)。
     * 别的表不许用 —— scripts/check-table-export.mjs 只放这两张。
     */
    extension?: ReadonlyArray<ExportColumnDef<T>>
    /** About 表里「筛选」那一栏;不给就列出当前地址栏里的查询参数(page 除外)。 */
    filters?: ReadonlyArray<[string, string]>
    /**
     * TABLE-EXPORT-3a:About 表上多写的几行(界面语言),例如过账预览的「预览,截至 <日期>,尚未过账」(Tim 2026-10-23 Q5)。
     */
    aboutExtra?: ReadonlyArray<[string, string]>
}

type Props<T> = {
    spec: TableExportSpec<T>
    columns: ReadonlyArray<ExportColumnDef<T>>
    /** 表手里那一份:筛过、排过、没分页的全体。 */
    rows: () => readonly T[]
}

type Busy = null | 'xlsx' | 'csv'

export function TableExportBar<T>({ spec, columns, rows }: Props<T>) {
    const t = useTranslations()
    const locale = useLocale()
    const [busy, setBusy] = React.useState<Busy>(null)
    const [problem, setProblem] = React.useState<string | null>(null)

    const run = async (fmt: 'xlsx' | 'csv') => {
        setBusy(fmt)
        setProblem(null)
        try {
            let data: readonly T[]
            if (spec.serverRows) {
                const res = await fetch(spec.serverRows, { headers: { accept: 'application/json' } })
                let body: { rows?: T[]; code?: string; count?: number; cap?: number } | null
                try { body = await res.json() } catch (e) {
                    // 回来的不是 JSON(多半是一页错误 HTML)—— 说出状态码与原因,不当成「没有行」
                    throw new Error(`HTTP ${res.status} · ${e instanceof Error ? e.message : String(e)}`)
                }
                if (res.status === 413 && body?.code === 'EXPORT_TOO_MANY_ROWS') {
                    setProblem(t('table.export.tooMany', { count: body.count ?? 0, cap: body.cap ?? 0 }))
                    return
                }
                if (res.status === 403) { setProblem(t('table.export.denied')); return }
                if (!res.ok || !body?.rows) throw new Error(`HTTP ${res.status}${body?.code ? ` ${body.code}` : ''}`)
                data = body.rows
            } else {
                data = rows()
            }

            const all = [...columns, ...(spec.extension ?? [])]
            const now = new Date()
            const table: ExportTable = {
                name: spec.name,
                title: spec.title,
                headers: all.map((c) => c.header),
                rows: data.map((r) => all.map((c) => c.exportAs(r))),
                restrictedText: t('common.restricted'),
                about: await aboutRows(t, locale, now, {
                    title: spec.title, rows: data.length, filters: spec.filters, extra: spec.aboutExtra,
                }),
            }
            if (fmt === 'csv') downloadBlob(buildCsv(table), CSV_MIME, exportFileName(spec.name, 'csv', now))
            else downloadBlob(await buildXlsx(table), XLSX_MIME, exportFileName(spec.name, 'xlsx', now))
        } catch (e) {
            setProblem(t('table.export.failed', { detail: e instanceof Error ? e.message : String(e) }))
        } finally {
            setBusy(null)
        }
    }

    return (
        <div className="ml-auto flex flex-wrap items-center justify-end gap-2" data-slot="table-export">
            <Button type="button" variant="outline" size="sm" disabled={busy !== null} onClick={() => run('xlsx')}>
                {busy === 'xlsx' ? t('table.export.busy') : t('table.export.excel')}
            </Button>
            <Button type="button" variant="outline" size="sm" disabled={busy !== null} onClick={() => run('csv')}>
                {busy === 'csv' ? t('table.export.busy') : t('table.export.csv')}
            </Button>
            {problem && <p role="alert" className="w-full text-right text-xs"><Refusal>{problem}</Refusal></p>}
        </div>
    )
}

type Translate = ReturnType<typeof useTranslations>

/**
 * Q12 About 表的几行 —— 列表导出与报表导出(report-export.tsx)【同一份】。
 * 【error 必须接住】三类见 lib/supabase/middleware.ts 抬头。「导出人」这一格:
 *   有 user → 写邮箱;问不到(AuthRetryableFetchError 之类)→ 写「判断不出」,不写成一个空、也不假装是谁。
 *   导出本身不因此停下 —— 行是页面已经读到的,谁导出只是附注。
 */
export async function aboutRows(
    t: Translate, locale: string, now: Date,
    o: { title: string; rows: number; filters?: ReadonlyArray<[string, string]>; extra?: ReadonlyArray<[string, string]> },
): Promise<Array<[string, string]>> {
    const { data: auth, error: authErr } = await createClient().auth.getUser()
    const exportedBy = auth.user?.email ?? (authErr ? t('table.export.aboutByUnknown') : '—')
    const filters = o.filters ?? currentQueryFilters()
    return [
        [t('table.export.aboutTable'), o.title],
        ...(o.extra ?? []),
        [t('table.export.aboutFilters'), filters.length ? filters.map(([k, v]) => `${k} = ${v}`).join('; ') : t('table.export.aboutNoFilters')],
        [t('table.export.aboutRows'), String(o.rows)],
        [t('table.export.aboutBy'), exportedBy],
        [t('table.export.aboutAt'), sgStamp(now.toISOString())],
        [t('table.export.aboutLanguage'), locale],
    ]
}

/** About 表的默认「筛选」:当前地址栏里的查询参数,翻页那一个除外。 */
function currentQueryFilters(): Array<[string, string]> {
    if (typeof window === 'undefined') return []
    const out: Array<[string, string]> = []
    new URLSearchParams(window.location.search).forEach((v, k) => { if (k !== 'page' && v !== '') out.push([k, v]) })
    return out
}
