create extension if not exists btree_gist with schema extensions;

--
-- PostgreSQL database dump
--

\restrict srbsFvztoYYwkMvnob89wdSzNHsXyf2JycSFUYsqwbWjJFrlKo0LK3bDdW2yx5i

-- Dumped from database version 17.11
-- Dumped by pg_dump version 17.11

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA public;


--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: check_booking_availability(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.check_booking_availability() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
declare
  v_type          text;
  v_default_cap   integer;
  v_override_cap  integer;
  v_cap           integer;
  v_booked        integer;
begin
  -- 1. Skip: admin override, or booking doesn't take up space
  if new.capacity_override
     or new.attendance_status not in ('upcoming', 'done')
     or new.payment_status not in ('pending', 'down_payment', 'paid') then
    return new;
  end if;

  -- 2. Closed on any of the booked dates? (camping checks every night)
  if exists (
    select 1 from public.date_overrides o
    where o.activity_id = new.activity_id
      and o.is_closed
      and o.override_date >= new.visit_date
      and o.override_date <  new.visit_date + coalesce(new.nights, 1)
  ) then
    raise exception 'DATE_CLOSED: this activity is closed on one of the selected dates.';
  end if;

  -- 3. Look up the activity and LOCK it (one check at a time)
  select type, daily_capacity into v_type, v_default_cap
  from public.activities
  where id = new.activity_id
  for update;

  if v_type <> 'rock_activity' then
    return new;
  end if;

  -- 4. Today's cap: the override if there is one, otherwise the default
  select daily_capacity into v_override_cap
  from public.date_overrides
  where activity_id = new.activity_id and override_date = new.visit_date;

  v_cap := coalesce(v_override_cap, v_default_cap);
  if v_cap is null then
    return new;   -- no daily limit set
  end if;

  -- 5. Count everyone booked that day (finished groups still count toward the DAY)
  select coalesce(sum(group_size), 0) into v_booked
  from public.bookings
  where activity_id = new.activity_id
    and visit_date = new.visit_date
    and id <> new.id
    and attendance_status in ('upcoming', 'done')
    and (payment_status in ('down_payment', 'paid')
         or (payment_status = 'pending'
             and (hold_expires_at is null or hold_expires_at > now())));

  if v_booked + new.group_size > v_cap then
    raise exception 'DAY_FULL: % has % of % spots taken; this group of % does not fit.',
      new.visit_date, v_booked, v_cap, new.group_size;
  end if;

  return new;
end;
$$;


--
-- Name: rls_auto_enable(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.rls_auto_enable() RETURNS event_trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'pg_catalog'
    AS $$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: activities; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activities (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    business_id uuid,
    code text NOT NULL,
    name text NOT NULL,
    type text NOT NULL,
    area_group text,
    description text,
    price numeric(10,2) NOT NULL,
    price_unit text NOT NULL,
    per_person_price numeric(10,2) DEFAULT 0 NOT NULL,
    capacity integer,
    requires_down_payment boolean DEFAULT true NOT NULL,
    down_payment_percent numeric(5,2) DEFAULT 50 NOT NULL,
    advance_notice_days integer DEFAULT 2 NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    viewing_price numeric(10,2),
    min_age integer,
    daily_capacity integer,
    CONSTRAINT activities_advance_notice_days_check CHECK ((advance_notice_days >= 0)),
    CONSTRAINT activities_capacity_check CHECK ((capacity > 0)),
    CONSTRAINT activities_daily_capacity_check CHECK ((daily_capacity > 0)),
    CONSTRAINT activities_down_payment_percent_check CHECK (((down_payment_percent >= (0)::numeric) AND (down_payment_percent <= (100)::numeric))),
    CONSTRAINT activities_min_age_check CHECK ((min_age >= 0)),
    CONSTRAINT activities_per_person_price_check CHECK ((per_person_price >= (0)::numeric)),
    CONSTRAINT activities_price_check CHECK ((price >= (0)::numeric)),
    CONSTRAINT activities_price_unit_check CHECK ((price_unit = ANY (ARRAY['per_night'::text, 'per_person'::text]))),
    CONSTRAINT activities_type_check CHECK ((type = ANY (ARRAY['camping'::text, 'rock_activity'::text]))),
    CONSTRAINT activities_viewing_price_check CHECK ((viewing_price >= (0)::numeric))
);


--
-- Name: activity_time_slots; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.activity_time_slots (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    activity_id uuid NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    capacity integer,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT activity_time_slots_capacity_check CHECK ((capacity > 0)),
    CONSTRAINT activity_time_slots_check CHECK ((end_time > start_time))
);


--
-- Name: admin_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    auth_user_id uuid NOT NULL,
    name text NOT NULL,
    role text NOT NULL,
    is_active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT admin_accounts_role_check CHECK ((role = ANY (ARRAY['super_admin'::text, 'staff_admin'::text, 'field_staff'::text])))
);


--
-- Name: bookings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.bookings (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    reference_number text DEFAULT ('GC-'::text || upper(substr(md5((random())::text), 1, 8))) NOT NULL,
    activity_id uuid NOT NULL,
    time_slot_id uuid,
    visit_date date NOT NULL,
    nights integer,
    guest_name text NOT NULL,
    companions_names text[],
    contact_number text NOT NULL,
    email text NOT NULL,
    group_size integer NOT NULL,
    senior_count integer DEFAULT 0 NOT NULL,
    pwd_count integer DEFAULT 0 NOT NULL,
    child_count integer DEFAULT 0 NOT NULL,
    local_count integer DEFAULT 0 NOT NULL,
    total_amount numeric(10,2) NOT NULL,
    amount_due numeric(10,2) NOT NULL,
    amount_paid numeric(10,2) DEFAULT 0 NOT NULL,
    payment_status text DEFAULT 'pending'::text NOT NULL,
    attendance_status text DEFAULT 'upcoming'::text NOT NULL,
    hold_expires_at timestamp with time zone,
    source text DEFAULT 'online'::text NOT NULL,
    assigned_field_staff_id uuid,
    guest_account_id uuid,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    viewing_count integer DEFAULT 0 NOT NULL,
    capacity_override boolean DEFAULT false NOT NULL,
    CONSTRAINT bookings_amount_due_check CHECK ((amount_due >= (0)::numeric)),
    CONSTRAINT bookings_amount_paid_check CHECK ((amount_paid >= (0)::numeric)),
    CONSTRAINT bookings_attendance_status_check CHECK ((attendance_status = ANY (ARRAY['upcoming'::text, 'done'::text, 'failed_to_show'::text, 'cancelled'::text]))),
    CONSTRAINT bookings_check CHECK (((senior_count <= group_size) AND (pwd_count <= group_size) AND (child_count <= group_size) AND (local_count <= group_size))),
    CONSTRAINT bookings_check1 CHECK (((nights IS NULL) OR (time_slot_id IS NULL))),
    CONSTRAINT bookings_child_count_check CHECK ((child_count >= 0)),
    CONSTRAINT bookings_group_size_check CHECK ((group_size >= 1)),
    CONSTRAINT bookings_local_count_check CHECK ((local_count >= 0)),
    CONSTRAINT bookings_nights_check CHECK ((nights >= 1)),
    CONSTRAINT bookings_payment_status_check CHECK ((payment_status = ANY (ARRAY['pending'::text, 'down_payment'::text, 'paid'::text, 'expired'::text, 'refunded'::text]))),
    CONSTRAINT bookings_pwd_count_check CHECK ((pwd_count >= 0)),
    CONSTRAINT bookings_senior_count_check CHECK ((senior_count >= 0)),
    CONSTRAINT bookings_source_check CHECK ((source = ANY (ARRAY['online'::text, 'walk_in'::text]))),
    CONSTRAINT bookings_total_amount_check CHECK ((total_amount >= (0)::numeric)),
    CONSTRAINT bookings_viewing_count_check CHECK ((viewing_count >= 0)),
    CONSTRAINT one_discount_per_person CHECK (((((senior_count + pwd_count) + child_count) + local_count) <= group_size)),
    CONSTRAINT override_walk_in_only CHECK (((capacity_override = false) OR (source = 'walk_in'::text))),
    CONSTRAINT viewing_within_group CHECK ((viewing_count <= group_size))
);


--
-- Name: cancellations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cancellations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    booking_id uuid NOT NULL,
    action text NOT NULL,
    reason_category text NOT NULL,
    reason_details text,
    original_visit_date date NOT NULL,
    new_visit_date date,
    refund_amount numeric(10,2),
    refund_status text DEFAULT 'not_applicable'::text NOT NULL,
    processed_by uuid NOT NULL,
    guest_notified_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT cancellations_action_check CHECK ((action = ANY (ARRAY['reschedule'::text, 'refund'::text, 'cancel'::text]))),
    CONSTRAINT cancellations_check CHECK (((action <> 'reschedule'::text) OR (new_visit_date IS NOT NULL))),
    CONSTRAINT cancellations_check1 CHECK (((action = 'reschedule'::text) OR (new_visit_date IS NULL))),
    CONSTRAINT cancellations_check2 CHECK (((action <> 'refund'::text) OR ((refund_amount IS NOT NULL) AND (refund_status <> 'not_applicable'::text)))),
    CONSTRAINT cancellations_check3 CHECK (((new_visit_date IS NULL) OR (new_visit_date <= (original_visit_date + '6 mons'::interval)))),
    CONSTRAINT cancellations_reason_category_check CHECK ((reason_category = ANY (ARRAY['weather'::text, 'health_emergency'::text, 'death'::text, 'guest_request'::text, 'other'::text]))),
    CONSTRAINT cancellations_refund_amount_check CHECK ((refund_amount >= (0)::numeric)),
    CONSTRAINT cancellations_refund_status_check CHECK ((refund_status = ANY (ARRAY['not_applicable'::text, 'pending'::text, 'processed'::text])))
);


--
-- Name: date_overrides; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.date_overrides (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    activity_id uuid NOT NULL,
    override_date date NOT NULL,
    daily_capacity integer,
    is_closed boolean DEFAULT false NOT NULL,
    reason text NOT NULL,
    set_by uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT date_overrides_check CHECK ((is_closed OR (daily_capacity IS NOT NULL))),
    CONSTRAINT date_overrides_daily_capacity_check CHECK ((daily_capacity >= 0))
);


--
-- Name: guest_accounts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.guest_accounts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    auth_user_id uuid,
    name text NOT NULL,
    email text NOT NULL,
    contact_number text,
    consent_given_at timestamp with time zone NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    booking_id uuid NOT NULL,
    amount numeric(10,2) NOT NULL,
    purpose text NOT NULL,
    method text NOT NULL,
    status text DEFAULT 'pending'::text NOT NULL,
    transaction_reference text,
    recorded_by uuid,
    paid_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT payments_amount_check CHECK ((amount > (0)::numeric)),
    CONSTRAINT payments_check CHECK (((status <> 'confirmed'::text) OR (paid_at IS NOT NULL))),
    CONSTRAINT payments_method_check CHECK ((method = ANY (ARRAY['qrph'::text, 'gcash'::text, 'maya'::text, 'card'::text, 'bank_transfer'::text, 'cash'::text]))),
    CONSTRAINT payments_purpose_check CHECK ((purpose = ANY (ARRAY['down_payment'::text, 'balance'::text]))),
    CONSTRAINT payments_status_check CHECK ((status = ANY (ARRAY['pending'::text, 'confirmed'::text, 'failed'::text])))
);


--
-- Name: activities activities_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_code_key UNIQUE (code);


--
-- Name: activities activities_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activities
    ADD CONSTRAINT activities_pkey PRIMARY KEY (id);


--
-- Name: activity_time_slots activity_time_slots_activity_id_start_time_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_time_slots
    ADD CONSTRAINT activity_time_slots_activity_id_start_time_key UNIQUE (activity_id, start_time);


--
-- Name: activity_time_slots activity_time_slots_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_time_slots
    ADD CONSTRAINT activity_time_slots_pkey PRIMARY KEY (id);


--
-- Name: admin_accounts admin_accounts_auth_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_accounts
    ADD CONSTRAINT admin_accounts_auth_user_id_key UNIQUE (auth_user_id);


--
-- Name: admin_accounts admin_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_accounts
    ADD CONSTRAINT admin_accounts_pkey PRIMARY KEY (id);


--
-- Name: bookings bookings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_pkey PRIMARY KEY (id);


--
-- Name: bookings bookings_reference_number_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_reference_number_key UNIQUE (reference_number);


--
-- Name: cancellations cancellations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cancellations
    ADD CONSTRAINT cancellations_pkey PRIMARY KEY (id);


--
-- Name: date_overrides date_overrides_activity_id_override_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.date_overrides
    ADD CONSTRAINT date_overrides_activity_id_override_date_key UNIQUE (activity_id, override_date);


--
-- Name: date_overrides date_overrides_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.date_overrides
    ADD CONSTRAINT date_overrides_pkey PRIMARY KEY (id);


--
-- Name: guest_accounts guest_accounts_auth_user_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_accounts
    ADD CONSTRAINT guest_accounts_auth_user_id_key UNIQUE (auth_user_id);


--
-- Name: guest_accounts guest_accounts_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_accounts
    ADD CONSTRAINT guest_accounts_email_key UNIQUE (email);


--
-- Name: guest_accounts guest_accounts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_accounts
    ADD CONSTRAINT guest_accounts_pkey PRIMARY KEY (id);


--
-- Name: bookings no_double_booking_camping; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT no_double_booking_camping EXCLUDE USING gist (activity_id WITH =, daterange(visit_date, (visit_date + nights)) WITH &&) WHERE (((nights IS NOT NULL) AND (payment_status = ANY (ARRAY['pending'::text, 'down_payment'::text, 'paid'::text])) AND (attendance_status <> 'cancelled'::text)));


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (id);


--
-- Name: payments payments_transaction_reference_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_transaction_reference_key UNIQUE (transaction_reference);


--
-- Name: bookings enforce_availability; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER enforce_availability BEFORE INSERT OR UPDATE OF visit_date, nights, activity_id, group_size, capacity_override ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.check_booking_availability();


--
-- Name: activity_time_slots activity_time_slots_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.activity_time_slots
    ADD CONSTRAINT activity_time_slots_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id);


--
-- Name: admin_accounts admin_accounts_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_accounts
    ADD CONSTRAINT admin_accounts_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: bookings bookings_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id);


--
-- Name: bookings bookings_assigned_field_staff_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_assigned_field_staff_id_fkey FOREIGN KEY (assigned_field_staff_id) REFERENCES public.admin_accounts(id);


--
-- Name: bookings bookings_guest_account_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_guest_account_id_fkey FOREIGN KEY (guest_account_id) REFERENCES public.guest_accounts(id);


--
-- Name: bookings bookings_time_slot_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.bookings
    ADD CONSTRAINT bookings_time_slot_id_fkey FOREIGN KEY (time_slot_id) REFERENCES public.activity_time_slots(id);


--
-- Name: cancellations cancellations_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cancellations
    ADD CONSTRAINT cancellations_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id);


--
-- Name: cancellations cancellations_processed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cancellations
    ADD CONSTRAINT cancellations_processed_by_fkey FOREIGN KEY (processed_by) REFERENCES public.admin_accounts(id);


--
-- Name: date_overrides date_overrides_activity_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.date_overrides
    ADD CONSTRAINT date_overrides_activity_id_fkey FOREIGN KEY (activity_id) REFERENCES public.activities(id);


--
-- Name: date_overrides date_overrides_set_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.date_overrides
    ADD CONSTRAINT date_overrides_set_by_fkey FOREIGN KEY (set_by) REFERENCES public.admin_accounts(id);


--
-- Name: guest_accounts guest_accounts_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.guest_accounts
    ADD CONSTRAINT guest_accounts_auth_user_id_fkey FOREIGN KEY (auth_user_id) REFERENCES auth.users(id) ON DELETE SET NULL;


--
-- Name: payments payments_booking_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_booking_id_fkey FOREIGN KEY (booking_id) REFERENCES public.bookings(id);


--
-- Name: payments payments_recorded_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_recorded_by_fkey FOREIGN KEY (recorded_by) REFERENCES public.admin_accounts(id);


--
-- Name: activities Public can view active activities; Type: POLICY; Schema: public; Owner: -
--

CREATE POLICY "Public can view active activities" ON public.activities FOR SELECT TO authenticated, anon USING ((is_active = true));


--
-- Name: activities; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.activities ENABLE ROW LEVEL SECURITY;

--
-- Name: activity_time_slots; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.activity_time_slots ENABLE ROW LEVEL SECURITY;

--
-- Name: admin_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.admin_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: bookings; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.bookings ENABLE ROW LEVEL SECURITY;

--
-- Name: cancellations; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.cancellations ENABLE ROW LEVEL SECURITY;

--
-- Name: date_overrides; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.date_overrides ENABLE ROW LEVEL SECURITY;

--
-- Name: guest_accounts; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.guest_accounts ENABLE ROW LEVEL SECURITY;

--
-- Name: payments; Type: ROW SECURITY; Schema: public; Owner: -
--

ALTER TABLE public.payments ENABLE ROW LEVEL SECURITY;

--
-- PostgreSQL database dump complete
--

\unrestrict srbsFvztoYYwkMvnob89wdSzNHsXyf2JycSFUYsqwbWjJFrlKo0LK3bDdW2yx5i

