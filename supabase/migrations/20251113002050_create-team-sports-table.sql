-- Create table only if it doesn't exist
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT FROM pg_tables
    WHERE schemaname = 'public'
    AND tablename = 'team_sports'
  ) THEN
    CREATE TABLE public.team_sports (
      id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
      name text NOT NULL,
      sport_type text,
      created_at timestamptz DEFAULT now(),
      updated_at timestamptz DEFAULT now()
    );
  END IF;
END $$;

-- Optional: add a trigger to update "updated_at" on modification
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_trigger WHERE tgname = 'team_sports_update_timestamp'
  ) THEN
    CREATE OR REPLACE FUNCTION public.update_team_sports_timestamp()
    RETURNS trigger AS $$
    BEGIN
      NEW.updated_at = now();
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql;

    CREATE TRIGGER team_sports_update_timestamp
    BEFORE UPDATE ON public.team_sports
    FOR EACH ROW
    EXECUTE FUNCTION public.update_team_sports_timestamp();
  END IF;
END $$;
