// 供应商附件允许的文件类型(资质文件常见格式:PDF / 图片 / Word / Excel)。
// 客户端面板(AttachmentsPanel)与服务端动作(recordAttachment)共用这一份定义,避免两边漂移。
// 这是普通模块(无 'use server'/'use client' 指令),两端都能 import。

// 允许的 MIME 类型。校验以 MIME 为准(客户端按 file.type、服务端按存入的 file_type)。
export const ALLOWED_ATTACHMENT_MIME_TYPES = [
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/msword', // .doc
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // .docx
    'application/vnd.ms-excel', // .xls
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', // .xlsx
] as const

// <input accept> 用的值:扩展名 + MIME 双写,让各系统的文件选择器都能预过滤。
export const ATTACHMENT_ACCEPT = [
    '.pdf',
    '.png',
    '.jpg',
    '.jpeg',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    ...ALLOWED_ATTACHMENT_MIME_TYPES,
].join(',')

export function isAllowedAttachmentType(mime: string | null | undefined): boolean {
    return !!mime && (ALLOWED_ATTACHMENT_MIME_TYPES as readonly string[]).includes(mime)
}
