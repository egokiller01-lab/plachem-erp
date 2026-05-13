-- Patch: Add missing Phase 4-C production costing columns required by confirm_production_document
-- Reason: Production confirm failed with: column "production_type" does not exist
-- Apply in Supabase SQL Editor after review/approval.

ALTER TABLE public.production_headers
ADD COLUMN IF NOT EXISTS production_type varchar(20) DEFAULT 'INTERNAL' CHECK (production_type IN ('INTERNAL', 'SUBCON')),
ADD COLUMN IF NOT EXISTS vendor_id bigint REFERENCES public.customers(id),
ADD COLUMN IF NOT EXISTS processing_fee numeric DEFAULT 0,
ADD COLUMN IF NOT EXISTS additional_cost numeric DEFAULT 0;

ALTER TABLE public.production_outputs
ADD COLUMN IF NOT EXISTS unit_cost numeric;

-- Normalize existing rows so RPC COALESCE/default behavior is predictable.
UPDATE public.production_headers
SET production_type = COALESCE(production_type, 'INTERNAL'),
    processing_fee = COALESCE(processing_fee, 0),
    additional_cost = COALESCE(additional_cost, 0)
WHERE production_type IS NULL
   OR processing_fee IS NULL
   OR additional_cost IS NULL;

-- Verification:
SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'production_headers'
  AND column_name IN ('production_type', 'vendor_id', 'processing_fee', 'additional_cost')
ORDER BY column_name;

SELECT column_name, data_type
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name = 'production_outputs'
  AND column_name = 'unit_cost';
