'use client'

// ════════════════════════════════════════════════════════════════════════════
// BASE-1(2026-09-02)· 取样页的第二节 —— 【组件层,连同它的手机形态】
// ════════════════════════════════════════════════════════════════════════════
// BRAND-1 那三个变体是【选样子】的;这一节不是选样子,是【看东西能不能用】。
// Tim 要在这一页上亲眼看到的三件:
//   ① 一张 13 列的账簿在 390px 上还是不是一张账簿(把窗口拖窄,或用手机开);
//   ② 四种拒绝态收敛成一种之后是什么样(以及它旁边那一排"从前的十种");
//   ③ 四种状态动效各是什么感觉 —— 尤其是【会不会烦】。
//
// 【数据是编的】形状取自 /inbound(全站最宽的一张表,13 列),数字与人名都是假的。
// ════════════════════════════════════════════════════════════════════════════

import * as React from 'react'
import { DataTable, type Column } from '@/app/components/ui/data-table'
import { Refusal } from '@/app/components/ui/refusal'
import { CountUp, Skeleton } from '@/app/components/ui/feedback'
import { Button } from '@/app/components/ui/button'
import { Input } from '@/app/components/ui/input'

type Row = {
    code: string; material: string; supplier: string; source: string
    qty: number; remaining: number; arrival: string
    stage: '待加工' | '加工中' | '已加工完'
    status: string; pricing: 'unpriced' | 'provisional' | 'final'
    created: string; receivedBy: string | null; label: string
}

const ROWS: Row[] = [
    { code: 'IN-2026-0180', material: '动力电池模组(拆解件)', supplier: '南方再生资源', source: 'PO-2026-0041', qty: 12400, remaining: 12400, arrival: '2026-08-14', stage: '待加工', status: '在库', pricing: 'provisional', created: '2026-08-14', receivedBy: '陈国伟', label: 'LBL-0180' },
    { code: 'IN-2026-0181', material: '磷酸铁锂电芯', supplier: '华东电池回收', source: 'PO-2026-0043', qty: 8150, remaining: 3020, arrival: '2026-08-16', stage: '加工中', status: '在库', pricing: 'final', created: '2026-08-16', receivedBy: 'Priya Raman', label: 'LBL-0181' },
    { code: 'IN-2026-0182', material: '混合黑粉', supplier: '南方再生资源', source: 'PO-2026-0044', qty: 3020, remaining: 0, arrival: '2026-08-19', stage: '加工中', status: '无库存', pricing: 'provisional', created: '2026-08-19', receivedBy: null, label: 'LBL-0182' },
    { code: 'IN-2026-0183', material: '钴酸锂电芯(消费类)', supplier: '深圳绿循', source: '早于来源规则', qty: 640, remaining: 640, arrival: '2026-08-21', stage: '待加工', status: '在库', pricing: 'unpriced', created: '2026-08-21', receivedBy: null, label: 'LBL-0183' },
    { code: 'IN-2026-0184', material: '镍钴铝正极边角料', supplier: '华东电池回收', source: 'PO-2026-0047', qty: 1875, remaining: 1875, arrival: '2026-08-25', stage: '已加工完', status: '在库', pricing: 'final', created: '2026-08-25', receivedBy: '陈国伟', label: 'LBL-0184' },
    { code: 'IN-2026-0185', material: '三元前驱体废料', supplier: '江苏锂源', source: 'PO-2026-0049', qty: 5420, remaining: 5420, arrival: '2026-08-27', stage: '待加工', status: '在库', pricing: 'provisional', created: '2026-08-27', receivedBy: 'Priya Raman', label: 'LBL-0185' },
    { code: 'IN-2026-0186', material: '废旧动力电池包', supplier: '深圳绿循', source: 'PO-2026-0052', qty: 22100, remaining: 18400, arrival: '2026-08-29', stage: '加工中', status: '在库', pricing: 'final', created: '2026-08-29', receivedBy: '陈国伟', label: 'LBL-0186' },
    { code: 'IN-2026-0187', material: '铜箔边角料', supplier: '江苏锂源', source: 'PO-2026-0053', qty: 940, remaining: 940, arrival: '2026-09-01', stage: '待加工', status: '在库', pricing: 'unpriced', created: '2026-09-01', receivedBy: null, label: 'LBL-0187' },
]

const num = (n: number) => n.toLocaleString('zh-Hans-CN', { minimumFractionDigits: 2 })

// ★ priority 就是【手机上留在表里的那几列】—— 这张表自己声明,组件不猜。
//   选的是「批次号 + 物料 + 余量」:在手机上找一批货,人问的是"哪一批、什么料、还剩多少"。
//   注意【不是前三列】—— 前三列是批次号、物料、供应商,而供应商在手机上让位给余量。
const COLUMNS: Column<Row>[] = [
    // 【批次号不许折行】390px 实测第一版把 IN-2026-0180 折成三行,一行占掉三行高。
    // 它是一个定长标识符,折了既不好看也不好认 —— 这一条是【这一列自己的判断】,
    // 所以写在列定义里,而不是让组件对所有列一刀切。
    { key: 'code', header: '批次号', priority: true, className: 'whitespace-nowrap', sortValue: (r) => r.code, render: (r) => <span className="font-mono text-xs">{r.code}</span> },
    { key: 'material', header: '物料', priority: true, sortValue: (r) => r.material, render: (r) => r.material },
    { key: 'remaining', header: '余量 (kg)', priority: true, align: 'right', sortValue: (r) => r.remaining, // 【密表格子里用短词,双语全称留给上面那份目录与 title】——
      // 一个格子里的 20 个字符会把整列撑宽,而在只剩三列的手机上那是最贵的一件事。
      render: (r) => (r.remaining === 0 ? <Refusal why="余量为 0 —— 这是一个【事实】,不是一次拒绝(out of stock)。">无库存</Refusal> : num(r.remaining)) },
    { key: 'supplier', header: '供应商', sortValue: (r) => r.supplier, render: (r) => r.supplier },
    { key: 'source', header: '来源', render: (r) => (r.source.startsWith('PO-') ? <span className="font-mono text-xs">{r.source}</span> : <Refusal why="这批货早于来源规则,既没有订单行也没有理由。刻意不回填:猜一个会伪造历史。">未说明 · Unexplained</Refusal>) },
    { key: 'qty', header: '收货量 (kg)', align: 'right', sortValue: (r) => r.qty, render: (r) => num(r.qty) },
    { key: 'arrival', header: '到货日', sortValue: (r) => r.arrival, render: (r) => r.arrival },
    { key: 'stage', header: '阶段', sortValue: (r) => r.stage, render: (r) => r.stage },
    { key: 'status', header: '库存状态', render: (r) => r.status },
    { key: 'pricing', header: '计价状态', sortValue: (r) => r.pricing, render: (r) => r.pricing },
    { key: 'unitPrice', header: '单价', align: 'right', render: () => <Refusal why="common.restricted —— 你没有权限看这个值,而不是这个值是空的。">受限 · Restricted</Refusal> },
    { key: 'receivedBy', header: '收货人', render: (r) => (r.receivedBy ?? <Refusal why="actor.unrecorded —— 当时没有人记下是谁做的,而不是这个人不存在。">未记录 · not recorded</Refusal>) },
    { key: 'label', header: '标签', render: (r) => <span className="font-mono text-xs">{r.label}</span> },
]

function H({ children }: { children: React.ReactNode }) {
    return <h3 className="mt-10 mb-3 border-b-2 border-[color:var(--brand-ocean)] pb-1.5 text-xl font-bold text-[color:var(--brand-text)]">{children}</h3>
}
function Note({ children }: { children: React.ReactNode }) {
    return <p className="mb-3 max-w-3xl text-sm leading-relaxed text-[color:var(--brand-muted-text)]">{children}</p>
}

export function Base1() {
    const [saved, setSaved] = React.useState(0)
    const [invalid, setInvalid] = React.useState(false)
    const [busy, setBusy] = React.useState(false)
    const [total, setTotal] = React.useState(48210)

    return (
        <section className="mb-24">
            <h2 className="mb-2 text-2xl font-bold text-[color:var(--brand-text)]">
                BASE-1 · 组件层(表格 / 动效 / 拒绝态)
            </h2>
            <Note>
                这一节不是让你选样子,是让你【试】。最要紧的一件事:把浏览器窗口拖到手机宽度
                (或者直接用手机打开这一页),看下面那张 13 列的表变成什么。
            </Note>

            <H>① 一张 13 列的账簿 —— 桌面上是账簿,390px 上【仍然是账簿】</H>
            <Note>
                形状取自 /inbound,全站最宽的一张表。桌面上 13 列全在;
                窄到 640px 以下时,只留【批次号 · 物料 · 余量】三列,其余十列收进每行左边那个
                「›」里,点开是一段带标签的列表。<strong>它没有变成卡片流</strong> ——
                一张账簿存在的意义是顺着一列往下比,而 8 行变成 8 张卡片之后那件事就做不了了。
                四个能力(排序 / 筛选 / 分页 / 列显隐)在这里【全部打开】只是为了让你看见它们;
                它们默认是关的,换上这个组件不会给任何页面凭空多出一个控件。
            </Note>
            <DataTable
                rows={ROWS}
                columns={COLUMNS}
                rowKey={(r) => r.code}
                sorting={{ mode: 'client', coverage: 'complete' }}
                filter={{ label: '筛选:批次号 / 物料 / 供应商', match: (r, q) => (r.code + r.material + r.supplier).toLowerCase().includes(q.toLowerCase()) }}
                pageSize={5}
                columnToggle
                caption="样例数据 · 不连库"
            />

            <H>② 拒绝态 —— 【一种画法】替掉十种</H>
            <Note>
                词没有漂,漂的是颜色:<code>t(&apos;common.restricted&apos;)</code> 出现 41 处、横跨 32 个文件,
                而直接包着它的元素上有 <strong>12 种</strong>不同的 className 写法,
                于是同一句话在不同页面上分量完全不同。
                左边是今天真实存在的几种,右边是收敛之后的那一种。
                四个字眼共用一种颜色 —— 区分由【词】承担,颜色只承担「这是一句拒绝」。
            </Note>
            <div className="grid gap-6 sm:grid-cols-2">
                <div className="rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] p-4">
                    <p className="mb-3 text-sm font-medium text-[color:var(--brand-text)]">今天(节选,全是真实写法)</p>
                    <ul className="space-y-2 text-sm">
                        <li><span className="text-gray-400 italic">受限 · Restricted</span> <span className="text-xs text-[color:var(--brand-muted-text)]">— text-gray-400 italic</span></li>
                        <li><span className="text-sm text-gray-600">受限 · Restricted</span> <span className="text-xs text-[color:var(--brand-muted-text)]">— text-sm text-gray-600(10 处,最常见)</span></li>
                        <li><span className="text-gray-500">受限 · Restricted</span> <span className="text-xs text-[color:var(--brand-muted-text)]">— text-gray-500</span></li>
                        <li><span className="border border-gray-300 px-2 py-2 text-right font-mono text-xs">受限</span> <span className="text-xs text-[color:var(--brand-muted-text)]">— font-mono text-xs 在表格里</span></li>
                        <li><span className="text-3xl font-bold text-gray-300">受限</span> <span className="text-xs text-[color:var(--brand-muted-text)]">— text-3xl(一张卡的大数字位)</span></li>
                    </ul>
                </div>
                <div className="rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] p-4">
                    <p className="mb-3 text-sm font-medium text-[color:var(--brand-text)]">收敛之后(变体 C 的填充小片 + 一条量过的边)</p>
                    <ul className="space-y-2.5 text-sm">
                        <li><Refusal why="你没有权限看这个值,而不是这个值是空的。">受限 · Restricted</Refusal></li>
                        <li><Refusal why="当时没有人记下是谁做的,而不是这个人不存在。">未记录 · not recorded</Refusal></li>
                        <li><Refusal why="记了总数、没有分类 —— 不是分类是 0。">未说明 · Unexplained</Refusal></li>
                        <li><Refusal why="余量为 0 —— 这是一个事实,不是一次拒绝。">无库存 · out of stock</Refusal></li>
                    </ul>
                    <p className="mt-3 text-xs text-[color:var(--brand-muted-text)]">
                        片内文字 12.59:1 ✓ AA。★ 那条边是本刀加的:变体 C 原样的填充色对着页底只有
                        1.05:1,在真实页面上几乎看不出是一个片。
                    </p>
                </div>
            </div>

            <H>③ 四种状态动效 —— 【会不会烦】要按几下才知道</H>
            <Note>
                R1:动效只用来反馈状态,永不装饰。下面四种就是全部 ——
                没有入场动画、没有页面转场、没有会跳的按钮。
                三种是纯 CSS,只有「数字变了」需要一个逐帧循环(~15 行 rAF),
                而那一行就是 motion.dev 要顶替的全部东西。
                <strong>系统偏好里打开「减弱动效」再看一遍</strong>:动全停,而颜色、禁用、骨架一个不少。
            </Note>
            <div className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
                <div className="rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] p-4">
                    <p className="mb-2 text-sm font-medium text-[color:var(--brand-text)]">成功</p>
                    <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">写完之后屏幕常常什么都没变,于是分不清「存好了」和「点漏了」。</p>
                    <div key={saved} className={saved > 0 ? 'base-flash-ok rounded p-2' : 'rounded p-2'}>
                        <span className="text-sm text-[color:var(--brand-text)]">这一行刚刚保存过</span>
                    </div>
                    <Button className="mt-2" onClick={() => setSaved((n) => n + 1)}>保存</Button>
                </div>
                <div className="rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] p-4">
                    <p className="mb-2 text-sm font-medium text-[color:var(--brand-text)]">校验失败</p>
                    <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">焦点常常不在出错那一格;一次极短的位移把眼睛带过去。</p>
                    <Input nudgeOnInvalid aria-invalid={invalid || undefined} defaultValue="不是一个数" />
                    <Button variant="outline" className="mt-2" onClick={() => { setInvalid(false); setTimeout(() => setInvalid(true), 30) }}>提交</Button>
                </div>
                <div className="rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] p-4">
                    <p className="mb-2 text-sm font-medium text-[color:var(--brand-text)]">加载中</p>
                    <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">「在取数」和「取回来是空的」在屏幕上长得一模一样。</p>
                    <div className="space-y-1.5"><Skeleton className="h-4 w-full" /><Skeleton className="h-4 w-4/5" /><Skeleton className="h-4 w-2/3" /></div>
                    <Button pending={busy} className="mt-3" onClick={() => { setBusy(true); setTimeout(() => setBusy(false), 2200) }}>
                        {busy ? '提交中…' : '提交(2.2 秒)'}
                    </Button>
                </div>
                <div className="rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] p-4">
                    <p className="mb-2 text-sm font-medium text-[color:var(--brand-text)]">数字变了</p>
                    <p className="mb-3 text-xs text-[color:var(--brand-muted-text)]">总数悄悄从一个数变成另一个,和它一直是那个数,在屏幕上一样。</p>
                    <p className="text-3xl font-bold text-[color:var(--brand-text)]"><CountUp value={total} /> <span className="text-sm font-normal">kg</span></p>
                    <Button variant="outline" className="mt-2" onClick={() => setTotal((t) => t + Math.round(1200 + Math.abs(Math.sin(t) * 4000)))}>再收一批</Button>
                </div>
            </div>

            <H>④ 卡片要不要磨砂 —— 【看着选,别读我的论证】</H>
            <Note>
                R2 把这一条留给了判断。我的建议是<strong>不要</strong>,理由是:
                卡片不是浮动层 —— 它底下什么都不经过,所以磨砂没有东西可以透出来,
                却要为此降低卡片里每一个数字的对比度。但这是一个看着才能定的事,所以两个都画在这里。
                (顶栏与 dock 上的磨砂不在这个问题里 —— 那些是真的浮动层,内容真的从底下滚过去。)
            </Note>
            <div className="grid gap-4 sm:grid-cols-2">
                <div className="rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] bg-[color:var(--brand-surface)] p-4 shadow-md">
                    <p className="text-sm font-medium text-[color:var(--brand-text)]">不磨砂(建议)· 实心白面</p>
                    <p className="mt-2 text-2xl font-bold text-[color:var(--brand-text)]">48,210.00 <span className="text-sm font-normal">kg</span></p>
                    <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">数字对白面 14.13:1</p>
                </div>
                <div className="nav-glass rounded-[var(--brand-radius)] border border-[color:var(--brand-border)] p-4 shadow-md">
                    <p className="text-sm font-medium text-[color:var(--brand-text)]">磨砂 · 与顶栏同一档(0.90)</p>
                    <p className="mt-2 text-2xl font-bold text-[color:var(--brand-text)]">48,210.00 <span className="text-sm font-normal">kg</span></p>
                    <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">底下没有东西经过,所以它看起来【只是白了一点点】</p>
                </div>
            </div>
        </section>
    )
}
