// app/operation/weighbridge/ticketFields.ts
// MES-2(2026-10-06,MES-2 Step 0 Q21):地磅单照片的桶与白名单 —— 一个普通模块,服务端动作与客户端控件共用(见 captureFields 的抬头)。
//   与迁移里那个桶(file_size_limit 10 MB · allowed_mime_types)和 weighbridge_ticket_photos 的 CHECK 逐字同一组。
export const PHOTO_BUCKET = 'capture-photos'
export const PHOTO_TYPES = ['image/jpeg', 'image/png', 'image/webp'] as const
export const PHOTO_MAX_BYTES = 10 * 1024 * 1024
