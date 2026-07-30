// 财务凭据附件允许的文件类型(PDF / 图片 / Word / Excel),端口自
// app/suppliers/[id]/edit/attachmentTypes.ts —— 客户端面板与服务端动作共用一份定义。
// 这是普通模块(无 'use server'/'use client' 指令),两端都能 import。

// 允许的 MIME 类型。校验以 MIME 为准(客户端按 file.type、服务端按传入的 mimeType)。
export const FINANCE_ATTACHMENT_MIME_TYPES = [
    'application/pdf',
    'image/png',
    'image/jpeg',
    'application/msword', // .doc
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document', // .docx
    'application/vnd.ms-excel', // .xls
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', // .xlsx
] as const

// <input accept> 用的值:扩展名 + MIME 双写,让各系统的文件选择器都能预过滤。
export const FINANCE_ATTACHMENT_ACCEPT = [
    '.pdf',
    '.png',
    '.jpg',
    '.jpeg',
    '.doc',
    '.docx',
    '.xls',
    '.xlsx',
    ...FINANCE_ATTACHMENT_MIME_TYPES,
].join(',')

export function isAllowedFinanceAttachmentType(mime: string | null | undefined): boolean {
    return !!mime && (FINANCE_ATTACHMENT_MIME_TYPES as readonly string[]).includes(mime)
}

// 附件挂靠的单据类型:AR 单据(sales_record)/ AP 单据(inbound_batch)/ 收付款单 / 开支单。
export type FinanceAttachmentParent = {
    kind: 'sale' | 'inbound' | 'payment' | 'expense'
    id: string
}

// 各 kind 对应的详情页路径(revalidatePath 用)
export function parentPagePath(parent: FinanceAttachmentParent): string {
    switch (parent.kind) {
        case 'sale':
            return `/finance/receivables/${parent.id}`
        case 'inbound':
            return `/finance/payables/${parent.id}`
        case 'payment':
            return `/finance/payments/${parent.id}`
        case 'expense':
            return `/finance/expenses/${parent.id}`
    }
}

// doc_type 规范值(与 finance_attachments.doc_type 的 CHECK 一致)
export const FINANCE_DOC_TYPES = [
    'invoice',
    'contract',
    'receipt',
    'bank_slip',
    'weighbridge',
    'other',
] as const

// created_at 已在服务端按当前语言格式化好传进来,避免客户端 toLocaleString 造成水合不一致。
export type FinanceAttachmentRow = {
    id: string
    file_name: string
    file_path: string
    file_size: number | null
    mime_type: string | null
    doc_type: string | null
    notes: string | null
    created_at_display: string
}
