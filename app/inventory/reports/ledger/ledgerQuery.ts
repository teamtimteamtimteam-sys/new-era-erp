// RPT-1:流水台账的取数 + 过滤。页面与 PDF 共用这一份(TABLE-EXPORT-1 起 Excel / CSV 从页面那张表写)。
//
// 【只有这张表需要界】它是 append-only 的流水,只会变长(今天 85 行);
// 另外三张的行数由当下的库存状态决定,不随时间增长 —— 理由写在
// reportShared.LEDGER_DEFAULT_DAYS 上。默认窗口 90 天,可改,可清空;
// 【清空是一个明确的动作】,不是默认 —— 默认无界的报表迟早在最忙的页面上变慢。
import { createClient } from '@/lib/supabase/server'
import { mustRows, mustCount } from '@/lib/db-helpers'
import { fetchAllPages, EXPORT_CAP } from '@/lib/export/serverRows'
import { defaultLedgerFrom } from '../reportShared'

export type LedgerParams = {
    from: string; to: string; materialId: string; batchCode: string
    /**
     * ★★【CONV-6 ⑥ 的扫尾:一条【指名一条流水】的筛选,此前根本不存在】★★
     * 被删记录页(app/settings/deleted/page.tsx:153)一直在发
     * `/inventory/reports/ledger?movement=<id>` 这样的链接 ——
     * **而这一页从来没有读过 movement 这个参数。** 点下去参数被静默丢掉,
     * 人落在一张默认 90 天的完整流水上,再自己去里面找那一条。
     * 屏幕上"筛到了"与"没筛"长得一模一样,所以没有人发现。
     * 它是 CONV-6 ⑥ 那条新判据(带参数的链接,目标页必须真的读那个参数)
     * 扫出来的【第二处】,而它不是搬家造成的 —— 这个参数【一次都没有实现过】。
     */
    movementId: string
}

export type LedgerRow = {
    id: string; business_date: string | null; occurred_at: string; movement_type: string
    qty_delta: number; stock_status: string; location_id: string | null
    inbound_batch_id: string | null; output_batch_id: string | null; notes: string | null
    storage_locations: { code: string } | null
    inbound_batches: { code: string; materials: { code: string; name: string } | null } | null
    output_batches: { code: string; materials: { code: string; name: string } | null } | null
}

export function parseLedgerParams(sp: Record<string, string | undefined>): LedgerParams {
    return {
        from: (sp.from ?? '').trim() || defaultLedgerFrom(),
        to: (sp.to ?? '').trim() || '',
        materialId: (sp.material_id ?? '').trim(),
        batchCode: (sp.batch ?? '').trim(),
        movementId: (sp.movement ?? '').trim(),
    }
}

export function describeFilters(p: LedgerParams): string {
    // 【指名一条流水时,日期窗不参与描述】—— 它本来就没有生效(见 fetchLedger)
    if (p.movementId) return `movement=${p.movementId}`
    const bits = [`${p.from || '…'} → ${p.to || '…'}`]
    if (p.materialId) bits.push(`material=${p.materialId}`)
    if (p.batchCode) bits.push(`batch=${p.batchCode}`)
    return bits.join(' · ')
}

/**
 * ★ TABLE-EXPORT-2b-2(Tim 2026-10-22 TABLE-EXPORT-2 Q2 · 2026-10-23 Step 0):
 *   · 页面画最新的 LEDGER_SHOWN 条,而且说出来。从前写的是 .limit(2000),而线上 PostgREST 的 `max_rows = 1000`
 *     (TABLE-EXPORT-1 实测)让它在 1,000 处就停 —— 数写成它真的生效的那一个。
 *   · 物料与批次筛选从前在截断【之后】用 JS 跑(旧 :84-90),于是收窄筛选找不回被截掉的行。它们在【嵌入的关联行】上,
 *     而一条流水的批次不是进料批就是产出批(`inventory_movements_one_batch`:两者恰好一个非空)——
 *     所以拆成【两条各自在库里筛过的读取】(进料那一侧 `inbound_batches!inner`、产出那一侧 `output_batches!inner`),
 *     两侧不可能重叠;合并、按同一个次序排,再截一次。总数 M = 两侧 count(exact) 之和。
 *   · 次序:业务日(空的排最后)↓ · 发生时刻 ↓ · id ↑ —— 翻页要一个【唯一】的次序,合并也按这同一个比较。
 */
export const LEDGER_SHOWN = 1000

type Client = Awaited<ReturnType<typeof createClient>>
type Side = 'all' | 'inbound' | 'output'

const EMBED = {
    all: `inbound_batches ( code, materials ( code, name ) ),
          output_batches ( code, materials ( code, name ) )`,
    inbound: `inbound_batches!inner ( code, materials!inner ( code, name ) ),
              output_batches ( code, materials ( code, name ) )`,
    output: `inbound_batches ( code, materials ( code, name ) ),
             output_batches!inner ( code, materials!inner ( code, name ) )`,
} as const
const COLS = `id, business_date, occurred_at, movement_type, qty_delta, stock_status,
              location_id, inbound_batch_id, output_batch_id, notes,
              storage_locations ( code ),`

/** 物料 / 批次有没有一条生效 —— 有就走两侧,没有就一条读取。指名一条流水时两者都不生效。 */
const narrowsByBatch = (p: LedgerParams) => !p.movementId && Boolean(p.materialId || p.batchCode)
const sidesOf = (p: LedgerParams): Side[] => (narrowsByBatch(p) ? ['inbound', 'output'] : ['all'])
// 批次号是「包含」(从前是 includes,不分大小写)—— ilike 里 % _ \ 是通配,人打进来的要按字面
const likeLiteral = (v: string) => `%${v.replace(/[\\%_]/g, (c) => `\\${c}`)}%`

function sideQuery(supabase: Client, side: Side, p: LedgerParams, head: boolean) {
    let q = head
        ? supabase.from('inventory_movements').select(side === 'all' ? 'id' : `id, ${EMBED[side]}`, { count: 'exact', head: true })
        : supabase.from('inventory_movements').select(`${COLS} ${EMBED[side]}`)
    // ★【指名一条流水时,【不】套那个 90 天默认窗】★
    //   这一条要是漏了,这次修复就修出一个更坏的东西:一个被删了一年的批次,
    //   它的注销流水落在窗外,页面会画出【一张自信的空表】——
    //   而"这条流水不在这个日期区间里"与"这条流水不存在"在屏幕上分不开。
    //   本仓库为这条区别付过账(gl_control_reconciliation 的「照答会返回一个
    //   自信的 0.00」是同一句话的另一处)。指名一条 id 是一次【定位】,不是一次浏览。
    if (p.movementId) {
        q = q.eq('id', p.movementId)
    } else {
        if (p.from) q = q.gte('business_date', p.from)
        if (p.to) q = q.lte('business_date', p.to)
        if (side !== 'all') {
            const rel = side === 'inbound' ? 'inbound_batches' : 'output_batches'
            if (p.materialId) q = q.eq(`${rel}.materials.code`, p.materialId)
            if (p.batchCode) q = q.ilike(`${rel}.code`, likeLiteral(p.batchCode))
        }
    }
    return q
}

function ordered<Q extends { order: (c: string, o: { ascending: boolean; nullsFirst?: boolean }) => Q }>(q: Q): Q {
    return q.order('business_date', { ascending: false, nullsFirst: false })
        .order('occurred_at', { ascending: false })
        .order('id', { ascending: true })
}

/** 与上面三个 order 同一个比较 —— 两侧合并时用。 */
export function ledgerOrder(a: LedgerRow, b: LedgerRow): number {
    if (a.business_date !== b.business_date) {
        if (a.business_date === null) return 1
        if (b.business_date === null) return -1
        return a.business_date < b.business_date ? 1 : -1
    }
    if (a.occurred_at !== b.occurred_at) return Date.parse(b.occurred_at) - Date.parse(a.occurred_at)
    return a.id < b.id ? -1 : a.id > b.id ? 1 : 0
}

/** 与页面同一套筛选的总行数(两侧之和)。 */
export async function ledgerCount(supabase: Client, p: LedgerParams): Promise<number> {
    let n = 0
    for (const side of sidesOf(p)) n += mustCount(await sideQuery(supabase, side, p, true), `inventory_movements count (${side})`)
    return n
}

/** 一侧的第 from..to 行(那一侧自己的次序)。 */
export function ledgerSidePage(supabase: Client, side: Side, p: LedgerParams, from: number, to: number) {
    return ordered(sideQuery(supabase, side, p, false)).range(from, to)
        .then(({ data, error }) => ({ error, data: data as unknown as LedgerRow[] | null }))
}

/** 页面与 PDF:合并后最新的 LEDGER_SHOWN 条 —— 每一侧各取前 LEDGER_SHOWN 条就一定够(合并的前 N 条只能来自各侧的前 N 条)。 */
export async function fetchLedger(p: LedgerParams): Promise<LedgerRow[]> {
    const supabase = await createClient()
    const sides = await Promise.all(sidesOf(p).map(async (side) =>
        mustRows(await ledgerSidePage(supabase, side, p, 0, LEDGER_SHOWN - 1), `inventory_movements (${side})`)))
    return sides.flat().sort(ledgerOrder).slice(0, LEDGER_SHOWN)
}

/** 导出:每一侧翻页取全(上限 50,000),合并,同一个次序。 */
export async function fetchLedgerAll(supabase: Client, p: LedgerParams): Promise<LedgerRow[]> {
    const sides = await Promise.all(sidesOf(p).map((side) =>
        fetchAllPages((from, to) => ledgerSidePage(supabase, side, p, from, to), `inventory_movements (${side})`, EXPORT_CAP)))
    return sides.flat().sort(ledgerOrder)
}

export const flatten = (r: LedgerRow) => {
    const mat = r.inbound_batches?.materials ?? r.output_batches?.materials ?? null
    return {
        date: r.business_date ?? '',
        batch: r.inbound_batches?.code ?? r.output_batches?.code ?? '',
        material: mat ? `${mat.code} ${mat.name}` : '',
        materialCode: mat?.code ?? '',
        location: r.storage_locations?.code ?? '',
        type: r.movement_type,
        status: r.stock_status,
        qty: r.qty_delta,
        notes: r.notes ?? '',
    }
}
