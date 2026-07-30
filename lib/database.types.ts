export type Json =
  | string
  | number
  | boolean
  | null
  | { [key: string]: Json | undefined }
  | Json[]

export type Database = {
  // Allows to automatically instantiate createClient with right options
  // instead of createClient<Database, { PostgrestVersion: 'XX' }>(URL, KEY)
  __InternalSupabase: {
    PostgrestVersion: "14.5"
  }
  public: {
    Tables: {
      accounts: {
        Row: {
          account_type: string
          code: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          account_type: string
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          account_type?: string
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      currencies: {
        Row: {
          code: string
          is_base: boolean
          name: string
        }
        Insert: {
          code: string
          is_base?: boolean
          name: string
        }
        Update: {
          code?: string
          is_base?: boolean
          name?: string
        }
        Relationships: []
      }
      customer_attachments: {
        Row: {
          created_at: string
          created_by: string | null
          customer_id: string
          deleted_at: string | null
          doc_category: string | null
          file_name: string
          file_size: number | null
          file_type: string | null
          id: string
          notes: string | null
          storage_path: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          customer_id: string
          deleted_at?: string | null
          doc_category?: string | null
          file_name: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          customer_id?: string
          deleted_at?: string | null
          doc_category?: string | null
          file_name?: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_attachments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      customers: {
        Row: {
          address: string | null
          code: string
          country: string
          created_at: string
          created_by: string | null
          credit_rating: string | null
          customer_types: string[] | null
          deleted_at: string | null
          id: string
          incoterm: string | null
          legal_name: string
          notes: string | null
          payment_terms: string | null
          short_name: string | null
          status: string
          tax_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          address?: string | null
          code: string
          country: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          customer_types?: string[] | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name: string
          notes?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: string
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          address?: string | null
          code?: string
          country?: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          customer_types?: string[] | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name?: string
          notes?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: string
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      expenses: {
        Row: {
          account_code: string
          amount_ccy: number
          amount_usd: number
          bank_account_code: string | null
          code: string
          created_at: string | null
          created_by: string | null
          currency: string
          expense_date: string
          fx_rate: number
          id: string
          journal_entry_id: string | null
          notes: string | null
          payee_name: string | null
          payment_status: string
          reversed_by_expense: string | null
          status: string
          supplier_id: string | null
        }
        Insert: {
          account_code: string
          amount_ccy: number
          amount_usd: number
          bank_account_code?: string | null
          code: string
          created_at?: string | null
          created_by?: string | null
          currency: string
          expense_date: string
          fx_rate: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payee_name?: string | null
          payment_status: string
          reversed_by_expense?: string | null
          status?: string
          supplier_id?: string | null
        }
        Update: {
          account_code?: string
          amount_ccy?: number
          amount_usd?: number
          bank_account_code?: string | null
          code?: string
          created_at?: string | null
          created_by?: string | null
          currency?: string
          expense_date?: string
          fx_rate?: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payee_name?: string | null
          payment_status?: string
          reversed_by_expense?: string | null
          status?: string
          supplier_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "expenses_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expenses_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "expenses_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_reversed_by_expense_fkey"
            columns: ["reversed_by_expense"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "expenses_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      finance_attachments: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          doc_type: string | null
          expense_id: string | null
          file_name: string
          file_path: string
          file_size: number | null
          id: string
          inbound_batch_id: string | null
          mime_type: string | null
          notes: string | null
          payment_id: string | null
          sales_record_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_type?: string | null
          expense_id?: string | null
          file_name: string
          file_path: string
          file_size?: number | null
          id?: string
          inbound_batch_id?: string | null
          mime_type?: string | null
          notes?: string | null
          payment_id?: string | null
          sales_record_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_type?: string | null
          expense_id?: string | null
          file_name?: string
          file_path?: string
          file_size?: number | null
          id?: string
          inbound_batch_id?: string | null
          mime_type?: string | null
          notes?: string | null
          payment_id?: string | null
          sales_record_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "finance_attachments_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "ar_open_items"
            referencedColumns: ["sales_record_id"]
          },
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
        ]
      }
      finance_settings: {
        Row: {
          id: boolean
          locked_before: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          id?: boolean
          locked_before?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          id?: boolean
          locked_before?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      fx_rates: {
        Row: {
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          id: string
          notes: string | null
          rate_date: string
          rate_to_usd: number
          source: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          currency: string
          deleted_at?: string | null
          id?: string
          notes?: string | null
          rate_date: string
          rate_to_usd: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          id?: string
          notes?: string | null
          rate_date?: string
          rate_to_usd?: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "fx_rates_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      inbound_batch_metals: {
        Row: {
          content_pct: number
          created_at: string
          created_by: string | null
          inbound_batch_id: string
          metal: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          created_at?: string
          created_by?: string | null
          inbound_batch_id: string
          metal: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          created_at?: string
          created_by?: string | null
          inbound_batch_id?: string
          metal?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      inbound_batches: {
        Row: {
          arrival_date: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          material_id: string
          notes: string | null
          quantity: number
          remaining_qty: number
          stage: string
          status: string
          supplier_id: string
          unit: string
          unit_price: number | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          arrival_date?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          material_id: string
          notes?: string | null
          quantity: number
          remaining_qty: number
          stage?: string
          status?: string
          supplier_id: string
          unit?: string
          unit_price?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          arrival_date?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          material_id?: string
          notes?: string | null
          quantity?: number
          remaining_qty?: number
          stage?: string
          status?: string
          supplier_id?: string
          unit?: string
          unit_price?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      inventory_movements: {
        Row: {
          business_date: string | null
          created_at: string
          created_by: string | null
          id: string
          inbound_batch_id: string | null
          location_id: string | null
          movement_type: string
          notes: string | null
          occurred_at: string
          output_batch_id: string | null
          qty_delta: number
          run_id: string | null
        }
        Insert: {
          business_date?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          location_id?: string | null
          movement_type: string
          notes?: string | null
          occurred_at?: string
          output_batch_id?: string | null
          qty_delta: number
          run_id?: string | null
        }
        Update: {
          business_date?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          location_id?: string | null
          movement_type?: string
          notes?: string | null
          occurred_at?: string
          output_batch_id?: string | null
          qty_delta?: number
          run_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      journal_entries: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          entry_date: string
          id: string
          memo: string | null
          reversed_by: string | null
          source_id: string | null
          source_type: string | null
          status: string
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          entry_date: string
          id?: string
          memo?: string | null
          reversed_by?: string | null
          source_id?: string | null
          source_type?: string | null
          status?: string
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          entry_date?: string
          id?: string
          memo?: string | null
          reversed_by?: string | null
          source_id?: string | null
          source_type?: string | null
          status?: string
        }
        Relationships: [
          {
            foreignKeyName: "journal_entries_reversed_by_fkey"
            columns: ["reversed_by"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      journal_lines: {
        Row: {
          account_id: string
          amount_ccy: number
          created_at: string
          credit: number
          currency: string
          debit: number
          entry_id: string
          fx_rate: number
          id: string
          line_memo: string | null
        }
        Insert: {
          account_id: string
          amount_ccy: number
          created_at?: string
          credit?: number
          currency: string
          debit?: number
          entry_id: string
          fx_rate: number
          id?: string
          line_memo?: string | null
        }
        Update: {
          account_id?: string
          amount_ccy?: number
          created_at?: string
          credit?: number
          currency?: string
          debit?: number
          entry_id?: string
          fx_rate?: number
          id?: string
          line_memo?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "journal_lines_account_id_fkey"
            columns: ["account_id"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "journal_lines_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "journal_lines_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      material_attachments: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          doc_category: string | null
          file_name: string
          file_size: number | null
          file_type: string | null
          id: string
          material_id: string
          notes: string | null
          storage_path: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          material_id: string
          notes?: string | null
          storage_path: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name?: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          material_id?: string
          notes?: string | null
          storage_path?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "material_attachments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
        ]
      }
      materials: {
        Row: {
          category: string
          chemistry: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string
          notes: string | null
          spec: string | null
          status: string
          unit: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          category: string
          chemistry?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name: string
          notes?: string | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          category?: string
          chemistry?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string
          notes?: string | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      metal_prices: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          metal: string
          notes: string | null
          price_date: string
          price_usd_per_tonne: number
          source: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal: string
          notes?: string | null
          price_date: string
          price_usd_per_tonne: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal?: string
          notes?: string | null
          price_date?: string
          price_usd_per_tonne?: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      output_batch_metals: {
        Row: {
          content_pct: number
          created_at: string
          created_by: string | null
          metal: string
          output_batch_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          created_at?: string
          created_by?: string | null
          metal: string
          output_batch_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          created_at?: string
          created_by?: string | null
          metal?: string
          output_batch_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      output_batches: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          customer_id: string | null
          deleted_at: string | null
          id: string
          material_id: string
          notes: string | null
          output_date: string | null
          purity: string | null
          quantity: number
          remaining_qty: number
          state: string
          status: string
          unit: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          id?: string
          material_id: string
          notes?: string | null
          output_date?: string | null
          purity?: string | null
          quantity: number
          remaining_qty: number
          state?: string
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          id?: string
          material_id?: string
          notes?: string | null
          output_date?: string | null
          purity?: string | null
          quantity?: number
          remaining_qty?: number
          state?: string
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batches_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_allocations: {
        Row: {
          allocated_usd: number
          created_at: string | null
          expense_id: string | null
          id: string
          inbound_batch_id: string | null
          payment_id: string
          sales_record_id: string | null
        }
        Insert: {
          allocated_usd: number
          created_at?: string | null
          expense_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          payment_id: string
          sales_record_id?: string | null
        }
        Update: {
          allocated_usd?: number
          created_at?: string | null
          expense_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          payment_id?: string
          sales_record_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payment_allocations_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "ar_open_items"
            referencedColumns: ["sales_record_id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
        ]
      }
      payments: {
        Row: {
          amount_ccy: number
          amount_usd: number
          bank_account_code: string
          code: string
          counterparty_type: string
          created_at: string | null
          created_by: string | null
          currency: string
          customer_id: string | null
          direction: string
          fx_rate: number
          id: string
          journal_entry_id: string | null
          notes: string | null
          payment_date: string
          reversed_by_payment: string | null
          status: string
          supplier_id: string | null
        }
        Insert: {
          amount_ccy: number
          amount_usd: number
          bank_account_code: string
          code: string
          counterparty_type: string
          created_at?: string | null
          created_by?: string | null
          currency: string
          customer_id?: string | null
          direction: string
          fx_rate: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_date: string
          reversed_by_payment?: string | null
          status?: string
          supplier_id?: string | null
        }
        Update: {
          amount_ccy?: number
          amount_usd?: number
          bank_account_code?: string
          code?: string
          counterparty_type?: string
          created_at?: string | null
          created_by?: string | null
          currency?: string
          customer_id?: string | null
          direction?: string
          fx_rate?: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_date?: string
          reversed_by_payment?: string | null
          status?: string
          supplier_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payments_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "payments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_reversed_by_payment_fkey"
            columns: ["reversed_by_payment"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payments_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      period_closes: {
        Row: {
          closed_at: string
          closed_by: string | null
          entries_count: number
          id: string
          notes: string | null
          period_end: string
          reopen_reason: string | null
          reopened_at: string | null
          reopened_by: string | null
          total_credits: number
          total_debits: number
        }
        Insert: {
          closed_at?: string
          closed_by?: string | null
          entries_count: number
          id?: string
          notes?: string | null
          period_end: string
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          total_credits: number
          total_debits: number
        }
        Update: {
          closed_at?: string
          closed_by?: string | null
          entries_count?: number
          id?: string
          notes?: string | null
          period_end?: string
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          total_credits?: number
          total_debits?: number
        }
        Relationships: []
      }
      price_history: {
        Row: {
          created_at: string
          created_by: string | null
          currency: string
          fx_rate: number
          id: string
          inbound_batch_id: string
          new_unit_price: number
          notes: string | null
          old_unit_price: number | null
          original_price: number
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          currency: string
          fx_rate: number
          id?: string
          inbound_batch_id: string
          new_unit_price: number
          notes?: string | null
          old_unit_price?: number | null
          original_price: number
        }
        Update: {
          created_at?: string
          created_by?: string | null
          currency?: string
          fx_rate?: number
          id?: string
          inbound_batch_id?: string
          new_unit_price?: number
          notes?: string | null
          old_unit_price?: number | null
          original_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entries: {
        Row: {
          amount_usd: number
          cost_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_estimate: boolean
          notes: string | null
          run_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount_usd: number
          cost_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          run_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount_usd?: number
          cost_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          run_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_inputs: {
        Row: {
          created_at: string
          id: string
          inbound_batch_id: string
          quantity_consumed: number
          run_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          inbound_batch_id: string
          quantity_consumed: number
          run_id: string
        }
        Update: {
          created_at?: string
          id?: string
          inbound_batch_id?: string
          quantity_consumed?: number
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_outputs: {
        Row: {
          allocated_cost_usd: number | null
          created_at: string
          id: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_usd: number | null
        }
        Insert: {
          allocated_cost_usd?: number | null
          created_at?: string
          id?: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_usd?: number | null
        }
        Update: {
          allocated_cost_usd?: number | null
          created_at?: string
          id?: string
          output_batch_id?: string
          quantity_produced?: number
          run_id?: string
          unit_cost_usd?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_runs: {
        Row: {
          allocated_at: string | null
          allocated_by: string | null
          allocation_basis: string
          allocation_snapshot: Json | null
          capitalization_entry_id: string | null
          capitalized_cost_usd: number | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          loss_qty: number | null
          material_cost_usd: number | null
          notes: string | null
          process_cost_usd: number | null
          process_date: string | null
          status: string
          total_cost_usd: number | null
          total_input: number | null
          total_output: number | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_usd?: number | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_usd?: number | null
          notes?: string | null
          process_cost_usd?: number | null
          process_date?: string | null
          status: string
          total_cost_usd?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_usd?: number | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_usd?: number | null
          notes?: string | null
          process_cost_usd?: number | null
          process_date?: string | null
          status?: string
          total_cost_usd?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_records: {
        Row: {
          amount_usd: number
          cogs_entry_id: string | null
          created_at: string | null
          created_by: string | null
          currency: string
          customer_id: string | null
          fx_rate: number
          id: string
          movement_id: string | null
          notes: string | null
          output_batch_id: string
          quantity: number
          sale_date: string
          unit_price: number
        }
        Insert: {
          amount_usd: number
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency: string
          customer_id?: string | null
          fx_rate: number
          id?: string
          movement_id?: string | null
          notes?: string | null
          output_batch_id: string
          quantity: number
          sale_date: string
          unit_price: number
        }
        Update: {
          amount_usd?: number
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string
          customer_id?: string | null
          fx_rate?: number
          id?: string
          movement_id?: string | null
          notes?: string | null
          output_batch_id?: string
          quantity?: number
          sale_date?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "sales_records_cogs_entry_id_fkey"
            columns: ["cogs_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_movement_id_fkey"
            columns: ["movement_id"]
            isOneToOne: false
            referencedRelation: "inventory_movements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      stocktake_lines: {
        Row: {
          book_qty: number
          counted_at: string
          counted_qty: number
          created_by: string | null
          id: string
          inbound_batch_id: string | null
          notes: string | null
          output_batch_id: string | null
          stocktake_id: string
        }
        Insert: {
          book_qty: number
          counted_at?: string
          counted_qty: number
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          stocktake_id: string
        }
        Update: {
          book_qty?: number
          counted_at?: string
          counted_qty?: number
          created_by?: string | null
          id?: string
          inbound_batch_id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          stocktake_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_stocktake_id_fkey"
            columns: ["stocktake_id"]
            isOneToOne: false
            referencedRelation: "stocktakes"
            referencedColumns: ["id"]
          },
        ]
      }
      stocktakes: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          notes: string | null
          posted_at: string | null
          started_at: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          notes?: string | null
          posted_at?: string | null
          started_at?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          notes?: string | null
          posted_at?: string | null
          started_at?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      storage_locations: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          name: string | null
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          name?: string | null
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      supplier_attachments: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          doc_category: string | null
          file_name: string
          file_size: number | null
          file_type: string | null
          id: string
          notes: string | null
          storage_path: string
          supplier_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path: string
          supplier_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          doc_category?: string | null
          file_name?: string
          file_size?: number | null
          file_type?: string | null
          id?: string
          notes?: string | null
          storage_path?: string
          supplier_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "supplier_attachments_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      supplier_compliance: {
        Row: {
          cert_no: string | null
          cert_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          document_id: string | null
          id: string
          issuing_body: string | null
          notes: string | null
          supplier_id: string
          updated_at: string
          updated_by: string | null
          valid_from: string | null
          valid_until: string | null
        }
        Insert: {
          cert_no?: string | null
          cert_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_id?: string | null
          id?: string
          issuing_body?: string | null
          notes?: string | null
          supplier_id: string
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Update: {
          cert_no?: string | null
          cert_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_id?: string | null
          id?: string
          issuing_body?: string | null
          notes?: string | null
          supplier_id?: string
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "supplier_compliance_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      suppliers: {
        Row: {
          address: string | null
          code: string
          country: string
          created_at: string
          created_by: string | null
          credit_rating: string | null
          deleted_at: string | null
          id: string
          incoterm: string | null
          legal_name: string
          notes: string | null
          owner_id: string | null
          payment_terms: string | null
          short_name: string | null
          status: Database["public"]["Enums"]["supplier_status"]
          supplier_types: string[]
          tax_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          address?: string | null
          code: string
          country: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name: string
          notes?: string | null
          owner_id?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: Database["public"]["Enums"]["supplier_status"]
          supplier_types?: string[]
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          address?: string | null
          code?: string
          country?: string
          created_at?: string
          created_by?: string | null
          credit_rating?: string | null
          deleted_at?: string | null
          id?: string
          incoterm?: string | null
          legal_name?: string
          notes?: string | null
          owner_id?: string | null
          payment_terms?: string | null
          short_name?: string | null
          status?: Database["public"]["Enums"]["supplier_status"]
          supplier_types?: string[]
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      tasks: {
        Row: {
          assigned_to: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          description: string | null
          due_date: string | null
          editors: string[] | null
          entity: string | null
          id: string
          owner_id: string | null
          priority: string
          reminder_at: string | null
          shared_with: string[] | null
          status: string
          tags: string[] | null
          task_type: string
          title: string
          updated_at: string
          updated_by: string | null
          visibility: string
        }
        Insert: {
          assigned_to?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description?: string | null
          due_date?: string | null
          editors?: string[] | null
          entity?: string | null
          id?: string
          owner_id?: string | null
          priority?: string
          reminder_at?: string | null
          shared_with?: string[] | null
          status?: string
          tags?: string[] | null
          task_type?: string
          title: string
          updated_at?: string
          updated_by?: string | null
          visibility?: string
        }
        Update: {
          assigned_to?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description?: string | null
          due_date?: string | null
          editors?: string[] | null
          entity?: string | null
          id?: string
          owner_id?: string | null
          priority?: string
          reminder_at?: string | null
          shared_with?: string[] | null
          status?: string
          tags?: string[] | null
          task_type?: string
          title?: string
          updated_at?: string
          updated_by?: string | null
          visibility?: string
        }
        Relationships: []
      }
    }
    Views: {
      ap_open_items: {
        Row: {
          bucket: string | null
          days_outstanding: number | null
          doc_code: string | null
          doc_date: string | null
          doc_id: string | null
          doc_kind: string | null
          doc_value_usd: number | null
          inbound_batch_id: string | null
          open_usd: number | null
          settled_usd: number | null
          supplier_id: string | null
          supplier_name: string | null
        }
        Relationships: []
      }
      ar_open_items: {
        Row: {
          amount_usd: number | null
          bucket: string | null
          customer_id: string | null
          customer_name: string | null
          days_outstanding: number | null
          doc_code: string | null
          open_usd: number | null
          sale_date: string | null
          sales_record_id: string | null
          settled_usd: number | null
        }
        Relationships: [
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_metal_recovery: {
        Row: {
          input_metal_kg: number | null
          metal: string | null
          output_metal_kg: number | null
          process_date: string | null
          recovery_pct: number | null
          run_code: string | null
          run_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      allocate_processing_costs: {
        Args: { p_basis?: string; p_run_id: string }
        Returns: Json
      }
      cancel_stocktake: { Args: { p_stocktake_id: string }; Returns: undefined }
      close_period: {
        Args: { p_notes?: string; p_period_end: string }
        Returns: Json
      }
      commit_processing_run: {
        Args: {
          p_inputs: Json
          p_loss_qty: number
          p_notes: string
          p_outputs: Json
          p_process_date: string
        }
        Returns: string
      }
      fin_cost_account: { Args: { p_cost_type: string }; Returns: string }
      fin_cost_lines: {
        Args: { p_amount: number; p_cost_type: string; p_reverse: boolean }
        Returns: Json
      }
      fin_next_payment_code: {
        Args: { p_date: string; p_prefix: string }
        Returns: string
      }
      post_journal_entry: {
        Args: {
          p_entry_date: string
          p_lines: Json
          p_memo: string
          p_source_id: string
          p_source_type: string
        }
        Returns: Json
      }
      post_stocktake: { Args: { p_stocktake_id: string }; Returns: Json }
      record_expense: {
        Args: {
          p_account_code: string
          p_amount: number
          p_bank_account?: string
          p_currency?: string
          p_expense_date: string
          p_fx_rate?: number
          p_notes?: string
          p_payee_name?: string
          p_payment_status?: string
          p_supplier_id?: string
        }
        Returns: Json
      }
      record_output_sale: {
        Args: {
          p_currency: string
          p_customer_id?: string
          p_fx_rate?: number
          p_notes?: string
          p_output_batch_id: string
          p_quantity: number
          p_sale_date?: string
          p_unit_price: number
        }
        Returns: Json
      }
      record_payment: {
        Args: {
          p_allocations?: Json
          p_amount: number
          p_bank_account?: string
          p_counterparty_id: string
          p_currency: string
          p_direction: string
          p_fx_rate?: number
          p_notes?: string
          p_payment_date?: string
        }
        Returns: Json
      }
      reopen_period: {
        Args: { p_period_end: string; p_reason: string }
        Returns: Json
      }
      reverse_expense: {
        Args: { p_expense_id: string; p_memo?: string }
        Returns: Json
      }
      reverse_journal_entry: {
        Args: { p_entry_id: string; p_memo?: string; p_reversal_date: string }
        Returns: Json
      }
      reverse_payment: {
        Args: { p_memo?: string; p_payment_id: string }
        Returns: Json
      }
      rollback_processing_run: {
        Args: { p_run_id: string }
        Returns: undefined
      }
      set_inbound_unit_price: {
        Args: {
          p_currency?: string
          p_fx_rate?: number
          p_inbound_batch_id: string
          p_notes?: string
          p_unit_price: number
        }
        Returns: Json
      }
    }
    Enums: {
      supplier_status:
        | "draft"
        | "pending_review"
        | "approved"
        | "rejected"
        | "active"
        | "suspended"
        | "blacklisted"
        | "archived"
    }
    CompositeTypes: {
      [_ in never]: never
    }
  }
}

type DatabaseWithoutInternals = Omit<Database, "__InternalSupabase">

type DefaultSchema = DatabaseWithoutInternals[Extract<keyof Database, "public">]

export type Tables<
  DefaultSchemaTableNameOrOptions extends
    | keyof (DefaultSchema["Tables"] & DefaultSchema["Views"])
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
        DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? (DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"] &
      DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Views"])[TableName] extends {
      Row: infer R
    }
    ? R
    : never
  : DefaultSchemaTableNameOrOptions extends keyof (DefaultSchema["Tables"] &
        DefaultSchema["Views"])
    ? (DefaultSchema["Tables"] &
        DefaultSchema["Views"])[DefaultSchemaTableNameOrOptions] extends {
        Row: infer R
      }
      ? R
      : never
    : never

export type TablesInsert<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Insert: infer I
    }
    ? I
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Insert: infer I
      }
      ? I
      : never
    : never

export type TablesUpdate<
  DefaultSchemaTableNameOrOptions extends
    | keyof DefaultSchema["Tables"]
    | { schema: keyof DatabaseWithoutInternals },
  TableName extends DefaultSchemaTableNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"]
    : never = never,
> = DefaultSchemaTableNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaTableNameOrOptions["schema"]]["Tables"][TableName] extends {
      Update: infer U
    }
    ? U
    : never
  : DefaultSchemaTableNameOrOptions extends keyof DefaultSchema["Tables"]
    ? DefaultSchema["Tables"][DefaultSchemaTableNameOrOptions] extends {
        Update: infer U
      }
      ? U
      : never
    : never

export type Enums<
  DefaultSchemaEnumNameOrOptions extends
    | keyof DefaultSchema["Enums"]
    | { schema: keyof DatabaseWithoutInternals },
  EnumName extends DefaultSchemaEnumNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"]
    : never = never,
> = DefaultSchemaEnumNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[DefaultSchemaEnumNameOrOptions["schema"]]["Enums"][EnumName]
  : DefaultSchemaEnumNameOrOptions extends keyof DefaultSchema["Enums"]
    ? DefaultSchema["Enums"][DefaultSchemaEnumNameOrOptions]
    : never

export type CompositeTypes<
  PublicCompositeTypeNameOrOptions extends
    | keyof DefaultSchema["CompositeTypes"]
    | { schema: keyof DatabaseWithoutInternals },
  CompositeTypeName extends PublicCompositeTypeNameOrOptions extends {
    schema: keyof DatabaseWithoutInternals
  }
    ? keyof DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"]
    : never = never,
> = PublicCompositeTypeNameOrOptions extends {
  schema: keyof DatabaseWithoutInternals
}
  ? DatabaseWithoutInternals[PublicCompositeTypeNameOrOptions["schema"]]["CompositeTypes"][CompositeTypeName]
  : PublicCompositeTypeNameOrOptions extends keyof DefaultSchema["CompositeTypes"]
    ? DefaultSchema["CompositeTypes"][PublicCompositeTypeNameOrOptions]
    : never

export const Constants = {
  public: {
    Enums: {
      supplier_status: [
        "draft",
        "pending_review",
        "approved",
        "rejected",
        "active",
        "suspended",
        "blacklisted",
        "archived",
      ],
    },
  },
} as const
