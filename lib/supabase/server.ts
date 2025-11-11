import { cookies } from 'next/headers';
import { createServerClient } from '@supabase/ssr';

/**
 * Creates a Supabase client for server usage in Next.js (App Router).
 * It persists auth via cookies so RLS policies work across server components and actions.
 */
export function createSupabaseServerClient() {
	const supabaseUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
	const supabaseAnonKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;

	if (!supabaseUrl || !supabaseAnonKey) {
		throw new Error(
			'Missing NEXT_PUBLIC_SUPABASE_URL or NEXT_PUBLIC_SUPABASE_ANON_KEY. Please set them in your environment.'
		);
	}

	const cookieStore = cookies();

	return createServerClient(supabaseUrl, supabaseAnonKey, {
		cookies: {
			get(name: string) {
				return cookieStore.get(name)?.value;
			},
			/**
			 * These can throw in environments where cookies are readonly (e.g., during
			 * certain render phases). We intentionally swallow errors to avoid crashing the request.
			 */
			set(name: string, value: string, options: Parameters<typeof cookieStore.set>[0]) {
				try {
					// next/headers cookies().set has multiple overloads; pass through object form
					cookieStore.set({ name, value, ...options });
				} catch {
					// noop
				}
			},
			remove(name: string, options: Parameters<typeof cookieStore.set>[0]) {
				try {
					cookieStore.set({ name, value: '', ...options });
				} catch {
					// noop
				}
			},
		},
	});
}


