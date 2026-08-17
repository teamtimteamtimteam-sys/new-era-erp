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
          cash_flow_section: string | null
          code: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          is_cash: boolean
          is_monetary: boolean
          is_system: boolean
          name_en: string
          name_zh: string
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          account_type: string
          cash_flow_section?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          is_cash?: boolean
          is_monetary: boolean
          is_system?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          account_type?: string
          cash_flow_section?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          is_cash?: boolean
          is_monetary?: boolean
          is_system?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      approval_log: {
        Row: {
          actor_user_id: string | null
          amount_base: number | null
          amount_ccy: number | null
          created_at: string
          currency: string | null
          decided_at: string
          decision: string
          fx_rate: number | null
          id: string
          is_reconstructed: boolean
          level: number | null
          note: string | null
          reconstruction_note: string | null
          seq: number
          subject_code: string | null
          subject_id: string
          subject_type: string
        }
        Insert: {
          actor_user_id?: string | null
          amount_base?: number | null
          amount_ccy?: number | null
          created_at?: string
          currency?: string | null
          decided_at?: string
          decision: string
          fx_rate?: number | null
          id?: string
          is_reconstructed?: boolean
          level?: number | null
          note?: string | null
          reconstruction_note?: string | null
          seq?: number
          subject_code?: string | null
          subject_id: string
          subject_type: string
        }
        Update: {
          actor_user_id?: string | null
          amount_base?: number | null
          amount_ccy?: number | null
          created_at?: string
          currency?: string | null
          decided_at?: string
          decision?: string
          fx_rate?: number | null
          id?: string
          is_reconstructed?: boolean
          level?: number | null
          note?: string | null
          reconstruction_note?: string | null
          seq?: number
          subject_code?: string | null
          subject_id?: string
          subject_type?: string
        }
        Relationships: [
          {
            foreignKeyName: "approval_log_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      assay_result_metals: {
        Row: {
          assay_result_id: string
          content_pct: number
          created_at: string
          metal: string
        }
        Insert: {
          assay_result_id: string
          content_pct: number
          created_at?: string
          metal: string
        }
        Update: {
          assay_result_id?: string
          content_pct?: number
          created_at?: string
          metal?: string
        }
        Relationships: [
          {
            foreignKeyName: "assay_result_metals_assay_result_id_fkey"
            columns: ["assay_result_id"]
            isOneToOne: false
            referencedRelation: "assay_results"
            referencedColumns: ["id"]
          },
        ]
      }
      assay_results: {
        Row: {
          applied_at: string | null
          applied_by: string | null
          assay_date: string
          certificate_ref: string | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          inbound_batch_id: string | null
          is_final: boolean
          lab_name: string | null
          notes: string | null
          output_batch_id: string | null
          sample_ref: string | null
          superseded_by: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          applied_at?: string | null
          applied_by?: string | null
          assay_date: string
          certificate_ref?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          inbound_batch_id?: string | null
          is_final?: boolean
          lab_name?: string | null
          notes?: string | null
          output_batch_id?: string | null
          sample_ref?: string | null
          superseded_by?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          applied_at?: string | null
          applied_by?: string | null
          assay_date?: string
          certificate_ref?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          inbound_batch_id?: string | null
          is_final?: boolean
          lab_name?: string | null
          notes?: string | null
          output_batch_id?: string | null
          sample_ref?: string | null
          superseded_by?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "assay_results_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "assay_results_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "assay_results_superseded_by_fkey"
            columns: ["superseded_by"]
            isOneToOne: false
            referencedRelation: "assay_results"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_import_profiles: {
        Row: {
          bank_account_code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          mapping: Json
          name: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          bank_account_code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          mapping: Json
          name: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          bank_account_code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          mapping?: Json
          name?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      bank_line_matches: {
        Row: {
          created_at: string | null
          created_by: string | null
          id: string
          journal_line_id: string
          matched_amount: number
          statement_line_id: string
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          id?: string
          journal_line_id: string
          matched_amount: number
          statement_line_id: string
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          id?: string
          journal_line_id?: string
          matched_amount?: number
          statement_line_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_line_matches_journal_line_id_fkey"
            columns: ["journal_line_id"]
            isOneToOne: true
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["journal_line_id"]
          },
          {
            foreignKeyName: "bank_line_matches_journal_line_id_fkey"
            columns: ["journal_line_id"]
            isOneToOne: true
            referencedRelation: "journal_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bank_line_matches_statement_line_id_fkey"
            columns: ["statement_line_id"]
            isOneToOne: false
            referencedRelation: "bank_statement_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_statement_lines: {
        Row: {
          amount: number
          created_at: string | null
          description: string | null
          id: string
          ignore_reason: string | null
          line_date: string
          line_no: number
          match_status: string
          notes: string | null
          reference: string | null
          statement_id: string
        }
        Insert: {
          amount: number
          created_at?: string | null
          description?: string | null
          id?: string
          ignore_reason?: string | null
          line_date: string
          line_no: number
          match_status?: string
          notes?: string | null
          reference?: string | null
          statement_id: string
        }
        Update: {
          amount?: number
          created_at?: string | null
          description?: string | null
          id?: string
          ignore_reason?: string | null
          line_date?: string
          line_no?: number
          match_status?: string
          notes?: string | null
          reference?: string | null
          statement_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_statement_lines_statement_id_fkey"
            columns: ["statement_id"]
            isOneToOne: false
            referencedRelation: "bank_statements"
            referencedColumns: ["id"]
          },
        ]
      }
      bank_statements: {
        Row: {
          bank_account_code: string
          closing_balance: number
          code: string
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          file_name: string | null
          id: string
          notes: string | null
          opening_balance: number
          period_end: string
          period_start: string
          reconciled_at: string | null
          reconciled_by: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          bank_account_code: string
          closing_balance: number
          code: string
          created_at?: string
          created_by?: string | null
          currency: string
          deleted_at?: string | null
          file_name?: string | null
          id?: string
          notes?: string | null
          opening_balance: number
          period_end: string
          period_start: string
          reconciled_at?: string | null
          reconciled_by?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          bank_account_code?: string
          closing_balance?: number
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          file_name?: string | null
          id?: string
          notes?: string | null
          opening_balance?: number
          period_end?: string
          period_start?: string
          reconciled_at?: string | null
          reconciled_by?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "bank_statements_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      bank_transfers: {
        Row: {
          amount_in: number
          amount_out: number
          bank_reference: string | null
          created_at: string
          created_by: string | null
          from_account: string
          id: string
          journal_entry_id: string
          notes: string | null
          reversal_entry_id: string | null
          reversed_at: string | null
          reversed_by: string | null
          to_account: string
          transfer_date: string
        }
        Insert: {
          amount_in: number
          amount_out: number
          bank_reference?: string | null
          created_at?: string
          created_by?: string | null
          from_account: string
          id?: string
          journal_entry_id: string
          notes?: string | null
          reversal_entry_id?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          to_account: string
          transfer_date: string
        }
        Update: {
          amount_in?: number
          amount_out?: number
          bank_reference?: string | null
          created_at?: string
          created_by?: string | null
          from_account?: string
          id?: string
          journal_entry_id?: string
          notes?: string | null
          reversal_entry_id?: string | null
          reversed_at?: string | null
          reversed_by?: string | null
          to_account?: string
          transfer_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "bank_transfers_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "bank_transfers_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "bank_transfers_reversal_entry_id_fkey"
            columns: ["reversal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "bank_transfers_reversal_entry_id_fkey"
            columns: ["reversal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      certificate_types: {
        Row: {
          code: string
          disposition: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          warn_lead_days: number
        }
        Insert: {
          code: string
          disposition: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          warn_lead_days?: number
        }
        Update: {
          code?: string
          disposition?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          warn_lead_days?: number
        }
        Relationships: []
      }
      cn_issues: {
        Row: {
          credit_note_id: string
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          sha256: string
          version: number
        }
        Insert: {
          credit_note_id: string
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256: string
          version: number
        }
        Update: {
          credit_note_id?: string
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "cn_issues_credit_note_id_fkey"
            columns: ["credit_note_id"]
            isOneToOne: false
            referencedRelation: "credit_notes"
            referencedColumns: ["id"]
          },
        ]
      }
      company_compliance: {
        Row: {
          cert_no: string | null
          cert_type_code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          document_path: string | null
          id: string
          issuing_body: string | null
          notes: string | null
          scope: string | null
          updated_at: string
          updated_by: string | null
          valid_from: string | null
          valid_until: string | null
        }
        Insert: {
          cert_no?: string | null
          cert_type_code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_path?: string | null
          id?: string
          issuing_body?: string | null
          notes?: string | null
          scope?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Update: {
          cert_no?: string | null
          cert_type_code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          document_path?: string | null
          id?: string
          issuing_body?: string | null
          notes?: string | null
          scope?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_from?: string | null
          valid_until?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "company_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "certificate_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "company_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "supplier_receiving_blocked"
            referencedColumns: ["cert_type_code"]
          },
        ]
      }
      company_profile: {
        Row: {
          address_lines: string | null
          bank_account_name: string | null
          bank_account_no: string | null
          bank_address: string | null
          bank_name: string | null
          bank_swift: string | null
          city: string | null
          country: string | null
          email: string | null
          id: boolean
          invoice_footer_text: string | null
          legal_name: string
          logo_path: string | null
          phone: string | null
          postal_code: string | null
          registration_no: string | null
          updated_at: string
          updated_by: string | null
          website: string | null
        }
        Insert: {
          address_lines?: string | null
          bank_account_name?: string | null
          bank_account_no?: string | null
          bank_address?: string | null
          bank_name?: string | null
          bank_swift?: string | null
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean
          invoice_footer_text?: string | null
          legal_name?: string
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string
          updated_by?: string | null
          website?: string | null
        }
        Update: {
          address_lines?: string | null
          bank_account_name?: string | null
          bank_account_no?: string | null
          bank_address?: string | null
          bank_name?: string | null
          bank_swift?: string | null
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean
          invoice_footer_text?: string | null
          legal_name?: string
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string
          updated_by?: string | null
          website?: string | null
        }
        Relationships: []
      }
      credit_note_lines: {
        Row: {
          amount: number
          created_at: string
          credit_note_id: string
          id: string
          invoice_line_id: string
          kind: string
          qty: number | null
        }
        Insert: {
          amount: number
          created_at?: string
          credit_note_id: string
          id?: string
          invoice_line_id: string
          kind: string
          qty?: number | null
        }
        Update: {
          amount?: number
          created_at?: string
          credit_note_id?: string
          id?: string
          invoice_line_id?: string
          kind?: string
          qty?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "credit_note_lines_credit_note_id_fkey"
            columns: ["credit_note_id"]
            isOneToOne: false
            referencedRelation: "credit_notes"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_note_lines_invoice_line_id_fkey"
            columns: ["invoice_line_id"]
            isOneToOne: false
            referencedRelation: "invoice_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_note_lines_invoice_line_id_fkey"
            columns: ["invoice_line_id"]
            isOneToOne: false
            referencedRelation: "invoice_lines_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      credit_notes: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          currency: string
          entry_id: string
          fx_rate: number
          id: string
          invoice_id: string
          note_date: string
          reason: string
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          currency: string
          entry_id: string
          fx_rate: number
          id?: string
          invoice_id: string
          note_date: string
          reason: string
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          entry_id?: string
          fx_rate?: number
          id?: string
          invoice_id?: string
          note_date?: string
          reason?: string
        }
        Relationships: [
          {
            foreignKeyName: "credit_notes_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "credit_notes_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "credit_notes_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "credit_notes_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
        ]
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
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "customer_attachments_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      customer_credit_history: {
        Row: {
          changed_at: string
          changed_by: string | null
          customer_id: string
          id: string
          new_credit_hold: boolean | null
          new_credit_limit_base: number | null
          old_credit_hold: boolean | null
          old_credit_limit_base: number | null
        }
        Insert: {
          changed_at?: string
          changed_by?: string | null
          customer_id: string
          id?: string
          new_credit_hold?: boolean | null
          new_credit_limit_base?: number | null
          old_credit_hold?: boolean | null
          old_credit_limit_base?: number | null
        }
        Update: {
          changed_at?: string
          changed_by?: string | null
          customer_id?: string
          id?: string
          new_credit_hold?: boolean | null
          new_credit_limit_base?: number | null
          old_credit_hold?: boolean | null
          old_credit_limit_base?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "customer_credit_history_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "customer_credit_history_customer_id_fkey"
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
          contact_person: string | null
          country: string
          created_at: string
          created_by: string | null
          credit_hold: boolean
          credit_limit_base: number | null
          credit_rating: string | null
          customer_types: string[] | null
          deleted_at: string | null
          email: string | null
          id: string
          incoterm: string | null
          legal_name: string
          notes: string | null
          payment_terms: string | null
          payment_terms_days: number | null
          phone: string | null
          short_name: string | null
          status: string
          tax_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          address?: string | null
          code: string
          contact_person?: string | null
          country: string
          created_at?: string
          created_by?: string | null
          credit_hold?: boolean
          credit_limit_base?: number | null
          credit_rating?: string | null
          customer_types?: string[] | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          incoterm?: string | null
          legal_name: string
          notes?: string | null
          payment_terms?: string | null
          payment_terms_days?: number | null
          phone?: string | null
          short_name?: string | null
          status?: string
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          address?: string | null
          code?: string
          contact_person?: string | null
          country?: string
          created_at?: string
          created_by?: string | null
          credit_hold?: boolean
          credit_limit_base?: number | null
          credit_rating?: string | null
          customer_types?: string[] | null
          deleted_at?: string | null
          email?: string | null
          id?: string
          incoterm?: string | null
          legal_name?: string
          notes?: string | null
          payment_terms?: string | null
          payment_terms_days?: number | null
          phone?: string | null
          short_name?: string | null
          status?: string
          tax_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      departments: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_active: boolean
          manager_employee_id: string | null
          name_en: string
          name_zh: string
          notes: string | null
          parent_department_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          manager_employee_id?: string | null
          name_en: string
          name_zh: string
          notes?: string | null
          parent_department_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_active?: boolean
          manager_employee_id?: string | null
          name_en?: string
          name_zh?: string
          notes?: string | null
          parent_department_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_manager_employee_id_fkey"
            columns: ["manager_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "departments_parent_department_id_fkey"
            columns: ["parent_department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
        ]
      }
      employees: {
        Row: {
          code: string
          confirmation_date: string | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          department_id: string | null
          employment_status: string
          employment_type: string
          hire_date: string
          id: string
          identity_no: string | null
          job_title: string | null
          legal_name: string
          manager_id: string | null
          monthly_salary: number | null
          monthly_salary_set: boolean | null
          notes: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          review_exempt: boolean
          separation_date: string | null
          separation_notes: string | null
          separation_type: string | null
          updated_at: string
          updated_by: string | null
          user_id: string | null
          work_category: string
          work_email: string | null
          work_pass_expiry_date: string | null
          work_pass_issue_date: string | null
          work_pass_no: string | null
          work_pass_type: string | null
          work_phone: string | null
        }
        Insert: {
          code: string
          confirmation_date?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string
          employment_type: string
          hire_date: string
          id?: string
          identity_no?: string | null
          job_title?: string | null
          legal_name: string
          manager_id?: string | null
          monthly_salary?: number | null
          monthly_salary_set?: boolean | null
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string
          updated_by?: string | null
          user_id?: string | null
          work_category: string
          work_email?: string | null
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: string | null
          work_pass_type?: string | null
          work_phone?: string | null
        }
        Update: {
          code?: string
          confirmation_date?: string | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string
          employment_type?: string
          hire_date?: string
          id?: string
          identity_no?: string | null
          job_title?: string | null
          legal_name?: string
          manager_id?: string | null
          monthly_salary?: number | null
          monthly_salary_set?: boolean | null
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string
          updated_by?: string | null
          user_id?: string | null
          work_category?: string
          work_email?: string | null
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: string | null
          work_pass_type?: string | null
          work_phone?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
      }
      employment_history: {
        Row: {
          change_type: string
          created_at: string
          created_by: string | null
          department_id: string | null
          effective_date: string
          employee_id: string
          employment_status: string | null
          employment_type: string | null
          id: string
          job_title: string | null
          new_monthly_salary: number | null
          notes: string | null
          old_monthly_salary: number | null
          work_category: string | null
        }
        Insert: {
          change_type: string
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          effective_date: string
          employee_id: string
          employment_status?: string | null
          employment_type?: string | null
          id?: string
          job_title?: string | null
          new_monthly_salary?: number | null
          notes?: string | null
          old_monthly_salary?: number | null
          work_category?: string | null
        }
        Update: {
          change_type?: string
          created_at?: string
          created_by?: string | null
          department_id?: string | null
          effective_date?: string
          employee_id?: string
          employment_status?: string | null
          employment_type?: string | null
          id?: string
          job_title?: string | null
          new_monthly_salary?: number | null
          notes?: string | null
          old_monthly_salary?: number | null
          work_category?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employment_history_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      expenses: {
        Row: {
          account_code: string
          amount_base: number
          amount_ccy: number
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
          amount_base: number
          amount_ccy: number
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
          amount_base?: number
          amount_ccy?: number
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
            foreignKeyName: "expenses_account_code_fkey"
            columns: ["account_code"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["account_code"]
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
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
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
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
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
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      finance_settings: {
        Row: {
          approval_level1_role_code: string | null
          approval_level2_user_id: string | null
          approval_threshold_base: number | null
          approvals_enabled: boolean
          default_allocation_basis: string
          first_fy_end: string | null
          fy_end_day: number
          fy_end_month: number
          gst_rate_pct: number
          gst_registered: boolean
          gst_registration_no: string | null
          id: boolean
          locked_before: string | null
          system_start_date: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          approval_level1_role_code?: string | null
          approval_level2_user_id?: string | null
          approval_threshold_base?: number | null
          approvals_enabled?: boolean
          default_allocation_basis?: string
          first_fy_end?: string | null
          fy_end_day?: number
          fy_end_month?: number
          gst_rate_pct?: number
          gst_registered?: boolean
          gst_registration_no?: string | null
          id?: boolean
          locked_before?: string | null
          system_start_date?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          approval_level1_role_code?: string | null
          approval_level2_user_id?: string | null
          approval_threshold_base?: number | null
          approvals_enabled?: boolean
          default_allocation_basis?: string
          first_fy_end?: string | null
          fy_end_day?: number
          fy_end_month?: number
          gst_rate_pct?: number
          gst_registered?: boolean
          gst_registration_no?: string | null
          id?: boolean
          locked_before?: string | null
          system_start_date?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "finance_settings_approval_level1_role_code_fkey"
            columns: ["approval_level1_role_code"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["code"]
          },
        ]
      }
      fixed_asset_cost_entries: {
        Row: {
          amount_base: number
          amount_ccy: number
          asset_id: string
          created_at: string
          created_by: string | null
          currency: string
          expense_id: string
          fx_rate: number
          id: string
        }
        Insert: {
          amount_base: number
          amount_ccy: number
          asset_id: string
          created_at?: string
          created_by?: string | null
          currency: string
          expense_id: string
          fx_rate: number
          id?: string
        }
        Update: {
          amount_base?: number
          amount_ccy?: number
          asset_id?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          expense_id?: string
          fx_rate?: number
          id?: string
        }
        Relationships: [
          {
            foreignKeyName: "fixed_asset_cost_entries_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_asset_cost_entries_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "fixed_asset_cost_entries_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: true
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      fixed_asset_depreciation: {
        Row: {
          amount_base: number
          asset_id: string
          created_at: string
          created_by: string | null
          id: string
          journal_entry_id: string
          period_end: string
        }
        Insert: {
          amount_base: number
          asset_id: string
          created_at?: string
          created_by?: string | null
          id?: string
          journal_entry_id: string
          period_end: string
        }
        Update: {
          amount_base?: number
          asset_id?: string
          created_at?: string
          created_by?: string | null
          id?: string
          journal_entry_id?: string
          period_end?: string
        }
        Relationships: [
          {
            foreignKeyName: "fixed_asset_depreciation_asset_id_fkey"
            columns: ["asset_id"]
            isOneToOne: false
            referencedRelation: "fixed_assets"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "fixed_asset_depreciation_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      fixed_assets: {
        Row: {
          acquisition_date: string
          category: string
          code: string
          cost_base: number
          cost_ccy: number
          created_at: string
          created_by: string | null
          currency: string
          depreciation_account_code: string
          description: string
          disposal_date: string | null
          disposal_journal_id: string | null
          disposal_proceeds_base: number | null
          expense_id: string
          fx_rate: number
          id: string
          in_service_date: string | null
          notes: string | null
          residual_base: number
          status: string
          useful_life_months: number
        }
        Insert: {
          acquisition_date: string
          category?: string
          code: string
          cost_base: number
          cost_ccy: number
          created_at?: string
          created_by?: string | null
          currency: string
          depreciation_account_code?: string
          description: string
          disposal_date?: string | null
          disposal_journal_id?: string | null
          disposal_proceeds_base?: number | null
          expense_id: string
          fx_rate: number
          id?: string
          in_service_date?: string | null
          notes?: string | null
          residual_base?: number
          status?: string
          useful_life_months: number
        }
        Update: {
          acquisition_date?: string
          category?: string
          code?: string
          cost_base?: number
          cost_ccy?: number
          created_at?: string
          created_by?: string | null
          currency?: string
          depreciation_account_code?: string
          description?: string
          disposal_date?: string | null
          disposal_journal_id?: string | null
          disposal_proceeds_base?: number | null
          expense_id?: string
          fx_rate?: number
          id?: string
          in_service_date?: string | null
          notes?: string | null
          residual_base?: number
          status?: string
          useful_life_months?: number
        }
        Relationships: [
          {
            foreignKeyName: "fixed_assets_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "fixed_assets_depreciation_account_code_fkey"
            columns: ["depreciation_account_code"]
            isOneToOne: false
            referencedRelation: "accounts"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "fixed_assets_depreciation_account_code_fkey"
            columns: ["depreciation_account_code"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["account_code"]
          },
          {
            foreignKeyName: "fixed_assets_disposal_journal_id_fkey"
            columns: ["disposal_journal_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "fixed_assets_disposal_journal_id_fkey"
            columns: ["disposal_journal_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "fixed_assets_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      freight_allocations: {
        Row: {
          amount_base: number
          basis_qty: number | null
          created_at: string
          created_by: string | null
          freight_document_id: string
          id: string
          in_stock_ratio: number
          inbound_batch_id: string
        }
        Insert: {
          amount_base: number
          basis_qty?: number | null
          created_at?: string
          created_by?: string | null
          freight_document_id: string
          id?: string
          in_stock_ratio: number
          inbound_batch_id: string
        }
        Update: {
          amount_base?: number
          basis_qty?: number | null
          created_at?: string
          created_by?: string | null
          freight_document_id?: string
          id?: string
          in_stock_ratio?: number
          inbound_batch_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "freight_allocations_freight_document_id_fkey"
            columns: ["freight_document_id"]
            isOneToOne: false
            referencedRelation: "freight_documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
        ]
      }
      freight_documents: {
        Row: {
          allocation_basis: string
          amount_base: number
          amount_ccy: number
          bank_account_code: string | null
          code: string
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          doc_date: string
          fx_rate: number
          id: string
          journal_entry_id: string | null
          notes: string | null
          payment_status: string
          status: string
          supplier_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          allocation_basis: string
          amount_base: number
          amount_ccy: number
          bank_account_code?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          currency: string
          deleted_at?: string | null
          doc_date: string
          fx_rate: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_status: string
          status?: string
          supplier_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          allocation_basis?: string
          amount_base?: number
          amount_ccy?: number
          bank_account_code?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          doc_date?: string
          fx_rate?: number
          id?: string
          journal_entry_id?: string | null
          notes?: string | null
          payment_status?: string
          status?: string
          supplier_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "freight_documents_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "freight_documents_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "freight_documents_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "freight_documents_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
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
          rate_sgd_per_unit: number
          rate_type: string
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
          rate_sgd_per_unit: number
          rate_type: string
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
          rate_sgd_per_unit?: number
          rate_type?: string
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
      hr_settings: {
        Row: {
          carry_forward_months: number
          id: boolean
          medical_annual_limit_sgd: number
          medical_pro_rate_for_joiners: boolean
          updated_at: string
          updated_by: string | null
          working_days_per_week: number
        }
        Insert: {
          carry_forward_months?: number
          id?: boolean
          medical_annual_limit_sgd?: number
          medical_pro_rate_for_joiners?: boolean
          updated_at?: string
          updated_by?: string | null
          working_days_per_week?: number
        }
        Update: {
          carry_forward_months?: number
          id?: boolean
          medical_annual_limit_sgd?: number
          medical_pro_rate_for_joiners?: boolean
          updated_at?: string
          updated_by?: string | null
          working_days_per_week?: number
        }
        Relationships: []
      }
      inbound_batch_metals: {
        Row: {
          content_pct: number
          content_source: string | null
          created_at: string
          created_by: string | null
          inbound_batch_id: string
          metal: string
          source_assay_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          content_source?: string | null
          created_at?: string
          created_by?: string | null
          inbound_batch_id: string
          metal: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          content_source?: string | null
          created_at?: string
          created_by?: string | null
          inbound_batch_id?: string
          metal?: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inbound_batch_metals_source_assay_id_fkey"
            columns: ["source_assay_id"]
            isOneToOne: false
            referencedRelation: "assay_results"
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
          pricing_formula_id: string | null
          pricing_status: string
          purchase_order_id: string | null
          purchase_order_line_id: string | null
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
          pricing_formula_id?: string | null
          pricing_status?: string
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
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
          pricing_formula_id?: string | null
          pricing_status?: string
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
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
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines_masked"
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
          pair_id: string | null
          qty_delta: number
          run_id: string | null
          stock_status: string
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
          pair_id?: string | null
          qty_delta: number
          run_id?: string | null
          stock_status?: string
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
          pair_id?: string | null
          qty_delta?: number
          run_id?: string | null
          stock_status?: string
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
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
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
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
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_issues: {
        Row: {
          file_path: string
          id: string
          invoice_id: string
          issued_at: string
          issued_by: string | null
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          invoice_id: string
          issued_at?: string
          issued_by?: string | null
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          invoice_id?: string
          issued_at?: string
          issued_by?: string | null
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_issues_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
        ]
      }
      invoice_lines: {
        Row: {
          amount_base: number
          amount_ccy: number | null
          created_at: string | null
          description: string
          id: string
          invoice_id: string
          invoice_voided: boolean
          line_no: number
          quantity: number
          sales_order_line_id: string | null
          sales_record_id: string | null
          unit: string
          unit_price: number
        }
        Insert: {
          amount_base: number
          amount_ccy?: number | null
          created_at?: string | null
          description: string
          id?: string
          invoice_id: string
          invoice_voided?: boolean
          line_no: number
          quantity: number
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          unit: string
          unit_price: number
        }
        Update: {
          amount_base?: number
          amount_ccy?: number | null
          created_at?: string | null
          description?: string
          id?: string
          invoice_id?: string
          invoice_voided?: boolean
          line_no?: number
          quantity?: number
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          unit?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices: {
        Row: {
          bill_to_snapshot: Json
          code: string
          created_at: string | null
          created_by: string | null
          currency: string
          customer_id: string
          due_date: string
          entry_id: string | null
          fx_rate: number | null
          id: string
          issue_date: string
          kind: string
          notes: string | null
          payment_terms_days: number
          sales_order_id: string | null
          status: string
          subtotal_base: number
          tax_base: number
          tax_rate_pct: number
          terms_text: string | null
          total_base: number
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          bill_to_snapshot: Json
          code: string
          created_at?: string | null
          created_by?: string | null
          currency: string
          customer_id: string
          due_date: string
          entry_id?: string | null
          fx_rate?: number | null
          id?: string
          issue_date: string
          kind?: string
          notes?: string | null
          payment_terms_days: number
          sales_order_id?: string | null
          status?: string
          subtotal_base: number
          tax_base?: number
          tax_rate_pct?: number
          terms_text?: string | null
          total_base: number
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          bill_to_snapshot?: Json
          code?: string
          created_at?: string | null
          created_by?: string | null
          currency?: string
          customer_id?: string
          due_date?: string
          entry_id?: string | null
          fx_rate?: number | null
          id?: string
          issue_date?: string
          kind?: string
          notes?: string | null
          payment_terms_days?: number
          sales_order_id?: string | null
          status?: string
          subtotal_base?: number
          tax_base?: number
          tax_rate_pct?: number
          terms_text?: string | null
          total_base?: number
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
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
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
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
          fx_rate_date: string | null
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
          fx_rate_date?: string | null
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
          fx_rate_date?: string | null
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
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
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
      leave_accrual_rates: {
        Row: {
          created_at: string
          created_by: string | null
          days_per_year: number | null
          effective_from: string
          employee_id: string | null
          id: string
          notes: string | null
          reason: string | null
          updated_at: string
          updated_by: string | null
          work_category: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          days_per_year?: number | null
          effective_from: string
          employee_id?: string | null
          id?: string
          notes?: string | null
          reason?: string | null
          updated_at?: string
          updated_by?: string | null
          work_category?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          days_per_year?: number | null
          effective_from?: string
          employee_id?: string | null
          id?: string
          notes?: string | null
          reason?: string | null
          updated_at?: string
          updated_by?: string | null
          work_category?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_accrual_rates_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      leave_consumption: {
        Row: {
          accrual_year: number | null
          created_at: string
          created_by: string | null
          days: number
          entry_type: string
          id: string
          leave_grant_id: string | null
          leave_request_id: string
          notes: string | null
        }
        Insert: {
          accrual_year?: number | null
          created_at?: string
          created_by?: string | null
          days: number
          entry_type?: string
          id?: string
          leave_grant_id?: string | null
          leave_request_id: string
          notes?: string | null
        }
        Update: {
          accrual_year?: number | null
          created_at?: string
          created_by?: string | null
          days?: number
          entry_type?: string
          id?: string
          leave_grant_id?: string | null
          leave_request_id?: string
          notes?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_consumption_leave_grant_id_fkey"
            columns: ["leave_grant_id"]
            isOneToOne: false
            referencedRelation: "leave_grants"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_consumption_leave_request_id_fkey"
            columns: ["leave_request_id"]
            isOneToOne: false
            referencedRelation: "leave_calendar"
            referencedColumns: ["request_id"]
          },
          {
            foreignKeyName: "leave_consumption_leave_request_id_fkey"
            columns: ["leave_request_id"]
            isOneToOne: false
            referencedRelation: "leave_requests"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_grants: {
        Row: {
          created_at: string
          created_by: string | null
          days: number
          deleted_at: string | null
          employee_id: string
          expires_on: string | null
          grant_type: string
          granted_on: string
          id: string
          leave_type_code: string
          leave_year: number
          notes: string | null
          source_grant_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          days: number
          deleted_at?: string | null
          employee_id: string
          expires_on?: string | null
          grant_type: string
          granted_on: string
          id?: string
          leave_type_code: string
          leave_year: number
          notes?: string | null
          source_grant_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          days?: number
          deleted_at?: string | null
          employee_id?: string
          expires_on?: string | null
          grant_type?: string
          granted_on?: string
          id?: string
          leave_type_code?: string
          leave_year?: number
          notes?: string | null
          source_grant_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_grants_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "leave_grants_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["leave_type_code"]
          },
          {
            foreignKeyName: "leave_grants_source_grant_id_fkey"
            columns: ["source_grant_id"]
            isOneToOne: false
            referencedRelation: "leave_grants"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_requests: {
        Row: {
          certificate_ref: string | null
          code: string
          created_at: string
          created_by: string | null
          days: number
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          deleted_at: string | null
          employee_id: string
          end_date: string
          end_half_day: boolean
          exception_reason: string | null
          id: string
          is_exception: boolean
          leave_type_code: string
          reason: string | null
          start_date: string
          start_half_day: boolean
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          certificate_ref?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          days: number
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          employee_id: string
          end_date: string
          end_half_day?: boolean
          exception_reason?: string | null
          id?: string
          is_exception?: boolean
          leave_type_code: string
          reason?: string | null
          start_date: string
          start_half_day?: boolean
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          certificate_ref?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          days?: number
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          employee_id?: string
          end_date?: string
          end_half_day?: boolean
          exception_reason?: string | null
          id?: string
          is_exception?: boolean
          leave_type_code?: string
          reason?: string | null
          start_date?: string
          start_half_day?: boolean
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["leave_type_code"]
          },
        ]
      }
      leave_types: {
        Row: {
          allows_half_day: boolean
          code: string
          created_at: string
          created_by: string | null
          default_days_per_year: number | null
          description_en: string | null
          description_zh: string | null
          gender_restriction: string | null
          is_accrued: boolean
          is_active: boolean
          is_paid: boolean
          name_en: string
          name_zh: string
          notes: string | null
          requires_approval: boolean
          requires_certificate_after_days: number | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          allows_half_day?: boolean
          code: string
          created_at?: string
          created_by?: string | null
          default_days_per_year?: number | null
          description_en?: string | null
          description_zh?: string | null
          gender_restriction?: string | null
          is_accrued?: boolean
          is_active?: boolean
          is_paid?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          requires_approval?: boolean
          requires_certificate_after_days?: number | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          allows_half_day?: boolean
          code?: string
          created_at?: string
          created_by?: string | null
          default_days_per_year?: number | null
          description_en?: string | null
          description_zh?: string | null
          gender_restriction?: string | null
          is_accrued?: boolean
          is_active?: boolean
          is_paid?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          requires_approval?: boolean
          requires_certificate_after_days?: number | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
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
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "material_attachments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_attachments_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
        ]
      }
      material_required_metals: {
        Row: {
          created_at: string
          created_by: string | null
          material_id: string
          metal: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          material_id: string
          metal: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          material_id?: string
          metal?: string
        }
        Relationships: [
          {
            foreignKeyName: "material_required_metals_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "material_required_metals_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "material_required_metals_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
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
          safety_stock_qty: number | null
          spec: string | null
          status: string
          unit: string
          updated_at: string
          updated_by: string | null
          waste_classification_code: string | null
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
          safety_stock_qty?: number | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
          waste_classification_code?: string | null
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
          safety_stock_qty?: number | null
          spec?: string | null
          status?: string
          unit?: string
          updated_at?: string
          updated_by?: string | null
          waste_classification_code?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "materials_waste_classification_code_fkey"
            columns: ["waste_classification_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
        ]
      }
      medical_claims: {
        Row: {
          amount_sgd: number
          claim_date: string
          claim_year: number
          code: string
          created_at: string
          created_by: string | null
          decided_at: string | null
          decided_by: string | null
          decision_notes: string | null
          deleted_at: string | null
          description: string | null
          employee_id: string
          expense_id: string | null
          id: string
          receipt_ref: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount_sgd: number
          claim_date: string
          claim_year: number
          code: string
          created_at?: string
          created_by?: string | null
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          description?: string | null
          employee_id: string
          expense_id?: string | null
          id?: string
          receipt_ref?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount_sgd?: number
          claim_date?: string
          claim_year?: number
          code?: string
          created_at?: string
          created_by?: string | null
          decided_at?: string | null
          decided_by?: string | null
          decision_notes?: string | null
          deleted_at?: string | null
          description?: string | null
          employee_id?: string
          expense_id?: string | null
          id?: string
          receipt_ref?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      metal_price_indices: {
        Row: {
          code: string
          created_at: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          quote_currency: string | null
          quote_currency_basis: string | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          quote_currency?: string | null
          quote_currency_basis?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          is_active?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          quote_currency?: string | null
          quote_currency_basis?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "metal_price_indices_quote_currency_fkey"
            columns: ["quote_currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      metal_prices: {
        Row: {
          anomaly_check: Json | null
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          metal: string
          notes: string | null
          price_date: string
          price_index: string | null
          price_usd_per_tonne: number
          source: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          anomaly_check?: Json | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal: string
          notes?: string | null
          price_date: string
          price_index?: string | null
          price_usd_per_tonne: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          anomaly_check?: Json | null
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          metal?: string
          notes?: string | null
          price_date?: string
          price_index?: string | null
          price_usd_per_tonne?: number
          source?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "metal_prices_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
        ]
      }
      notification_reads: {
        Row: {
          notification_id: string
          read_at: string
          user_id: string
        }
        Insert: {
          notification_id: string
          read_at?: string
          user_id: string
        }
        Update: {
          notification_id?: string
          read_at?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "notification_reads_notification_id_fkey"
            columns: ["notification_id"]
            isOneToOne: false
            referencedRelation: "notifications"
            referencedColumns: ["id"]
          },
        ]
      }
      notifications: {
        Row: {
          actor_user_id: string | null
          created_at: string
          event_type: string
          id: string
          occurred_at: string
          payload: Json
          subject_code: string | null
          subject_id: string | null
          subject_type: string
        }
        Insert: {
          actor_user_id?: string | null
          created_at?: string
          event_type: string
          id?: string
          occurred_at?: string
          payload?: Json
          subject_code?: string | null
          subject_id?: string | null
          subject_type: string
        }
        Update: {
          actor_user_id?: string | null
          created_at?: string
          event_type?: string
          id?: string
          occurred_at?: string
          payload?: Json
          subject_code?: string | null
          subject_id?: string | null
          subject_type?: string
        }
        Relationships: []
      }
      output_batch_metals: {
        Row: {
          content_pct: number
          content_source: string
          created_at: string
          created_by: string | null
          metal: string
          output_batch_id: string
          source_assay_id: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          content_pct: number
          content_source: string
          created_at?: string
          created_by?: string | null
          metal: string
          output_batch_id: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          content_pct?: number
          content_source?: string
          created_at?: string
          created_by?: string | null
          metal?: string
          output_batch_id?: string
          source_assay_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "output_batch_metals_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batch_metals_source_assay_id_fkey"
            columns: ["source_assay_id"]
            isOneToOne: false
            referencedRelation: "assay_results"
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
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
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
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "output_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
        ]
      }
      payment_allocations: {
        Row: {
          allocated_base: number
          allocated_ccy: number
          allocated_pay: number
          created_at: string | null
          expense_id: string | null
          freight_document_id: string | null
          id: string
          inbound_batch_id: string | null
          invoice_id: string | null
          payment_id: string
          purchase_order_id: string | null
          sales_record_id: string | null
        }
        Insert: {
          allocated_base: number
          allocated_ccy: number
          allocated_pay: number
          created_at?: string | null
          expense_id?: string | null
          freight_document_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          invoice_id?: string | null
          payment_id: string
          purchase_order_id?: string | null
          sales_record_id?: string | null
        }
        Update: {
          allocated_base?: number
          allocated_ccy?: number
          allocated_pay?: number
          created_at?: string | null
          expense_id?: string | null
          freight_document_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          invoice_id?: string | null
          payment_id?: string
          purchase_order_id?: string | null
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
            foreignKeyName: "payment_allocations_freight_document_id_fkey"
            columns: ["freight_document_id"]
            isOneToOne: false
            referencedRelation: "freight_documents"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "payment_allocations_payment_id_fkey"
            columns: ["payment_id"]
            isOneToOne: false
            referencedRelation: "payments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_term_template_lines: {
        Row: {
          created_at: string
          days_offset: number | null
          fixed_amount_ccy: number | null
          id: string
          label: string
          notes: string | null
          percentage: number | null
          seq: number
          template_id: string
          trigger_event: string
        }
        Insert: {
          created_at?: string
          days_offset?: number | null
          fixed_amount_ccy?: number | null
          id?: string
          label: string
          notes?: string | null
          percentage?: number | null
          seq: number
          template_id: string
          trigger_event: string
        }
        Update: {
          created_at?: string
          days_offset?: number | null
          fixed_amount_ccy?: number | null
          id?: string
          label?: string
          notes?: string | null
          percentage?: number | null
          seq?: number
          template_id?: string
          trigger_event?: string
        }
        Relationships: [
          {
            foreignKeyName: "payment_term_template_lines_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "payment_term_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_term_templates: {
        Row: {
          created_at: string
          created_by: string | null
          currency: string | null
          deleted_at: string | null
          description: string | null
          id: string
          is_active: boolean
          name: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          description?: string | null
          id?: string
          is_active?: boolean
          name: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payment_term_templates_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      payments: {
        Row: {
          amount_base: number
          amount_ccy: number
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
          amount_base: number
          amount_ccy: number
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
          amount_base?: number
          amount_ccy?: number
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
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
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
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
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
      payroll_lines: {
        Row: {
          created_at: string
          employee_cpf: number
          employee_id: string
          employer_cpf: number
          gross_pay: number
          id: string
          net_pay: number
          notes: string | null
          other_deductions: number
          paid_at: string | null
          paid_journal_entry_id: string | null
          payroll_period_id: string
        }
        Insert: {
          created_at?: string
          employee_cpf?: number
          employee_id: string
          employer_cpf?: number
          gross_pay: number
          id?: string
          net_pay: number
          notes?: string | null
          other_deductions?: number
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id: string
        }
        Update: {
          created_at?: string
          employee_cpf?: number
          employee_id?: string
          employer_cpf?: number
          gross_pay?: number
          id?: string
          net_pay?: number
          notes?: string | null
          other_deductions?: number
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_payroll_period_id_fkey"
            columns: ["payroll_period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_periods: {
        Row: {
          code: string
          cpf_journal_entry_id: string | null
          cpf_paid_at: string | null
          created_at: string
          created_by: string | null
          currency: string
          deductions_journal_entry_id: string | null
          deductions_paid_at: string | null
          deleted_at: string | null
          employee_cpf_total: number
          employer_cpf_total: number
          fx_rate: number
          gross_total: number
          id: string
          journal_entry_id: string | null
          net_pay_total: number
          notes: string | null
          other_deductions_total: number
          payment_date: string
          period_month: string
          source_note: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          cpf_journal_entry_id?: string | null
          cpf_paid_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          deductions_journal_entry_id?: string | null
          deductions_paid_at?: string | null
          deleted_at?: string | null
          employee_cpf_total?: number
          employer_cpf_total?: number
          fx_rate: number
          gross_total?: number
          id?: string
          journal_entry_id?: string | null
          net_pay_total?: number
          notes?: string | null
          other_deductions_total?: number
          payment_date: string
          period_month: string
          source_note?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          cpf_journal_entry_id?: string | null
          cpf_paid_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          deductions_journal_entry_id?: string | null
          deductions_paid_at?: string | null
          deleted_at?: string | null
          employee_cpf_total?: number
          employer_cpf_total?: number
          fx_rate?: number
          gross_total?: number
          id?: string
          journal_entry_id?: string | null
          net_pay_total?: number
          notes?: string | null
          other_deductions_total?: number
          payment_date?: string
          period_month?: string
          source_note?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payroll_periods_cpf_journal_entry_id_fkey"
            columns: ["cpf_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_periods_cpf_journal_entry_id_fkey"
            columns: ["cpf_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_periods_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "payroll_periods_deductions_journal_entry_id_fkey"
            columns: ["deductions_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_periods_deductions_journal_entry_id_fkey"
            columns: ["deductions_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_periods_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_periods_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
      performance_reviews: {
        Row: {
          acknowledged_at: string | null
          approved_at: string | null
          approved_by: string | null
          created_at: string
          created_by: string | null
          cycle_id: string | null
          employee_id: string
          id: string
          new_monthly_salary: number | null
          notes: string | null
          period_end: string
          period_start: string
          probation_outcome: string | null
          rating_code: string | null
          review_type: string
          reviewer_employee_id: string | null
          salary_effective_date: string | null
          self_assessment_submitted_at: string | null
          self_assessment_text: string | null
          status: string
          submitted_at: string | null
          submitted_by: string | null
          summary_text: string | null
          updated_at: string
          updated_by: string | null
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          created_by?: string | null
          cycle_id?: string | null
          employee_id: string
          id?: string
          new_monthly_salary?: number | null
          notes?: string | null
          period_end: string
          period_start: string
          probation_outcome?: string | null
          rating_code?: string | null
          review_type: string
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string
          created_by?: string | null
          cycle_id?: string | null
          employee_id?: string
          id?: string
          new_monthly_salary?: number | null
          notes?: string | null
          period_end?: string
          period_start?: string
          probation_outcome?: string | null
          rating_code?: string | null
          review_type?: string
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "performance_reviews_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "review_cycles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_rating_code_fkey"
            columns: ["rating_code"]
            isOneToOne: false
            referencedRelation: "review_rating_scale"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
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
      permissions: {
        Row: {
          category: string
          code: string
          description_en: string | null
          description_zh: string | null
          name_en: string
          name_zh: string
          sort_order: number
        }
        Insert: {
          category: string
          code: string
          description_en?: string | null
          description_zh?: string | null
          name_en: string
          name_zh: string
          sort_order?: number
        }
        Update: {
          category?: string
          code?: string
          description_en?: string | null
          description_zh?: string | null
          name_en?: string
          name_zh?: string
          sort_order?: number
        }
        Relationships: []
      }
      po_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          purchase_order_id: string
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          purchase_order_id: string
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          purchase_order_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "po_issues_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      prepayment_applications: {
        Row: {
          amount_base: number
          created_at: string
          created_by: string | null
          id: string
          inbound_batch_id: string
          journal_entry_id: string | null
          notes: string | null
          purchase_order_id: string
        }
        Insert: {
          amount_base: number
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id: string
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id: string
        }
        Update: {
          amount_base?: number
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id?: string
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
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
          rate_as_of: string | null
          rate_type: string | null
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
          rate_as_of?: string | null
          rate_type?: string | null
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
          rate_as_of?: string | null
          rate_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
        ]
      }
      pricing_formula_history: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          formula_id: string
          id: string
          metal: string | null
          new_average_days: number | null
          new_direction: string | null
          new_flat_discount_pct: number | null
          new_is_active: boolean | null
          new_name: string | null
          new_payable_pct: number | null
          new_price_basis: string | null
          new_treatment_charge_usd_per_tonne: number | null
          old_average_days: number | null
          old_direction: string | null
          old_flat_discount_pct: number | null
          old_is_active: boolean | null
          old_name: string | null
          old_payable_pct: number | null
          old_price_basis: string | null
          old_treatment_charge_usd_per_tonne: number | null
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          formula_id: string
          id?: string
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: number | null
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: number | null
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: number | null
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: number | null
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: number | null
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: number | null
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          formula_id?: string
          id?: string
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: number | null
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: number | null
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: number | null
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: number | null
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: number | null
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_formula_metals: {
        Row: {
          created_at: string
          created_by: string | null
          formula_id: string
          metal: string
          payable_pct: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          formula_id: string
          metal: string
          payable_pct: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          formula_id?: string
          metal?: string
          payable_pct?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_formulas: {
        Row: {
          average_days: number | null
          code: string
          created_at: string
          created_by: string | null
          customer_id: string | null
          deleted_at: string | null
          direction: string
          flat_discount_pct: number
          id: string
          is_active: boolean
          name: string
          notes: string | null
          price_basis: string
          price_index: string | null
          supplier_id: string | null
          treatment_charge_usd_per_tonne: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          average_days?: number | null
          code: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string
          flat_discount_pct?: number
          id?: string
          is_active?: boolean
          name: string
          notes?: string | null
          price_basis?: string
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          average_days?: number | null
          code?: string
          created_at?: string
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string
          flat_discount_pct?: number
          id?: string
          is_active?: boolean
          name?: string
          notes?: string | null
          price_basis?: string
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formulas_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_formulas_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_settings: {
        Row: {
          default_metal_index: string | null
          id: boolean
          metal_price_change_warn_pct: number
          metal_quote_stale_days: number
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          default_metal_index?: string | null
          id?: boolean
          metal_price_change_warn_pct: number
          metal_quote_stale_days?: number
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          default_metal_index?: string | null
          id?: boolean
          metal_price_change_warn_pct?: number
          metal_quote_stale_days?: number
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_settings_default_metal_index_fkey"
            columns: ["default_metal_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
        ]
      }
      pricing_term_commitment_metals: {
        Row: {
          commitment_id: string
          metal: string
          payable_pct: number
        }
        Insert: {
          commitment_id: string
          metal: string
          payable_pct: number
        }
        Update: {
          commitment_id?: string
          metal?: string
          payable_pct?: number
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_term_commitments: {
        Row: {
          average_days: number | null
          committed_at: string
          committed_by: string | null
          flat_discount_pct: number
          id: string
          inbound_batch_id: string | null
          price_basis: string
          price_index: string | null
          purchase_order_line_id: string | null
          source_formula_code: string
          source_formula_id: string | null
          source_formula_name: string | null
          treatment_charge_usd_per_tonne: number
        }
        Insert: {
          average_days?: number | null
          committed_at?: string
          committed_by?: string | null
          flat_discount_pct: number
          id?: string
          inbound_batch_id?: string | null
          price_basis: string
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code: string
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne: number
        }
        Update: {
          average_days?: number | null
          committed_at?: string
          committed_by?: string | null
          flat_discount_pct?: number
          id?: string
          inbound_batch_id?: string | null
          price_basis?: string
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code?: string
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne?: number
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entries: {
        Row: {
          amount_base: number
          cost_type: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          is_estimate: boolean
          notes: string | null
          relief_expense_id: string | null
          relieved_at: string | null
          remitted_at: string | null
          remitted_journal_entry_id: string | null
          run_id: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          amount_base: number
          cost_type: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          amount_base?: number
          cost_type?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          is_estimate?: boolean
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entries_relief_expense_id_fkey"
            columns: ["relief_expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entry_history: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          entry_id: string
          id: string
          new_amount_base: number | null
          new_cost_type: string | null
          new_is_estimate: boolean | null
          old_amount_base: number | null
          old_cost_type: string | null
          old_is_estimate: boolean | null
          run_id: string
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          entry_id: string
          id?: string
          new_amount_base?: number | null
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: number | null
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id: string
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          entry_id?: string
          id?: string
          new_amount_base?: number | null
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: number | null
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_inputs: {
        Row: {
          created_at: string
          id: string
          inbound_batch_id: string | null
          output_batch_id: string | null
          quantity_consumed: number
          run_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          inbound_batch_id?: string | null
          output_batch_id?: string | null
          quantity_consumed: number
          run_id: string
        }
        Update: {
          created_at?: string
          id?: string
          inbound_batch_id?: string | null
          output_batch_id?: string | null
          quantity_consumed?: number
          run_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "processing_inputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_inputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_outputs: {
        Row: {
          allocated_cost_base: number | null
          cost_incomplete: boolean
          created_at: string
          id: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_base: number | null
        }
        Insert: {
          allocated_cost_base?: number | null
          cost_incomplete?: boolean
          created_at?: string
          id?: string
          output_batch_id: string
          quantity_produced: number
          run_id: string
          unit_cost_base?: number | null
        }
        Update: {
          allocated_cost_base?: number | null
          cost_incomplete?: boolean
          created_at?: string
          id?: string
          output_batch_id?: string
          quantity_produced?: number
          run_id?: string
          unit_cost_base?: number | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
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
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_runs: {
        Row: {
          allocated_at: string | null
          allocated_by: string | null
          allocation_basis: string
          allocation_basis_changed_at: string | null
          allocation_snapshot: Json | null
          capitalization_entry_id: string | null
          capitalized_cost_base: number | null
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          id: string
          loss_qty: number | null
          material_cost_base: number | null
          notes: string | null
          process_cost_base: number | null
          process_date: string | null
          status: string
          total_cost_base: number | null
          total_input: number | null
          total_output: number | null
          updated_at: string
          updated_by: string | null
          work_order_id: string | null
        }
        Insert: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis: string
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: number | null
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_base?: number | null
          notes?: string | null
          process_cost_base?: number | null
          process_date?: string | null
          status: string
          total_cost_base?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
          work_order_id?: string | null
        }
        Update: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: number | null
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          id?: string
          loss_qty?: number | null
          material_cost_base?: number | null
          notes?: string | null
          process_cost_base?: number | null
          process_date?: string | null
          status?: string
          total_cost_base?: number | null
          total_input?: number | null
          total_output?: number | null
          updated_at?: string
          updated_by?: string | null
          work_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_runs_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_settings: {
        Row: {
          id: boolean
          notes: string | null
          updated_at: string
          updated_by: string | null
          wo_input_overrun_pct: number
          wo_output_shortfall_pct: number
        }
        Insert: {
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          wo_input_overrun_pct?: number
          wo_output_shortfall_pct?: number
        }
        Update: {
          id?: boolean
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          wo_input_overrun_pct?: number
          wo_output_shortfall_pct?: number
        }
        Relationships: []
      }
      public_holidays: {
        Row: {
          country: string
          created_at: string
          created_by: string | null
          holiday_date: string
          id: string
          is_active: boolean
          name_en: string
          name_zh: string
          notes: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          country?: string
          created_at?: string
          created_by?: string | null
          holiday_date: string
          id?: string
          is_active?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          country?: string
          created_at?: string
          created_by?: string | null
          holiday_date?: string
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
      purchase_order_history: {
        Row: {
          amend_reason: string | null
          change_type: string
          changed_at: string
          changed_by: string | null
          id: string
          line_no: number | null
          new_estimated_amount_ccy: number | null
          new_estimated_total_ccy: number | null
          new_estimated_unit_price: number | null
          new_expected_delivery_date: string | null
          new_fx_rate: number | null
          new_incoterm: string | null
          new_notes: string | null
          new_order_date: string | null
          new_quantity: number | null
          new_terms_text: string | null
          new_unit: string | null
          old_estimated_amount_ccy: number | null
          old_estimated_total_ccy: number | null
          old_estimated_unit_price: number | null
          old_expected_delivery_date: string | null
          old_fx_rate: number | null
          old_incoterm: string | null
          old_notes: string | null
          old_order_date: string | null
          old_quantity: number | null
          old_terms_text: string | null
          old_unit: string | null
          purchase_order_id: string
          purchase_order_line_id: string | null
        }
        Insert: {
          amend_reason?: string | null
          change_type: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          line_no?: number | null
          new_estimated_amount_ccy?: number | null
          new_estimated_total_ccy?: number | null
          new_estimated_unit_price?: number | null
          new_expected_delivery_date?: string | null
          new_fx_rate?: number | null
          new_incoterm?: string | null
          new_notes?: string | null
          new_order_date?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit?: string | null
          old_estimated_amount_ccy?: number | null
          old_estimated_total_ccy?: number | null
          old_estimated_unit_price?: number | null
          old_expected_delivery_date?: string | null
          old_fx_rate?: number | null
          old_incoterm?: string | null
          old_notes?: string | null
          old_order_date?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit?: string | null
          purchase_order_id: string
          purchase_order_line_id?: string | null
        }
        Update: {
          amend_reason?: string | null
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          id?: string
          line_no?: number | null
          new_estimated_amount_ccy?: number | null
          new_estimated_total_ccy?: number | null
          new_estimated_unit_price?: number | null
          new_expected_delivery_date?: string | null
          new_fx_rate?: number | null
          new_incoterm?: string | null
          new_notes?: string | null
          new_order_date?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit?: string | null
          old_estimated_amount_ccy?: number | null
          old_estimated_total_ccy?: number | null
          old_estimated_unit_price?: number | null
          old_expected_delivery_date?: string | null
          old_fx_rate?: number | null
          old_incoterm?: string | null
          old_notes?: string | null
          old_order_date?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit?: string | null
          purchase_order_id?: string
          purchase_order_line_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_history_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_lines: {
        Row: {
          created_at: string
          created_by: string | null
          estimated_amount_ccy: number
          estimated_unit_price: number | null
          expected_assay: Json | null
          id: string
          line_no: number
          material_id: string
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          pricing_formula_id: string | null
          purchase_order_id: string
          quantity: number
          unit: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          estimated_amount_ccy?: number
          estimated_unit_price?: number | null
          expected_assay?: Json | null
          id?: string
          line_no: number
          material_id: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id: string
          quantity: number
          unit?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          estimated_amount_ccy?: number
          estimated_unit_price?: number | null
          expected_assay?: Json | null
          id?: string
          line_no?: number
          material_id?: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id?: string
          quantity?: number
          unit?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_payment_terms: {
        Row: {
          created_at: string
          due_date: string | null
          fixed_amount_ccy: number | null
          id: string
          label: string
          notes: string | null
          percentage: number | null
          purchase_order_id: string
          seq: number
          trigger_event: string
        }
        Insert: {
          created_at?: string
          due_date?: string | null
          fixed_amount_ccy?: number | null
          id?: string
          label: string
          notes?: string | null
          percentage?: number | null
          purchase_order_id: string
          seq: number
          trigger_event: string
        }
        Update: {
          created_at?: string
          due_date?: string | null
          fixed_amount_ccy?: number | null
          id?: string
          label?: string
          notes?: string | null
          percentage?: number | null
          purchase_order_id?: string
          seq?: number
          trigger_event?: string
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_orders: {
        Row: {
          approval_status: string
          approved_at: string | null
          approved_by: string | null
          cancel_reason: string | null
          cancelled_at: string | null
          closed_at: string | null
          code: string
          created_at: string
          created_by: string | null
          currency: string
          deleted_at: string | null
          estimated_total_ccy: number
          expected_delivery_date: string | null
          fx_rate: number
          id: string
          incoterm: string | null
          notes: string | null
          order_date: string
          status: string
          supplier_id: string
          terms_text: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          approval_status?: string
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          estimated_total_ccy?: number
          expected_delivery_date?: string | null
          fx_rate: number
          id?: string
          incoterm?: string | null
          notes?: string | null
          order_date: string
          status?: string
          supplier_id: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          approval_status?: string
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          currency?: string
          deleted_at?: string | null
          estimated_total_ccy?: number
          expected_delivery_date?: string | null
          fx_rate?: number
          id?: string
          incoterm?: string | null
          notes?: string | null
          order_date?: string
          status?: string
          supplier_id?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      qt_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          quote_id: string
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          quote_id: string
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          quote_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "qt_issues_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quote_status"
            referencedColumns: ["quote_id"]
          },
          {
            foreignKeyName: "qt_issues_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
        ]
      }
      quote_history: {
        Row: {
          change_type: string
          changed_at: string
          changed_by: string | null
          detail: string | null
          id: string
          quote_id: string
        }
        Insert: {
          change_type: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          quote_id: string
        }
        Update: {
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          quote_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "quote_history_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quote_status"
            referencedColumns: ["quote_id"]
          },
          {
            foreignKeyName: "quote_history_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
        ]
      }
      quote_lines: {
        Row: {
          created_at: string
          id: string
          line_no: number
          material_id: string
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          quantity: number
          quote_id: string
          unit_price: number
        }
        Insert: {
          created_at?: string
          id?: string
          line_no: number
          material_id: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity: number
          quote_id: string
          unit_price: number
        }
        Update: {
          created_at?: string
          id?: string
          line_no?: number
          material_id?: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity?: number
          quote_id?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "quote_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "quote_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "quote_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "quote_lines_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quote_status"
            referencedColumns: ["quote_id"]
          },
          {
            foreignKeyName: "quote_lines_quote_id_fkey"
            columns: ["quote_id"]
            isOneToOne: false
            referencedRelation: "quotes"
            referencedColumns: ["id"]
          },
        ]
      }
      quotes: {
        Row: {
          code: string
          converted_order_id: string | null
          created_at: string
          created_by: string | null
          currency: string
          customer_id: string
          decline_reason: string | null
          deleted_at: string | null
          fx_rate: number
          id: string
          notes: string | null
          quote_date: string
          status: string
          terms_text: string | null
          updated_at: string
          updated_by: string | null
          valid_until: string
        }
        Insert: {
          code: string
          converted_order_id?: string | null
          created_at?: string
          created_by?: string | null
          currency: string
          customer_id: string
          decline_reason?: string | null
          deleted_at?: string | null
          fx_rate: number
          id?: string
          notes?: string | null
          quote_date: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_until: string
        }
        Update: {
          code?: string
          converted_order_id?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          customer_id?: string
          decline_reason?: string | null
          deleted_at?: string | null
          fx_rate?: number
          id?: string
          notes?: string | null
          quote_date?: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
          valid_until?: string
        }
        Relationships: [
          {
            foreignKeyName: "quotes_converted_order_id_fkey"
            columns: ["converted_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "quotes_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      review_cycles: {
        Row: {
          created_at: string
          created_by: string | null
          deleted_at: string | null
          due_date: string
          id: string
          name: string
          notes: string | null
          period_end: string
          period_start: string
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date: string
          id?: string
          name: string
          notes?: string | null
          period_end: string
          period_start: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          due_date?: string
          id?: string
          name?: string
          notes?: string | null
          period_end?: string
          period_start?: string
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      review_goals: {
        Row: {
          actual_value: number | null
          created_at: string
          created_by: string | null
          employee_result_text: string | null
          id: string
          objective_text: string
          review_id: string
          reviewer_assessment_text: string | null
          sequence: number
          target_value: number | null
          unit: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          actual_value?: number | null
          created_at?: string
          created_by?: string | null
          employee_result_text?: string | null
          id?: string
          objective_text: string
          review_id: string
          reviewer_assessment_text?: string | null
          sequence: number
          target_value?: number | null
          unit?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          actual_value?: number | null
          created_at?: string
          created_by?: string | null
          employee_result_text?: string | null
          id?: string
          objective_text?: string
          review_id?: string
          reviewer_assessment_text?: string | null
          sequence?: number
          target_value?: number | null
          unit?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_self_assessment"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      review_rating_scale: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          description_en: string | null
          description_zh: string | null
          is_active: boolean
          is_probation_pass: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          description_en?: string | null
          description_zh?: string | null
          is_active?: boolean
          is_probation_pass?: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          description_en?: string | null
          description_zh?: string | null
          is_active?: boolean
          is_probation_pass?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      role_permissions: {
        Row: {
          created_at: string
          created_by: string | null
          permission_code: string
          role_id: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          permission_code: string
          role_id: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          permission_code?: string
          role_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "role_permissions_permission_code_fkey"
            columns: ["permission_code"]
            isOneToOne: false
            referencedRelation: "permissions"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "role_permissions_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
        ]
      }
      roles: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          description_en: string | null
          description_zh: string | null
          id: string
          is_active: boolean
          is_system: boolean
          name_en: string
          name_zh: string
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description_en?: string | null
          description_zh?: string | null
          id?: string
          is_active?: boolean
          is_system?: boolean
          name_en: string
          name_zh: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          description_en?: string | null
          description_zh?: string | null
          id?: string
          is_active?: boolean
          is_system?: boolean
          name_en?: string
          name_zh?: string
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      sales_attribution_log: {
        Row: {
          amount_base: number
          attributed_at: string
          attributed_by: string | null
          customer_id: string
          exposure_after: number
          id: string
          note: string | null
          sales_record_id: string
        }
        Insert: {
          amount_base: number
          attributed_at?: string
          attributed_by?: string | null
          customer_id: string
          exposure_after: number
          id?: string
          note?: string | null
          sales_record_id: string
        }
        Update: {
          amount_base?: number
          attributed_at?: string
          attributed_by?: string | null
          customer_id?: string
          exposure_after?: number
          id?: string
          note?: string | null
          sales_record_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_attribution_log_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_attribution_log_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_attribution_log_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_attribution_log_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_attribution_log_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_order_history: {
        Row: {
          amend_reason: string | null
          change_type: string
          changed_at: string
          changed_by: string | null
          detail: string | null
          id: string
          line_no: number | null
          new_notes: string | null
          new_quantity: number | null
          new_terms_text: string | null
          new_unit_price: number | null
          old_notes: string | null
          old_quantity: number | null
          old_terms_text: string | null
          old_unit_price: number | null
          sales_order_id: string
          sales_order_line_id: string | null
        }
        Insert: {
          amend_reason?: string | null
          change_type: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          line_no?: number | null
          new_notes?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit_price?: number | null
          old_notes?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit_price?: number | null
          sales_order_id: string
          sales_order_line_id?: string | null
        }
        Update: {
          amend_reason?: string | null
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          line_no?: number | null
          new_notes?: string | null
          new_quantity?: number | null
          new_terms_text?: string | null
          new_unit_price?: number | null
          old_notes?: string | null
          old_quantity?: number | null
          old_terms_text?: string | null
          old_unit_price?: number | null
          sales_order_id?: string
          sales_order_line_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sales_order_history_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_order_lines: {
        Row: {
          created_at: string
          id: string
          line_no: number
          material_id: string
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          quantity: number
          sales_order_id: string
          unit_price: number
        }
        Insert: {
          created_at?: string
          id?: string
          line_no: number
          material_id: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity: number
          sales_order_id: string
          unit_price: number
        }
        Update: {
          created_at?: string
          id?: string
          line_no?: number
          material_id?: string
          notes?: string | null
          price_provenance?: Json | null
          price_source?: string | null
          quantity?: number
          sales_order_id?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "sales_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "sales_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "sales_order_lines_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_order_reservations: {
        Row: {
          consumed_at: string | null
          consumed_by: string | null
          created_at: string
          created_by: string | null
          id: string
          location_id: string | null
          output_batch_id: string
          pair_id: string
          qty: number
          release_pair_id: string | null
          release_reason: string | null
          released_at: string | null
          released_by: string | null
          sales_order_line_id: string
        }
        Insert: {
          consumed_at?: string | null
          consumed_by?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          location_id?: string | null
          output_batch_id: string
          pair_id: string
          qty: number
          release_pair_id?: string | null
          release_reason?: string | null
          released_at?: string | null
          released_by?: string | null
          sales_order_line_id: string
        }
        Update: {
          consumed_at?: string | null
          consumed_by?: string | null
          created_at?: string
          created_by?: string | null
          id?: string
          location_id?: string | null
          output_batch_id?: string
          pair_id?: string
          qty?: number
          release_pair_id?: string | null
          release_reason?: string | null
          released_at?: string | null
          released_by?: string | null
          sales_order_line_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_order_reservations_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_order_reservations_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_order_reservations_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_order_reservations_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_orders: {
        Row: {
          cancel_reason: string | null
          cancelled_at: string | null
          closed_at: string | null
          code: string
          confirmed_at: string | null
          created_at: string
          created_by: string | null
          currency: string
          customer_id: string
          deleted_at: string | null
          fx_rate: number
          id: string
          notes: string | null
          order_date: string
          status: string
          terms_text: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code: string
          confirmed_at?: string | null
          created_at?: string
          created_by?: string | null
          currency: string
          customer_id: string
          deleted_at?: string | null
          fx_rate: number
          id?: string
          notes?: string | null
          order_date: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code?: string
          confirmed_at?: string | null
          created_at?: string
          created_by?: string | null
          currency?: string
          customer_id?: string
          deleted_at?: string | null
          fx_rate?: number
          id?: string
          notes?: string | null
          order_date?: string
          status?: string
          terms_text?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "sales_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "sales_orders_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_orders_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_record_movements: {
        Row: {
          created_at: string
          id: string
          movement_id: string
          sales_record_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          movement_id: string
          sales_record_id: string
        }
        Update: {
          created_at?: string
          id?: string
          movement_id?: string
          sales_record_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "sales_record_movements_movement_id_fkey"
            columns: ["movement_id"]
            isOneToOne: true
            referencedRelation: "inventory_movements"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_record_movements_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_record_movements_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_record_movements_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_records: {
        Row: {
          amount_base: number
          cogs_entry_id: string | null
          created_at: string | null
          created_by: string | null
          currency: string
          customer_id: string | null
          fx_rate: number
          id: string
          notes: string | null
          output_batch_id: string
          price_provenance: Json | null
          price_source: string | null
          quantity: number
          sale_date: string
          sales_order_line_id: string | null
          unit_price: number
        }
        Insert: {
          amount_base: number
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency: string
          customer_id?: string | null
          fx_rate: number
          id?: string
          notes?: string | null
          output_batch_id: string
          price_provenance?: Json | null
          price_source?: string | null
          quantity: number
          sale_date: string
          sales_order_line_id?: string | null
          unit_price: number
        }
        Update: {
          amount_base?: number
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string
          customer_id?: string | null
          fx_rate?: number
          id?: string
          notes?: string | null
          output_batch_id?: string
          price_provenance?: Json | null
          price_source?: string | null
          quantity?: number
          sale_date?: string
          sales_order_line_id?: string | null
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "sales_records_cogs_entry_id_fkey"
            columns: ["cogs_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
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
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      shipment_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          sha256: string
          shipment_id: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256: string
          shipment_id: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sha256?: string
          shipment_id?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "shipment_issues_shipment_id_fkey"
            columns: ["shipment_id"]
            isOneToOne: false
            referencedRelation: "shipments"
            referencedColumns: ["id"]
          },
        ]
      }
      shipment_lines: {
        Row: {
          created_at: string
          id: string
          location_id: string | null
          output_batch_id: string
          qty: number
          reservation_id: string
          sales_order_line_id: string
          sales_record_id: string
          shipment_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          location_id?: string | null
          output_batch_id: string
          qty: number
          reservation_id: string
          sales_order_line_id: string
          sales_record_id: string
          shipment_id: string
        }
        Update: {
          created_at?: string
          id?: string
          location_id?: string | null
          output_batch_id?: string
          qty?: number
          reservation_id?: string
          sales_order_line_id?: string
          sales_record_id?: string
          shipment_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipment_lines_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "shipment_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_reservation_id_fkey"
            columns: ["reservation_id"]
            isOneToOne: true
            referencedRelation: "sales_order_reservations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "shipment_lines_shipment_id_fkey"
            columns: ["shipment_id"]
            isOneToOne: false
            referencedRelation: "shipments"
            referencedColumns: ["id"]
          },
        ]
      }
      shipments: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          notes: string | null
          sales_order_id: string
          ship_date: string
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          sales_order_id: string
          ship_date: string
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          sales_order_id?: string
          ship_date?: string
        }
        Relationships: [
          {
            foreignKeyName: "shipments_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      so_issues: {
        Row: {
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          sales_order_id: string
          sha256: string
          version: number
        }
        Insert: {
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sales_order_id: string
          sha256: string
          version: number
        }
        Update: {
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          sales_order_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "so_issues_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
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
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "stocktake_lines_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "stocktake_lines_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
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
      storage_location_allowed_classes: {
        Row: {
          classification_code: string
          created_at: string
          created_by: string | null
          id: string
          location_id: string
        }
        Insert: {
          classification_code: string
          created_at?: string
          created_by?: string | null
          id?: string
          location_id: string
        }
        Update: {
          classification_code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          location_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "storage_location_allowed_classes_classification_code_fkey"
            columns: ["classification_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "storage_location_allowed_classes_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
        ]
      }
      storage_locations: {
        Row: {
          code: string
          created_at: string
          created_by: string | null
          id: string
          is_active: boolean
          name: string
          notes: string | null
          updated_at: string
          updated_by: string | null
          zone: string | null
        }
        Insert: {
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          name: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          zone?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          is_active?: boolean
          name?: string
          notes?: string | null
          updated_at?: string
          updated_by?: string | null
          zone?: string | null
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
          cert_type_code: string
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
          cert_type_code: string
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
          cert_type_code?: string
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
            foreignKeyName: "supplier_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "certificate_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "supplier_compliance_cert_type_code_fkey"
            columns: ["cert_type_code"]
            isOneToOne: false
            referencedRelation: "supplier_receiving_blocked"
            referencedColumns: ["cert_type_code"]
          },
          {
            foreignKeyName: "supplier_compliance_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "supplier_compliance_document_fkey"
            columns: ["document_id"]
            isOneToOne: false
            referencedRelation: "supplier_attachments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_compliance_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "supplier_compliance_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
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
          default_payment_term_template_id: string | null
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
          default_payment_term_template_id?: string | null
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
          default_payment_term_template_id?: string | null
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
        Relationships: [
          {
            foreignKeyName: "suppliers_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "suppliers_default_payment_term_template_id_fkey"
            columns: ["default_payment_term_template_id"]
            isOneToOne: false
            referencedRelation: "payment_term_templates"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "suppliers_owner_id_fkey"
            columns: ["owner_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
          {
            foreignKeyName: "suppliers_updated_by_fkey"
            columns: ["updated_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
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
      traceability_report_issues: {
        Row: {
          code: string
          file_path: string
          id: string
          issued_at: string
          issued_by: string | null
          output_batch_id: string
          sha256: string
          version: number
        }
        Insert: {
          code: string
          file_path: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          output_batch_id: string
          sha256: string
          version: number
        }
        Update: {
          code?: string
          file_path?: string
          id?: string
          issued_at?: string
          issued_by?: string | null
          output_batch_id?: string
          sha256?: string
          version?: number
        }
        Relationships: [
          {
            foreignKeyName: "traceability_report_issues_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "traceability_report_issues_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      training_records: {
        Row: {
          category: string | null
          certificate_ref: string | null
          completed_date: string
          created_at: string
          created_by: string | null
          deleted_at: string | null
          employee_id: string
          expiry_date: string | null
          id: string
          notes: string | null
          provider: string | null
          training_name: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          category?: string | null
          certificate_ref?: string | null
          completed_date: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          employee_id: string
          expiry_date?: string | null
          id?: string
          notes?: string | null
          provider?: string | null
          training_name: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          category?: string | null
          certificate_ref?: string | null
          completed_date?: string
          created_at?: string
          created_by?: string | null
          deleted_at?: string | null
          employee_id?: string
          expiry_date?: string | null
          id?: string
          notes?: string | null
          provider?: string | null
          training_name?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "training_records_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      user_roles: {
        Row: {
          granted_at: string
          granted_by: string | null
          id: string
          revoke_reason: string | null
          revoked_at: string | null
          revoked_by: string | null
          role_id: string
          user_id: string
        }
        Insert: {
          granted_at?: string
          granted_by?: string | null
          id?: string
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          role_id: string
          user_id: string
        }
        Update: {
          granted_at?: string
          granted_by?: string | null
          id?: string
          revoke_reason?: string | null
          revoked_at?: string | null
          revoked_by?: string | null
          role_id?: string
          user_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "user_roles_role_id_fkey"
            columns: ["role_id"]
            isOneToOne: false
            referencedRelation: "roles"
            referencedColumns: ["id"]
          },
        ]
      }
      waste_classifications: {
        Row: {
          code: string
          created_at: string
          is_active: boolean
          is_controlled: boolean
          name_en: string
          name_zh: string
          notes: string | null
          sort_order: number
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          code: string
          created_at?: string
          is_active?: boolean
          is_controlled: boolean
          name_en: string
          name_zh: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          code?: string
          created_at?: string
          is_active?: boolean
          is_controlled?: boolean
          name_en?: string
          name_zh?: string
          notes?: string | null
          sort_order?: number
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      work_order_expected_outputs: {
        Row: {
          created_at: string
          expected_qty: number
          id: string
          material_id: string
          work_order_id: string
        }
        Insert: {
          created_at?: string
          expected_qty: number
          id?: string
          material_id: string
          work_order_id: string
        }
        Update: {
          created_at?: string
          expected_qty?: number
          id?: string
          material_id?: string
          work_order_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_order_expected_outputs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_expected_outputs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_order_expected_outputs_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_expected_outputs_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      work_order_history: {
        Row: {
          amend_reason: string | null
          change_type: string
          changed_at: string
          changed_by: string | null
          detail: string | null
          id: string
          material_id: string | null
          new_notes: string | null
          new_qty: number | null
          new_scheduled_date: string | null
          old_notes: string | null
          old_qty: number | null
          old_scheduled_date: string | null
          work_order_expected_id: string | null
          work_order_id: string
          work_order_line_id: string | null
        }
        Insert: {
          amend_reason?: string | null
          change_type: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          material_id?: string | null
          new_notes?: string | null
          new_qty?: number | null
          new_scheduled_date?: string | null
          old_notes?: string | null
          old_qty?: number | null
          old_scheduled_date?: string | null
          work_order_expected_id?: string | null
          work_order_id: string
          work_order_line_id?: string | null
        }
        Update: {
          amend_reason?: string | null
          change_type?: string
          changed_at?: string
          changed_by?: string | null
          detail?: string | null
          id?: string
          material_id?: string | null
          new_notes?: string | null
          new_qty?: number | null
          new_scheduled_date?: string | null
          old_notes?: string | null
          old_qty?: number | null
          old_scheduled_date?: string | null
          work_order_expected_id?: string | null
          work_order_id?: string
          work_order_line_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "work_order_history_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      work_order_lines: {
        Row: {
          created_at: string
          id: string
          material_id: string
          planned_qty: number
          work_order_id: string
        }
        Insert: {
          created_at?: string
          id?: string
          material_id: string
          planned_qty: number
          work_order_id: string
        }
        Update: {
          created_at?: string
          id?: string
          material_id?: string
          planned_qty?: number
          work_order_id?: string
        }
        Relationships: [
          {
            foreignKeyName: "work_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "work_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "work_order_lines_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      work_orders: {
        Row: {
          cancel_reason: string | null
          cancelled_at: string | null
          cancelled_by: string | null
          close_reason: string | null
          closed_at: string | null
          closed_by: string | null
          code: string
          created_at: string
          created_by: string | null
          id: string
          notes: string | null
          scheduled_date: string | null
          status: string
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          close_reason?: string | null
          closed_at?: string | null
          closed_by?: string | null
          code: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          scheduled_date?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          cancel_reason?: string | null
          cancelled_at?: string | null
          cancelled_by?: string | null
          close_reason?: string | null
          closed_at?: string | null
          closed_by?: string | null
          code?: string
          created_at?: string
          created_by?: string | null
          id?: string
          notes?: string | null
          scheduled_date?: string | null
          status?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
      }
      year_closes: {
        Row: {
          closed_at: string
          closed_by: string | null
          closing_journal_id: string
          id: string
          net_result: number
          notes: string | null
          reopen_reason: string | null
          reopened_at: string | null
          reopened_by: string | null
          reversal_journal_id: string | null
          year_end: string
        }
        Insert: {
          closed_at?: string
          closed_by?: string | null
          closing_journal_id: string
          id?: string
          net_result: number
          notes?: string | null
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          reversal_journal_id?: string | null
          year_end: string
        }
        Update: {
          closed_at?: string
          closed_by?: string | null
          closing_journal_id?: string
          id?: string
          net_result?: number
          notes?: string | null
          reopen_reason?: string | null
          reopened_at?: string | null
          reopened_by?: string | null
          reversal_journal_id?: string | null
          year_end?: string
        }
        Relationships: [
          {
            foreignKeyName: "year_closes_closing_journal_id_fkey"
            columns: ["closing_journal_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "year_closes_closing_journal_id_fkey"
            columns: ["closing_journal_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "year_closes_reversal_journal_id_fkey"
            columns: ["reversal_journal_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "year_closes_reversal_journal_id_fkey"
            columns: ["reversal_journal_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
        ]
      }
    }
    Views: {
      ap_open_items: {
        Row: {
          bucket: string | null
          currency: string | null
          days_outstanding: number | null
          doc_code: string | null
          doc_date: string | null
          doc_id: string | null
          doc_kind: string | null
          doc_value_base: number | null
          inbound_batch_id: string | null
          open_base: number | null
          open_ccy: number | null
          settled_base: number | null
          supplier_id: string | null
          supplier_name: string | null
        }
        Relationships: []
      }
      ar_open_items: {
        Row: {
          amount_base: number | null
          amount_ccy: number | null
          bucket: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          customer_name: string | null
          days_outstanding: number | null
          doc_code: string | null
          doc_kind: string | null
          invoice_code: string | null
          invoice_id: string | null
          open_base: number | null
          open_ccy: number | null
          sale_date: string | null
          sales_record_id: string | null
          settled_base: number | null
          settled_ccy: number | null
        }
        Relationships: []
      }
      bank_reconciliation_status: {
        Row: {
          account_code: string | null
          currency: string | null
          difference: number | null
          ignored_statement_lines: number | null
          latest_closing_balance: number | null
          latest_statement_code: string | null
          latest_statement_period_end: string | null
          ledger_balance: number | null
          unmatched_journal_amount: number | null
          unmatched_journal_lines: number | null
          unmatched_statement_lines: number | null
        }
        Relationships: []
      }
      bank_unmatched_journal_lines: {
        Row: {
          account_code: string | null
          amount_ccy: number | null
          currency: string | null
          direction: string | null
          entry_code: string | null
          entry_date: string | null
          entry_id: string | null
          journal_line_id: string | null
          memo: string | null
          source_id: string | null
          source_type: string | null
        }
        Relationships: [
          {
            foreignKeyName: "journal_lines_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      batch_assay_status: {
        Row: {
          assay_count: number | null
          batch_code: string | null
          formula_code: string | null
          has_unapplied_assay: boolean | null
          inbound_batch_id: string | null
          latest_assay_applied: boolean | null
          latest_assay_code: string | null
          latest_assay_date: string | null
          latest_assay_id: string | null
          material_name: string | null
          po_code: string | null
          pricing_formula_id: string | null
          pricing_status: string | null
          purchase_order_id: string | null
          quantity: number | null
          supplier_name: string | null
          unit: string | null
          unit_price: number | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      batch_lineage: {
        Row: {
          depth: number | null
          output_batch_id: string | null
          parent_batch_id: string | null
          parent_code: string | null
          parent_kind: string | null
          quantity_consumed: number | null
          via_run_code: string | null
          via_run_id: string | null
        }
        Relationships: []
      }
      batch_lineage_all: {
        Row: {
          depth: number | null
          output_batch_id: string | null
          parent_batch_id: string | null
          parent_code: string | null
          parent_kind: string | null
          quantity_consumed: number | null
          via_run_code: string | null
          via_run_id: string | null
        }
        Relationships: []
      }
      batch_margin: {
        Row: {
          batch_code: string | null
          cogs_differs: boolean | null
          cogs_posted_base: number | null
          cost_current_base: number | null
          cost_incomplete: boolean | null
          is_stale: boolean | null
          margin_base: number | null
          margin_pct: number | null
          margin_status: string | null
          material_name: string | null
          output_batch_id: string | null
          qty_sold: number | null
          revenue_base: number | null
          run_code: string | null
          run_id: string | null
          unit_cost_base: number | null
        }
        Relationships: []
      }
      batch_required_assay_gaps: {
        Row: {
          arrival_date: string | null
          batch_code: string | null
          inbound_batch_id: string | null
          material_code: string | null
          material_id: string | null
          material_name: string | null
          missing_metals: string[] | null
          remaining_qty: number | null
          required_metals: string[] | null
          sampleable: boolean | null
          supplier_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
        ]
      }
      company_profile_masked: {
        Row: {
          address_lines: string | null
          bank_account_name: string | null
          bank_account_no: string | null
          bank_address: string | null
          bank_name: string | null
          bank_swift: string | null
          city: string | null
          country: string | null
          email: string | null
          id: boolean | null
          invoice_footer_text: string | null
          legal_name: string | null
          logo_path: string | null
          phone: string | null
          postal_code: string | null
          registration_no: string | null
          updated_at: string | null
          updated_by: string | null
          website: string | null
        }
        Insert: {
          address_lines?: string | null
          bank_account_name?: never
          bank_account_no?: never
          bank_address?: never
          bank_name?: never
          bank_swift?: never
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean | null
          invoice_footer_text?: string | null
          legal_name?: string | null
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string | null
          updated_by?: string | null
          website?: string | null
        }
        Update: {
          address_lines?: string | null
          bank_account_name?: never
          bank_account_no?: never
          bank_address?: never
          bank_name?: never
          bank_swift?: never
          city?: string | null
          country?: string | null
          email?: string | null
          id?: boolean | null
          invoice_footer_text?: string | null
          legal_name?: string | null
          logo_path?: string | null
          phone?: string | null
          postal_code?: string | null
          registration_no?: string | null
          updated_at?: string | null
          updated_by?: string | null
          website?: string | null
        }
        Relationships: []
      }
      customer_credit_status: {
        Row: {
          code: string | null
          credit_hold: boolean | null
          credit_limit_base: number | null
          customer_id: string | null
          exposure_base: number | null
          headroom_base: number | null
          legal_name: string | null
          sales_blocked: boolean | null
        }
        Insert: {
          code?: string | null
          credit_hold?: boolean | null
          credit_limit_base?: number | null
          customer_id?: string | null
          exposure_base?: never
          headroom_base?: never
          legal_name?: string | null
          sales_blocked?: never
        }
        Update: {
          code?: string | null
          credit_hold?: boolean | null
          credit_limit_base?: number | null
          customer_id?: string | null
          exposure_base?: never
          headroom_base?: never
          legal_name?: string | null
          sales_blocked?: never
        }
        Relationships: []
      }
      employee_directory: {
        Row: {
          annual_leave_accrued_days: number | null
          annual_leave_available_days: number | null
          annual_leave_rate_days: number | null
          code: string | null
          current_gross_pay: number | null
          current_pay_period: string | null
          days_to_work_pass_expiry: number | null
          department_id: string | null
          department_name_en: string | null
          department_name_zh: string | null
          employee_id: string | null
          employment_status: string | null
          employment_type: string | null
          hire_date: string | null
          job_title: string | null
          legal_name: string | null
          manager_code: string | null
          manager_id: string | null
          manager_name: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          training_count: number | null
          work_category: string | null
          work_pass_alert: string | null
          work_pass_expiry_date: string | null
          work_pass_type: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employees_masked: {
        Row: {
          annual_leave_accrued_days: number | null
          annual_leave_available_days: number | null
          annual_leave_rate_days: number | null
          code: string | null
          confirmation_date: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          department_id: string | null
          employment_status: string | null
          employment_type: string | null
          hire_date: string | null
          id: string | null
          identity_no: string | null
          job_title: string | null
          legal_name: string | null
          manager_id: string | null
          monthly_salary: number | null
          monthly_salary_set: boolean | null
          notes: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          review_exempt: boolean | null
          separation_date: string | null
          separation_notes: string | null
          separation_type: string | null
          updated_at: string | null
          updated_by: string | null
          user_id: string | null
          work_category: string | null
          work_email: string | null
          work_pass_expiry_date: string | null
          work_pass_issue_date: string | null
          work_pass_no: string | null
          work_pass_type: string | null
          work_phone: string | null
        }
        Insert: {
          annual_leave_accrued_days?: never
          annual_leave_available_days?: never
          annual_leave_rate_days?: never
          code?: string | null
          confirmation_date?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          hire_date?: string | null
          id?: string | null
          identity_no?: never
          job_title?: string | null
          legal_name?: string | null
          manager_id?: string | null
          monthly_salary?: never
          monthly_salary_set?: boolean | null
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean | null
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string | null
          updated_by?: string | null
          user_id?: string | null
          work_category?: string | null
          work_email?: never
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: never
          work_pass_type?: string | null
          work_phone?: never
        }
        Update: {
          annual_leave_accrued_days?: never
          annual_leave_available_days?: never
          annual_leave_rate_days?: never
          code?: string | null
          confirmation_date?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          department_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          hire_date?: string | null
          id?: string | null
          identity_no?: never
          job_title?: string | null
          legal_name?: string | null
          manager_id?: string | null
          monthly_salary?: never
          monthly_salary_set?: boolean | null
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
          review_exempt?: boolean | null
          separation_date?: string | null
          separation_notes?: string | null
          separation_type?: string | null
          updated_at?: string | null
          updated_by?: string | null
          user_id?: string | null
          work_category?: string | null
          work_email?: never
          work_pass_expiry_date?: string | null
          work_pass_issue_date?: string | null
          work_pass_no?: never
          work_pass_type?: string | null
          work_phone?: never
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_manager_id_fkey"
            columns: ["manager_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employees_user_id_fkey"
            columns: ["user_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
          },
        ]
      }
      employment_history_masked: {
        Row: {
          change_type: string | null
          created_at: string | null
          created_by: string | null
          department_id: string | null
          effective_date: string | null
          employee_id: string | null
          employment_status: string | null
          employment_type: string | null
          id: string | null
          job_title: string | null
          new_monthly_salary: number | null
          notes: string | null
          old_monthly_salary: number | null
          work_category: string | null
        }
        Insert: {
          change_type?: string | null
          created_at?: string | null
          created_by?: string | null
          department_id?: string | null
          effective_date?: string | null
          employee_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          id?: string | null
          job_title?: string | null
          new_monthly_salary?: never
          notes?: string | null
          old_monthly_salary?: never
          work_category?: string | null
        }
        Update: {
          change_type?: string | null
          created_at?: string | null
          created_by?: string | null
          department_id?: string | null
          effective_date?: string | null
          employee_id?: string | null
          employment_status?: string | null
          employment_type?: string | null
          id?: string | null
          job_title?: string | null
          new_monthly_salary?: never
          notes?: string | null
          old_monthly_salary?: never
          work_category?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employment_history_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "employment_history_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      fx_rate_gaps: {
        Row: {
          currency: string | null
          entry_count: number | null
          gap_source: string | null
          missing_types: string[] | null
          quote_count: number | null
          rate_date: string | null
        }
        Relationships: []
      }
      hr_alerts: {
        Row: {
          alert_type: string | null
          days_remaining: number | null
          due_date: string | null
          employee_code: string | null
          employee_id: string | null
          employee_name: string | null
          severity: string | null
          subject: string | null
        }
        Relationships: []
      }
      inbound_batches_masked: {
        Row: {
          arrival_date: string | null
          code: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          material_id: string | null
          notes: string | null
          pricing_formula_id: string | null
          pricing_status: string | null
          purchase_order_id: string | null
          purchase_order_line_id: string | null
          quantity: number | null
          remaining_qty: number | null
          stage: string | null
          status: string | null
          supplier_id: string | null
          unit: string | null
          unit_price: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          arrival_date?: string | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          material_id?: string | null
          notes?: string | null
          pricing_formula_id?: string | null
          pricing_status?: string | null
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
          quantity?: number | null
          remaining_qty?: number | null
          stage?: string | null
          status?: string | null
          supplier_id?: string | null
          unit?: string | null
          unit_price?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          arrival_date?: string | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          material_id?: string | null
          notes?: string | null
          pricing_formula_id?: string | null
          pricing_status?: string | null
          purchase_order_id?: string | null
          purchase_order_line_id?: string | null
          quantity?: number | null
          remaining_qty?: number | null
          stage?: string | null
          status?: string | null
          supplier_id?: string | null
          unit?: string | null
          unit_price?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inbound_batches_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_lines_masked"
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
      invoice_document_totals: {
        Row: {
          currency: string | null
          invoice_id: string | null
          subtotal_ccy: number | null
          tax_ccy: number | null
          total_ccy: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
        ]
      }
      invoice_lines_masked: {
        Row: {
          amount_base: number | null
          amount_ccy: number | null
          created_at: string | null
          description: string | null
          id: string | null
          invoice_id: string | null
          invoice_voided: boolean | null
          line_no: number | null
          quantity: number | null
          sales_order_line_id: string | null
          sales_record_id: string | null
          unit: string | null
          unit_price: number | null
        }
        Insert: {
          amount_base?: never
          amount_ccy?: never
          created_at?: string | null
          description?: string | null
          id?: string | null
          invoice_id?: string | null
          invoice_voided?: boolean | null
          line_no?: number | null
          quantity?: number | null
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          unit?: string | null
          unit_price?: never
        }
        Update: {
          amount_base?: never
          amount_ccy?: never
          created_at?: string | null
          description?: string | null
          id?: string | null
          invoice_id?: string | null
          invoice_voided?: boolean | null
          line_no?: number | null
          quantity?: number | null
          sales_order_line_id?: string | null
          sales_record_id?: string | null
          unit?: string | null
          unit_price?: never
        }
        Relationships: [
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_document_totals"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoice_status"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "invoices_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_balance_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "order_invoice_open_all"
            referencedColumns: ["invoice_id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_visible"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_status: {
        Row: {
          code: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          customer_name: string | null
          days_overdue: number | null
          due_date: string | null
          invoice_id: string | null
          issue_date: string | null
          kind: string | null
          open_base: number | null
          overdue: boolean | null
          payment_state: string | null
          settled_base: number | null
          total_base: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      invoices_masked: {
        Row: {
          bill_to_snapshot: Json | null
          code: string | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          customer_id: string | null
          due_date: string | null
          entry_id: string | null
          fx_rate: number | null
          id: string | null
          issue_date: string | null
          kind: string | null
          notes: string | null
          payment_terms_days: number | null
          sales_order_id: string | null
          status: string | null
          subtotal_base: number | null
          tax_base: number | null
          tax_rate_pct: number | null
          terms_text: string | null
          total_base: number | null
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          bill_to_snapshot?: Json | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          due_date?: string | null
          entry_id?: string | null
          fx_rate?: never
          id?: string | null
          issue_date?: string | null
          kind?: string | null
          notes?: string | null
          payment_terms_days?: number | null
          sales_order_id?: string | null
          status?: string | null
          subtotal_base?: never
          tax_base?: never
          tax_rate_pct?: number | null
          terms_text?: string | null
          total_base?: never
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          bill_to_snapshot?: Json | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          due_date?: string | null
          entry_id?: string | null
          fx_rate?: never
          id?: string | null
          issue_date?: string | null
          kind?: string | null
          notes?: string | null
          payment_terms_days?: number | null
          sales_order_id?: string | null
          status?: string | null
          subtotal_base?: never
          tax_base?: never
          tax_rate_pct?: number | null
          terms_text?: string | null
          total_base?: never
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "invoices_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "invoices_sales_order_id_fkey"
            columns: ["sales_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      leave_calendar: {
        Row: {
          code: string | null
          days: number | null
          department_id: string | null
          employee_code: string | null
          employee_id: string | null
          end_date: string | null
          end_half_day: boolean | null
          leave_type_code: string | null
          leave_type_en: string | null
          leave_type_zh: string | null
          legal_name: string | null
          request_id: string | null
          start_date: string | null
          start_half_day: boolean | null
          status: string | null
        }
        Relationships: [
          {
            foreignKeyName: "employees_department_id_fkey"
            columns: ["department_id"]
            isOneToOne: false
            referencedRelation: "departments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "leave_types"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "leave_requests_leave_type_code_fkey"
            columns: ["leave_type_code"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["leave_type_code"]
          },
        ]
      }
      material_stock_available: {
        Row: {
          available_qty: number | null
          code: string | null
          last_movement_date: string | null
          material_id: string | null
          name: string | null
          safety_stock_qty: number | null
          unit: string | null
        }
        Relationships: []
      }
      medical_claim_status: {
        Row: {
          amount_sgd: number | null
          claim_date: string | null
          claim_id: string | null
          claim_year: number | null
          code: string | null
          decided_at: string | null
          description: string | null
          employee_code: string | null
          employee_id: string | null
          expense_amount_base: number | null
          expense_code: string | null
          expense_id: string | null
          legal_name: string | null
          linked_to_expense: boolean | null
          receipt_ref: string | null
          settled_base: number | null
          settlement_state: string | null
          status: string | null
        }
        Relationships: [
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "medical_claims_expense_id_fkey"
            columns: ["expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
        ]
      }
      my_leave_balance: {
        Row: {
          available: number | null
          consumed: number | null
          employee_code: string | null
          employee_id: string | null
          expired: number | null
          granted: number | null
          leave_type_code: string | null
          name_en: string | null
          name_zh: string | null
        }
        Relationships: []
      }
      my_profile: {
        Row: {
          annual_leave_accrued_days: number | null
          annual_leave_available_days: number | null
          annual_leave_rate_days: number | null
          code: string | null
          department_name_en: string | null
          department_name_zh: string | null
          employee_id: string | null
          employment_status: string | null
          employment_type: string | null
          hire_date: string | null
          identity_no: string | null
          job_title: string | null
          latest_payroll_code: string | null
          latest_payroll_month: string | null
          legal_name: string | null
          manager_code: string | null
          manager_name: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
          training_count: number | null
          work_category: string | null
          work_email: string | null
          work_pass_expiry_date: string | null
          work_pass_issue_date: string | null
          work_pass_no: string | null
          work_pass_type: string | null
          work_phone: string | null
        }
        Relationships: []
      }
      my_review_subjects: {
        Row: {
          cycle_name: string | null
          department_name_en: string | null
          department_name_zh: string | null
          employee_code: string | null
          employee_id: string | null
          employee_name: string | null
          job_title: string | null
          review_id: string | null
        }
        Relationships: []
      }
      my_self_assessment: {
        Row: {
          cycle_id: string | null
          cycle_name: string | null
          employee_id: string | null
          period_end: string | null
          period_start: string | null
          review_id: string | null
          review_type: string | null
          self_assessment_submitted_at: string | null
          self_assessment_text: string | null
          status: string | null
        }
        Relationships: [
          {
            foreignKeyName: "performance_reviews_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "review_cycles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      my_self_assessment_goals: {
        Row: {
          actual_value: number | null
          employee_result_text: string | null
          goal_id: string | null
          objective_text: string | null
          review_id: string | null
          sequence: number | null
          target_value: number | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "my_self_assessment"
            referencedColumns: ["review_id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "review_goals_review_id_fkey"
            columns: ["review_id"]
            isOneToOne: false
            referencedRelation: "performance_reviews_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      operations_now: {
        Row: {
          days_waiting: number | null
          doc_kind: string | null
          item_code: string | null
          item_date: string | null
          item_id: string | null
          item_type: string | null
          permission: string | null
          permission_any: string[] | null
          subject: string | null
        }
        Relationships: []
      }
      order_invoice_balance_all: {
        Row: {
          amount_ccy: number | null
          code: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          due_date: string | null
          fx_rate: number | null
          invoice_id: string | null
          issue_date: string | null
          open_base: number | null
          open_ccy: number | null
          settled_ccy: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      order_invoice_open_all: {
        Row: {
          amount_ccy: number | null
          code: string | null
          credited_base: number | null
          credited_ccy: number | null
          currency: string | null
          customer_id: string | null
          due_date: string | null
          fx_rate: number | null
          invoice_id: string | null
          issue_date: string | null
          open_base: number | null
          open_ccy: number | null
          settled_ccy: number | null
        }
        Relationships: [
          {
            foreignKeyName: "invoices_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "invoices_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_term_template_lines_masked: {
        Row: {
          created_at: string | null
          days_offset: number | null
          fixed_amount_ccy: number | null
          id: string | null
          label: string | null
          notes: string | null
          percentage: number | null
          seq: number | null
          template_id: string | null
          trigger_event: string | null
        }
        Insert: {
          created_at?: string | null
          days_offset?: number | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          seq?: number | null
          template_id?: string | null
          trigger_event?: string | null
        }
        Update: {
          created_at?: string | null
          days_offset?: number | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          seq?: number | null
          template_id?: string | null
          trigger_event?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payment_term_template_lines_template_id_fkey"
            columns: ["template_id"]
            isOneToOne: false
            referencedRelation: "payment_term_templates"
            referencedColumns: ["id"]
          },
        ]
      }
      payroll_lines_masked: {
        Row: {
          created_at: string | null
          employee_cpf: number | null
          employee_id: string | null
          employer_cpf: number | null
          gross_pay: number | null
          id: string | null
          net_pay: number | null
          notes: string | null
          other_deductions: number | null
          paid_at: string | null
          paid_journal_entry_id: string | null
          payroll_period_id: string | null
        }
        Insert: {
          created_at?: string | null
          employee_cpf?: never
          employee_id?: string | null
          employer_cpf?: never
          gross_pay?: never
          id?: string | null
          net_pay?: never
          notes?: string | null
          other_deductions?: never
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id?: string | null
        }
        Update: {
          created_at?: string | null
          employee_cpf?: never
          employee_id?: string | null
          employer_cpf?: never
          gross_pay?: never
          id?: string | null
          net_pay?: never
          notes?: string | null
          other_deductions?: never
          paid_at?: string | null
          paid_journal_entry_id?: string | null
          payroll_period_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "payroll_lines_paid_journal_entry_id_fkey"
            columns: ["paid_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "payroll_lines_payroll_period_id_fkey"
            columns: ["payroll_period_id"]
            isOneToOne: false
            referencedRelation: "payroll_periods"
            referencedColumns: ["id"]
          },
        ]
      }
      performance_reviews_masked: {
        Row: {
          acknowledged_at: string | null
          approved_at: string | null
          approved_by: string | null
          created_at: string | null
          created_by: string | null
          cycle_id: string | null
          employee_id: string | null
          id: string | null
          new_monthly_salary: number | null
          notes: string | null
          period_end: string | null
          period_start: string | null
          probation_outcome: string | null
          rating_code: string | null
          review_type: string | null
          reviewer_employee_id: string | null
          salary_effective_date: string | null
          self_assessment_submitted_at: string | null
          self_assessment_text: string | null
          status: string | null
          submitted_at: string | null
          submitted_by: string | null
          summary_text: string | null
          updated_at: string | null
          updated_by: string | null
          void_reason: string | null
          voided_at: string | null
          voided_by: string | null
        }
        Insert: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string | null
          created_by?: string | null
          cycle_id?: string | null
          employee_id?: string | null
          id?: string | null
          new_monthly_salary?: never
          notes?: string | null
          period_end?: string | null
          period_start?: string | null
          probation_outcome?: string | null
          rating_code?: string | null
          review_type?: string | null
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string | null
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Update: {
          acknowledged_at?: string | null
          approved_at?: string | null
          approved_by?: string | null
          created_at?: string | null
          created_by?: string | null
          cycle_id?: string | null
          employee_id?: string | null
          id?: string | null
          new_monthly_salary?: never
          notes?: string | null
          period_end?: string | null
          period_start?: string | null
          probation_outcome?: string | null
          rating_code?: string | null
          review_type?: string | null
          reviewer_employee_id?: string | null
          salary_effective_date?: string | null
          self_assessment_submitted_at?: string | null
          self_assessment_text?: string | null
          status?: string | null
          submitted_at?: string | null
          submitted_by?: string | null
          summary_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
          void_reason?: string | null
          voided_at?: string | null
          voided_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "performance_reviews_cycle_id_fkey"
            columns: ["cycle_id"]
            isOneToOne: false
            referencedRelation: "review_cycles"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_employee_id_fkey"
            columns: ["employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_rating_code_fkey"
            columns: ["rating_code"]
            isOneToOne: false
            referencedRelation: "review_rating_scale"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employee_directory"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "employees_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_leave_balance"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_profile"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "my_review_subjects"
            referencedColumns: ["employee_id"]
          },
          {
            foreignKeyName: "performance_reviews_reviewer_employee_id_fkey"
            columns: ["reviewer_employee_id"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      po_prepayment_applicable: {
        Row: {
          applicable_base: number | null
          batch_ap_open_base: number | null
          batch_code: string | null
          inbound_batch_id: string | null
          po_code: string | null
          po_unapplied_prepayment_base: number | null
          purchase_order_id: string | null
          supplier_id: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      po_receivable_lines: {
        Row: {
          estimated_unit_price: number | null
          expected_assay: Json | null
          line_id: string | null
          line_no: number | null
          material_id: string | null
          material_name: string | null
          order_date: string | null
          ordered_qty: number | null
          po_code: string | null
          po_id: string | null
          pricing_formula_id: string | null
          received_qty: number | null
          remaining_qty: number | null
          supplier_id: string | null
          supplier_name: string | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      prepayment_applications_masked: {
        Row: {
          amount_base: number | null
          created_at: string | null
          created_by: string | null
          id: string | null
          inbound_batch_id: string | null
          journal_entry_id: string | null
          notes: string | null
          purchase_order_id: string | null
        }
        Insert: {
          amount_base?: never
          created_at?: string | null
          created_by?: string | null
          id?: string | null
          inbound_batch_id?: string | null
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id?: string | null
        }
        Update: {
          amount_base?: never
          created_at?: string | null
          created_by?: string | null
          id?: string | null
          inbound_batch_id?: string | null
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "prepayment_applications_journal_entry_id_fkey"
            columns: ["journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "prepayment_applications_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      price_history_masked: {
        Row: {
          created_at: string | null
          created_by: string | null
          currency: string | null
          fx_rate: number | null
          id: string | null
          inbound_batch_id: string | null
          new_unit_price: number | null
          notes: string | null
          old_unit_price: number | null
          original_price: number | null
          rate_as_of: string | null
          rate_type: string | null
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          fx_rate?: never
          id?: string | null
          inbound_batch_id?: string | null
          new_unit_price?: never
          notes?: string | null
          old_unit_price?: never
          original_price?: never
          rate_as_of?: string | null
          rate_type?: string | null
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          fx_rate?: never
          id?: string | null
          inbound_batch_id?: string | null
          new_unit_price?: never
          notes?: string | null
          old_unit_price?: never
          original_price?: never
          rate_as_of?: string | null
          rate_type?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "price_history_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
        ]
      }
      pricing_formula_history_masked: {
        Row: {
          change_type: string | null
          changed_at: string | null
          changed_by: string | null
          formula_id: string | null
          id: string | null
          metal: string | null
          new_average_days: number | null
          new_direction: string | null
          new_flat_discount_pct: number | null
          new_is_active: boolean | null
          new_name: string | null
          new_payable_pct: number | null
          new_price_basis: string | null
          new_treatment_charge_usd_per_tonne: number | null
          old_average_days: number | null
          old_direction: string | null
          old_flat_discount_pct: number | null
          old_is_active: boolean | null
          old_name: string | null
          old_payable_pct: number | null
          old_price_basis: string | null
          old_treatment_charge_usd_per_tonne: number | null
        }
        Insert: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          formula_id?: string | null
          id?: string | null
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: never
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: never
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: never
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: never
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: never
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: never
        }
        Update: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          formula_id?: string | null
          id?: string | null
          metal?: string | null
          new_average_days?: number | null
          new_direction?: string | null
          new_flat_discount_pct?: never
          new_is_active?: boolean | null
          new_name?: string | null
          new_payable_pct?: never
          new_price_basis?: string | null
          new_treatment_charge_usd_per_tonne?: never
          old_average_days?: number | null
          old_direction?: string | null
          old_flat_discount_pct?: never
          old_is_active?: boolean | null
          old_name?: string | null
          old_payable_pct?: never
          old_price_basis?: string | null
          old_treatment_charge_usd_per_tonne?: never
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_history_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_formula_metals_masked: {
        Row: {
          created_at: string | null
          created_by: string | null
          formula_id: string | null
          metal: string | null
          payable_pct: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          formula_id?: string | null
          metal?: string | null
          payable_pct?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          formula_id?: string | null
          metal?: string | null
          payable_pct?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formula_metals_formula_id_fkey"
            columns: ["formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_formulas_masked: {
        Row: {
          average_days: number | null
          code: string | null
          created_at: string | null
          created_by: string | null
          customer_id: string | null
          deleted_at: string | null
          direction: string | null
          flat_discount_pct: number | null
          id: string | null
          is_active: boolean | null
          name: string | null
          notes: string | null
          price_basis: string | null
          price_index: string | null
          supplier_id: string | null
          treatment_charge_usd_per_tonne: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          average_days?: number | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string | null
          flat_discount_pct?: never
          id?: string | null
          is_active?: boolean | null
          name?: string | null
          notes?: string | null
          price_basis?: string | null
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          average_days?: number | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          customer_id?: string | null
          deleted_at?: string | null
          direction?: string | null
          flat_discount_pct?: never
          id?: string | null
          is_active?: boolean | null
          name?: string | null
          notes?: string | null
          price_basis?: string | null
          price_index?: string | null
          supplier_id?: string | null
          treatment_charge_usd_per_tonne?: never
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "pricing_formulas_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_formulas_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_formulas_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_term_commitment_metals_masked: {
        Row: {
          commitment_id: string | null
          metal: string | null
          payable_pct: number | null
        }
        Insert: {
          commitment_id?: string | null
          metal?: string | null
          payable_pct?: never
        }
        Update: {
          commitment_id?: string | null
          metal?: string | null
          payable_pct?: never
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitment_metals_commitment_id_fkey"
            columns: ["commitment_id"]
            isOneToOne: false
            referencedRelation: "pricing_term_commitments_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      pricing_term_commitments_masked: {
        Row: {
          average_days: number | null
          committed_at: string | null
          committed_by: string | null
          flat_discount_pct: number | null
          id: string | null
          inbound_batch_id: string | null
          price_basis: string | null
          price_index: string | null
          purchase_order_line_id: string | null
          source_formula_code: string | null
          source_formula_id: string | null
          source_formula_name: string | null
          treatment_charge_usd_per_tonne: number | null
        }
        Insert: {
          average_days?: number | null
          committed_at?: string | null
          committed_by?: string | null
          flat_discount_pct?: never
          id?: string | null
          inbound_batch_id?: string | null
          price_basis?: string | null
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code?: string | null
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne?: never
        }
        Update: {
          average_days?: number | null
          committed_at?: string | null
          committed_by?: string | null
          flat_discount_pct?: never
          id?: string | null
          inbound_batch_id?: string | null
          price_basis?: string | null
          price_index?: string | null
          purchase_order_line_id?: string | null
          source_formula_code?: string | null
          source_formula_id?: string | null
          source_formula_name?: string | null
          treatment_charge_usd_per_tonne?: never
        }
        Relationships: [
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: true
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_price_index_fkey"
            columns: ["price_index"]
            isOneToOne: false
            referencedRelation: "metal_price_indices"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["line_id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "pricing_term_commitments_purchase_order_line_id_fkey"
            columns: ["purchase_order_line_id"]
            isOneToOne: true
            referencedRelation: "purchase_order_lines_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entries_masked: {
        Row: {
          amount_base: number | null
          cost_type: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          is_estimate: boolean | null
          notes: string | null
          relief_expense_id: string | null
          relieved_at: string | null
          remitted_at: string | null
          remitted_journal_entry_id: string | null
          run_id: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          amount_base?: never
          cost_type?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          is_estimate?: boolean | null
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          amount_base?: never
          cost_type?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          is_estimate?: boolean | null
          notes?: string | null
          relief_expense_id?: string | null
          relieved_at?: string | null
          remitted_at?: string | null
          remitted_journal_entry_id?: string | null
          run_id?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entries_relief_expense_id_fkey"
            columns: ["relief_expense_id"]
            isOneToOne: false
            referencedRelation: "expenses"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_remitted_journal_entry_id_fkey"
            columns: ["remitted_journal_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_entry_history_masked: {
        Row: {
          change_type: string | null
          changed_at: string | null
          changed_by: string | null
          entry_id: string | null
          id: string | null
          new_amount_base: number | null
          new_cost_type: string | null
          new_is_estimate: boolean | null
          old_amount_base: number | null
          old_cost_type: string | null
          old_is_estimate: boolean | null
          run_id: string | null
        }
        Insert: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          entry_id?: string | null
          id?: string | null
          new_amount_base?: never
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: never
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id?: string | null
        }
        Update: {
          change_type?: string | null
          changed_at?: string | null
          changed_by?: string | null
          entry_id?: string | null
          id?: string | null
          new_amount_base?: never
          new_cost_type?: string | null
          new_is_estimate?: boolean | null
          old_amount_base?: never
          old_cost_type?: string | null
          old_is_estimate?: boolean | null
          run_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_entry_id_fkey"
            columns: ["entry_id"]
            isOneToOne: false
            referencedRelation: "processing_cost_entries_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_cost_entry_history_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_cost_variance: {
        Row: {
          actual_total: number | null
          cost_type: string | null
          direction: string | null
          estimated_total: number | null
          month: string | null
          variance: number | null
        }
        Relationships: []
      }
      processing_metal_recovery: {
        Row: {
          conservation_warning: boolean | null
          input_measured: boolean | null
          input_metal_kg: number | null
          input_source: string | null
          metal: string | null
          output_measured: boolean | null
          output_metal_kg: number | null
          output_source: string | null
          process_date: string | null
          recovery_blocked_by: string | null
          recovery_pct: number | null
          run_code: string | null
          run_id: string | null
          run_recovery_computable: boolean | null
        }
        Relationships: []
      }
      processing_metal_recovery_all: {
        Row: {
          conservation_warning: boolean | null
          input_measured: boolean | null
          input_metal_kg: number | null
          input_source: string | null
          metal: string | null
          output_measured: boolean | null
          output_metal_kg: number | null
          output_source: string | null
          process_date: string | null
          recovery_blocked_by: string | null
          recovery_pct: number | null
          run_code: string | null
          run_id: string | null
          run_recovery_computable: boolean | null
        }
        Relationships: []
      }
      processing_outputs_masked: {
        Row: {
          allocated_cost_base: number | null
          cost_incomplete: boolean | null
          created_at: string | null
          id: string | null
          output_batch_id: string | null
          quantity_produced: number | null
          run_id: string | null
          unit_cost_base: number | null
        }
        Insert: {
          allocated_cost_base?: never
          cost_incomplete?: boolean | null
          created_at?: string | null
          id?: string | null
          output_batch_id?: string | null
          quantity_produced?: number | null
          run_id?: string | null
          unit_cost_base?: never
        }
        Update: {
          allocated_cost_base?: never
          cost_incomplete?: boolean | null
          created_at?: string | null
          id?: string | null
          output_batch_id?: string | null
          quantity_produced?: number | null
          run_id?: string | null
          unit_cost_base?: never
        }
        Relationships: [
          {
            foreignKeyName: "processing_outputs_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
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
            referencedRelation: "batch_margin"
            referencedColumns: ["run_id"]
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
            referencedRelation: "processing_metal_recovery_all"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_run_allocation_status"
            referencedColumns: ["run_id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_run_allocation_status: {
        Row: {
          allocated_at: string | null
          code: string | null
          cogs_posted: number | null
          is_stale: boolean | null
          last_cost_change: string | null
          run_id: string | null
          safe_to_reallocate: boolean | null
        }
        Relationships: []
      }
      processing_runs_masked: {
        Row: {
          allocated_at: string | null
          allocated_by: string | null
          allocation_basis: string | null
          allocation_basis_changed_at: string | null
          allocation_snapshot: Json | null
          capitalization_entry_id: string | null
          capitalized_cost_base: number | null
          code: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          loss_qty: number | null
          material_cost_base: number | null
          notes: string | null
          process_cost_base: number | null
          process_date: string | null
          status: string | null
          total_cost_base: number | null
          total_input: number | null
          total_output: number | null
          updated_at: string | null
          updated_by: string | null
          work_order_id: string | null
        }
        Insert: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string | null
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: never
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          loss_qty?: number | null
          material_cost_base?: never
          notes?: string | null
          process_cost_base?: never
          process_date?: string | null
          status?: string | null
          total_cost_base?: never
          total_input?: number | null
          total_output?: number | null
          updated_at?: string | null
          updated_by?: string | null
          work_order_id?: string | null
        }
        Update: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string | null
          allocation_basis_changed_at?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_base?: never
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          loss_qty?: number | null
          material_cost_base?: never
          notes?: string | null
          process_cost_base?: never
          process_date?: string | null
          status?: string | null
          total_cost_base?: never
          total_input?: number | null
          total_output?: number | null
          updated_at?: string | null
          updated_by?: string | null
          work_order_id?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
          {
            foreignKeyName: "processing_runs_capitalization_entry_id_fkey"
            columns: ["capitalization_entry_id"]
            isOneToOne: false
            referencedRelation: "journal_entries"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "processing_runs_work_order_id_fkey"
            columns: ["work_order_id"]
            isOneToOne: false
            referencedRelation: "work_orders"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_lines_masked: {
        Row: {
          created_at: string | null
          created_by: string | null
          estimated_amount_ccy: number | null
          estimated_unit_price: number | null
          expected_assay: Json | null
          id: string | null
          line_no: number | null
          material_id: string | null
          notes: string | null
          price_provenance: Json | null
          price_source: string | null
          pricing_formula_id: string | null
          purchase_order_id: string | null
          quantity: number | null
          unit: string | null
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          estimated_amount_ccy?: never
          estimated_unit_price?: never
          expected_assay?: Json | null
          id?: string | null
          line_no?: number | null
          material_id?: string | null
          notes?: string | null
          price_provenance?: never
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id?: string | null
          quantity?: number | null
          unit?: string | null
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          estimated_amount_ccy?: never
          estimated_unit_price?: never
          expected_assay?: Json | null
          id?: string | null
          line_no?: number | null
          material_id?: string | null
          notes?: string | null
          price_provenance?: never
          price_source?: string | null
          pricing_formula_id?: string | null
          purchase_order_id?: string | null
          quantity?: number | null
          unit?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "material_stock_available"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "materials"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_material_id_fkey"
            columns: ["material_id"]
            isOneToOne: false
            referencedRelation: "stock_snapshot"
            referencedColumns: ["material_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_pricing_formula_id_fkey"
            columns: ["pricing_formula_id"]
            isOneToOne: false
            referencedRelation: "pricing_formulas_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_lines_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_payment_terms_masked: {
        Row: {
          created_at: string | null
          due_date: string | null
          fixed_amount_ccy: number | null
          id: string | null
          label: string | null
          notes: string | null
          percentage: number | null
          purchase_order_id: string | null
          seq: number | null
          trigger_event: string | null
        }
        Insert: {
          created_at?: string | null
          due_date?: string | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          purchase_order_id?: string | null
          seq?: number | null
          trigger_event?: string | null
        }
        Update: {
          created_at?: string | null
          due_date?: string | null
          fixed_amount_ccy?: never
          id?: string | null
          label?: string | null
          notes?: string | null
          percentage?: number | null
          purchase_order_id?: string | null
          seq?: number | null
          trigger_event?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["purchase_order_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "po_receivable_lines"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_order_status"
            referencedColumns: ["po_id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "purchase_order_payment_terms_purchase_order_id_fkey"
            columns: ["purchase_order_id"]
            isOneToOne: false
            referencedRelation: "purchase_orders_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_order_status: {
        Row: {
          code: string | null
          currency: string | null
          estimated_total_ccy: number | null
          expected_delivery_date: string | null
          order_date: string | null
          ordered_qty: number | null
          po_id: string | null
          prepaid_applied_base: number | null
          prepaid_base: number | null
          prepaid_remaining_base: number | null
          receipt_pct: number | null
          received_batches: number | null
          received_qty: number | null
          status: string | null
          supplier_id: string | null
          supplier_name: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      purchase_orders_masked: {
        Row: {
          approval_status: string | null
          approved_at: string | null
          approved_by: string | null
          cancel_reason: string | null
          cancelled_at: string | null
          closed_at: string | null
          code: string | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          deleted_at: string | null
          estimated_total_ccy: number | null
          expected_delivery_date: string | null
          fx_rate: number | null
          id: string | null
          incoterm: string | null
          notes: string | null
          order_date: string | null
          status: string | null
          supplier_id: string | null
          terms_text: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          approval_status?: string | null
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          estimated_total_ccy?: never
          expected_delivery_date?: string | null
          fx_rate?: never
          id?: string | null
          incoterm?: string | null
          notes?: string | null
          order_date?: string | null
          status?: string | null
          supplier_id?: string | null
          terms_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          approval_status?: string | null
          approved_at?: string | null
          approved_by?: string | null
          cancel_reason?: string | null
          cancelled_at?: string | null
          closed_at?: string | null
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          deleted_at?: string | null
          estimated_total_ccy?: never
          expected_delivery_date?: string | null
          fx_rate?: never
          id?: string | null
          incoterm?: string | null
          notes?: string | null
          order_date?: string | null
          status?: string | null
          supplier_id?: string | null
          terms_text?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Relationships: [
          {
            foreignKeyName: "purchase_orders_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "purchase_orders_supplier_id_fkey"
            columns: ["supplier_id"]
            isOneToOne: false
            referencedRelation: "suppliers"
            referencedColumns: ["id"]
          },
        ]
      }
      quote_status: {
        Row: {
          amended_since_issue: boolean | null
          code: string | null
          converted_order_code: string | null
          converted_order_id: string | null
          convertible: boolean | null
          currency: string | null
          customer_code: string | null
          customer_id: string | null
          customer_name: string | null
          decline_reason: string | null
          expired: boolean | null
          fx_rate: number | null
          issue_version: number | null
          notes: string | null
          quote_date: string | null
          quote_id: string | null
          status: string | null
          terms_text: string | null
          updated_at: string | null
          valid_until: string | null
        }
        Relationships: [
          {
            foreignKeyName: "quotes_converted_order_id_fkey"
            columns: ["converted_order_id"]
            isOneToOne: false
            referencedRelation: "sales_orders"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "quotes_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "quotes_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_records_masked: {
        Row: {
          amount_base: number | null
          cogs_entry_id: string | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          customer_id: string | null
          fx_rate: number | null
          id: string | null
          notes: string | null
          output_batch_id: string | null
          price_provenance: Json | null
          price_source: string | null
          quantity: number | null
          sale_date: string | null
          sales_order_line_id: string | null
          unit_price: number | null
        }
        Insert: {
          amount_base?: never
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          fx_rate?: never
          id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          price_provenance?: never
          price_source?: string | null
          quantity?: number | null
          sale_date?: string | null
          sales_order_line_id?: string | null
          unit_price?: never
        }
        Update: {
          amount_base?: never
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          fx_rate?: never
          id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          price_provenance?: never
          price_source?: string | null
          quantity?: number | null
          sale_date?: string | null
          sales_order_line_id?: string | null
          unit_price?: never
        }
        Relationships: [
          {
            foreignKeyName: "sales_records_cogs_entry_id_fkey"
            columns: ["cogs_entry_id"]
            isOneToOne: false
            referencedRelation: "bank_unmatched_journal_lines"
            referencedColumns: ["entry_id"]
          },
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
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_sales_order_line_id_fkey"
            columns: ["sales_order_line_id"]
            isOneToOne: false
            referencedRelation: "sales_order_lines"
            referencedColumns: ["id"]
          },
        ]
      }
      sales_records_visible: {
        Row: {
          amount_base: number | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          customer_id: string | null
          customer_name: string | null
          fx_rate: number | null
          id: string | null
          notes: string | null
          output_batch_code: string | null
          output_batch_id: string | null
          quantity: number | null
          sale_date: string | null
          unit_price: number | null
        }
        Relationships: [
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
            referencedRelation: "customer_credit_status"
            referencedColumns: ["customer_id"]
          },
          {
            foreignKeyName: "sales_records_customer_id_fkey"
            columns: ["customer_id"]
            isOneToOne: false
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "sales_records_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
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
      stock_by_status: {
        Row: {
          batch_code: string | null
          inbound_batch_id: string | null
          location_code: string | null
          location_id: string | null
          location_name: string | null
          output_batch_id: string | null
          qty: number | null
          stock_status: string | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_assay_status"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "batch_required_assay_gaps"
            referencedColumns: ["inbound_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "inbound_batches_masked"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "inventory_movements_inbound_batch_id_fkey"
            columns: ["inbound_batch_id"]
            isOneToOne: false
            referencedRelation: "po_prepayment_applicable"
            referencedColumns: ["inbound_batch_id"]
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
            referencedRelation: "batch_margin"
            referencedColumns: ["output_batch_id"]
          },
          {
            foreignKeyName: "inventory_movements_output_batch_id_fkey"
            columns: ["output_batch_id"]
            isOneToOne: false
            referencedRelation: "output_batches"
            referencedColumns: ["id"]
          },
        ]
      }
      stock_class_violations: {
        Row: {
          class_code: string | null
          location_code: string | null
          location_id: string | null
          material_code: string | null
          material_id: string | null
          qty: number | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "materials_waste_classification_code_fkey"
            columns: ["class_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
        ]
      }
      stock_class_violations_all: {
        Row: {
          class_code: string | null
          location_code: string | null
          location_id: string | null
          material_code: string | null
          material_id: string | null
          qty: number | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
          {
            foreignKeyName: "materials_waste_classification_code_fkey"
            columns: ["class_code"]
            isOneToOne: false
            referencedRelation: "waste_classifications"
            referencedColumns: ["code"]
          },
        ]
      }
      stock_snapshot: {
        Row: {
          location_code: string | null
          location_id: string | null
          location_name: string | null
          material_code: string | null
          material_id: string | null
          material_name: string | null
          qty: number | null
          stock_status: string | null
          unit: string | null
        }
        Relationships: [
          {
            foreignKeyName: "inventory_movements_location_id_fkey"
            columns: ["location_id"]
            isOneToOne: false
            referencedRelation: "storage_locations"
            referencedColumns: ["id"]
          },
        ]
      }
      supplier_receiving_blocked: {
        Row: {
          cert_type_code: string | null
          name_en: string | null
          name_zh: string | null
          supplier_code: string | null
          supplier_id: string | null
          valid_until: string | null
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
      user_directory: {
        Row: {
          created_at: string | null
          email: string | null
          employee_code: string | null
          employee_id: string | null
          employee_name: string | null
          last_sign_in_at: string | null
          roles: Json | null
          user_id: string | null
        }
        Relationships: []
      }
      work_order_fulfilment: {
        Row: {
          actual_qty: number | null
          has_plan: boolean | null
          material_code: string | null
          material_id: string | null
          material_name: string | null
          planned_or_expected_qty: number | null
          scheduled_date: string | null
          side: string | null
          status: string | null
          variance_qty: number | null
          work_order_code: string | null
          work_order_id: string | null
        }
        Relationships: []
      }
    }
    Functions: {
      account_ledger: {
        Args: {
          p_account_code: string
          p_from: string
          p_include_year_close: boolean
          p_to: string
        }
        Returns: Json
      }
      accrued_annual_leave: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: number
      }
      accrued_annual_leave_detail: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: Json
      }
      acknowledge_review: { Args: { p_review_id: string }; Returns: Json }
      add_review_goal: {
        Args: {
          p_objective_text: string
          p_review_id: string
          p_target_value?: number
          p_unit?: string
        }
        Returns: Json
      }
      allocate_processing_costs: {
        Args: { p_basis?: string; p_run_id: string }
        Returns: Json
      }
      amend_purchase_order: {
        Args: {
          p_header?: Json
          p_lines?: Json
          p_purchase_order_id: string
          p_reason: string
        }
        Returns: Json
      }
      amend_sales_order: {
        Args: {
          p_header?: Json
          p_lines?: Json
          p_order_id: string
          p_reason: string
        }
        Returns: Json
      }
      amend_work_order: {
        Args: {
          p_expected?: Json
          p_lines?: Json
          p_notes?: string
          p_reason: string
          p_scheduled_date?: string
          p_set_notes?: boolean
          p_set_scheduled?: boolean
          p_work_order_id: string
        }
        Returns: Json
      }
      annual_leave_available_from: {
        Args: { p_days: number; p_employee_id: string; p_from?: string }
        Returns: string
      }
      annual_leave_rate_per_year: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: number
      }
      apply_assay_result: {
        Args: {
          p_assay_result_id: string
          p_pricing_formula_id?: string
          p_reference_date?: string
        }
        Returns: Json
      }
      apply_output_assay: { Args: { p_assay_result_id: string }; Returns: Json }
      apply_payment_term_template: {
        Args: { p_purchase_order_id: string; p_template_id: string }
        Returns: Json
      }
      apply_prepayment: {
        Args: {
          p_amount: number
          p_inbound_batch_id: string
          p_notes?: string
          p_purchase_order_id: string
        }
        Returns: Json
      }
      approval_level_for: { Args: { p_amount_base: number }; Returns: number }
      approvals_enabled: { Args: never; Returns: boolean }
      approve_purchase_order: {
        Args: { p_note?: string; p_po_id: string }
        Returns: Json
      }
      approve_review: { Args: { p_review_id: string }; Returns: Json }
      arm_permission_any: { Args: { p_item_type: string }; Returns: string[] }
      assert_posting_allowed: {
        Args: { p_entry_date: string; p_source_type: string }
        Returns: undefined
      }
      attribute_sale_customer: {
        Args: {
          p_customer_id: string
          p_note?: string
          p_sales_record_id: string
        }
        Returns: Json
      }
      available_annual_accrual: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: number
      }
      balance_sheet: { Args: { p_as_of: string }; Returns: Json }
      bank_account_for_currency: {
        Args: { p_currency: string }
        Returns: string
      }
      bank_native_currency: {
        Args: { p_account_code: string }
        Returns: string
      }
      base_currency_code: { Args: never; Returns: string }
      batch_freight_base: {
        Args: { p_inbound_batch_id: string }
        Returns: number
      }
      calculate_leave_days: {
        Args: {
          p_end: string
          p_end_half?: boolean
          p_start: string
          p_start_half?: boolean
        }
        Returns: number
      }
      calculate_metal_price: {
        Args: {
          p_formula_id: string
          p_metals: Json
          p_quantity_kg: number
          p_reference_date?: string
        }
        Returns: Json
      }
      calculate_metal_price_from_terms: {
        Args: {
          p_metals: Json
          p_quantity_kg: number
          p_reference_date: string
          p_terms: Json
        }
        Returns: Json
      }
      calculate_metal_price_internal: {
        Args: {
          p_formula_id: string
          p_metals: Json
          p_quantity_kg: number
          p_reference_date?: string
        }
        Returns: Json
      }
      cancel_leave_request: {
        Args: { p_reason?: string; p_request_id: string }
        Returns: Json
      }
      cancel_purchase_order: {
        Args: { p_id: string; p_reason?: string }
        Returns: Json
      }
      cancel_stocktake: { Args: { p_stocktake_id: string }; Returns: undefined }
      cancel_work_order: {
        Args: { p_reason: string; p_work_order_id: string }
        Returns: Json
      }
      carry_forward_annual_leave: {
        Args: { p_leave_year: number }
        Returns: Json
      }
      cash_flow_statement: {
        Args: { p_from: string; p_to: string }
        Returns: Json
      }
      check_location_class: {
        Args: { p_location_id: string; p_material_id: string }
        Returns: string[]
      }
      close_financial_year: {
        Args: { p_notes?: string; p_year_end: string }
        Returns: Json
      }
      close_period: {
        Args: { p_notes?: string; p_period_end: string }
        Returns: Json
      }
      close_purchase_order: {
        Args: { p_notes?: string; p_purchase_order_id: string }
        Returns: Json
      }
      close_work_order: {
        Args: { p_reason: string; p_work_order_id: string }
        Returns: Json
      }
      commit_pricing_terms: {
        Args: {
          p_formula_id: string
          p_inbound_batch_id?: string
          p_purchase_order_line_id?: string
        }
        Returns: string
      }
      commit_processing_run: {
        Args: {
          p_allocation_basis: string
          p_inputs: Json
          p_loss_qty: number
          p_notes: string
          p_outputs: Json
          p_process_date: string
          p_work_order_id?: string
        }
        Returns: string
      }
      committed_terms_price: {
        Args: { p_inbound_batch_id: string; p_reference_date: string }
        Returns: Json
      }
      compute_leave_encashment: {
        Args: { p_as_of?: string; p_employee_id: string }
        Returns: Json
      }
      consumed_from_accrual: {
        Args: { p_employee_id: string; p_leave_year: number }
        Returns: number
      }
      convert_quote: {
        Args: { p_order_date: string; p_quote_id: string }
        Returns: Json
      }
      create_credit_note: {
        Args: {
          p_invoice_id: string
          p_lines: Json
          p_note_date: string
          p_reason: string
        }
        Returns: Json
      }
      create_inbound_batch: {
        Args: {
          p_arrival_date?: string
          p_location_id?: string
          p_material_id: string
          p_notes?: string
          p_purchase_order_id?: string
          p_purchase_order_line_id?: string
          p_quantity: number
          p_stage?: string
          p_supplier_id: string
          p_unit?: string
          p_unit_price?: number
        }
        Returns: Json
      }
      create_invoice: {
        Args: {
          p_customer_id: string
          p_issue_date?: string
          p_notes?: string
          p_payment_terms_days?: number
          p_sales_record_ids: string[]
          p_terms_text?: string
        }
        Returns: Json
      }
      create_order_invoice: {
        Args: {
          p_issue_date: string
          p_line_ids?: string[]
          p_notes?: string
          p_payment_terms_days?: number
          p_sales_order_id: string
          p_terms_text?: string
        }
        Returns: Json
      }
      create_output_batch: {
        Args: {
          p_customer_id?: string
          p_location_id?: string
          p_material_id: string
          p_notes?: string
          p_output_date?: string
          p_purity?: string
          p_quantity: number
          p_state?: string
          p_unit?: string
        }
        Returns: Json
      }
      create_purchase_order: {
        Args: {
          p_currency: string
          p_expected_delivery: string
          p_fx_rate: number
          p_incoterm: string
          p_lines: Json
          p_notes: string
          p_order_date: string
          p_payment_terms?: Json
          p_supplier_id: string
          p_terms_text: string
        }
        Returns: Json
      }
      create_sales_order: {
        Args: {
          p_currency: string
          p_customer_id: string
          p_fx_rate: number
          p_lines: Json
          p_notes?: string
          p_order_date: string
          p_terms_text?: string
        }
        Returns: Json
      }
      create_stock_transfer: {
        Args: {
          p_from_location_id?: string
          p_inbound_batch_id?: string
          p_note?: string
          p_output_batch_id?: string
          p_qty: number
          p_stock_status?: string
          p_to_location_id: string
        }
        Returns: Json
      }
      create_work_order: {
        Args: {
          p_expected?: Json
          p_lines: Json
          p_notes?: string
          p_scheduled_date?: string
        }
        Returns: Json
      }
      current_user_employee: { Args: never; Returns: string }
      current_user_permissions: { Args: never; Returns: string[] }
      customer_ar_exposure_base: {
        Args: { p_customer_id: string }
        Returns: number
      }
      customer_ar_exposure_visible: {
        Args: { p_customer_id: string }
        Returns: number
      }
      decide_leave_request: {
        Args: { p_approve: boolean; p_notes?: string; p_request_id: string }
        Returns: Json
      }
      decide_medical_claim: {
        Args: { p_approve: boolean; p_claim_id: string; p_notes?: string }
        Returns: Json
      }
      decline_quote: {
        Args: { p_quote_id: string; p_reason: string }
        Returns: Json
      }
      depreciate_fixed_assets: { Args: { p_period_end: string }; Returns: Json }
      derived_stock_qty: {
        Args: {
          p_inbound_batch_id: string
          p_location_id: string
          p_output_batch_id: string
          p_stock_status: string
        }
        Returns: number
      }
      dispose_fixed_asset: {
        Args: {
          p_asset_id: string
          p_bank_account?: string
          p_disposal_date: string
          p_notes?: string
          p_proceeds?: number
        }
        Returns: Json
      }
      drain_stock: {
        Args: {
          p_business_date: string
          p_created_by?: string
          p_inbound_batch_id?: string
          p_movement_type: string
          p_notes?: string
          p_output_batch_id?: string
          p_qty: number
          p_run_id?: string
          p_statuses?: string[]
        }
        Returns: string[]
      }
      employee_work_category_at: {
        Args: { p_employee_id: string; p_month: string }
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
      fx_rate_asof: {
        Args: { p_currency: string; p_date: string; p_rate_type: string }
        Returns: {
          as_of: string
          rate: number
        }[]
      }
      fx_rate_for: {
        Args: { p_currency: string; p_date: string; p_rate_type: string }
        Returns: number
      }
      has_any_permission: { Args: { p_codes: string[] }; Returns: boolean }
      has_permission: { Args: { p_code: string }; Returns: boolean }
      hold_stock: {
        Args: {
          p_inbound_batch_id?: string
          p_location_id?: string
          p_output_batch_id?: string
          p_qty: number
          p_reason: string
        }
        Returns: Json
      }
      ignore_bank_line: {
        Args: { p_reason: string; p_statement_line_id: string }
        Returns: undefined
      }
      import_bank_statement: {
        Args: {
          p_bank_account: string
          p_closing: number
          p_file_name: string
          p_lines: Json
          p_opening: number
          p_period_end: string
          p_period_start: string
        }
        Returns: Json
      }
      is_business_day: {
        Args: { p_country?: string; p_date: string }
        Returns: boolean
      }
      is_reviewer_of: {
        Args: { p_reviewer_employee_id: string }
        Returns: boolean
      }
      journal_activity_lines: {
        Args: { p_from: string; p_include_year_close: boolean; p_to: string }
        Returns: {
          account_code: string
          account_id: string
          account_name_en: string
          account_name_zh: string
          account_type: string
          credit: number
          debit: number
          entry_code: string
          entry_date: string
          entry_id: string
          entry_memo: string
          entry_status: string
          line_id: string
          line_memo: string
          signed_base: number
          source_id: string
          source_type: string
        }[]
      }
      leave_accrual_rate: {
        Args: {
          p_employee_id: string
          p_month: string
          p_work_category: string
        }
        Returns: Json
      }
      leave_balance: {
        Args: {
          p_as_of?: string
          p_employee_id: string
          p_leave_type_code?: string
        }
        Returns: Json
      }
      leave_balance_internal: {
        Args: {
          p_as_of?: string
          p_employee_id: string
          p_leave_type_code?: string
        }
        Returns: Json
      }
      line_spoken_for: {
        Args: { p_sales_order_line_id: string }
        Returns: number
      }
      match_bank_line: {
        Args: { p_journal_line_ids: string[]; p_statement_line_id: string }
        Returns: Json
      }
      medical_claim_balance: {
        Args: { p_employee_id: string; p_year: number }
        Returns: Json
      }
      metal_price_anomaly: {
        Args: {
          p_exclude_id?: string
          p_metal: string
          p_price: number
          p_price_date: string
          p_price_index?: string
        }
        Returns: Json
      }
      metal_quote_to_usd: {
        Args: {
          p_price: number
          p_quote_currency: string
          p_quote_date: string
        }
        Returns: {
          leg: Json
          usd: number
        }[]
      }
      mirror_consume_restore: {
        Args: {
          p_business_date: string
          p_created_by: string
          p_expected_total: number
          p_inbound_batch_id: string
          p_output_batch_id: string
          p_run_id: string
        }
        Returns: undefined
      }
      next_assay_code: { Args: { p_date?: string }; Returns: string }
      next_credit_note_code: { Args: { p_date?: string }; Returns: string }
      next_employee_code: { Args: { p_date?: string }; Returns: string }
      next_leave_request_code: { Args: { p_date?: string }; Returns: string }
      next_medical_claim_code: { Args: { p_date?: string }; Returns: string }
      next_payroll_code: { Args: { p_date?: string }; Returns: string }
      next_pricing_formula_code: { Args: { p_date?: string }; Returns: string }
      next_purchase_order_code: { Args: { p_date?: string }; Returns: string }
      next_quote_code: { Args: { p_date?: string }; Returns: string }
      next_sales_order_code: { Args: { p_date?: string }; Returns: string }
      next_shipment_code: { Args: { p_date: string }; Returns: string }
      next_traceability_report_code: {
        Args: { p_date?: string }
        Returns: string
      }
      next_work_order_code: { Args: { p_date?: string }; Returns: string }
      notify_class_violations: {
        Args: {
          p_cause: string
          p_location_ids: string[]
          p_material_ids: string[]
        }
        Returns: undefined
      }
      notify_landing_warnings: {
        Args: { p_location_id: string; p_material_id: string; p_warn: string[] }
        Returns: undefined
      }
      open_for_self_assessment: { Args: { p_review_id: string }; Returns: Json }
      open_review_cycle: { Args: { p_cycle_id: string }; Returns: Json }
      pay_medical_claim: {
        Args: {
          p_claim_id: string
          p_expense_date?: string
          p_fx_rate?: number
          p_supplier_id?: string
        }
        Returns: Json
      }
      pay_payroll_cpf: {
        Args: {
          p_bank_account?: string
          p_payment_date?: string
          p_payroll_period_id: string
        }
        Returns: Json
      }
      pay_payroll_deductions: {
        Args: {
          p_bank_account?: string
          p_payment_date?: string
          p_payroll_period_id: string
        }
        Returns: Json
      }
      pay_payroll_lines: {
        Args: {
          p_bank_account?: string
          p_line_ids: string[]
          p_payment_date?: string
          p_payroll_period_id: string
        }
        Returns: Json
      }
      pnl_statement: { Args: { p_from: string; p_to: string }; Returns: Json }
      po_document_data: { Args: { p_po_id: string }; Returns: Json }
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
      post_payroll_period: {
        Args: { p_payroll_period_id: string }
        Returns: Json
      }
      post_stocktake: { Args: { p_stocktake_id: string }; Returns: Json }
      preview_apply_output_assay: {
        Args: { p_assay_result_id?: string; p_output_batch_id: string }
        Returns: Json
      }
      preview_assay_price: {
        Args: {
          p_inbound_batch_id: string
          p_metals: Json
          p_reference_date: string
        }
        Returns: Json
      }
      preview_close_financial_year: {
        Args: { p_year_end?: string }
        Returns: Json
      }
      preview_depreciate_fixed_assets: {
        Args: { p_period_end: string }
        Returns: Json
      }
      preview_metal_price_anomalies: {
        Args: { p_price_date: string; p_price_index?: string; p_prices: Json }
        Returns: Json
      }
      preview_reprice_from_committed_terms: {
        Args: { p_inbound_batch_id: string; p_reference_date?: string }
        Returns: Json
      }
      preview_reprice_inbound_batch: {
        Args: {
          p_currency: string
          p_inbound_batch_id: string
          p_new_unit_price: number
        }
        Returns: Json
      }
      preview_revalue_foreign_balances: {
        Args: { p_period_end: string }
        Returns: Json
      }
      price_output_sale: {
        Args: {
          p_currency: string
          p_formula_id: string
          p_output_batch_id: string
          p_quantity: number
          p_reference_date: string
        }
        Returns: Json
      }
      pricing_terms_of_commitment: {
        Args: { p_commitment_id: string }
        Returns: Json
      }
      pricing_terms_of_formula: {
        Args: { p_formula_id: string }
        Returns: Json
      }
      quote_is_expired: { Args: { p_valid_until: string }; Returns: boolean }
      receive_inbound_batch_against_po: {
        Args: {
          p_arrival_date?: string
          p_location_id?: string
          p_material_id: string
          p_notes?: string
          p_purchase_order_id?: string
          p_purchase_order_line_id?: string
          p_quantity: number
          p_supplier_id: string
        }
        Returns: Json
      }
      reconcile_statement: { Args: { p_statement_id: string }; Returns: Json }
      record_approval_decision: {
        Args: {
          p_decision: string
          p_level?: number
          p_note?: string
          p_subject_id: string
          p_subject_type: string
        }
        Returns: string
      }
      record_assay_result: {
        Args: {
          p_assay_date: string
          p_certificate_ref?: string
          p_inbound_batch_id?: string
          p_is_final?: boolean
          p_lab_name?: string
          p_metals: Json
          p_notes?: string
          p_output_batch_id?: string
          p_sample_ref?: string
        }
        Returns: Json
      }
      record_bank_transfer: {
        Args: {
          p_amount_in: number
          p_amount_out: number
          p_bank_reference?: string
          p_from_account: string
          p_notes?: string
          p_to_account: string
          p_transfer_date: string
        }
        Returns: Json
      }
      record_cn_issue: {
        Args: {
          p_credit_note_id: string
          p_file_path: string
          p_sha256: string
        }
        Returns: Json
      }
      record_expense: {
        Args: {
          p_account_code: string
          p_amount: number
          p_asset?: Json
          p_bank_account?: string
          p_currency: string
          p_expense_date: string
          p_fx_rate?: number
          p_notes?: string
          p_payee_name?: string
          p_payment_status?: string
          p_supplier_id?: string
        }
        Returns: Json
      }
      record_freight_document: {
        Args: {
          p_allocation_basis: string
          p_allocations?: Json
          p_amount: number
          p_bank_account?: string
          p_currency: string
          p_doc_date: string
          p_gst_amount?: number
          p_notes?: string
          p_payment_status?: string
          p_supplier_id: string
        }
        Returns: Json
      }
      record_invoice_issue: {
        Args: { p_file_path: string; p_invoice_id: string; p_sha256: string }
        Returns: Json
      }
      record_output_sale: {
        Args: {
          p_currency: string
          p_customer_id?: string
          p_fx_rate?: number
          p_notes?: string
          p_output_batch_id: string
          p_price_provenance?: Json
          p_price_source?: string
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
      record_po_issue: {
        Args: { p_file_path: string; p_po_id: string; p_sha256: string }
        Returns: Json
      }
      record_qt_issue: {
        Args: { p_file_path: string; p_quote_id: string; p_sha256: string }
        Returns: Json
      }
      record_shipment_issue: {
        Args: { p_file_path: string; p_sha256: string; p_shipment_id: string }
        Returns: Json
      }
      record_so_issue: {
        Args: { p_file_path: string; p_order_id: string; p_sha256: string }
        Returns: Json
      }
      record_traceability_report_issue: {
        Args: {
          p_file_path: string
          p_output_batch_id: string
          p_sha256: string
        }
        Returns: Json
      }
      reject_purchase_order: {
        Args: { p_po_id: string; p_reason: string }
        Returns: Json
      }
      release_reservation: {
        Args: { p_qty?: number; p_reason?: string; p_reservation_id: string }
        Returns: Json
      }
      release_stock: {
        Args: {
          p_inbound_batch_id?: string
          p_location_id?: string
          p_note?: string
          p_output_batch_id?: string
          p_qty: number
        }
        Returns: Json
      }
      release_work_order: { Args: { p_work_order_id: string }; Returns: Json }
      relieve_processing_accruals: {
        Args: {
          p_actual_amount: number
          p_bank_account?: string
          p_entry_ids: string[]
          p_expense_date: string
          p_notes?: string
          p_payee_name?: string
          p_payment_status?: string
          p_supplier_id?: string
        }
        Returns: Json
      }
      remit_processing_costs: {
        Args: {
          p_bank_account?: string
          p_entry_ids: string[]
          p_payment_date?: string
        }
        Returns: Json
      }
      remove_review_goal: { Args: { p_goal_id: string }; Returns: Json }
      reopen_financial_year: {
        Args: { p_reason: string; p_year_end: string }
        Returns: Json
      }
      reopen_period: {
        Args: { p_period_end: string; p_reason: string }
        Returns: Json
      }
      reopen_purchase_order: {
        Args: { p_purchase_order_id: string; p_reason: string }
        Returns: Json
      }
      reprice_from_committed_terms: {
        Args: { p_inbound_batch_id: string; p_reference_date?: string }
        Returns: Json
      }
      reprice_inbound_batch: {
        Args: {
          p_currency?: string
          p_fx_rate?: number
          p_inbound_batch_id: string
          p_notes?: string
          p_unit_price: number
        }
        Returns: Json
      }
      reprice_split: {
        Args: {
          p_new_price: number
          p_old_price: number
          p_quantity: number
          p_remaining: number
        }
        Returns: Json
      }
      require_approver_for: { Args: { p_level: number }; Returns: undefined }
      require_permission: { Args: { p_code: string }; Returns: undefined }
      require_reviewer_of: {
        Args: { p_allowed_status: string[]; p_review_id: string }
        Returns: undefined
      }
      reserve_stock: {
        Args: {
          p_location_id?: string
          p_output_batch_id: string
          p_qty: number
          p_sales_order_line_id: string
        }
        Returns: Json
      }
      resolve_pricing_commitment: {
        Args: { p_inbound_batch_id: string }
        Returns: string
      }
      resolve_receipt_location: {
        Args: { p_location_id: string }
        Returns: string
      }
      revalue_foreign_balances: {
        Args: { p_period_end: string }
        Returns: Json
      }
      reverse_bank_transfer: {
        Args: {
          p_memo?: string
          p_reversal_date?: string
          p_transfer_id: string
        }
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
      reverse_journal_entry_internal: {
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
      sales_order_fulfilment_status: {
        Args: { p_sales_order_id: string }
        Returns: string
      }
      save_self_assessment: {
        Args: {
          p_final?: boolean
          p_goal_results?: Json
          p_review_id: string
          p_self_assessment_text: string
        }
        Returns: Json
      }
      set_asset_in_service: {
        Args: { p_asset_id: string; p_date: string }
        Returns: Json
      }
      set_goal_actual_value: {
        Args: { p_actual_value: number; p_goal_id: string }
        Returns: Json
      }
      set_goal_assessment: {
        Args: { p_goal_id: string; p_reviewer_assessment_text: string }
        Returns: Json
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
      set_material_required_metals: {
        Args: { p_material_id: string; p_metals: string[] }
        Returns: Json
      }
      set_review_conclusion: {
        Args: {
          p_rating_code: string
          p_review_id: string
          p_summary_text: string
        }
        Returns: Json
      }
      set_review_reviewer: {
        Args: { p_review_id: string; p_reviewer_employee_id: string }
        Returns: Json
      }
      set_role_permissions: {
        Args: { p_permission_codes: string[]; p_role_id: string }
        Returns: Json
      }
      set_sales_order_status: {
        Args: { p_order_id: string; p_reason?: string; p_to: string }
        Returns: Json
      }
      set_user_employee_link: {
        Args: { p_employee_id?: string; p_user_id: string }
        Returns: Json
      }
      set_user_roles: {
        Args: { p_reason?: string; p_role_ids: string[]; p_user_id: string }
        Returns: Json
      }
      ship_order: {
        Args: { p_lines: Json; p_sales_order_id: string; p_ship_date: string }
        Returns: Json
      }
      submit_leave_request: {
        Args: {
          p_certificate_ref?: string
          p_employee_id: string
          p_end: string
          p_end_half?: boolean
          p_exception_days?: number
          p_exception_reason?: string
          p_is_exception?: boolean
          p_leave_type_code: string
          p_reason?: string
          p_start: string
          p_start_half?: boolean
        }
        Returns: Json
      }
      submit_medical_claim: {
        Args: {
          p_amount_sgd: number
          p_claim_date: string
          p_description?: string
          p_employee_id: string
          p_receipt_ref?: string
        }
        Returns: Json
      }
      submit_review: { Args: { p_review_id: string }; Returns: Json }
      traceability_report_data: {
        Args: { p_output_batch_id: string }
        Returns: Json
      }
      unapply_assay_result: {
        Args: { p_assay_result_id: string; p_reason: string }
        Returns: Json
      }
      unignore_bank_line: {
        Args: { p_statement_line_id: string }
        Returns: undefined
      }
      unmatch_bank_line: {
        Args: { p_statement_line_id: string }
        Returns: undefined
      }
      unpost_payroll_period: {
        Args: { p_id: string; p_reason: string }
        Returns: Json
      }
      unreconcile_statement: {
        Args: { p_reason: string; p_statement_id: string }
        Returns: undefined
      }
      update_review_goal: {
        Args: {
          p_goal_id: string
          p_objective_text: string
          p_target_value?: number
          p_unit?: string
        }
        Returns: Json
      }
      upsert_metal_prices: {
        Args: { p_price_date: string; p_price_index?: string; p_prices: Json }
        Returns: Json
      }
      upsert_payroll_period: {
        Args: {
          p_currency: string
          p_fx_rate: number
          p_lines: Json
          p_notes: string
          p_payment_date: string
          p_period_month: string
          p_source_note: string
        }
        Returns: Json
      }
      void_invoice: {
        Args: {
          p_invoice_id: string
          p_reason: string
          p_reversal_date?: string
        }
        Returns: Json
      }
      void_review: {
        Args: { p_reason: string; p_review_id: string }
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
