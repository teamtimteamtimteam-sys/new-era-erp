// app/finance/journal/export/route.ts
// GLEXPORT-1:总账 / 日记账导出(Next 16 Route Handler)。端口自
// app/finance/receivables/export/route.ts —— 抬头块单独一个模块、共用 lib/csv.ts。
//
// ★【一行一【分录行】,不是一行一分录】★ 会计师要的是能重算出试算平衡的东西,
//   而抽样也是按行抽的。一行一分录在超过两条腿的时候就写不下了(线上最多 5 条)。
//
// ★【每一行都带着它那张分录的完整身份,而这不是冗余,是防一次静默失败】★
//   读的人会把这份 CSV 拉进 Excel 然后【按科目排序】—— 那一刻分录的配对就散了。
//   所以 entry_code / date / memo / source / status 每一行都重复一遍,
//   外加一个【分录内行号】(line_no),于是任何重排都还原得回来。
//   一份重排之后就读不回去的导出,坏得很安静。
//
// ★【它读 journal_activity_lines,所以【不】按 status 过滤】★
//   冲销的做法是原分录标 reversed + 过一张等额反向的 posted 分录。只留 posted
//   会丢原件、留冲销件,净额刚好错成 −原件。这个病在本仓库现身过四次,
//   其中 bank_reconciliation_status 那一次【在线上错了几个月】,差 USD 1,585.00。
//   两边都在,净额才对 —— 而抬头里那句 csvReversalNote 就是对读者说的同一句话。
import type { NextRequest } from 'next/server'
import { createClient } from '@/lib/supabase/server'
import { getBaseCurrency } from '@/lib/currency'
import { mustRows } from '@/lib/db-helpers'
import { isYmd } from '@/lib/dateFilter'
import { csvRow, csvResponse } from '@/lib/csv'
import { glCsvHeader, glCsvFilename } from '../../glExportCsv'

const HEADERS = [
    'Entry',
    'Entry Date',
    'Entry Status',
    'Source',
    'Entry Memo',
    'Line No',
    'Account',
    'Account Name (EN)',
    'Account Name (ZH)',
    'Account Type',
    'Line Memo',
    'Debit (base)',
    'Credit (base)',
    'Signed (base)',
]

type Line = {
    entry_code: string; entry_date: string; entry_status: string
    source_type: string | null; entry_memo: string | null
    account_code: string; account_name_en: string; account_name_zh: string
    account_type: string; line_memo: string | null
    debit: number; credit: number; signed_base: number
}

export async function GET(request: NextRequest) {
    const sp = request.nextUrl.searchParams
    const from = (sp.get('from') ?? '').trim()
    const to = (sp.get('to') ?? '').trim()
    // 【期间必填且必须合法 —— 不给默认】一份"默认全部"的总账导出会在库长大之后
    // 悄悄变成一件很贵的事,而且没有人说得出它覆盖到哪天。
    if (!isYmd(from) || !isYmd(to) || from > to) {
        return new Response('Export failed: a valid from/to period is required (YYYY-MM-DD)', { status: 400 })
    }
    const includeYearClose = sp.get('year_close') === '1'

    const supabase = await createClient()
    const baseCurrency = await getBaseCurrency()

    // 【推导住在 journal_activity_lines 里,这里一行算术都没有】
    const res = await supabase.rpc('journal_activity_lines', {
        p_from: from, p_to: to, p_include_year_close: includeYearClose,
    })
    // mustRows:查询失败必须【失败】。一份读成空表的导出会被当成"这一期没有分录",
    // 而 RLS 把无权的人挡下来时正是这个形状 —— 报错,不返回一份空 CSV。
    const rows = mustRows(res) as unknown as Line[]

    const entryCodes = new Set(rows.map((r) => r.entry_code))
    const lines = await glCsvHeader({
        from, to, today: new Date().toISOString().slice(0, 10),
        baseCurrency, includeYearClose,
        entryCount: entryCodes.size, lineCount: rows.length,
    })
    lines.push(csvRow(HEADERS))

    // 【排序与行号】按分录日期、分录号、科目排;行号在【分录内】从 1 起 ——
    // 于是读的人按任何一列重排之后,(Entry, Line No) 仍然还原得回原来的样子。
    const sorted = [...rows].sort((a, b) =>
        a.entry_date.localeCompare(b.entry_date) ||
        a.entry_code.localeCompare(b.entry_code) ||
        a.account_code.localeCompare(b.account_code))
    let currentEntry = ''
    let lineNo = 0
    for (const r of sorted) {
        if (r.entry_code !== currentEntry) { currentEntry = r.entry_code; lineNo = 0 }
        lineNo += 1
        lines.push(csvRow([
            r.entry_code,
            r.entry_date,
            r.entry_status,
            r.source_type ?? '',
            r.entry_memo ?? '',
            lineNo,
            r.account_code,
            // 【两个名字给成【两列】,不是按界面语言挑一个,也不是拼起来】
            // 这是一份给【外部会计师】的文件:他手上那份科目表是中文还是英文,
            // 出表的人不知道。F5 导出同一个做法(Label (EN) / Label (ZH) 两列)。
            // 与 check-bilingual-concat 不冲突 —— 它抓的是"同一个主语被两次插值
            // 拼成一句话",而这里是两个独立的单元格。
            r.account_name_en,
            r.account_name_zh,
            r.account_type,
            r.line_memo ?? '',
            r.debit,
            r.credit,
            r.signed_base,
        ]))
    }

    return csvResponse(lines, glCsvFilename(from, to))
}
