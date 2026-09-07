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
// ════════════════════════════════════════════════════════════════════════════
// ★★【COD-1(2026-09-07):解析搬到 brandSvg.ts 了 —— 而那正是本文件请求过的事】★★
// ════════════════════════════════════════════════════════════════════════════
// 本文件原来自带一支解析器,它【只认扁平的一组 <path>】,遇到 <g>、transform、
// 渐变就当场抛错。那段抬头把两条出路写得很清楚:
//     "要么把这个构造从 SVG 里去掉,要么【在这里实现它】。"
//
// 公司印章撞上了第二条:2 个圆 + 1 个星形 + 35 个【各带一个 transform 的 <g>】
// (文字转成路径,沿圆环摆开)。于是 COD-1 把解析抽成 brandSvg.ts 并【实现】了
// 圆、多边形与一层 <g transform>,字标与印章从此读【同一支】解析器 ——
// 不是两份实现,是一份实现的两个调用者。
//
// ★【"拒绝画不对的东西"一个字都没松】★ 渐变、<text>、<image>、<use>、<mask>、
// <clipPath>、<filter> 仍然当场抛错。一份印着残缺字标的发票,和一份印着完整
// 字标的发票,在生成时都是"成功"。**能画错的东西必须先能报错。**
import { Svg, G, Path, Circle, Polygon } from '@react-pdf/renderer'
import { readBrandSvg, type BrandShape } from './brandSvg'

const WORDMARK = readBrandSvg('evoltrya-wordmark.svg')

/** 字标的长宽比 —— 调用方给宽度,高度由它算,免得有人把字标拉变形。 */
export const WORDMARK_ASPECT = WORDMARK.width / WORDMARK.height

function Shape({ s }: { s: BrandShape }) {
    const paint = {
        ...(s.fill ? { fill: s.fill } : { fill: 'none' }),
        ...(s.stroke ? { stroke: s.stroke } : {}),
        ...(s.strokeWidth != null ? { strokeWidth: s.strokeWidth } : {}),
    }
    const el =
        s.kind === 'path' ? <Path d={s.d} {...paint} />
        : s.kind === 'circle' ? <Circle cx={s.cx} cy={s.cy} r={s.r} {...paint} />
        : <Polygon points={s.points} {...paint} />
    return s.transform ? <G transform={s.transform}>{el}</G> : el
}

/**
 * 字标。**只给宽度**;高度按原始比例算出来。
 * R1:没有水印 —— 螺旋球体只作为字标里的那个 "O" 出现,不做背景、不做装饰。
 */
export default function Wordmark({ width }: { width: number }) {
    return (
        <Svg width={width} height={width / WORDMARK_ASPECT} viewBox={WORDMARK.viewBox}>
            {WORDMARK.shapes.map((s, i) => (
                <Shape key={i} s={s} />
            ))}
        </Svg>
    )
}
