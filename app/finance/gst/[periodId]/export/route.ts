// app/finance/gst/[periodId]/export/route.ts
// 一个 GST 期间的 F5 导出(Next 16 Route Handler)。端口自 app/output/export/route.ts。
//
// ★【导出的是什么形态,为什么是这个形态】★ 申报这件事发生在 IRAS 的 myTax Portal 上:
//   人对着屏幕把【九个数字】打进对应的格子。所以这里要的不是一份 PDF 表格,
//   也不是什么官方的机读格式(IRAS 不接受本系统直接提交)——
//   要的是【格号 · 措辞 · 数字】三列,照 F5 自己的顺序排好,
//   一边照着打,一边留一份存档。CSV 正是这个用途:能打开、能打印、能存档、能对。
//
// ★【已申报的期间导出【抄下来的那一份】,未申报的导出现算的】★
//   这两者是不同的问题("当时报了多少" vs "现在算出来是多少"),
//   而导出最容易把它们混成一件事 —— 一份导出如果在申报之后随底下的数据变,
//   它就不能拿去对账,也不能在 IRAS 问起时作数。
//   所以文件名与文件里的第一行都【写明这一份是哪一种】。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { mustRows } from '@/lib/db-helpers'

type Box = { box: string; label_en: string; label_zh: string; value: number }
type Snap = { box: string; label_en: string; label_zh: string; value_base: number }

// 与 output 导出同一套:一律加双引号,内部双引号翻倍。
function csvCell(value: unknown): string {
    if (value === null || value === undefined) return '""'
    return '"' + String(value).replace(/"/g, '""') + '"'
}

export async function GET(
    _request: NextRequest,
    { params }: { params: Promise<{ periodId: string }> },
) {
    const { periodId } = await params
    const supabase = await createClient()

    const { data: period, error: pErr } = await supabase.from('gst_periods')
        .select('code, period_start, period_end, status, filed_on, filed_reference')
        .eq('id', periodId).single()
    // RLS 会把没有 module.finance.view 的人挡在这里 —— 报错,不返回空表。
    // 一份【空的 CSV】读起来像"这一期没有数",那是一句假话。
    if (pErr || !period) {
        return new Response(`Export failed: ${pErr?.message ?? 'period not found'}`, { status: pErr ? 500 : 404 })
    }

    const filed = period.status === 'filed'
    let rows: { box: string; label_en: string; label_zh: string; value: number }[]

    if (filed) {
        // mustRows:查询失败必须【失败】—— 一份读成空表的导出会被当成"这一期没有数"。
        const snapRes = await supabase.from('gst_return_boxes')
            .select('box, label_en, label_zh, value_base').eq('period_id', periodId).order('box')
        rows = (mustRows(snapRes) as Snap[]).map(r => ({
            box: r.box, label_en: r.label_en, label_zh: r.label_zh, value: r.value_base,
        }))
    } else {
        const { data, error } = await supabase.rpc('f5_return', {
            p_period_start: period.period_start, p_period_end: period.period_end,
        })
        if (error) return new Response(`Export failed: ${error.message}`, { status: 500 })
        rows = ((data as unknown as { boxes: Box[] } | null)?.boxes ?? []).map(b => ({
            box: b.box, label_en: b.label_en, label_zh: b.label_zh, value: b.value,
        }))
    }

    const lines: string[] = []
    // 抬头三行:这一份【是什么】。没有它们,两种导出在硬盘上长得一模一样。
    lines.push([csvCell('GST F5'), csvCell(period.code),
                csvCell(`${period.period_start} .. ${period.period_end}`)].join(','))
    lines.push(filed
        ? [csvCell('AS FILED / 已申报的那一份'), csvCell(period.filed_on ?? ''),
           csvCell(period.filed_reference ?? '')].join(',')
        : [csvCell('NOT YET FILED — computed now / 尚未申报,现算'), csvCell(''), csvCell('')].join(','))
    lines.push('')
    lines.push(['Box', 'Label (EN)', 'Label (ZH)', 'Amount (SGD)'].map(csvCell).join(','))
    for (const r of rows) {
        lines.push([csvCell(r.box), csvCell(r.label_en), csvCell(r.label_zh), csvCell(r.value)].join(','))
    }

    // CRLF + UTF-8 BOM:Excel 才会正确分行并认出中文措辞。
    const csv = '﻿' + lines.join('\r\n') + '\r\n'
    const suffix = filed ? 'as-filed' : 'draft'
    return new Response(csv, {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            'Content-Disposition': `attachment; filename="F5-${period.code}-${suffix}.csv"`,
        },
    })
}
