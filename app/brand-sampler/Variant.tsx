'use client'

// BRAND-1 · sampler 的一个【变体】。【临时文件,随 sampler 一起删】
//
// 三个变体渲染的是【同一份内容】,只有下面这张 Spec 里的几项不同 ——
// 密度、按钮画法、表格画法、卡片投影、以及【拒绝态怎么画】。
// 刻意不做成"每一个排列组合都摆一遍"的组件动物园:Tim 要能
// 【指着一个说就这个】,而不是自己拼一个出来。

import * as React from 'react'
import { Button } from '@/app/components/ui/button'
import { Input } from '@/app/components/ui/input'
import { Label } from '@/app/components/ui/label'
import { Textarea } from '@/app/components/ui/textarea'
import { Badge } from '@/app/components/ui/badge'
import { Alert, AlertTitle, AlertDescription } from '@/app/components/ui/alert'
import { Card, CardHeader, CardTitle, CardDescription, CardContent } from '@/app/components/ui/card'
import {
    Table, TableBody, TableCell, TableHead, TableHeader, TableRow,
} from '@/app/components/ui/table'
import {
    Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from '@/app/components/ui/select'
import { BATCHES, REFUSALS, type Batch, type Refusal } from './data'

export type Spec = {
    key: 'ledger' | 'workbench' | 'brand'
    name: string
    oneLiner: string
    /** 密度 */
    cellPad: string
    text: string
    /** 按钮画法 */
    primary: 'default' | 'outline'
    secondary: 'outline' | 'secondary' | 'ghost'
    /** 表格画法 */
    table: 'bordered' | 'striped' | 'plain'
    /** 卡片投影 */
    card: string
    /** 表头 */
    headRow: string
    /** 拒绝态画法 */
    refusal: 'plain' | 'outline' | 'chip'
}

const isRefusal = (v: string): v is Refusal =>
    v === 'restricted' || v === 'unrecorded' || v === 'unexplained' || v === 'outOfStock'

/** 拒绝态 —— 三种画法,这是本 sampler 最要紧的一个选择。 */
function Refused({ kind, spec }: { kind: Refusal; spec: Spec }) {
    const r = REFUSALS[kind]
    const label = `${r.zh} · ${r.en}`
    if (spec.refusal === 'plain') {
        return <span className="text-[color:var(--brand-muted-text)] italic">{label}</span>
    }
    if (spec.refusal === 'outline') {
        return (
            <span className="inline-flex items-center rounded border border-[color:var(--brand-border-strong)] px-1.5 py-0.5 text-xs text-[color:var(--brand-muted-text)]">
                {label}
            </span>
        )
    }
    return (
        <span className="inline-flex items-center rounded-full bg-[color:var(--brand-accent)] px-2 py-0.5 text-xs text-[color:var(--brand-text)]">
            {label}
        </span>
    )
}

function StageBadge({ stage }: { stage: Batch['stage'] }) {
    const v = stage === '已加工完' ? 'secondary' : stage === '加工中' ? 'default' : 'outline'
    return <Badge variant={v}>{stage}</Badge>
}

export function Variant({ spec }: { spec: Spec }) {
    const rowCls = (i: number) =>
        spec.table === 'striped' && i % 2 === 1 ? 'bg-[color:var(--brand-muted)]' : ''
    const cellCls = [
        spec.cellPad, spec.text,
        spec.table === 'bordered' ? 'border border-[color:var(--brand-border)]' : '',
    ].join(' ')

    return (
        <section className="mb-20">
            {/* ── 变体标题:Tim 要能【叫出这个名字】,所以名字印得很大 ───────── */}
            <div className="mb-5 flex flex-wrap items-baseline gap-x-4 gap-y-1 border-b-2 border-[color:var(--brand-ocean)] pb-2">
                <h2 className="text-2xl font-bold text-[color:var(--brand-text)]">
                    {spec.name}
                </h2>
                <p className="text-sm text-[color:var(--brand-muted-text)]">{spec.oneLiner}</p>
            </div>

            {/* 【表格给整幅宽度】第一版把它塞在 2fr 栏里,7 列在 950px 上放不下,
                「收货人」那一栏被切掉 —— 而那一栏正是「未记录」的演示位。
                overflow-x-auto 仍然留着(它是对的,FE-0 记着 161 个含表文件里只有
                27 个有),但不该靠它来遮住一个排版问题。 */}
            <div className="grid gap-6">
                {/* ── 一、进料批次表 ──────────────────────────────────────────── */}
                <Card className={spec.card}>
                    <CardHeader>
                        <CardTitle className="text-[color:var(--brand-text)]">进料批次 · Inbound batches</CardTitle>
                        <CardDescription>
                            批次号、物料、化学体系、余量、阶段、单价 —— 与 /inbound 同形。
                        </CardDescription>
                    </CardHeader>
                    <CardContent>
                        <div className="overflow-x-auto">
                            <Table>
                                <TableHeader>
                                    <TableRow className={spec.headRow}>
                                        <TableHead className={cellCls}>批次号</TableHead>
                                        <TableHead className={cellCls}>物料</TableHead>
                                        <TableHead className={cellCls}>化学</TableHead>
                                        <TableHead className={`${cellCls} text-right`}>余量 (kg)</TableHead>
                                        <TableHead className={cellCls}>阶段</TableHead>
                                        <TableHead className={cellCls}>单价</TableHead>
                                        <TableHead className={cellCls}>收货人</TableHead>
                                    </TableRow>
                                </TableHeader>
                                <TableBody>
                                    {BATCHES.map((b, i) => (
                                        <TableRow key={b.code} className={rowCls(i)}>
                                            <TableCell className={`${cellCls} font-mono whitespace-nowrap`}>
                                                {b.code}
                                            </TableCell>
                                            <TableCell className={cellCls}>
                                                <div>{b.material}</div>
                                                <div className="font-mono text-xs text-[color:var(--brand-muted-text)]">
                                                    {b.materialCode}
                                                </div>
                                            </TableCell>
                                            <TableCell className={cellCls}>{b.chemistry}</TableCell>
                                            <TableCell className={`${cellCls} text-right font-mono tabular-nums`}>
                                                {b.weightKg === '0.00'
                                                    ? <Refused kind="outOfStock" spec={spec} />
                                                    : b.weightKg}
                                            </TableCell>
                                            <TableCell className={cellCls}><StageBadge stage={b.stage} /></TableCell>
                                            <TableCell className={cellCls}>
                                                {isRefusal(b.unitPrice)
                                                    ? <Refused kind={b.unitPrice} spec={spec} />
                                                    : b.unitPrice}
                                            </TableCell>
                                            <TableCell className={cellCls}>
                                                {isRefusal(b.receivedBy)
                                                    ? <Refused kind={b.receivedBy} spec={spec} />
                                                    : b.receivedBy}
                                            </TableCell>
                                        </TableRow>
                                    ))}
                                </TableBody>
                            </Table>
                        </div>
                    </CardContent>
                </Card>
            </div>

            <div className="mt-6 grid gap-6 lg:grid-cols-2">
                {/* ── 二、表单 ────────────────────────────────────────────────── */}
                <Card className={spec.card}>
                    <CardHeader>
                        <CardTitle className="text-[color:var(--brand-text)]">登记来源 · Record source</CardTitle>
                        <CardDescription>与 /inbound/[id] 的来源面板同形。</CardDescription>
                    </CardHeader>
                    <CardContent className="space-y-4">
                        <div className="space-y-1.5">
                            <Label htmlFor={`${spec.key}-batch`}>批次号</Label>
                            <Input id={`${spec.key}-batch`} defaultValue="IN-2026-0183" className="font-mono" readOnly />
                        </div>
                        <div className="space-y-1.5">
                            <Label htmlFor={`${spec.key}-reason`}>来源理由</Label>
                            <Select>
                                <SelectTrigger id={`${spec.key}-reason`}>
                                    <SelectValue placeholder="尚未选择" />
                                </SelectTrigger>
                                <SelectContent>
                                    <SelectItem value="return">客户退货 · Customer return</SelectItem>
                                    <SelectItem value="sample">免费样品 · Free sample</SelectItem>
                                    <SelectItem value="stocktake_gain">盘盈 · Stocktake gain</SelectItem>
                                    <SelectItem value="other">其他 · Other</SelectItem>
                                </SelectContent>
                            </Select>
                        </div>
                        <div className="space-y-1.5">
                            <Label htmlFor={`${spec.key}-note`}>说明</Label>
                            <Textarea id={`${spec.key}-note`} rows={3} placeholder="记下你知道的部分就好 —— 不知道的不要猜。" />
                        </div>
                        <div className="flex flex-wrap gap-2 pt-1">
                            <Button variant={spec.primary}>保存</Button>
                            <Button variant={spec.secondary}>取消</Button>
                            <Button variant="destructive">作废</Button>
                            <Button variant={spec.primary} disabled>保存(禁用)</Button>
                        </div>
                    </CardContent>
                </Card>

                {/* ── 三、拒绝态对照 —— 本页最要紧的一块 ────────────────────── */}
                <Card className={spec.card}>
                    <CardHeader>
                    <CardTitle className="text-[color:var(--brand-text)]">
                        拒绝态 · 四种,含义各不相同
                    </CardTitle>
                    <CardDescription>
                        ★ 这四个词是这套前端最值钱的东西。它们【今天被印成十种样子】,
                        而它们说的不是同一件事 —— 挑变体时请先看这一块。
                    </CardDescription>
                </CardHeader>
                <CardContent>
                    <div className="overflow-x-auto">
                        <Table>
                            <TableBody>
                                {(Object.keys(REFUSALS) as Refusal[]).map((k) => (
                                    <TableRow key={k}>
                                        <TableCell className={`${cellCls} w-56 align-top`}>
                                            <Refused kind={k} spec={spec} />
                                        </TableCell>
                                        {/* whitespace-normal:shadcn 的 TableCell 自带
                                            whitespace-nowrap(表格单元本该如此),
                                            而这一栏是【整句说明】,不覆盖就会溢出卡片。 */}
                                        <TableCell className={`${cellCls} align-top whitespace-normal text-[color:var(--brand-muted-text)]`}>
                                            {REFUSALS[k].why}
                                        </TableCell>
                                    </TableRow>
                                ))}
                            </TableBody>
                        </Table>
                    </div>
                    </CardContent>
                </Card>
            </div>

            {/* ── 四、横幅与空状态 ──────────────────────────────────────────── */}
            <div className="mt-6 grid gap-6 lg:grid-cols-2">
                <div className="space-y-3">
                    <Alert>
                        <AlertTitle>本月尚未重估外币余额</AlertTitle>
                        <AlertDescription>
                            2026-08 的 tt_sell 汇率已齐备,可以重估。
                        </AlertDescription>
                    </Alert>
                    <Alert variant="destructive">
                        <AlertTitle>缺 2026-09-01 的 tt_buy 汇率</AlertTitle>
                        <AlertDescription>
                            系统【拒绝】按最近一天的汇率折算 —— 请先补录这一天的汇率。
                        </AlertDescription>
                    </Alert>
                </div>
                <Card className={spec.card}>
                    <CardContent className="py-10 text-center">
                        <p className={`${spec.text} text-[color:var(--brand-muted-text)]`}>
                            这个筛选条件下没有批次。
                        </p>
                        <p className="mt-1 text-xs text-[color:var(--brand-muted-text)]">
                            空状态 —— 【没有数据】,不是【查询失败】。两者必须长得不一样。
                        </p>
                        <div className="mt-4">
                            <Button variant={spec.secondary}>清除筛选</Button>
                        </div>
                    </CardContent>
                </Card>
            </div>
        </section>
    )
}
