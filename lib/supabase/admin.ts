import { createClient } from '@supabase/supabase-js';

/**
 * Creates a Supabase "admin" client using the service role key.
 * Never import this into client/browser code. Use only in Route Handlers,
 * server actions, or background jobs where secrets are safe.
 */
export function createSupabaseAdminClient() {
	if (typeof window !== 'undefined') {
		throw new Error('createSupabaseAdminClient must only be used on the server.');
	}

	const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
	const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

	if (!supabaseUrl || !serviceRoleKey) {
		throw new Error(
			'Missing NEXT_PUBLIC_SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY. Please set them in your environment.'
		);
	}

	return createClient(supabaseUrl, serviceRoleKey, {
		auth: {
			persistSession: false,
			autoRefreshToken: false,
			detectSessionInUrl: false,
		},
	});
}


