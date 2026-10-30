// lib/contractSignLayout.ts
// CONTRACT-ESIGN(Tim 2026-10-30 Q6):签名与印章在一页上的大小与默认位置 —— 签字页的预览(浏览器)与盖章(服务端,lib/contractFiles.ts)
//   读的是【同一份】数:预览上看见的那个框,就是 PDF 上落下的那个框。位置是那一页可见区域里【中心点】的位置,0..1,自左上角量。
/** 签名的宽度占页宽的比例(A4 上约 5.2 cm);高度按签名图自己的宽高比 */
export const SIGNATURE_WIDTH_OF_PAGE = 0.25
/** 印章的宽度占页宽的比例(A4 上约 3.4 cm) */
export const STAMP_WIDTH_OF_PAGE = 0.16
/** Q6:默认放在最后一页的右下角;印章挨在签名左边 */
export const DEFAULT_SIGNATURE_AT = { x: 0.75, y: 0.88 }
export const DEFAULT_STAMP_AT = { x: 0.52, y: 0.88 }
