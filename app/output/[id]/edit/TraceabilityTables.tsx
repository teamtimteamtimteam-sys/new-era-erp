'use client'

// app/output/[id]/edit/TraceabilityTables.tsx
// TABLE-CONVERT-5:AUD-2 可追溯报告那两张手搓 <table> 换成 DataTable ——
//   ① 血缘链(6 列)· ② 回收率(7 列)
//
// 【为什么两张合一个文件】TraceabilitySection 是 server component,两张表都要过
//   server→client 那道边界(Column.render 是函数)。同一页、同一次判断,合成一个
//   client 文件 —— 与 TABLE-CONVERT-4 的 output/[id]/assays/[assayId]/AssayTables.tsx 同形。
//
// ★★【单元格文案仍然由 app/output/traceabilityShared.ts 出,一份实现两个消费者】★★
//   recoveryText / sourceText / kgText 在【服务端】就调好了,本文件拿到的是成品字串。
//   这不是图省事:那三个函数同时喂着 PDF,屏幕这一侧一旦自己拼一遍,
//   "客户手里那张纸"与"屏幕上这一行"就会各说各的 —— 而这正是 AUD-2 最不能出的错。
//
// ★★【这两张表此前【没有】手机档判断 —— 本刀是第一个做的】★★
//   转换前一处 hidden sm:table-cell 都没有。TABLE-MEASURE-1 实测:
//   ① 要横拖 145px、行高 145px / 折 8 行;② 要横拖 196px、七列里【两列完全看不见】,
//   两张的身份列都是 static,横滚到底就离开视野。**这两张是六张里最坏的两张。**
import Link from 'next/link'
import { useTranslations } from '@/lib/i18n/client'
import { DataTable, type Column } from '@/app/components/ui/data-table'

// ── ① 血缘链(6 列)────────────────────────────────────────────────────────
/** 服务端压平好的一行 —— 一个函数都没有。 */
export type ChainTableRow = {
    key: string
    depth: string
    runId: string
    runCode: string
    /** 上游那一批是进料还是产出 —— 服务端已经译成文案 */
    parentKindLabel: string
    parentHref: string
    parentCode: string
    quantityConsumed: string
    supplierCode: string | null
    supplierName: string | null
    arrivalDate: string
}

export function ChainTable({ rows }: { rows: readonly ChainTableRow[] }) {
    const t = useTranslations()

    // ★★【留哪两列 —— 加工单 · 上游批次】★★
    //   这张表的一行就是【血缘上的一跳】:某一支加工单吃掉了某一个上游批次。
    //   行键写的就是这件事(`${depth}-${via_run_id}-${parent_batch_id}`)——
    //   而那三样里,能让人认出"这是哪一跳"的是【加工单】与【上游批次】两个单号。
    //
    // 【层级(Step)为什么折 —— 而这一条我要说白】
    //   它只有一个数字,可它在 table-fixed 下要吃掉整整一列的宽度(见下面那条登记)。
    //   行本来就按层级顺序画出来,而层级本身带着列头躺在展开区里,一点就到。
    //   ☞ 这是本刀六个判断里【最接近可以两说】的一个,照直摆在这里给 Tim 看。
    //
    // 【消耗量 / 供应商 / 到货日 为什么折】三样都是【上游那一批】的属性,
    //   不是这一跳本身;而且供应商只在链末的进料父上有值,上游几跳全是 '—'
    //   —— 拿三分之一的屏宽去画一列破折号,是这张表最不划算的一笔。
    const columns: Column<ChainTableRow>[] = [
        {
            key: 'step',
            header: t('traceability.colStep'),
            align: 'right',
            render: (c) => c.depth,
        },
        {
            key: 'run',
            header: t('traceability.colRun'),
            // ★ 这一跳是哪一支加工单 —— 手机上留下。
            priority: true,
            render: (c) => (
                <Link href={`/operation/processing/${c.runId}`} className="hover:underline app-link">
                    {c.runCode}
                </Link>
            ),
        },
        {
            key: 'parent',
            header: t('traceability.colParent'),
            // ★ 这一跳吃掉了哪一批 —— 手机上留下。可追溯报告问的就是它。
            priority: true,
            render: (c) => (
                <>
                    <span className="text-gray-500 mr-1">{c.parentKindLabel}</span>
                    <Link href={c.parentHref} className="hover:underline app-link">
                        {c.parentCode}
                    </Link>
                </>
            ),
        },
        {
            key: 'qty',
            header: t('traceability.colQtyConsumed'),
            align: 'right',
            render: (c) => c.quantityConsumed,
        },
        {
            key: 'supplier',
            header: t('traceability.colSupplier'),
            // 供应商只在链末的进料父上有 —— 上游那几段的父是自家的产出批
            render: (c) =>
                c.supplierName ? (
                    <>
                        <span>{c.supplierCode}</span> {c.supplierName}
                    </>
                ) : (
                    '—'
                ),
        },
        {
            key: 'arrival',
            header: t('traceability.colArrival'),
            render: (c) => c.arrivalDate,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(c) => c.key}
            phone={{ mode: 'columns' }}
            className="mb-6"
        />
    )
}

// ── ② 回收率(7 列)────────────────────────────────────────────────────────
export type RecoveryTableRow = {
    key: string
    runCode: string
    /** 金属名 —— 服务端按金属码查字典译好 */
    metalLabel: string
    /** kgText(...) —— 没测过就是那句「未测量」,不是 0 */
    inputKg: string
    outputKg: string
    /** recoveryText(...) —— 算不出时这里是【具名原因】,不是空白也不是 0 */
    recoveryText: string
    /** recovery_pct 有值 = 真的是个百分比(等宽);没有 = 那是一句原因(灰字) */
    recoveryIsNumeric: boolean
    /** 守恒告警的文案;没有告警就是 null */
    conservationFlag: string | null
    /** sourceText(...) —— unknown 就印 unknown,不抹平成 assay */
    inputSource: string
    outputSource: string
}

export function RecoveryTable({ rows }: { rows: readonly RecoveryTableRow[] }) {
    const t = useTranslations()

    // ★★【留哪三列 —— 加工单 · 金属 · 回收率】★★
    //   身份【真的需要两列】:一支加工单有好几种金属,一种金属又横跨好几支加工单,
    //   所以"这是哪一行"的答案是【加工单 × 金属】—— 行键写的就是 `${run_id}-${metal}`。
    //   而结论是【回收率】:这张表存在的理由就是那个百分比。
    //   ☞ 读数说 390px 上七列里【有两列完全看不见】,要横拖 196px 才够得到最右边。
    //     被推出去的正是右边那几列,而回收率排第五 —— 它靠横拖才看得到。
    //
    // ★★【一条要给 Tim 看的取舍:出处这一次【折进了展开区】】★★
    //   TraceabilitySection.tsx 抬头那条规矩写着「**出处跟着数字走**」——
    //   不说出除的是哪一种数,这个百分比就没有意义。而本刀把 input_source /
    //   output_source 折了。**理由与它没有打架,但这是我自己的判断,不是搬运:**
    //     · 「算不出」那一半仍然贴着数字走:算不出时回收率这一格印的【就是具名原因】
    //       (input_not_measured 等),它跟着 priority 列一起留在明面上,一个字没动。
    //     · 折走的是「算得出时,这个数来自化验还是手录」——它进了展开区,
    //       带着自己的列头(Input content from / Output content from),点一下就到。
    //     · 另一条路是 mode:'scroll' 把七列全留下,但那正好把这一刀要治的病留在原地:
    //       196px 的横拖、两列完全看不见。**它治不了,所以不选它。**
    //   ☞ 如果 Tim 认为出处必须与百分比同屏,那是把它们提成 priority 的事,一行改动。
    const columns: Column<RecoveryTableRow>[] = [
        {
            key: 'run',
            header: t('traceability.colRun'),
            // ★ 身份之一 —— 手机上留下。
            priority: true,
            render: (r) => r.runCode,
        },
        {
            key: 'metal',
            header: t('traceability.colMetal'),
            // ★ 身份之二 —— 手机上留下。行键是 run × metal,少一个就认不出行。
            priority: true,
            render: (r) => r.metalLabel,
        },
        {
            key: 'inputKg',
            header: t('traceability.colInputKg'),
            align: 'right',
            render: (r) => r.inputKg,
        },
        {
            key: 'outputKg',
            header: t('traceability.colOutputKg'),
            align: 'right',
            render: (r) => r.outputKg,
        },
        {
            key: 'recovery',
            header: t('traceability.colRecovery'),
            // ★ 结论 —— 手机上留下。
            priority: true,
            align: 'right',
            // ⚠ 转换前这一格的 class 是【按行算的】(算不出 → text-gray-500,
            //   算得出 → 等宽),而组件今天【没有按行的格子 className】
            //   (已登记的缺口,不在本刀里修)。所以那个条件搬到了格子【里面】那层
            //   <span> 上。
            // ★★ FONT-3(2026-09-12):**等宽那一半没有了** —— 算得出的那一支从
            //   `font-mono` 变成 `undefined`(不发 class)。三元留着,因为
            //   **算不出的那一支仍然要灰**;两支之间今天分开的只有颜色,不再有字族。
            render: (r) => (
                <>
                    <span className={r.recoveryIsNumeric ? undefined : 'text-gray-500'}>
                        {r.recoveryText}
                    </span>
                    {r.conservationFlag && (
                        <span className="ml-2 text-amber-700">{r.conservationFlag}</span>
                    )}
                </>
            ),
        },
        {
            key: 'inputSource',
            header: t('traceability.colInputSource'),
            render: (r) => r.inputSource,
        },
        {
            key: 'outputSource',
            header: t('traceability.colOutputSource'),
            render: (r) => r.outputSource,
        },
    ]

    return (
        <DataTable
            rows={rows}
            columns={columns}
            rowKey={(r) => r.key}
            phone={{ mode: 'columns' }}
            className="mb-3"
        />
    )
}
