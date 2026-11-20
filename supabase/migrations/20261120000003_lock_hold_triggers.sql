-- =====================================================================
-- Lock the two new trigger functions (Nov 20)
-- Same rule as my other trigger functions: only the database runs them
-- (as triggers), nobody calls them directly.
-- =====================================================================

revoke execute on function public.start_payment_hold() from public, anon, authenticated;
revoke execute on function public.free_expired_holds() from public, anon, authenticated;
