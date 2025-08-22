--
-- PostgreSQL database dump
--

-- Dumped from database version 17.5
-- Dumped by pg_dump version 17.5

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
-- Name: video_state; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.video_state AS ENUM (
    'needs_analysis',
    'analyzed',
    'crf_searching',
    'crf_searched',
    'encoding',
    'encoded',
    'failed'
);


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: configs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.configs (
    id bigint NOT NULL,
    url character varying(255),
    api_key character varying(255),
    enabled boolean DEFAULT false NOT NULL,
    service_type character varying(255),
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: configs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.configs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: configs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.configs_id_seq OWNED BY public.configs.id;


--
-- Name: libraries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.libraries (
    id bigint NOT NULL,
    path character varying(255),
    monitor boolean DEFAULT false NOT NULL,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: libraries_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.libraries_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: libraries_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.libraries_id_seq OWNED BY public.libraries.id;


--
-- Name: schema_migrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schema_migrations (
    version bigint NOT NULL,
    inserted_at timestamp(0) without time zone
);


--
-- Name: video_failures; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.video_failures (
    id bigint NOT NULL,
    video_id bigint NOT NULL,
    failure_stage character varying(255) NOT NULL,
    failure_category character varying(255) NOT NULL,
    failure_code character varying(255),
    failure_message text NOT NULL,
    system_context jsonb,
    retry_count integer DEFAULT 0,
    resolved boolean DEFAULT false,
    resolved_at timestamp(0) without time zone,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL
);


--
-- Name: video_failures_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.video_failures_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: video_failures_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.video_failures_id_seq OWNED BY public.video_failures.id;


--
-- Name: videos; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.videos (
    id bigint NOT NULL,
    path text,
    size bigint,
    bitrate integer,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    library_id bigint,
    mediainfo jsonb,
    duration double precision,
    width integer,
    height integer,
    frame_rate double precision,
    video_count integer,
    audio_count integer,
    text_count integer,
    hdr character varying(255),
    video_codecs character varying(255)[],
    audio_codecs character varying(255)[],
    text_codecs character varying(255)[],
    atmos boolean DEFAULT false,
    max_audio_channels integer DEFAULT 0,
    title character varying(255),
    service_id character varying(255),
    service_type character varying(255),
    state public.video_state NOT NULL
);


--
-- Name: videos_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.videos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: videos_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.videos_id_seq OWNED BY public.videos.id;


--
-- Name: vmafs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.vmafs (
    id bigint NOT NULL,
    score double precision,
    crf double precision,
    video_id bigint,
    inserted_at timestamp(0) without time zone NOT NULL,
    updated_at timestamp(0) without time zone NOT NULL,
    params text[],
    chosen boolean DEFAULT false NOT NULL,
    size text,
    percent double precision,
    "time" integer,
    savings bigint,
    target integer DEFAULT 95
);


--
-- Name: vmafs_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.vmafs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: vmafs_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.vmafs_id_seq OWNED BY public.vmafs.id;


--
-- Name: configs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configs ALTER COLUMN id SET DEFAULT nextval('public.configs_id_seq'::regclass);


--
-- Name: libraries id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.libraries ALTER COLUMN id SET DEFAULT nextval('public.libraries_id_seq'::regclass);


--
-- Name: video_failures id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_failures ALTER COLUMN id SET DEFAULT nextval('public.video_failures_id_seq'::regclass);


--
-- Name: videos id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.videos ALTER COLUMN id SET DEFAULT nextval('public.videos_id_seq'::regclass);


--
-- Name: vmafs id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vmafs ALTER COLUMN id SET DEFAULT nextval('public.vmafs_id_seq'::regclass);


--
-- Name: configs configs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.configs
    ADD CONSTRAINT configs_pkey PRIMARY KEY (id);


--
-- Name: libraries libraries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.libraries
    ADD CONSTRAINT libraries_pkey PRIMARY KEY (id);


--
-- Name: schema_migrations schema_migrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schema_migrations
    ADD CONSTRAINT schema_migrations_pkey PRIMARY KEY (version);


--
-- Name: video_failures video_failures_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_failures
    ADD CONSTRAINT video_failures_pkey PRIMARY KEY (id);


--
-- Name: videos videos_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.videos
    ADD CONSTRAINT videos_pkey PRIMARY KEY (id);


--
-- Name: vmafs vmafs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vmafs
    ADD CONSTRAINT vmafs_pkey PRIMARY KEY (id);


--
-- Name: configs_service_type_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX configs_service_type_index ON public.configs USING btree (service_type);


--
-- Name: libraries_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX libraries_path_index ON public.libraries USING btree (path);


--
-- Name: video_failures_failure_category_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_failures_failure_category_index ON public.video_failures USING btree (failure_category);


--
-- Name: video_failures_failure_stage_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_failures_failure_stage_index ON public.video_failures USING btree (failure_stage);


--
-- Name: video_failures_inserted_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_failures_inserted_at_index ON public.video_failures USING btree (inserted_at);


--
-- Name: video_failures_resolved_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_failures_resolved_index ON public.video_failures USING btree (resolved);


--
-- Name: video_failures_video_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_failures_video_id_index ON public.video_failures USING btree (video_id);


--
-- Name: video_failures_video_id_resolved_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX video_failures_video_id_resolved_index ON public.video_failures USING btree (video_id, resolved);


--
-- Name: videos_path_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX videos_path_index ON public.videos USING btree (path);


--
-- Name: videos_state_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX videos_state_index ON public.videos USING btree (state);


--
-- Name: videos_state_size_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX videos_state_size_index ON public.videos USING btree (state, size);


--
-- Name: videos_state_updated_at_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX videos_state_updated_at_index ON public.videos USING btree (state, updated_at);


--
-- Name: vmafs_chosen_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vmafs_chosen_index ON public.vmafs USING btree (chosen);


--
-- Name: vmafs_crf_video_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX vmafs_crf_video_id_index ON public.vmafs USING btree (crf, video_id);


--
-- Name: vmafs_video_id_index; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX vmafs_video_id_index ON public.vmafs USING btree (video_id);


--
-- Name: video_failures video_failures_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.video_failures
    ADD CONSTRAINT video_failures_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id) ON DELETE CASCADE;


--
-- Name: videos videos_library_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.videos
    ADD CONSTRAINT videos_library_id_fkey FOREIGN KEY (library_id) REFERENCES public.libraries(id);


--
-- Name: vmafs vmafs_video_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.vmafs
    ADD CONSTRAINT vmafs_video_id_fkey FOREIGN KEY (video_id) REFERENCES public.videos(id);


--
-- PostgreSQL database dump complete
--

INSERT INTO public."schema_migrations" (version) VALUES (20241125195030);
INSERT INTO public."schema_migrations" (version) VALUES (20241125220026);
INSERT INTO public."schema_migrations" (version) VALUES (20241125220225);
INSERT INTO public."schema_migrations" (version) VALUES (20241125220353);
INSERT INTO public."schema_migrations" (version) VALUES (20241125221035);
INSERT INTO public."schema_migrations" (version) VALUES (20241125221224);
INSERT INTO public."schema_migrations" (version) VALUES (20241126000141);
INSERT INTO public."schema_migrations" (version) VALUES (20241126010807);
INSERT INTO public."schema_migrations" (version) VALUES (20241126045935);
INSERT INTO public."schema_migrations" (version) VALUES (20241128015107);
INSERT INTO public."schema_migrations" (version) VALUES (20241128170506);
INSERT INTO public."schema_migrations" (version) VALUES (20241128171811);
INSERT INTO public."schema_migrations" (version) VALUES (20241128211730);
INSERT INTO public."schema_migrations" (version) VALUES (20241129003853);
INSERT INTO public."schema_migrations" (version) VALUES (20241129014035);
INSERT INTO public."schema_migrations" (version) VALUES (20241129022746);
INSERT INTO public."schema_migrations" (version) VALUES (20241129173018);
INSERT INTO public."schema_migrations" (version) VALUES (20241129174923);
INSERT INTO public."schema_migrations" (version) VALUES (20241129180207);
INSERT INTO public."schema_migrations" (version) VALUES (20241130010208);
INSERT INTO public."schema_migrations" (version) VALUES (20241209161557);
INSERT INTO public."schema_migrations" (version) VALUES (20241209162627);
INSERT INTO public."schema_migrations" (version) VALUES (20241209165334);
INSERT INTO public."schema_migrations" (version) VALUES (20241218162131);
INSERT INTO public."schema_migrations" (version) VALUES (20241228042138);
INSERT INTO public."schema_migrations" (version) VALUES (20250218170919);
INSERT INTO public."schema_migrations" (version) VALUES (20250218172000);
INSERT INTO public."schema_migrations" (version) VALUES (20250710160042);
INSERT INTO public."schema_migrations" (version) VALUES (20250729205447);
INSERT INTO public."schema_migrations" (version) VALUES (20250815224041);
INSERT INTO public."schema_migrations" (version) VALUES (20250819215136);
INSERT INTO public."schema_migrations" (version) VALUES (20250822201804);
