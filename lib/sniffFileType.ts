// lib/sniffFileType.ts
// MES-9c / CLAIM-RECEIPTS-1 / GOLIVE-2 第 9 行:按文件头认类型 —— 不信浏览器报的类型与扩展名(一个改名成 .pdf、报成 application/pdf 的 GIF
//   就是这样溜进来的,MES-9c 本地证明抓到的)。认不出回 null。浏览器(上传之前先认一次)与服务端(传完之后从存储里读文件头再认一次)共用这一份。
export function sniffFileType(b: Uint8Array): string | null {
    if (b.length >= 5 && b[0] === 0x25 && b[1] === 0x50 && b[2] === 0x44 && b[3] === 0x46 && b[4] === 0x2d) return 'application/pdf'
    if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return 'image/jpeg'
    if (b.length >= 8 && b[0] === 0x89 && b[1] === 0x50 && b[2] === 0x4e && b[3] === 0x47
        && b[4] === 0x0d && b[5] === 0x0a && b[6] === 0x1a && b[7] === 0x0a) return 'image/png'
    return null
}

/** portal_submission_begin 给路径时用的扩展名(与它函数体里那一段同一张表) */
export const EXT_OF_TYPE: Readonly<Record<string, string>> = { 'application/pdf': 'pdf', 'image/jpeg': 'jpg', 'image/png': 'png' }
