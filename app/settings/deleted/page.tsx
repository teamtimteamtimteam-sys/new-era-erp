// app/settings/deleted/page.tsx
// AUDEL-3:一个看得见"删掉了什么"的地方。
//
// 【为什么它要存在】AUDEL-1b 让每一次软删记下【谁】与【为什么】,AUDEL-2 把理由
// 问了出来 —— 而在此之前,那些记录【一处都不显示】:所有列表与详情页都过滤
// `deleted_at IS NULL`,一条被删的记录在系统里没有任何界面。记下来却看不见,
// 与没记下来在审计上是同一件事。
//
// ════════════════════════════════════════════════════════════════════════════
// ★★【UI-FIX-1 ⑦(2026-09-02):这一页的门换了,而下面两段旧文必须先更正】★★
// ════════════════════════════════════════════════════════════════════════════
// 【它现在属于【设置】,只属于设置】Tim 裁定这一页是【审计性质】的,不是日常的。
// 属主从「采购 / 运营 / 销售 / 库存」四个收成【设置】一个;
// 判据从「六个模块码任一」换成 **action.manage_permissions** ——
// 也就是把着 /settings/accounts 与 /settings/approvals 的那同一个码。
//
// ★【这是本刀唯一一处【真的】改了谁进得去的地方,代价照直写在这里】★
//   对着 live 授权实测(role_permissions,2026-09-02):
//     改动前看得见的 9 个角色:admin auditor cfo finance gm operations
//                              procurement sales warehouse
//     改动后看得见的 1 个角色:admin
//   Tim 预期失去的是采购 / 仓库 / 销售 —— 它们确实失去了;
//   **一并失去的还有 auditor、gm、cfo、finance 与 operations**,
//   而 auditor 那一条留给他再看一眼(一页被判为"审计性质",却挡住了审计角色)。
//   完整推理与那张表在 docs/information-architecture.md §13.2.3。
//
// 【下面这一段写的是 NAV-REG-1 当时的形态,读的时候要知道它已经被上面那段取代】
// —— 它留着不是懒,是因为"六个码的并集"那条推理【解释了行一级的过滤为什么长这样】,
//    而行一级的过滤【一个字没动】。
//
// 【权限:每一行跟着它自己模块的读权限,没有新权限码】
// 视图 deleted_records 每支自带 permission 列,外层 has_permission 按调用者裁决,
// 于是【无权的那一类整类缺席】—— 不是显示成零。这是 /margin 那一课:
// 为跨模块页面合成一个新权限码,会是"谁能看什么"的第二份定义。
// ★ 上面那次改判【没有】新造码:action.manage_permissions 是一个早就存在的码,
//   而视图里那六个码一个都没动 —— 换掉的只是【这一页的门】。
// 【为什么现在要把关,而从前不把】从前不把关的理由是"藏错的代价比露错的大":
// 加一道守卫就意味着一个模块都没有的人【看不见这个入口】。R4 之后那个代价没有了 ——
// 导航条把进不去的项画成「受限」而不是藏起来。于是剩下的只有好处:一个模块都没有的
// 人看到的不再是一张空表(与"没人删过东西"分不清),而是一句权限答复。
// 【行一级的过滤一字未动】进来之后看得见哪几类,仍然由每一行自己的 has_permission
// 决定 —— 本守卫只回答"这一页对你有没有意义",不回答"你看得见哪几行"。
//
// 【永不提供恢复】撤销删除是一个没有人做过的决定 —— 台账上已经有一条注销流水、
// 回滚的投入已经还回去了。这里放一个按钮等于替所有人默默把那个决定做了。
// 本页只读,连一个可写入口都没有。
import { DatePicker } from '@/app/components/ui/date-picker'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/server'
import { getTranslations } from '@/lib/i18n/server'
import { mustRows } from '@/lib/db-helpers'
import { isYmd } from '@/lib/dateFilter'
import ActorName, { loadActorNames } from '@/app/components/ActorName'
import { ListPage } from '@/app/components/ui/list-page'
import DeletedTable, { type DeletedRow } from './DeletedTable'
import { requireFunction } from '@/app/components/moduleGuard'
import { FN } from '@/lib/modules'
import { Button } from '@/app/components/ui/button'
import { formatTrailStamp } from '@/lib/dates'

type Row = {
    record_kind: string
    permission: string
    record_id: string
    code: string
    deleted_at: string
    deleted_by: string | null
    delete_reason: string | null
    movement_id: string | null
    detail: string | null
}

// 种类 → 它属于哪张页面。认不出的种类【不给链接】而不是猜一个:
// 一个合法的 uuid 指错了表,打开的是别人的单据,而且不会报错(首页那一课)。
// ★ AUDIT-TRAIL-1b-3(Tim 的 Q9 · Q21):每一种都有落点了 ——
//   · 销售订单与报价那两条链接此前是【死的】(详情页过滤掉已删的,404);采购单同一个毛病。
//     现在三页都对持 data.view_deleted 的人只读打开(横幅 + 审计记录),别人得到一句具名拒绝,不是 404。
//   · 客户 · 供应商 · 物料 · 定价公式四类新加,落到它们各自那一页(后三种只有编辑页),同样只读带横幅。
//   · 注销的批次与回滚的加工单:这里原来写着"没有详情页 —— 这一页就是它唯一的落点",
//     那句话自 AUDIT-TRAIL-1b-1 起就不成立了(它们对本来的读者只读打开、带横幅),所以也接上。
const KIND_HREF: Record<string, (id: string) => string | null> = {
    inbound_batch: (id) => `/inbound/${id}/edit`,
    output_batch: (id) => `/output/${id}/edit`,
    processing_run: (id) => `/operation/processing/${id}`,
    stocktake: (id) => `/stocktakes/${id}`,
    purchase_order: (id) => `/purchasing/orders/${id}`,
    sales_order: (id) => `/sales/orders/${id}`,
    quote: (id) => `/sales/quotes/${id}`,
    customer: (id) => `/sales/customers/${id}`,
    supplier: (id) => `/suppliers/${id}/edit`,
    material: (id) => `/materials/${id}/edit`,
    pricing_formula: (id) => `/tools/pricing/formulas/${id}/edit`,
    // AUDIT-TRAIL-1c-2(Tim 的 Q6):删掉的对账单以前在详情页上 404、在清单上被藏起来 —— 一处都看不见。
    //   现在它对持 data.view_deleted 的人只读打开(横幅 + 审计记录),这里是它的入口
    bank_statement: (id) => `/finance/bank/statements/${id}`,
    // AUDIT-TRAIL-1d-1(Tim 的 Q25 · Q26):删掉的角色 · 员工 · 部门 · 培训记录 —— 以前在各自那一页 404、这里也没有它们;
    //   现在对持 data.view_deleted 的人只读打开(横幅 + 审计记录),这里是入口。部门与培训记录只有编辑页
    role: (id) => `/settings/roles/${id}`,
    employee: (id) => `/hr/employees/${id}`,
    department: (id) => `/hr/departments/${id}/edit`,
    training_record: (id) => `/hr/training/${id}/edit`,
}

const KINDS = Object.keys(KIND_HREF)

export default async function DeletedRecordsPage({
    searchParams,
}: {
    searchParams: Promise<{ kind?: string; from?: string; to?: string }>
}) {
    const denied = await requireFunction(FN.deleted)
    if (denied) return denied

    const sp = await searchParams
    const supabase = await createClient()
    const t = await getTranslations()

    const kind = KINDS.includes(sp.kind ?? '') ? (sp.kind as string) : ''
    const from = isYmd(sp.from ?? '') ? (sp.from as string) : ''
    const to = isYmd(sp.to ?? '') ? (sp.to as string) : ''

    let q = supabase
        .from('deleted_records')
        .select('record_kind, permission, record_id, code, deleted_at, deleted_by, delete_reason, movement_id, detail')
        .order('deleted_at', { ascending: false })
    if (kind) q = q.eq('record_kind', kind)
    if (from) q = q.gte('deleted_at', from)
    // to 是一个【日期】,而 deleted_at 是时刻 —— 用当天的下一天做上界,
    // 否则当天的记录会被整天漏掉(经典的边界错)。
    if (to) q = q.lt('deleted_at', new Date(new Date(to).getTime() + 86400000).toISOString().slice(0, 10))

    // 【失败必须失败】不 `?? []`:读不出来会渲染成"什么都没删过",
    // 而那正是这一页最不能撒的谎。
    const rows = mustRows(await q, 'deleted_records') as unknown as Row[]

    // 一次把姓名查回来(逐行查会是 N 次往返)
    const names = await loadActorNames(supabase, rows.map((r) => r.deleted_by))

    function filterHref(next: { kind?: string; from?: string; to?: string }) {
        const p = new URLSearchParams()
        const k = next.kind ?? kind
        const f = next.from ?? from
        const tt = next.to ?? to
        if (k) p.set('kind', k)
        if (f) p.set('from', f)
        if (tt) p.set('to', tt)
        const s = p.toString()
        return s ? `/settings/deleted?${s}` : '/settings/deleted'
    }

    // CONV-5:套 CONV-1 的两文件模板。
    // ★ state 恒为 'ok' —— 种类筛选与日期表单是真实出口(§⑩-3),而那句
    //   noRestoreNote(「没有恢复,那是一个决定不是一个遗漏」)必须无条件出现,
    //   所以它走 notices。空态那句【同时说两件事】的话(不是"什么都没删过",
    //   是"你看得见的范围里没有")由 DataTable 自己的 empty 说。
    const tableRows: DeletedRow[] = rows.map((r) => ({
        key: `${r.record_kind}-${r.record_id}`,
        kindLabel: t('deleted.kind.' + r.record_kind),
        code: r.code,
        detail: r.detail ?? null,
        href: KIND_HREF[r.record_kind]?.(r.record_id) ?? null,
        // AUDIT-TRAIL-1a(Q15):这一页的时刻与审计记录同一种写法 —— DD/MM/YYYY HH:MM,新加坡时间
        whenLabel: formatTrailStamp(r.deleted_at),
        // 服务端渲染好的四态元素 —— 判据不过边界,元素过(见 DeletedTable 抬头)
        whoCell: (
            <ActorName
                userId={r.deleted_by}
                names={names}
                unrecordedHint={t('deleted.beforeAudel1b')}
            />
        ),
        reason: r.delete_reason || null,
        ledgerHref: r.movement_id ? `/inventory/reports/ledger?movement=${r.movement_id}` : null,
        reversalIsTheRun: r.record_kind === 'processing_run',
    }))

    return (
        <ListPage
            title={t('deleted.title')}
            intro={t('deleted.intro')}
            notices={
                /* 【说清这一页不能做什么】—— 没有恢复,而那是一个决定,不是一个遗漏 */
                <p className="text-sm text-[color:var(--brand-text)] bg-gray-50 border border-gray-200 rounded px-3 py-2 mb-4 max-w-3xl">
                    {t('deleted.noRestoreNote')}
                </p>
            }
            state={{ kind: 'ok' }}
        >
            {/* ── 筛选:种类 + 日期 ─────────────────────────────────────────── */}
            <div className="flex flex-wrap items-center gap-2 mb-4 text-sm">
                <Link
                    href={filterHref({ kind: '' })}
                    className={
                        'px-2 py-1 rounded border ' +
                        (kind === '' ? 'bg-gray-200 border-gray-400' : 'border-gray-300 hover:bg-gray-50')
                    }
                >
                    {t('deleted.allKinds')}
                </Link>
                {KINDS.map((k) => (
                    <Link
                        key={k}
                        href={filterHref({ kind: k })}
                        className={
                            'px-2 py-1 rounded border ' +
                            (kind === k ? 'bg-gray-200 border-gray-400' : 'border-gray-300 hover:bg-gray-50')
                        }
                    >
                        {t('deleted.kind.' + k)}
                    </Link>
                ))}
                {/* CONV-5:390px 上这一行原本把整页顶宽 27px(两个日期框 + 按钮
                    在 ml-auto 后面排成一条不折行的 385px)。加 flex-wrap ——
                    表格那一半本来就没有溢出,溢出的一直是这条筛选行。 */}
                <form className="flex flex-wrap items-center gap-2 sm:ml-auto" action="/settings/deleted">
                    {kind && <input type="hidden" name="kind" value={kind} />}
                    {/* DATE-PICK-1:两个日期框是全站共用的 DatePicker(提交的仍是 ISO 的 from / to) */}
                    <DatePicker name="from" defaultValue={from} aria-label={t('changeHistory.filterFrom')} />
                    <span className="text-[color:var(--brand-muted-text)]">–</span>
                    <DatePicker name="to" defaultValue={to} aria-label={t('changeHistory.filterTo')} />
                    <Button variant="secondary" type="submit">
                        {t('common.filter')}
                    </Button>
                </form>
            </div>

            <DeletedTable rows={tableRows} empty={t('deleted.empty')} />
        </ListPage>
    )
}
