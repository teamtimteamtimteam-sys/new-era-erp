'use server'

// MES-3b(2026-10-07,MES-3b Step 0 Q18 · Q19,Tim):每一个扫码框都问这一支 —— resolve_scan_code 认出这一串是什么,
//   页面自己从不判断身份。它【只返回、从不抛】(四种结果 + signed_out),所以这里没有错误要翻译;
//   一次真正的调用失败(网络、库)才抛 —— 一次失败不是一个"没认出来"(mustRows 那条规矩)。
import { createClient } from '@/lib/supabase/server'

export type ScanContext = 'lookup' | 'receipt' | 'transfer' | 'feed' | 'reserve' | 'ship'
export type ScanMethod = 'keyboard' | 'camera' | 'link'
export type ScanKind = 'inbound_batch' | 'output_batch' | 'storage_location'
export type ScanResult = {
    outcome: 'found' | 'restricted' | 'unknown' | 'unreadable' | 'signed_out'
    kind: ScanKind | null
    code: string | null
    id: string | null
    needs: string | null
    is_active?: boolean
    is_quarantine?: boolean
    scan_id?: number
}

export async function resolveScan(value: string, context: ScanContext, method: ScanMethod): Promise<ScanResult> {
    const supabase = await createClient()
    const { data, error } = await supabase.rpc('resolve_scan_code', { p_value: value, p_context: context, p_method: method })
    if (error) throw new Error(`resolve_scan_code: ${error.message}`)
    return data as unknown as ScanResult
}
