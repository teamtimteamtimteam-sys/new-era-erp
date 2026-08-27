// lib/csv.ts
// CSV 组装的共享一份。
//
// 【为什么现在才有这个文件】仓库里十条导出路由,每一条都自己写了一遍
// `csvCell` —— 一模一样的四行,复制了十份(app/finance/gst/[periodId]/export
// 的注释里明写着「与 output 导出同一套」)。AGING-1 要再加两条,
// 于是问题从"十份重复"变成"要不要写第十一、十二份"。
//
// 【只把新的两条接过来,不回头改那十条】那十条各自绿着、各自被冒烟走过,
// 在一刀里顺手重构十条导出路由是把风险堆到一次提交里,而收益只是整齐。
// 把共享的那一份立起来,新的写在这里 —— 回头的那一步按名进了队列。
//
// 引号规则与既有十处逐字相同:一律加双引号、内部双引号翻倍。
// 一律 CRLF + UTF-8 BOM —— Excel 才会正确分行并认出中文措辞。

export function csvCell(value: unknown): string {
    if (value === null || value === undefined) return '""'
    return '"' + String(value).replace(/"/g, '""') + '"'
}

export function csvRow(values: unknown[]): string {
    return values.map(csvCell).join(',')
}

/** 把已经拼好的行组装成一份可下载的 CSV(BOM + CRLF + 末尾换行)。 */
export function csvDocument(lines: string[]): string {
    return '﻿' + lines.join('\r\n') + '\r\n'
}

export function csvResponse(lines: string[], filename: string): Response {
    return new Response(csvDocument(lines), {
        headers: {
            'Content-Type': 'text/csv; charset=utf-8',
            'Content-Disposition': `attachment; filename="${filename}"`,
        },
    })
}
