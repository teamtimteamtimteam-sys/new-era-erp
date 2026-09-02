// app/components/pdf/Wordmark.tsx
// PDF-1:字标,画成【矢量】,而且【只有一份真源】。(2026-09-02)
//
// ★【为什么不把路径抄进这个文件】★
// R1 点名 `public/brand/evoltrya-wordmark.svg` 是字标。把它的 8 条路径复制成一份
// TSX 常量,就等于让品牌资产有两份副本 —— 而本仓库为"两份实现在写下来那天一致、
// 之后悄悄分开"已经付过多次账(见 AGENTS.md 的预览规则)。改了 SVG 而 PDF 还印着
// 老字标,不会有任何东西报错。所以这里在【模块加载时】读那个文件。
//
// ★【为什么不用 <Image>】★
// @react-pdf/renderer 的 Image **不支持 SVG**(app/finance/company/actions.ts 为此
// 拒收 SVG 上传)。栅格化成 PNG 是另一条路,但那要么在构建期产出第二份资产
// (又是副本),要么在渲染期起一个光栅化器。而 react-pdf 4.5.1 【原生支持】
// <Svg>/<Path> —— 矢量、无文件转换、放大不糊,这是最直的一条路。
//
// ★【它拒绝它画不对的东西 —— 这是承重的】★
// 下面的解析只认"扁平的一组 <path>"。今天的字标正是这个形状(8 条 path,无 <g>、
// 无 transform、无渐变)。哪天设计换了一版带分组或渐变的 SVG,这里会【当场抛错】,
// 而不是安静地少画一块 —— 一个印着残缺字标的发票,和一个印着完整字标的发票,
// 在生成时都是"成功"。**能画错的东西必须先能报错。**
import fs from 'node:fs'
import path from 'node:path'
import { Svg, Path } from '@react-pdf/renderer'

const SVG_PATH = path.join(process.cwd(), 'public', 'brand', 'evoltrya-wordmark.svg')

type Parsed = { viewBox: string; width: number; height: number; paths: { d: string; fill: string }[] }

function parseWordmark(): Parsed {
    const raw = fs.readFileSync(SVG_PATH, 'utf8')

    const vb = /viewBox="([^"]+)"/.exec(raw)
    if (!vb) throw new Error(`字标 SVG 没有 viewBox:${SVG_PATH}`)
    const nums = vb[1].trim().split(/[\s,]+/).map(Number)
    if (nums.length !== 4 || nums.some((n) => !Number.isFinite(n))) {
        throw new Error(`字标 SVG 的 viewBox 读不懂:"${vb[1]}"`)
    }

    // 【拒绝画不对的构造】—— 见抬头。分组与变换会改变绘制结果,而下面的渲染
    // 不实现它们;渐变同理(react-pdf 的 Path 只吃纯色 fill)。
    for (const [re, what] of [
        [/<g[\s>]/, '<g> 分组'],
        [/\stransform=/, 'transform 变换'],
        [/<(linear|radial)Gradient[\s>]/, '渐变'],
        [/<(image|text|use)[\s>]/, '<image>/<text>/<use>'],
    ] as [RegExp, string][]) {
        if (re.test(raw)) {
            throw new Error(
                `字标 SVG 里出现了 ${what},而 app/components/pdf/Wordmark.tsx 不实现它。\n` +
                    `照现在这样画会得到一个【残缺的字标】,而那在生成时看起来是成功的。\n` +
                    `要么把这个构造从 SVG 里去掉(设计工具通常可以"展平"),要么在这里实现它。`
            )
        }
    }

    const paths: { d: string; fill: string }[] = []
    for (const m of raw.matchAll(/<path\b([^>]*?)\/?>/g)) {
        const attrs = m[1]
        const d = /\sd="([^"]*)"/.exec(attrs)
        if (!d) continue
        const fill = /\bfill="([^"]*)"/.exec(attrs)
        if (!fill || fill[1] === 'none') {
            throw new Error(`字标 SVG 里有一条没有纯色 fill 的 path —— 画出来会是黑的或不见。`)
        }
        paths.push({ d: d[1], fill: fill[1] })
    }
    if (paths.length === 0) throw new Error(`字标 SVG 里一条 <path> 都没有:${SVG_PATH}`)

    return { viewBox: vb[1], width: nums[2], height: nums[3], paths }
}

const WORDMARK = parseWordmark()

/** 字标的长宽比 —— 调用方给宽度,高度由它算,免得有人把字标拉变形。 */
export const WORDMARK_ASPECT = WORDMARK.width / WORDMARK.height

/**
 * 字标。**只给宽度**;高度按原始比例算出来。
 * R1:没有水印 —— 螺旋球体只作为字标里的那个 "O" 出现,不做背景、不做装饰。
 */
export default function Wordmark({ width }: { width: number }) {
    return (
        <Svg width={width} height={width / WORDMARK_ASPECT} viewBox={WORDMARK.viewBox}>
            {WORDMARK.paths.map((p, i) => (
                <Path key={i} d={p.d} fill={p.fill} />
            ))}
        </Svg>
    )
}
