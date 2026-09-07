// app/components/pdf/brandSvg.ts
// COD-1:读一份【品牌 SVG】,把它变成 @react-pdf/renderer 画得出来的图元。(2026-09-07)
//
// ════════════════════════════════════════════════════════════════════════════
// 【为什么这一支存在 —— 它是 Wordmark.tsx 抬头里那句话的兑现】
// ════════════════════════════════════════════════════════════════════════════
// PDF-1 把字标画成矢量,并且【只从 public/brand/ 那个文件读】,不把路径抄成
// 一份 TSX 常量 —— 理由写在 Wordmark.tsx 抬头:品牌资产有两份副本,改了 SVG
// 而 PDF 还印着老的,不会有任何东西报错。
//
// 那支解析器【只认扁平的一组 <path>】,并且对 <g>、transform、渐变【当场抛错】。
// 它的抬头把两条出路都写了出来:
//     "要么把这个构造从 SVG 里去掉,要么【在这里实现它】。"
//
// COD-1 撞上了第二条:公司印章是 2 个圆 + 1 个星形 + 35 个字形,而【每个字形都是
// 一个带 transform 的 <g>】(文字转成了路径,沿圆环摆开)。把 35 个 transform
// 烘进路径坐标是另一条路,但那要重写一遍 SVG 路径语法的仿射变换 —— 一件算错了
// 不会报错、只会让印章歪掉一点点的事。
//
// 所以这里【实现它】,并且做成【一份实现、两个调用者】:字标与印章读同一支解析器。
// react-pdf 4.5.1 原生支持 <Svg>/<G transform>/<Path>/<Circle>/<Polygon>。
//
// ════════════════════════════════════════════════════════════════════════════
// 【它仍然拒绝它画不对的东西 —— 这条是承重的,一个字都没松】
// ════════════════════════════════════════════════════════════════════════════
// 渐变、<text>、<image>、<use>、<mask>、<clipPath>、<filter> 一律【当场抛错】。
// 一张印着【残缺印章】的销毁证书,和一张印着完整印章的,在生成时都是"成功"。
// **能画错的东西必须先能报错。**
import fs from 'node:fs'
import path from 'node:path'

export type BrandShape =
    | { kind: 'path'; d: string; fill: string | null; stroke: string | null; strokeWidth: number | null; transform: string | null }
    | { kind: 'circle'; cx: number; cy: number; r: number; fill: string | null; stroke: string | null; strokeWidth: number | null; transform: string | null }
    | { kind: 'polygon'; points: string; fill: string | null; stroke: string | null; strokeWidth: number | null; transform: string | null }

export type BrandSvg = { viewBox: string; width: number; height: number; shapes: BrandShape[] }

/** 画不出来的构造 —— 见抬头。名字进这个表 = 遇到就抛。 */
const UNDRAWABLE = ['linearGradient', 'radialGradient', 'image', 'text', 'tspan', 'use', 'mask', 'clipPath', 'filter', 'pattern']

const attr = (attrs: string, name: string): string | null => {
    const m = new RegExp(`\\s${name}="([^"]*)"`).exec(attrs)
    return m ? m[1] : null
}

/**
 * 读一份品牌 SVG 并【展平】成一串图元。
 *
 * 继承规则只实现真正用到的两条:`fill` 沿 <g> 往下继承,`transform` 沿 <g> 累积
 * (外层在前,与 SVG 的语义一致)。**没有实现的继承一律不猜** —— 一个猜错的
 * 继承画出来是"差一点点",而那正是最难被发现的一类错。
 */
export function readBrandSvg(fileName: string): BrandSvg {
    // ★【前缀写死,只有文件名是变量 —— 这是打包器逼出来的,也顺手关掉一扇门】★
    // 头一版收的是整条相对路径,于是 path.join(process.cwd(), relPath) 里【全是变量】,
    // Turbopack 的静态追踪认不出来,就把【整个项目】拖进了这条路由的产物
    // (构建日志:"Encountered unexpected file in NFT list")。
    // 把 public/brand 写成字面量之后追踪重新成立;附带的好处是这支函数【只读得到
    // 品牌目录】,再也不可能被一个拼出来的路径领到别处去。
    const file = path.join(process.cwd(), 'public', 'brand', fileName)
    const raw = fs.readFileSync(file, 'utf8')

    const vb = /viewBox="([^"]+)"/.exec(raw)
    if (!vb) throw new Error(`品牌 SVG 没有 viewBox:${file}`)
    const nums = vb[1].trim().split(/[\s,]+/).map(Number)
    if (nums.length !== 4 || nums.some((n) => !Number.isFinite(n))) {
        throw new Error(`品牌 SVG 的 viewBox 读不懂:"${vb[1]}"(${file})`)
    }

    for (const tag of UNDRAWABLE) {
        if (new RegExp(`<${tag}[\\s>/]`).test(raw)) {
            throw new Error(
                `品牌 SVG 里出现了 <${tag}>,而 app/components/pdf/brandSvg.ts 不实现它。\n` +
                    `照现在这样画会得到一个【残缺的图形】,而那在生成时看起来是成功的。\n` +
                    `要么把这个构造从 SVG 里去掉(设计工具通常可以"展平"),要么在这里实现它。\n` +
                    `文件:${file}`
            )
        }
    }

    const shapes: BrandShape[] = []
    // 栈里存 <g> 带下来的继承值。转换按【外层在前】拼接,与 SVG 语义一致。
    const stack: { fill: string | null; transform: string[] }[] = [{ fill: null, transform: [] }]
    const top = () => stack[stack.length - 1]
    const joinT = () => (top().transform.length ? top().transform.join(' ') : null)

    const num = (s: string | null): number | null => {
        if (s === null) return null
        const n = Number(s)
        return Number.isFinite(n) ? n : null
    }
    // fill="none" 在 SVG 里是【明确的不填充】(印章的两个圆就是这样:只描边)。
    // 它与"没写 fill"是两件事,所以原样带下去,不折成 null。
    const paint = (v: string | null, inherited: string | null) => (v !== null ? (v === 'none' ? null : v) : inherited)

    for (const m of raw.matchAll(/<(\/?)([A-Za-z][A-Za-z0-9]*)([^>]*?)(\/?)>/g)) {
        const [, closing, tag, attrs, selfClose] = m
        if (tag === 'svg') continue

        if (closing) {
            if (tag === 'g') stack.pop()
            continue
        }

        if (tag === 'g') {
            const t = attr(attrs, 'transform')
            const parent = top()
            stack.push({
                fill: attr(attrs, 'fill') ?? parent.fill,
                transform: t ? [...parent.transform, t] : [...parent.transform],
            })
            // 自闭合的 <g/> 立刻弹回 —— 空组,不影响任何东西。
            if (selfClose) stack.pop()
            continue
        }

        const stroke = attr(attrs, 'stroke')
        const strokeWidth = num(attr(attrs, 'stroke-width'))
        const fill = paint(attr(attrs, 'fill'), top().fill)
        const transform = joinT()

        if (tag === 'path') {
            const d = attr(attrs, 'd')
            if (!d) continue
            if (!fill && !stroke) {
                throw new Error(`品牌 SVG 里有一条既没有 fill 也没有 stroke 的 <path> —— 画出来会不见。(${file})`)
            }
            shapes.push({ kind: 'path', d, fill, stroke, strokeWidth, transform })
        } else if (tag === 'circle') {
            const cx = num(attr(attrs, 'cx')), cy = num(attr(attrs, 'cy')), r = num(attr(attrs, 'r'))
            if (cx === null || cy === null || r === null) {
                throw new Error(`品牌 SVG 里的 <circle> 缺 cx/cy/r。(${file})`)
            }
            shapes.push({ kind: 'circle', cx, cy, r, fill, stroke, strokeWidth, transform })
        } else if (tag === 'polygon') {
            const points = attr(attrs, 'points')
            if (!points) throw new Error(`品牌 SVG 里的 <polygon> 缺 points。(${file})`)
            shapes.push({ kind: 'polygon', points, fill, stroke, strokeWidth, transform })
        }
        // 其余标签(metadata / title / desc 之类)不画,也不拦 —— 它们不产生墨迹。
    }

    if (shapes.length === 0) throw new Error(`品牌 SVG 里一个画得出来的图元都没有:${file}`)
    return { viewBox: vb[1], width: nums[2], height: nums[3], shapes }
}
