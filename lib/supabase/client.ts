import { createBrowserClient } from '@supabase/ssr';

/**
 * Creates a Supabase client for browser usage.
 * Relies on public environment variables exposed by Next.js.
 */
export function createSupabaseBrowserClient() {
	const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
	const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

	if (!supabaseUrl || !supabaseAnonKey) {
		throw new Error(
			'Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY. Please set them in your environment.'
		);
	}

	return createBrowserClient(supabaseUrl, supabaseAnonKey);
}


