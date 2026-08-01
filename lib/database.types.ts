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
          inbound_batch_id: string
          is_final: boolean
          lab_name: string | null
          notes: string | null
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
          inbound_batch_id: string
          is_final?: boolean
          lab_name?: string | null
          notes?: string | null
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
          inbound_batch_id?: string
          is_final?: boolean
          lab_name?: string | null
          notes?: string | null
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
          contact_person: string | null
          country: string
          created_at: string
          created_by: string | null
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
          name_en?: string
          name_zh?: string
          notes?: string | null
          parent_department_id?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: [
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
          annual_leave_days: number
          code: string
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
          notes: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
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
          annual_leave_days?: number
          code: string
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
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
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
          annual_leave_days?: number
          code?: string
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
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
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
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
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
          notes: string | null
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
          notes?: string | null
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
          notes?: string | null
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
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
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
          {
            foreignKeyName: "finance_attachments_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      finance_settings: {
        Row: {
          gst_rate_pct: number
          gst_registered: boolean
          gst_registration_no: string | null
          id: boolean
          locked_before: string | null
          updated_at: string
          updated_by: string | null
        }
        Insert: {
          gst_rate_pct?: number
          gst_registered?: boolean
          gst_registration_no?: string | null
          id?: boolean
          locked_before?: string | null
          updated_at?: string
          updated_by?: string | null
        }
        Update: {
          gst_rate_pct?: number
          gst_registered?: boolean
          gst_registration_no?: string | null
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
            referencedRelation: "batch_assay_status"
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
            referencedRelation: "materials"
            referencedColumns: ["id"]
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
            referencedRelation: "batch_assay_status"
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
          {
            foreignKeyName: "inventory_movements_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      invoice_lines: {
        Row: {
          amount_usd: number
          created_at: string | null
          description: string
          id: string
          invoice_id: string
          invoice_voided: boolean
          line_no: number
          quantity: number
          sales_record_id: string
          unit: string
          unit_price: number
        }
        Insert: {
          amount_usd: number
          created_at?: string | null
          description: string
          id?: string
          invoice_id: string
          invoice_voided?: boolean
          line_no: number
          quantity: number
          sales_record_id: string
          unit: string
          unit_price: number
        }
        Update: {
          amount_usd?: number
          created_at?: string | null
          description?: string
          id?: string
          invoice_id?: string
          invoice_voided?: boolean
          line_no?: number
          quantity?: number
          sales_record_id?: string
          unit?: string
          unit_price?: number
        }
        Relationships: [
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "ar_open_items"
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
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "ar_open_items"
            referencedColumns: ["sales_record_id"]
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
          id: string
          issue_date: string
          notes: string | null
          payment_terms_days: number
          status: string
          subtotal_usd: number
          tax_rate_pct: number
          tax_usd: number
          terms_text: string | null
          total_usd: number
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
          id?: string
          issue_date: string
          notes?: string | null
          payment_terms_days: number
          status?: string
          subtotal_usd: number
          tax_rate_pct?: number
          tax_usd?: number
          terms_text?: string | null
          total_usd: number
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
          id?: string
          issue_date?: string
          notes?: string | null
          payment_terms_days?: number
          status?: string
          subtotal_usd?: number
          tax_rate_pct?: number
          tax_usd?: number
          terms_text?: string | null
          total_usd?: number
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
            referencedRelation: "customers"
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
          purchase_order_id: string | null
          sales_record_id: string | null
        }
        Insert: {
          allocated_usd: number
          created_at?: string | null
          expense_id?: string | null
          id?: string
          inbound_batch_id?: string | null
          payment_id: string
          purchase_order_id?: string | null
          sales_record_id?: string | null
        }
        Update: {
          allocated_usd?: number
          created_at?: string | null
          expense_id?: string | null
          id?: string
          inbound_batch_id?: string | null
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
          {
            foreignKeyName: "payment_allocations_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "sales_records_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_term_template_lines: {
        Row: {
          created_at: string
          days_offset: number | null
          fixed_amount_usd: number | null
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
          fixed_amount_usd?: number | null
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
          fixed_amount_usd?: number | null
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
          deleted_at?: string | null
          description?: string | null
          id?: string
          is_active?: boolean
          name?: string
          updated_at?: string
          updated_by?: string | null
        }
        Relationships: []
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
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
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
          created_at: string
          created_by: string | null
          currency: string
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
          created_at?: string
          created_by?: string | null
          currency?: string
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
          created_at?: string
          created_by?: string | null
          currency?: string
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
            foreignKeyName: "payroll_periods_currency_fkey"
            columns: ["currency"]
            isOneToOne: false
            referencedRelation: "currencies"
            referencedColumns: ["code"]
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
      prepayment_applications: {
        Row: {
          amount_usd: number
          created_at: string
          created_by: string | null
          id: string
          inbound_batch_id: string
          journal_entry_id: string | null
          notes: string | null
          purchase_order_id: string
        }
        Insert: {
          amount_usd: number
          created_at?: string
          created_by?: string | null
          id?: string
          inbound_batch_id: string
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id: string
        }
        Update: {
          amount_usd?: number
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
            referencedRelation: "batch_assay_status"
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
            referencedRelation: "customers"
            referencedColumns: ["id"]
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
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
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
            referencedRelation: "batch_assay_status"
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
        ]
      }
      purchase_order_lines: {
        Row: {
          created_at: string
          created_by: string | null
          estimated_amount_usd: number
          estimated_unit_price: number | null
          expected_assay: Json | null
          id: string
          line_no: number
          material_id: string
          notes: string | null
          pricing_formula_id: string | null
          purchase_order_id: string
          quantity: number
          unit: string
        }
        Insert: {
          created_at?: string
          created_by?: string | null
          estimated_amount_usd?: number
          estimated_unit_price?: number | null
          expected_assay?: Json | null
          id?: string
          line_no: number
          material_id: string
          notes?: string | null
          pricing_formula_id?: string | null
          purchase_order_id: string
          quantity: number
          unit?: string
        }
        Update: {
          created_at?: string
          created_by?: string | null
          estimated_amount_usd?: number
          estimated_unit_price?: number | null
          expected_assay?: Json | null
          id?: string
          line_no?: number
          material_id?: string
          notes?: string | null
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
            referencedRelation: "materials"
            referencedColumns: ["id"]
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
          fixed_amount_usd: number | null
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
          fixed_amount_usd?: number | null
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
          fixed_amount_usd?: number | null
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
          estimated_total_usd: number
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
          estimated_total_usd?: number
          expected_delivery_date?: string | null
          fx_rate?: number
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
          estimated_total_usd?: number
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
            referencedRelation: "batch_assay_status"
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
            foreignKeyName: "supplier_compliance_created_by_fkey"
            columns: ["created_by"]
            isOneToOne: false
            referencedRelation: "user_directory"
            referencedColumns: ["user_id"]
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
          invoice_code: string | null
          invoice_id: string | null
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
      employee_directory: {
        Row: {
          annual_leave_days: number | null
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
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
      }
      employees_masked: {
        Row: {
          annual_leave_days: number | null
          code: string | null
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
          notes: string | null
          preferred_name: string | null
          probation_end_date: string | null
          residency_status: string | null
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
          annual_leave_days?: number | null
          code?: string | null
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
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
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
          annual_leave_days?: number | null
          code?: string | null
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
          notes?: string | null
          preferred_name?: string | null
          probation_end_date?: string | null
          residency_status?: string | null
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
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
          },
        ]
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
            referencedRelation: "materials"
            referencedColumns: ["id"]
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
      invoice_lines_masked: {
        Row: {
          amount_usd: number | null
          created_at: string | null
          description: string | null
          id: string | null
          invoice_id: string | null
          invoice_voided: boolean | null
          line_no: number | null
          quantity: number | null
          sales_record_id: string | null
          unit: string | null
          unit_price: number | null
        }
        Insert: {
          amount_usd?: never
          created_at?: string | null
          description?: string | null
          id?: string | null
          invoice_id?: string | null
          invoice_voided?: boolean | null
          line_no?: number | null
          quantity?: number | null
          sales_record_id?: string | null
          unit?: string | null
          unit_price?: never
        }
        Update: {
          amount_usd?: never
          created_at?: string | null
          description?: string | null
          id?: string | null
          invoice_id?: string | null
          invoice_voided?: boolean | null
          line_no?: number | null
          quantity?: number | null
          sales_record_id?: string | null
          unit?: string | null
          unit_price?: never
        }
        Relationships: [
          {
            foreignKeyName: "invoice_lines_invoice_id_fkey"
            columns: ["invoice_id"]
            isOneToOne: false
            referencedRelation: "ar_open_items"
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
            foreignKeyName: "invoice_lines_sales_record_id_fkey"
            columns: ["sales_record_id"]
            isOneToOne: false
            referencedRelation: "ar_open_items"
            referencedColumns: ["sales_record_id"]
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
        ]
      }
      invoice_status: {
        Row: {
          code: string | null
          currency: string | null
          customer_id: string | null
          customer_name: string | null
          days_overdue: number | null
          due_date: string | null
          invoice_id: string | null
          issue_date: string | null
          open_usd: number | null
          overdue: boolean | null
          payment_state: string | null
          settled_usd: number | null
          total_usd: number | null
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
          id: string | null
          issue_date: string | null
          notes: string | null
          payment_terms_days: number | null
          status: string | null
          subtotal_usd: number | null
          tax_rate_pct: number | null
          tax_usd: number | null
          terms_text: string | null
          total_usd: number | null
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
          id?: string | null
          issue_date?: string | null
          notes?: string | null
          payment_terms_days?: number | null
          status?: string | null
          subtotal_usd?: never
          tax_rate_pct?: number | null
          tax_usd?: never
          terms_text?: string | null
          total_usd?: never
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
          id?: string | null
          issue_date?: string | null
          notes?: string | null
          payment_terms_days?: number | null
          status?: string | null
          subtotal_usd?: never
          tax_rate_pct?: number | null
          tax_usd?: never
          terms_text?: string | null
          total_usd?: never
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
            referencedRelation: "customers"
            referencedColumns: ["id"]
          },
        ]
      }
      payment_term_template_lines_masked: {
        Row: {
          created_at: string | null
          days_offset: number | null
          fixed_amount_usd: number | null
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
          fixed_amount_usd?: never
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
          fixed_amount_usd?: never
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
            referencedRelation: "user_directory"
            referencedColumns: ["employee_id"]
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
      po_prepayment_applicable: {
        Row: {
          applicable_usd: number | null
          batch_ap_open_usd: number | null
          batch_code: string | null
          inbound_batch_id: string | null
          po_code: string | null
          po_unapplied_prepayment_usd: number | null
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
            referencedRelation: "materials"
            referencedColumns: ["id"]
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
          amount_usd: number | null
          created_at: string | null
          created_by: string | null
          id: string | null
          inbound_batch_id: string | null
          journal_entry_id: string | null
          notes: string | null
          purchase_order_id: string | null
        }
        Insert: {
          amount_usd?: never
          created_at?: string | null
          created_by?: string | null
          id?: string | null
          inbound_batch_id?: string | null
          journal_entry_id?: string | null
          notes?: string | null
          purchase_order_id?: string | null
        }
        Update: {
          amount_usd?: never
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
            referencedRelation: "customers"
            referencedColumns: ["id"]
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
      processing_cost_entries_masked: {
        Row: {
          amount_usd: number | null
          cost_type: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          is_estimate: boolean | null
          notes: string | null
          run_id: string | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          amount_usd?: never
          cost_type?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          is_estimate?: boolean | null
          notes?: string | null
          run_id?: string | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          amount_usd?: never
          cost_type?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          is_estimate?: boolean | null
          notes?: string | null
          run_id?: string | null
          updated_at?: string | null
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
          {
            foreignKeyName: "processing_cost_entries_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
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
      processing_outputs_masked: {
        Row: {
          allocated_cost_usd: number | null
          created_at: string | null
          id: string | null
          output_batch_id: string | null
          quantity_produced: number | null
          run_id: string | null
          unit_cost_usd: number | null
        }
        Insert: {
          allocated_cost_usd?: never
          created_at?: string | null
          id?: string | null
          output_batch_id?: string | null
          quantity_produced?: number | null
          run_id?: string | null
          unit_cost_usd?: never
        }
        Update: {
          allocated_cost_usd?: never
          created_at?: string | null
          id?: string | null
          output_batch_id?: string | null
          quantity_produced?: number | null
          run_id?: string | null
          unit_cost_usd?: never
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
          {
            foreignKeyName: "processing_outputs_run_id_fkey"
            columns: ["run_id"]
            isOneToOne: false
            referencedRelation: "processing_runs_masked"
            referencedColumns: ["id"]
          },
        ]
      }
      processing_runs_masked: {
        Row: {
          allocated_at: string | null
          allocated_by: string | null
          allocation_basis: string | null
          allocation_snapshot: Json | null
          capitalization_entry_id: string | null
          capitalized_cost_usd: number | null
          code: string | null
          created_at: string | null
          created_by: string | null
          deleted_at: string | null
          id: string | null
          loss_qty: number | null
          material_cost_usd: number | null
          notes: string | null
          process_cost_usd: number | null
          process_date: string | null
          status: string | null
          total_cost_usd: number | null
          total_input: number | null
          total_output: number | null
          updated_at: string | null
          updated_by: string | null
        }
        Insert: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_usd?: never
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          loss_qty?: number | null
          material_cost_usd?: never
          notes?: string | null
          process_cost_usd?: never
          process_date?: string | null
          status?: string | null
          total_cost_usd?: never
          total_input?: number | null
          total_output?: number | null
          updated_at?: string | null
          updated_by?: string | null
        }
        Update: {
          allocated_at?: string | null
          allocated_by?: string | null
          allocation_basis?: string | null
          allocation_snapshot?: Json | null
          capitalization_entry_id?: string | null
          capitalized_cost_usd?: never
          code?: string | null
          created_at?: string | null
          created_by?: string | null
          deleted_at?: string | null
          id?: string | null
          loss_qty?: number | null
          material_cost_usd?: never
          notes?: string | null
          process_cost_usd?: never
          process_date?: string | null
          status?: string | null
          total_cost_usd?: never
          total_input?: number | null
          total_output?: number | null
          updated_at?: string | null
          updated_by?: string | null
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
        ]
      }
      purchase_order_lines_masked: {
        Row: {
          created_at: string | null
          created_by: string | null
          estimated_amount_usd: number | null
          estimated_unit_price: number | null
          expected_assay: Json | null
          id: string | null
          line_no: number | null
          material_id: string | null
          notes: string | null
          pricing_formula_id: string | null
          purchase_order_id: string | null
          quantity: number | null
          unit: string | null
        }
        Insert: {
          created_at?: string | null
          created_by?: string | null
          estimated_amount_usd?: never
          estimated_unit_price?: never
          expected_assay?: Json | null
          id?: string | null
          line_no?: number | null
          material_id?: string | null
          notes?: string | null
          pricing_formula_id?: string | null
          purchase_order_id?: string | null
          quantity?: number | null
          unit?: string | null
        }
        Update: {
          created_at?: string | null
          created_by?: string | null
          estimated_amount_usd?: never
          estimated_unit_price?: never
          expected_assay?: Json | null
          id?: string | null
          line_no?: number | null
          material_id?: string | null
          notes?: string | null
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
            referencedRelation: "materials"
            referencedColumns: ["id"]
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
          fixed_amount_usd: number | null
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
          fixed_amount_usd?: never
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
          fixed_amount_usd?: never
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
          estimated_total_usd: number | null
          expected_delivery_date: string | null
          order_date: string | null
          ordered_qty: number | null
          po_id: string | null
          prepaid_applied_usd: number | null
          prepaid_remaining_usd: number | null
          prepaid_usd: number | null
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
          estimated_total_usd: number | null
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
          estimated_total_usd?: never
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
          estimated_total_usd?: never
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
      sales_records_masked: {
        Row: {
          amount_usd: number | null
          cogs_entry_id: string | null
          created_at: string | null
          created_by: string | null
          currency: string | null
          customer_id: string | null
          fx_rate: number | null
          id: string | null
          movement_id: string | null
          notes: string | null
          output_batch_id: string | null
          quantity: number | null
          sale_date: string | null
          unit_price: number | null
        }
        Insert: {
          amount_usd?: never
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          fx_rate?: never
          id?: string | null
          movement_id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          quantity?: number | null
          sale_date?: string | null
          unit_price?: never
        }
        Update: {
          amount_usd?: never
          cogs_entry_id?: string | null
          created_at?: string | null
          created_by?: string | null
          currency?: string | null
          customer_id?: string | null
          fx_rate?: never
          id?: string | null
          movement_id?: string | null
          notes?: string | null
          output_batch_id?: string | null
          quantity?: number | null
          sale_date?: string | null
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
    }
    Functions: {
      allocate_processing_costs: {
        Args: { p_basis?: string; p_run_id: string }
        Returns: Json
      }
      apply_assay_result: {
        Args: {
          p_assay_result_id: string
          p_pricing_formula_id?: string
          p_reference_date?: string
        }
        Returns: Json
      }
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
      bank_native_currency: {
        Args: { p_account_code: string }
        Returns: string
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
      calculate_metal_price_internal: {
        Args: {
          p_formula_id: string
          p_metals: Json
          p_quantity_kg: number
          p_reference_date?: string
        }
        Returns: Json
      }
      cancel_purchase_order: {
        Args: { p_id: string; p_reason?: string }
        Returns: Json
      }
      cancel_stocktake: { Args: { p_stocktake_id: string }; Returns: undefined }
      close_period: {
        Args: { p_notes?: string; p_period_end: string }
        Returns: Json
      }
      close_purchase_order: {
        Args: { p_notes?: string; p_purchase_order_id: string }
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
      current_user_employee: { Args: never; Returns: string }
      current_user_permissions: { Args: never; Returns: string[] }
      fin_cost_account: { Args: { p_cost_type: string }; Returns: string }
      fin_cost_lines: {
        Args: { p_amount: number; p_cost_type: string; p_reverse: boolean }
        Returns: Json
      }
      fin_next_payment_code: {
        Args: { p_date: string; p_prefix: string }
        Returns: string
      }
      has_permission: { Args: { p_code: string }; Returns: boolean }
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
      match_bank_line: {
        Args: { p_journal_line_ids: string[]; p_statement_line_id: string }
        Returns: Json
      }
      next_assay_code: { Args: { p_date?: string }; Returns: string }
      next_employee_code: { Args: { p_date?: string }; Returns: string }
      next_payroll_code: { Args: { p_date?: string }; Returns: string }
      next_pricing_formula_code: { Args: { p_date?: string }; Returns: string }
      next_purchase_order_code: { Args: { p_date?: string }; Returns: string }
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
      preview_reprice_inbound_batch: {
        Args: { p_inbound_batch_id: string; p_new_unit_price: number }
        Returns: Json
      }
      reconcile_statement: { Args: { p_statement_id: string }; Returns: Json }
      record_assay_result: {
        Args: {
          p_assay_date: string
          p_certificate_ref?: string
          p_inbound_batch_id: string
          p_is_final?: boolean
          p_lab_name?: string
          p_metals: Json
          p_notes?: string
          p_sample_ref?: string
        }
        Returns: Json
      }
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
      reopen_purchase_order: {
        Args: { p_purchase_order_id: string; p_reason: string }
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
      require_permission: { Args: { p_code: string }; Returns: undefined }
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
      set_role_permissions: {
        Args: { p_permission_codes: string[]; p_role_id: string }
        Returns: Json
      }
      set_user_roles: {
        Args: { p_reason?: string; p_role_ids: string[]; p_user_id: string }
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
      upsert_metal_prices: {
        Args: { p_price_date: string; p_prices: Json }
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
        Args: { p_invoice_id: string; p_reason: string }
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
