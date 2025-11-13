DO $$
BEGIN
  -- Create table if it doesn't exist
  IF NOT EXISTS (
    SELECT FROM pg_tables
    WHERE schemaname = 'public'
    AND tablename = 'olympic_sports'
  ) THEN
    CREATE TABLE public.olympic_sports (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      sport_name text NOT NULL,
      category text, -- e.g., Summer, Winter
      participants_count int,
      medal_events int,
      host_city text,
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now()
    );
  END IF;

  -- Create trigger function if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM pg_proc WHERE proname = 'update_olympic_sports_timestamp'
  ) THEN
    CREATE OR REPLACE FUNCTION public.update_olympic_sports_timestamp()
    RETURNS trigger AS $fn$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql;
  END IF;

  -- Create trigger if it doesn't exist
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'olympic_sports_update_timestamp'
  ) THEN
    CREATE TRIGGER olympic_sports_update_timestamp
    BEFORE UPDATE ON public.olympic_sports
    FOR EACH ROW
    EXECUTE FUNCTION public.update_olympic_sports_timestamp();
  END IF;
END $$;
