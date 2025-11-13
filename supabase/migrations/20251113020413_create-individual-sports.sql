DO $$
BEGIN
  -- Create table if it doesn't exist
  IF NOT EXISTS (
    SELECT FROM pg_tables
    WHERE schemaname = 'public'
    AND tablename = 'individual_sports'
  ) THEN
    CREATE TABLE public.individual_sports (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      athlete_name text NOT NULL,
      sport_name text NOT NULL,
      country text,
      score numeric,
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now()
    );
  END IF;

  -- Create trigger function if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'update_individual_sports_timestamp'
  ) THEN
    CREATE OR REPLACE FUNCTION public.update_individual_sports_timestamp()
    RETURNS trigger AS $fn$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql;
  END IF;

  -- Create trigger if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'individual_sports_update_timestamp'
  ) THEN
    CREATE TRIGGER individual_sports_update_timestamp
    BEFORE UPDATE ON public.individual_sports
    FOR EACH ROW
    EXECUTE FUNCTION public.update_individual_sports_timestamp();
  END IF;
END $$;
