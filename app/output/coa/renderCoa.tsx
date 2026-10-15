// app/output/coa/renderCoa.tsx
// MES-6b-2(2026-10-15,MES-6b Step 0 Q31,Tim):【把一份快照渲染成一张分析证书的 PDF】—— 路由的签发与预览、以及线上证明脚本
//   (db/scripts/2026-10-15-mes6b2-live-proof.mjs,经 jiti 读本文件)都调这一支。入参只有快照与模式 —— 没有数据库、没有请求、
//   没有此刻的公司资料:纸只可能来自快照。
//   先过字体覆盖守卫(纸上会印的每一个字符串;一个画不出来的字会被印成别的东西,而那是无声的),再渲染。
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer'
import type { ReactElement } from 'react'
import { findUnrenderableText, coverageErrorMessage } from '@/lib/pdfFontCoverage'
import CoaDocument, { coaPdfStrings } from './CoaDocument'
import type { CoaMode, CoaSnapshot } from './coaTypes'

/** 纸上会印的字里有没有画不出来的 —— 有就返回那句说明(点名字段与字符),没有返回 null。签发之前拿【同一份组装】先问一次(路由的 POST)。 */
export function coaUnrenderable(snapshot: CoaSnapshot): string | null {
    const bad = findUnrenderableText(coaPdfStrings(snapshot))
    return bad.length > 0 ? coverageErrorMessage(bad) : null
}

export async function renderCoaPdf(snapshot: CoaSnapshot, mode: CoaMode): Promise<Buffer> {
    const bad = findUnrenderableText(coaPdfStrings(snapshot))
    if (bad.length > 0) throw new Error(coverageErrorMessage(bad))
    return renderToBuffer(<CoaDocument data={snapshot} mode={mode} /> as unknown as ReactElement<DocumentProps>)
}
