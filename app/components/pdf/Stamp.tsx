// app/components/pdf/Stamp.tsx
// COD-1:公司印章,画成【矢量】,而且【只有一份真源】。(2026-09-07)
//
// ★【为什么不把 35 条路径抄进这个文件】★
// 与 Wordmark.tsx 同一条理由:品牌资产有两份副本,改了 SVG 而 PDF 还盖着老印章,
// 不会有任何东西报错。所以这里在【模块加载时】读 public/brand 里的那个文件。
//
// ★【为什么不用 <Image>】★
// @react-pdf/renderer 的 Image **不支持 SVG**;栅格化成 PNG 会在放大与打印时糊掉,
// 而一枚糊掉的公章正是收件人会拿去质疑的东西。react-pdf 4.5.1 原生支持
// <Svg>/<G>/<Path>/<Circle>/<Polygon> —— 矢量、无文件转换,这是最直的一条路。
//
// ★★【C2PA:那份文件带着一段"AI 工具生成"的元数据,它没有进仓库】★★
// 原始文件 18,678 字符里有 7,736 字符(41.4%)是一段 base64 的 c2pa 清单,
// 明文写着是哪个 AI 工具产出了它。入库前【整段剥掉】,只剩 10,904 字符的几何。
// 剥除是可复现的:去掉 <metadata>…</metadata> 与 xmlns:c2pa 声明,其余一字未动
// (剥前剥后:2 个圆、1 个星形、35 条路径、36 个 <g>,单色 #1F3A93)。
// 【将来任何人再把一份品牌 SVG 放进 public/brand/,先剥元数据。】
//
// ★【印章上刻的字与 company_profile.legal_name 不一致 —— 记录在案,两边都没动】★
// 环上刻的是 EVOLTRYA RECOVERY PTE LTD(全大写、无句点),中心是 UEN 202616658E
// (与 company_profile.registration_no 逐字相同)。而 legal_name 是
// "EVoltrya Recovery Pte. Ltd." —— 句点不一致。Tim 另行裁定哪一个是权威,
// 本刀【不改任何一边】,只把差异写在这里,免得下一个人以为是笔误顺手"修"掉。
import { Svg, G, Path, Circle, Polygon } from '@react-pdf/renderer'
import { readBrandSvg, type BrandShape } from './brandSvg'

const STAMP = readBrandSvg('evoltrya-stamp-navy.svg')

/** 印章是正方的;调用方给边长。 */
export const STAMP_ASPECT = STAMP.width / STAMP.height

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
    // 【transform 只在有的时候才包一层 <G>】—— 空的 transform 属性在 react-pdf 里
    // 是一个要被解析的字符串,给它一个空值等于让它去解析"没有"。
    return s.transform ? <G transform={s.transform}>{el}</G> : el
}

/**
 * 公司印章。**只给边长**。
 * 【它只出现在【已签发】的销毁证书上】—— 内部存档不盖章(那份纸不是发出去的东西),
 * 而一枚盖在未签发文件上的公章,正是这份证书最该防住的误认。
 */
export default function Stamp({ size }: { size: number }) {
    return (
        <Svg width={size} height={size / STAMP_ASPECT} viewBox={STAMP.viewBox}>
            {STAMP.shapes.map((s, i) => (
                <Shape key={i} s={s} />
            ))}
        </Svg>
    )
}
