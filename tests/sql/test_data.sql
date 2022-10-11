--
-- PostgreSQL database dump
--

-- Dumped from database version 11.13 (Debian 11.13-1.pgdg100+1)
-- Dumped by pg_dump version 13.7 (Ubuntu 13.7-1.pgdg20.04+1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: gobs; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA gobs;


--
-- Name: postgis; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;


--
-- Name: EXTENSION postgis; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION postgis IS 'PostGIS geometry, geography, and raster spatial types and functions';


--
-- Name: uuid-ossp; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;


--
-- Name: EXTENSION "uuid-ossp"; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION "uuid-ossp" IS 'generate universally unique identifiers (UUIDs)';


--
-- Name: find_observation_with_wrong_spatial_object(integer); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.find_observation_with_wrong_spatial_object(_id_series integer) RETURNS TABLE(ob_uid uuid, so_unique_id text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
    o.ob_uid, s.so_unique_id
    FROM gobs.observation AS o
    INNER JOIN gobs.spatial_object AS s
        ON s.id = o.fk_id_spatial_object
    WHERE True
    -- the same series
    AND o.fk_id_series = _id_series
    -- wrong start (and optional end) dates compared to validity dates of linked spatial object
    AND (
            ob_start_timestamp
            NOT BETWEEN Coalesce('-infinity'::timestamp, so_valid_from) AND Coalesce(so_valid_to, 'infinity'::timestamp)
        OR
        (    ob_end_timestamp IS NOT NULL
            AND ob_end_timestamp
            NOT BETWEEN Coalesce('-infinity'::timestamp, so_valid_from) AND Coalesce(so_valid_to, 'infinity'::timestamp)
        )
    )
    ;

END;
$$;


--
-- Name: FUNCTION find_observation_with_wrong_spatial_object(_id_series integer); Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON FUNCTION gobs.find_observation_with_wrong_spatial_object(_id_series integer) IS 'Find the observations with having incompatible start and end timestamp with related spatial objects validity dates';


--
-- Name: log_deleted_object(); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.log_deleted_object() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    oid text;
BEGIN
    INSERT INTO gobs.deleted_data_log (
        de_table,
        de_uid,
        de_timestamp
    )
    VALUES (
        TG_TABLE_NAME::text,
        OLD.ob_uid,
        now()
    )
    ;
    RETURN OLD;
END;
$$;


--
-- Name: manage_object_timestamps(); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.manage_object_timestamps() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    nowtm timestamp;
BEGIN
    nowtm = now();
    IF TG_OP = 'INSERT' THEN
        NEW.created_at = nowtm;
        NEW.updated_at = nowtm;
    END IF;

    IF TG_OP = 'UPDATE' THEN
        NEW.updated_at = nowtm;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: parse_indicator_paths(integer, text); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.parse_indicator_paths(i_id integer, i_path text) RETURNS integer
    LANGUAGE plpgsql
    AS $$
DECLARE
    _path text;
    _group text;
    _word text;
    _parent text;
    _gid integer;
    _leaf text;
    _leaves text[];
BEGIN
    _parent = NULL;

    -- PARSE PATHS
    -- Insert root
    INSERT INTO gobs.graph_node (gn_label)
    VALUES ('ROOT')
    ON CONFLICT DO NOTHING;

    -- Explode path
    FOR _group IN
        SELECT trim(g)
        FROM regexp_split_to_table(i_path, ',') AS g
    LOOP
        RAISE NOTICE 'groupe = "%" ', _group;
        -- Explode group
        FOR _word IN
            SELECT trim(w) AS w
            FROM regexp_split_to_table(_group, '/') AS w
        LOOP
            RAISE NOTICE '  * word = "%", parent = "%" ', _word, _parent;

            -- gobs.graph_node
            INSERT INTO gobs.graph_node (gn_label)
            VALUES (_word)
            ON CONFLICT (gn_label)
            DO NOTHING
            RETURNING id
            INTO _gid;
            IF _gid IS NULL THEN
                SELECT id INTO _gid
                FROM gobs.graph_node
                WHERE gn_label = _word;
            END IF;

            -- gobs.r_graph_edge
            INSERT INTO gobs.r_graph_edge (ge_parent_node, ge_child_node)
            VALUES (
                (SELECT id FROM gobs.graph_node WHERE gn_label = coalesce(_parent, 'ROOT') LIMIT 1),
                _gid
            )
            ON CONFLICT DO NOTHING;

            -- Change parent with current word -> Next will have it as parent
            _parent =  _word;

            -- store leaf
            _leaf = _word;

        END LOOP;
        -- Put back parent to NULL -> next will start with ROOT
        _parent =  NULL;

        -- Add leaf to leaves
        _leaves = _leaves || _leaf ;
        _leaf = NULL;
    END LOOP;

    -- Add leaves to r_indicator_node
    RAISE NOTICE '  leaves % ', _leaves;

    INSERT INTO gobs.r_indicator_node
    (fk_id_indicator, fk_id_node)
    SELECT i_id, (
        SELECT id FROM gobs.graph_node WHERE gn_label = leaf LIMIT 1
    )
    FROM (
        SELECT unnest(_leaves) AS leaf
    ) AS source
    ON CONFLICT DO NOTHING;

    RETURN 1;
END;
$$;


--
-- Name: trg_after_import_validation(); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.trg_after_import_validation() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    _output integer;
BEGIN
    IF TG_OP = 'UPDATE' AND NEW.im_status = 'V' AND NEW.im_status != OLD.im_status THEN
        UPDATE gobs.observation
        SET ob_validation = now()
        WHERE TRUE
        AND fk_id_import = NEW.id
        ;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: trg_parse_indicator_paths(); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.trg_parse_indicator_paths() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    _output integer;
BEGIN
    IF TG_OP = 'INSERT' OR NEW.id_paths != OLD.id_paths THEN
        SELECT gobs.parse_indicator_paths(NEW.id, NEW.id_paths)
        INTO _output;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: update_observation_on_spatial_object_change(); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.update_observation_on_spatial_object_change() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND NOT ST_Equals(NEW.geom, OLD.geom) THEN
        UPDATE gobs.observation
        SET updated_at = now()
        WHERE fk_id_spatial_object = NEW.id
        ;
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: update_observations_with_wrong_spatial_objects(integer); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.update_observations_with_wrong_spatial_objects(_id_series integer) RETURNS TABLE(modified_obs_count integer, remaining_obs_count integer)
    LANGUAGE plpgsql
    AS $$
DECLARE
    modified_count integer;
    remaining_count integer;
BEGIN

-- Update the observations
WITH problem AS (
    SELECT *
    FROM gobs.find_observation_with_wrong_spatial_object(_id_series)
), solution AS (
    SELECT
    o.ob_uid, so.id AS new_id
    FROM
        gobs.observation AS o,
        problem AS p,
        gobs.spatial_object AS so
    WHERE True
    -- same unique id as problematic
    AND p.so_unique_id = so.so_unique_id
    -- not itself
    AND True
    -- problematic only
    AND p.ob_uid = o.ob_uid
    -- same series
    AND o.fk_id_series = _id_series
    -- same spatial layer
    AND so.fk_id_spatial_layer IN (
        SELECT fk_id_spatial_layer
        FROM gobs.series
        WHERE id = _id_series
    )
    -- compatible dates
    AND
        ob_start_timestamp
        BETWEEN Coalesce(so.so_valid_from, '-infinity'::timestamp) AND Coalesce(so.so_valid_to, 'infinity'::timestamp)
    AND (
        ob_end_timestamp IS NULL
        OR
        (    ob_end_timestamp IS NOT NULL
            AND ob_end_timestamp
            BETWEEN Coalesce(so_valid_from, '-infinity'::timestamp) AND Coalesce(so_valid_to, 'infinity'::timestamp)
        )
    )
)
UPDATE gobs.observation oo
SET fk_id_spatial_object = s.new_id
FROM solution AS s
WHERE oo.ob_uid = s.ob_uid
;

-- Get the number of rows updated
GET DIAGNOSTICS modified_count = ROW_COUNT;

-- Check if there is anything remaining
-- for example if no new id have been found to replace the wrong ones
SELECT count(*)
FROM gobs.find_observation_with_wrong_spatial_object(_id_series)
INTO remaining_count;

RETURN QUERY SELECT modified_count, remaining_count;

END;
$$;


--
-- Name: FUNCTION update_observations_with_wrong_spatial_objects(_id_series integer); Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON FUNCTION gobs.update_observations_with_wrong_spatial_objects(_id_series integer) IS 'Update observations with wrong spatial objects: it search the observation for which the start and end timestamp does not match anymore the related spatial objects validity dates. It gets the correct one if possible and perform an UPDATE for these observations. It returns a line with 2 integer columns: modified_obs_count (number of modified observations) and remaining_obs_count (number of observations still with wrong observations';


--
-- Name: update_spatial_object_end_validity(); Type: FUNCTION; Schema: gobs; Owner: -
--

CREATE FUNCTION gobs.update_spatial_object_end_validity() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    nowtm timestamp;
    last_id integer;
BEGIN
    last_id = 0;
    IF TG_OP = 'INSERT' THEN

        -- Get the last corresponding item
        SELECT INTO last_id
        so.id
        FROM gobs.spatial_object so
        WHERE TRUE
        -- do not modify if there is already a value
        AND so.so_valid_to IS NULL
        -- only for same spatial layer
        AND so.fk_id_spatial_layer = NEW.fk_id_spatial_layer
        -- and same unique id ex: code insee
        AND so.so_unique_id = NEW.so_unique_id
        -- and not for the same object
        AND so.so_uid != NEW.so_uid
        -- only if the new object has a start validity date AFTER the existing one
        AND so.so_valid_from < NEW.so_valid_from
        -- only the preceding one
        ORDER BY so_valid_from DESC
        LIMIT 1
        ;

        -- Update it
        IF last_id > 0 THEN
            UPDATE gobs.spatial_object so
            SET so_valid_to = NEW.so_valid_from
            WHERE so.id = last_id
            ;
        END IF;

    END IF;

    RETURN NEW;
END;
$$;


SET default_tablespace = '';

--
-- Name: actor; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.actor (
    id integer NOT NULL,
    a_label text NOT NULL,
    a_description text NOT NULL,
    a_email text NOT NULL,
    id_category integer NOT NULL,
    a_login text NOT NULL
);


--
-- Name: TABLE actor; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.actor IS 'Actors';


--
-- Name: COLUMN actor.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor.id IS 'ID';


--
-- Name: COLUMN actor.a_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor.a_label IS 'Name of the actor (can be a person or an entity)';


--
-- Name: COLUMN actor.a_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor.a_description IS 'Description of the actor';


--
-- Name: COLUMN actor.a_email; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor.a_email IS 'Email of the actor';


--
-- Name: COLUMN actor.id_category; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor.id_category IS 'Category of actor';


--
-- Name: COLUMN actor.a_login; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor.a_login IS 'Login of the actor. It is the unique identifier of the actor.';


--
-- Name: actor_category; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.actor_category (
    id integer NOT NULL,
    ac_label text NOT NULL,
    ac_description text NOT NULL
);


--
-- Name: TABLE actor_category; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.actor_category IS 'Actors categories';


--
-- Name: COLUMN actor_category.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor_category.id IS 'ID';


--
-- Name: COLUMN actor_category.ac_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor_category.ac_label IS 'Name of the actor category';


--
-- Name: COLUMN actor_category.ac_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.actor_category.ac_description IS 'Description of the actor category';


--
-- Name: actor_category_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.actor_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: actor_category_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.actor_category_id_seq OWNED BY gobs.actor_category.id;


--
-- Name: actor_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.actor_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: actor_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.actor_id_seq OWNED BY gobs.actor.id;


--
-- Name: application; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.application (
    id integer NOT NULL,
    ap_code text NOT NULL,
    ap_label text NOT NULL,
    ap_description text NOT NULL,
    ap_default_values jsonb NOT NULL
);


--
-- Name: TABLE application; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.application IS 'List the external applications interacting with G-Obs database with the web API.
This will help storing application specific data such as the default values when creating automatically series, protocols, users, etc.';


--
-- Name: COLUMN application.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.application.id IS 'Unique identifier';


--
-- Name: COLUMN application.ap_code; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.application.ap_code IS 'Code of the application. Ex: kobo_toolbox';


--
-- Name: COLUMN application.ap_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.application.ap_label IS 'Label of the application. Ex: Kobo Toolbox';


--
-- Name: COLUMN application.ap_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.application.ap_description IS 'Description of the application.';


--
-- Name: COLUMN application.ap_default_values; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.application.ap_default_values IS 'Default values for the different API need. JSONB to allow to easily add more data when necessary';


--
-- Name: application_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.application_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: application_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.application_id_seq OWNED BY gobs.application.id;


--
-- Name: deleted_data_log; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.deleted_data_log (
    de_table text NOT NULL,
    de_uid uuid NOT NULL,
    de_timestamp timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE deleted_data_log; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.deleted_data_log IS 'Log of deleted objects from observation table. Use for synchronization purpose';


--
-- Name: COLUMN deleted_data_log.de_table; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.deleted_data_log.de_table IS 'Source table of the deleted object: observation';


--
-- Name: COLUMN deleted_data_log.de_uid; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.deleted_data_log.de_uid IS 'Unique text identifier of the object. Observation: ob_uid';


--
-- Name: COLUMN deleted_data_log.de_timestamp; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.deleted_data_log.de_timestamp IS 'Timestamp of the deletion';


--
-- Name: document; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.document (
    id integer NOT NULL,
    do_uid uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    do_label text NOT NULL,
    do_description text,
    do_type text NOT NULL,
    do_path text NOT NULL,
    fk_id_indicator integer,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE document; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.document IS 'List of documents for describing indicators.';


--
-- Name: COLUMN document.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.id IS 'ID';


--
-- Name: COLUMN document.do_uid; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.do_uid IS 'Document uid: autogenerated unique identifier';


--
-- Name: COLUMN document.do_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.do_label IS 'Label of the document, used for display. Must be unique';


--
-- Name: COLUMN document.do_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.do_description IS 'Description of the document';


--
-- Name: COLUMN document.do_type; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.do_type IS 'Type of the document';


--
-- Name: COLUMN document.do_path; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.do_path IS 'Relative path of the document to the project storage. Ex: media/indicator/documents/indicator_weather_status_description.pdf';


--
-- Name: COLUMN document.fk_id_indicator; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.fk_id_indicator IS 'Indicator id';


--
-- Name: COLUMN document.created_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.created_at IS 'Creation timestamp';


--
-- Name: COLUMN document.updated_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.document.updated_at IS 'Last updated timestamp';


--
-- Name: document_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.document_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: document_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.document_id_seq OWNED BY gobs.document.id;


--
-- Name: glossary; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.glossary (
    id integer NOT NULL,
    gl_field text NOT NULL,
    gl_code text NOT NULL,
    gl_label text NOT NULL,
    gl_description text NOT NULL,
    gl_order smallint
);


--
-- Name: TABLE glossary; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.glossary IS 'List of labels and words used as labels for stored data';


--
-- Name: COLUMN glossary.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.glossary.id IS 'ID';


--
-- Name: COLUMN glossary.gl_field; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.glossary.gl_field IS 'Target field for this glossary item';


--
-- Name: COLUMN glossary.gl_code; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.glossary.gl_code IS 'Item code to store in tables';


--
-- Name: COLUMN glossary.gl_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.glossary.gl_label IS 'Item label to show for users';


--
-- Name: COLUMN glossary.gl_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.glossary.gl_description IS 'Description of the item';


--
-- Name: COLUMN glossary.gl_order; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.glossary.gl_order IS 'Display order among the field items';


--
-- Name: glossary_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.glossary_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: glossary_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.glossary_id_seq OWNED BY gobs.glossary.id;


--
-- Name: graph_node; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.graph_node (
    id integer NOT NULL,
    gn_label text NOT NULL
);


--
-- Name: TABLE graph_node; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.graph_node IS 'Graph nodes, to store key words used to find an indicator.';


--
-- Name: COLUMN graph_node.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.graph_node.id IS 'ID';


--
-- Name: COLUMN graph_node.gn_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.graph_node.gn_label IS 'Name of the node';


--
-- Name: graph_node_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.graph_node_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: graph_node_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.graph_node_id_seq OWNED BY gobs.graph_node.id;


--
-- Name: import; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.import (
    id integer NOT NULL,
    im_timestamp timestamp without time zone DEFAULT now() NOT NULL,
    fk_id_series integer NOT NULL,
    im_status text DEFAULT 'p'::text
);


--
-- Name: TABLE import; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.import IS 'Journal des imports';


--
-- Name: COLUMN import.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.import.id IS 'Id';


--
-- Name: COLUMN import.im_timestamp; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.import.im_timestamp IS 'Import date';


--
-- Name: COLUMN import.fk_id_series; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.import.fk_id_series IS 'Series ID';


--
-- Name: COLUMN import.im_status; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.import.im_status IS 'Status of import : pending, validated';


--
-- Name: import_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.import_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: import_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.import_id_seq OWNED BY gobs.import.id;


--
-- Name: indicator; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.indicator (
    id integer NOT NULL,
    id_code text NOT NULL,
    id_label text NOT NULL,
    id_description text NOT NULL,
    id_date_format text DEFAULT 'day'::text NOT NULL,
    id_value_code text[] NOT NULL,
    id_value_name text[] NOT NULL,
    id_value_type text[] NOT NULL,
    id_value_unit text[] NOT NULL,
    id_paths text,
    id_category text,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE indicator; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.indicator IS 'Groups of observation data for decisional purpose. ';


--
-- Name: COLUMN indicator.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id IS 'ID';


--
-- Name: COLUMN indicator.id_code; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_code IS 'Short name';


--
-- Name: COLUMN indicator.id_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_label IS 'Title';


--
-- Name: COLUMN indicator.id_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_description IS 'Describes the indicator regarding its rôle inside the project.';


--
-- Name: COLUMN indicator.id_date_format; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_date_format IS 'Help to know what is the format for the date. Example : ‘year’';


--
-- Name: COLUMN indicator.id_value_code; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_value_code IS 'List of the codes of the vector dimensions. Ex : [‘pop_h’, ‘pop_f’]';


--
-- Name: COLUMN indicator.id_value_name; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_value_name IS 'List of the names of the vector dimensions. Ex : [‘population homme’, ‘population femme’]';


--
-- Name: COLUMN indicator.id_value_type; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_value_type IS 'Type of the stored values. Ex : ‘integer’ or ‘real’';


--
-- Name: COLUMN indicator.id_value_unit; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_value_unit IS 'Unit ot the store values. Ex : ‘inhabitants’ or ‘°C’';


--
-- Name: COLUMN indicator.id_paths; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_paths IS 'Paths given to help finding an indicator. They will be split up to fill the graph_node and r_indicator_node tables. If you need multiple paths, use | as a separator. Ex: Environment / Water resources | Measure / Physics / Water';


--
-- Name: COLUMN indicator.id_category; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.id_category IS 'Category of the indicator. Used to group several indicators by themes.';


--
-- Name: COLUMN indicator.created_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.created_at IS 'Creation timestamp';


--
-- Name: COLUMN indicator.updated_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.indicator.updated_at IS 'Last updated timestamp';


--
-- Name: indicator_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.indicator_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: indicator_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.indicator_id_seq OWNED BY gobs.indicator.id;


--
-- Name: metadata; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.metadata (
    id integer NOT NULL,
    me_version text NOT NULL,
    me_version_date date NOT NULL,
    me_status smallint NOT NULL
);


--
-- Name: TABLE metadata; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.metadata IS 'Metadata of the structure : version and date. Usefull for database structure and glossary data migrations between versions';


--
-- Name: COLUMN metadata.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.metadata.id IS 'Id of the version';


--
-- Name: COLUMN metadata.me_version; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.metadata.me_version IS 'Version. Ex: 1.0.2';


--
-- Name: COLUMN metadata.me_version_date; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.metadata.me_version_date IS 'Date of the version. Ex: 2019-06-01';


--
-- Name: COLUMN metadata.me_status; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.metadata.me_status IS 'Status of the version. 1 means active version, 0 means older version';


--
-- Name: metadata_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.metadata_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: metadata_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.metadata_id_seq OWNED BY gobs.metadata.id;


--
-- Name: observation; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.observation (
    id bigint NOT NULL,
    fk_id_series integer NOT NULL,
    fk_id_spatial_object bigint NOT NULL,
    fk_id_import integer NOT NULL,
    ob_value jsonb NOT NULL,
    ob_start_timestamp timestamp without time zone NOT NULL,
    ob_validation timestamp without time zone,
    ob_end_timestamp timestamp without time zone,
    ob_uid uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE observation; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.observation IS 'Les données brutes au format pivot ( indicateur, date, valeurs et entité spatiale, auteur, etc.)';


--
-- Name: COLUMN observation.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.id IS 'ID';


--
-- Name: COLUMN observation.fk_id_series; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.fk_id_series IS 'Series ID';


--
-- Name: COLUMN observation.fk_id_spatial_object; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.fk_id_spatial_object IS 'ID of the object in the spatial object table';


--
-- Name: COLUMN observation.fk_id_import; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.fk_id_import IS 'Import id';


--
-- Name: COLUMN observation.ob_value; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.ob_value IS 'Vector containing the measured or computed data values. Ex : [1543, 1637]';


--
-- Name: COLUMN observation.ob_start_timestamp; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.ob_start_timestamp IS 'Start timestamp of the observation data';


--
-- Name: COLUMN observation.ob_validation; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.ob_validation IS 'Date and time when the data has been validated (the corresponding import status has been changed from pending to validated). Can be used to find all observations not yet validated, with NULL values in this field.';


--
-- Name: COLUMN observation.ob_end_timestamp; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.ob_end_timestamp IS 'End timestamp of the observation data (optional)';


--
-- Name: COLUMN observation.ob_uid; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.ob_uid IS 'Observation uid: autogenerated unique identifier';


--
-- Name: COLUMN observation.created_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.created_at IS 'Creation timestamp';


--
-- Name: COLUMN observation.updated_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.observation.updated_at IS 'Last updated timestamp';


--
-- Name: observation_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.observation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: observation_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.observation_id_seq OWNED BY gobs.observation.id;


--
-- Name: project; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.project (
    id integer NOT NULL,
    pt_code text NOT NULL,
    pt_lizmap_project_key text,
    pt_label text NOT NULL,
    pt_description text,
    pt_indicator_codes text[],
    pt_groups text,
    pt_xmin real,
    pt_ymin real,
    pt_xmax real,
    pt_ymax real
);


--
-- Name: TABLE project; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.project IS 'List of projects, which represents a group of indicators';


--
-- Name: COLUMN project.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.id IS 'Unique identifier';


--
-- Name: COLUMN project.pt_code; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_code IS 'Project code. Ex: weather_data';


--
-- Name: COLUMN project.pt_lizmap_project_key; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_lizmap_project_key IS 'Lizmap project unique identifier (optional): repository_code~project_file_name. Ex: environment~weather';


--
-- Name: COLUMN project.pt_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_label IS 'Human readable label of the project. Ex: Weather data publication';


--
-- Name: COLUMN project.pt_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_description IS 'Description of the project.';


--
-- Name: COLUMN project.pt_indicator_codes; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_indicator_codes IS 'List of indicator codes available for this project';


--
-- Name: COLUMN project.pt_groups; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_groups IS 'List of groups of users which have access to the project and its indicators, separated by coma.';


--
-- Name: COLUMN project.pt_xmin; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_xmin IS 'Minimum longitude (X min) in EPSG:4326';


--
-- Name: COLUMN project.pt_ymin; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_ymin IS 'Minimum latitude (Y min) in EPSG:4326';


--
-- Name: COLUMN project.pt_xmax; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_xmax IS 'Maximum longitude (X max) in EPSG:4326';


--
-- Name: COLUMN project.pt_ymax; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project.pt_ymax IS 'Maximum latitude (Y max) in EPSG:4326';


--
-- Name: project_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.project_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.project_id_seq OWNED BY gobs.project.id;


--
-- Name: project_view; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.project_view (
    id integer NOT NULL,
    pv_label text NOT NULL,
    fk_id_project integer NOT NULL,
    pv_groups text,
    fk_id_spatial_layer integer,
    fk_so_unique_id text
);


--
-- Name: TABLE project_view; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.project_view IS 'Allow to filter the access on projects and relative data (indicators, observations, etc.) with a spatial object for a given list of user groups';


--
-- Name: COLUMN project_view.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project_view.id IS 'Unique identifier';


--
-- Name: COLUMN project_view.pv_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project_view.pv_label IS 'Label of the project view';


--
-- Name: COLUMN project_view.fk_id_project; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project_view.fk_id_project IS 'Project id (foreign key)';


--
-- Name: COLUMN project_view.pv_groups; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project_view.pv_groups IS 'List of user groups allowed to see observation data inside this project view spatial layer object. Use a coma separated value. Ex: "group_a, group_b"';


--
-- Name: COLUMN project_view.fk_id_spatial_layer; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project_view.fk_id_spatial_layer IS 'Spatial layer id (foreign key)';


--
-- Name: COLUMN project_view.fk_so_unique_id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.project_view.fk_so_unique_id IS 'Spatial object unique id (foreign key). Ex: AB1234. This references the object unique code, not the object integer id field';


--
-- Name: project_view_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.project_view_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: project_view_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.project_view_id_seq OWNED BY gobs.project_view.id;


--
-- Name: protocol; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.protocol (
    id integer NOT NULL,
    pr_code text NOT NULL,
    pr_label text NOT NULL,
    pr_description text NOT NULL
);


--
-- Name: TABLE protocol; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.protocol IS 'List of protocols';


--
-- Name: COLUMN protocol.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.protocol.id IS 'ID';


--
-- Name: COLUMN protocol.pr_code; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.protocol.pr_code IS 'Code';


--
-- Name: COLUMN protocol.pr_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.protocol.pr_label IS 'Name of the indicator';


--
-- Name: COLUMN protocol.pr_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.protocol.pr_description IS 'Description, including URLs to references and authors.';


--
-- Name: protocol_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.protocol_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: protocol_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.protocol_id_seq OWNED BY gobs.protocol.id;


--
-- Name: r_graph_edge; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.r_graph_edge (
    ge_parent_node integer NOT NULL,
    ge_child_node integer NOT NULL
);


--
-- Name: TABLE r_graph_edge; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.r_graph_edge IS 'Graph edges: relations between nodes';


--
-- Name: COLUMN r_graph_edge.ge_parent_node; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.r_graph_edge.ge_parent_node IS 'Parent node';


--
-- Name: COLUMN r_graph_edge.ge_child_node; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.r_graph_edge.ge_child_node IS 'Child node';


--
-- Name: r_indicator_node; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.r_indicator_node (
    fk_id_indicator integer NOT NULL,
    fk_id_node integer NOT NULL
);


--
-- Name: TABLE r_indicator_node; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.r_indicator_node IS 'Pivot table between indicators and nodes';


--
-- Name: COLUMN r_indicator_node.fk_id_indicator; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.r_indicator_node.fk_id_indicator IS 'Parent indicator';


--
-- Name: COLUMN r_indicator_node.fk_id_node; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.r_indicator_node.fk_id_node IS 'Parent node';


--
-- Name: series; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.series (
    id integer NOT NULL,
    fk_id_protocol integer NOT NULL,
    fk_id_actor integer NOT NULL,
    fk_id_indicator integer NOT NULL,
    fk_id_spatial_layer integer NOT NULL
);


--
-- Name: TABLE series; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.series IS 'Series of data';


--
-- Name: COLUMN series.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.series.id IS 'Id';


--
-- Name: COLUMN series.fk_id_protocol; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.series.fk_id_protocol IS 'Protocol';


--
-- Name: COLUMN series.fk_id_actor; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.series.fk_id_actor IS 'Actor, source of the observation data.';


--
-- Name: COLUMN series.fk_id_indicator; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.series.fk_id_indicator IS 'Indicator. The series is named after the indicator.';


--
-- Name: COLUMN series.fk_id_spatial_layer; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.series.fk_id_spatial_layer IS 'Spatial layer, mandatory. If needed, use a global spatial layer with only 1 object representing the global area.';


--
-- Name: series_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.series_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: series_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.series_id_seq OWNED BY gobs.series.id;


--
-- Name: spatial_layer; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.spatial_layer (
    id integer NOT NULL,
    sl_code text NOT NULL,
    sl_label text NOT NULL,
    sl_description text NOT NULL,
    sl_creation_date date DEFAULT '2018-06-28'::date NOT NULL,
    fk_id_actor integer NOT NULL,
    sl_geometry_type text NOT NULL
);


--
-- Name: TABLE spatial_layer; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.spatial_layer IS 'List the spatial layers, used to regroup the spatial data. Ex : cities, rivers, stations';


--
-- Name: COLUMN spatial_layer.sl_code; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_layer.sl_code IS 'Unique short code for the spatial layer';


--
-- Name: COLUMN spatial_layer.sl_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_layer.sl_label IS 'Label of the spatial layer';


--
-- Name: COLUMN spatial_layer.sl_description; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_layer.sl_description IS 'Description';


--
-- Name: COLUMN spatial_layer.sl_creation_date; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_layer.sl_creation_date IS 'Creation date';


--
-- Name: COLUMN spatial_layer.fk_id_actor; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_layer.fk_id_actor IS 'Source actor.';


--
-- Name: COLUMN spatial_layer.sl_geometry_type; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_layer.sl_geometry_type IS 'Type of geometry (POINT, POLYGON, MULTIPOLYGON, etc.)';


--
-- Name: spatial_layer_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.spatial_layer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: spatial_layer_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.spatial_layer_id_seq OWNED BY gobs.spatial_layer.id;


--
-- Name: spatial_object; Type: TABLE; Schema: gobs; Owner: -
--

CREATE TABLE gobs.spatial_object (
    id bigint NOT NULL,
    so_unique_id text NOT NULL,
    so_unique_label text NOT NULL,
    geom public.geometry(Geometry,4326) NOT NULL,
    fk_id_spatial_layer integer NOT NULL,
    so_valid_from date DEFAULT (now())::date NOT NULL,
    so_valid_to date,
    so_uid uuid DEFAULT public.uuid_generate_v4() NOT NULL,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    updated_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: TABLE spatial_object; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON TABLE gobs.spatial_object IS 'Contains all the spatial objects, caracterized by a geometry type and an entity';


--
-- Name: COLUMN spatial_object.id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.id IS 'ID';


--
-- Name: COLUMN spatial_object.so_unique_id; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.so_unique_id IS 'Unique code of each object in the spatial layer ( INSEE, tag, etc.)';


--
-- Name: COLUMN spatial_object.so_unique_label; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.so_unique_label IS 'Label of each spatial object. Ex : name of the city.';


--
-- Name: COLUMN spatial_object.geom; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.geom IS 'Geometry of the spatial object. Alway in EPSG:4326';


--
-- Name: COLUMN spatial_object.fk_id_spatial_layer; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.fk_id_spatial_layer IS 'Spatial layer';


--
-- Name: COLUMN spatial_object.so_valid_from; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.so_valid_from IS 'Date from which the spatial object is valid.';


--
-- Name: COLUMN spatial_object.so_valid_to; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.so_valid_to IS 'Date from which the spatial object is not valid. Optional: if not given, the spatial object is always valid';


--
-- Name: COLUMN spatial_object.so_uid; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.so_uid IS 'Spatial object uid: autogenerated unique identifier';


--
-- Name: COLUMN spatial_object.created_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.created_at IS 'Creation timestamp';


--
-- Name: COLUMN spatial_object.updated_at; Type: COMMENT; Schema: gobs; Owner: -
--

COMMENT ON COLUMN gobs.spatial_object.updated_at IS 'Last updated timestamp';


--
-- Name: spatial_object_id_seq; Type: SEQUENCE; Schema: gobs; Owner: -
--

CREATE SEQUENCE gobs.spatial_object_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: spatial_object_id_seq; Type: SEQUENCE OWNED BY; Schema: gobs; Owner: -
--

ALTER SEQUENCE gobs.spatial_object_id_seq OWNED BY gobs.spatial_object.id;


--
-- Name: actor id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.actor ALTER COLUMN id SET DEFAULT nextval('gobs.actor_id_seq'::regclass);


--
-- Name: actor_category id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.actor_category ALTER COLUMN id SET DEFAULT nextval('gobs.actor_category_id_seq'::regclass);


--
-- Name: application id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.application ALTER COLUMN id SET DEFAULT nextval('gobs.application_id_seq'::regclass);


--
-- Name: document id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.document ALTER COLUMN id SET DEFAULT nextval('gobs.document_id_seq'::regclass);


--
-- Name: glossary id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.glossary ALTER COLUMN id SET DEFAULT nextval('gobs.glossary_id_seq'::regclass);


--
-- Name: graph_node id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.graph_node ALTER COLUMN id SET DEFAULT nextval('gobs.graph_node_id_seq'::regclass);


--
-- Name: import id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.import ALTER COLUMN id SET DEFAULT nextval('gobs.import_id_seq'::regclass);


--
-- Name: indicator id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.indicator ALTER COLUMN id SET DEFAULT nextval('gobs.indicator_id_seq'::regclass);


--
-- Name: metadata id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.metadata ALTER COLUMN id SET DEFAULT nextval('gobs.metadata_id_seq'::regclass);


--
-- Name: observation id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.observation ALTER COLUMN id SET DEFAULT nextval('gobs.observation_id_seq'::regclass);


--
-- Name: project id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project ALTER COLUMN id SET DEFAULT nextval('gobs.project_id_seq'::regclass);


--
-- Name: project_view id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project_view ALTER COLUMN id SET DEFAULT nextval('gobs.project_view_id_seq'::regclass);


--
-- Name: protocol id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.protocol ALTER COLUMN id SET DEFAULT nextval('gobs.protocol_id_seq'::regclass);


--
-- Name: series id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.series ALTER COLUMN id SET DEFAULT nextval('gobs.series_id_seq'::regclass);


--
-- Name: spatial_layer id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.spatial_layer ALTER COLUMN id SET DEFAULT nextval('gobs.spatial_layer_id_seq'::regclass);


--
-- Name: spatial_object id; Type: DEFAULT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.spatial_object ALTER COLUMN id SET DEFAULT nextval('gobs.spatial_object_id_seq'::regclass);


--
-- Data for Name: actor; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.actor (id, a_label, a_description, a_email, id_category, a_login) FROM stdin;
1	IGN	French national geographical institute.	contact@ign.fr	1	ign
2	CIRAD	The French agricultural research and international cooperation organization	contact@cirad.fr	2	cirad
3	DREAL Bretagne	Direction régionale de l'environnement, de l'aménagement et du logement.	email@dreal.fr	1	dreal
4	Al	Al A.	al@al.al	3	al
5	Bob	Bob B.	bob@bob.bob	3	bob
6	John	John J.	jon@jon.jon	3	john
7	Mike	Mike M.	mik@mik.mik	3	mike
8	Phil	Phil P.	phi@phi.phi	3	phil
\.


--
-- Data for Name: actor_category; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.actor_category (id, ac_label, ac_description) FROM stdin;
1	Public organizations	Public organizations and stakeholders
2	Research centers	Public or private research centers
3	Individuals	Persons acting as a single individual
\.


--
-- Data for Name: application; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.application (id, ap_code, ap_label, ap_description, ap_default_values) FROM stdin;
\.


--
-- Data for Name: deleted_data_log; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.deleted_data_log (de_table, de_uid, de_timestamp) FROM stdin;
\.


--
-- Data for Name: document; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.document (id, do_uid, do_label, do_description, do_type, do_path, fk_id_indicator, created_at, updated_at) FROM stdin;
1	542aa72f-d1de-4810-97bb-208f2388698b	Illustration	Picture to use as the indicator illustration.	preview	hiker_position/preview/hiking.jpg	3	2022-10-11 08:30:18.012801	2022-10-11 08:50:01.248526
2	1a7f7323-6b18-46ed-a9fe-9efbe1f006a2	Hiking presentation	Presentation of hiking.	document	hiker_position/document/hiking_doc.txt	3	2022-10-11 08:30:18.012801	2022-10-11 08:50:01.248526
\.


--
-- Data for Name: glossary; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.glossary (id, gl_field, gl_code, gl_label, gl_description, gl_order) FROM stdin;
1	id_date_format	second	Second	Second resolution	1
2	id_date_format	minute	Minute	Minute resolution	2
3	id_date_format	hour	Hour	Hour resolution	3
4	id_date_format	day	Day	Day resolution	4
5	id_date_format	month	Month	Month resolution	5
6	id_date_format	year	Year	Year resolution	6
7	id_value_type	integer	Integer	Integer	1
8	id_value_type	real	Real	Real	2
9	id_value_type	text	Text	Text	3
10	id_value_type	date	Date	Date	4
11	id_value_type	timestamp	Timestamp	Timestamp	5
12	id_value_type	boolean	Boolean	Boolean	6
13	sl_geometry_type	point	Point	Simple point geometry	1
14	sl_geometry_type	multipoint	MultiPoint	Multi point geometry	2
15	sl_geometry_type	linestring	Linestring	Simple linestring geometry	3
16	sl_geometry_type	multilinestring	MultiLinestring	Multi linestring geometry	4
17	sl_geometry_type	polygon	Polygon	Simple polygon	5
18	sl_geometry_type	multipolygon	MultiPolygon	Multi Polygon geometry	6
19	im_status	P	Pending validation	Data has been imported but not yet validated by its owner	1
20	im_status	V	Validated data	Data has been validated and is visible to more users depending on their granted access	2
21	do_type	preview	Preview	Preview is an image defining the indicator	1
22	do_type	image	Image	Image	2
23	do_type	video	Video	Video	3
24	do_type	document	Document	Generic document like PDF, ODT, text files or archives	4
25	do_type	url	URL	URL pointing to the document	5
26	do_type	other	Other	Other type of document	6
\.


--
-- Data for Name: graph_node; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.graph_node (id, gn_label) FROM stdin;
1	ROOT
2	Environment
3	Water
4	Data | Physical and chemical conditions
7	Socio-eco
8	Demography
9	Population
11	Hiking
12	Tracks
15	Fauna
16	Species
\.


--
-- Data for Name: import; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.import (id, im_timestamp, fk_id_series, im_status) FROM stdin;
1	2022-10-05 14:53:51	1	P
2	2022-10-05 15:12:08	2	P
3	2022-10-05 15:12:14	2	P
4	2022-10-05 15:12:22	2	P
5	2022-10-05 15:12:30	2	P
6	2022-10-05 15:12:37	2	P
7	2022-10-05 15:12:43	2	P
8	2022-10-05 15:22:44	3	P
\.


--
-- Data for Name: indicator; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.indicator (id, id_code, id_label, id_description, id_date_format, id_value_code, id_value_name, id_value_type, id_value_unit, id_paths, id_category, created_at, updated_at) FROM stdin;
1	pluviometry	Hourly pluviometry 	Hourly rainfall pluviometry in millimetre	hour	{pluviometry}	{Pluviometry}	{real}	{mm}	Environment / Water / Data | Physical and chemical conditions / Water 	Water	2022-10-05 16:03:24.479396	2022-10-05 16:03:24.479396
2	population	Population 	Number of inhabitants for city	year	{population}	{Population}	{integer}	{people}	Socio-eco / Demography / Population 	Population	2022-10-05 16:03:24.479396	2022-10-05 16:03:24.479396
3	hiker_position	Hikers position	Position and altitude of hikers	second	{altitude}	{Altitude}	{integer}	{m}	Hiking / Tracks	Tracks	2022-10-05 16:03:24.479396	2022-10-05 16:03:24.479396
4	observation	Observations	Faunal observations in the field	second	{number,species}	{"Number of individuals","Observed species"}	{integer,text}	{ind,sp}	Environment / Fauna / Species	Species	2022-10-05 16:03:24.479396	2022-10-05 16:03:24.479396
\.


--
-- Data for Name: metadata; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.metadata (id, me_version, me_version_date, me_status) FROM stdin;
1	6.0.0	2022-10-05	1
\.


--
-- Data for Name: observation; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.observation (id, fk_id_series, fk_id_spatial_object, fk_id_import, ob_value, ob_start_timestamp, ob_validation, ob_end_timestamp, ob_uid, created_at, updated_at) FROM stdin;
1	1	12	1	[0.200000003]	2019-06-16 09:00:00	\N	\N	b22a913e-e6e7-4b15-a875-3448132316c9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2	1	11	1	[0]	2019-06-16 09:00:00	\N	\N	d77d6adf-ded0-43d6-931c-ef0c3a4843ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3	1	10	1	[0.200000003]	2019-06-16 09:00:00	\N	\N	3d520657-d9ec-4315-aedc-d1dd5833732b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
4	1	9	1	[0]	2019-06-16 09:00:00	\N	\N	eb253858-d2ed-4368-bbd3-d5d91a784b38	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
5	1	8	1	[1.20000005]	2019-06-16 09:00:00	\N	\N	97bb3272-63dc-4154-bcec-9ff359a84425	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
6	1	12	1	[0]	2019-06-16 10:00:00	\N	\N	b00ab0db-1842-460a-8548-0f729d8852a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
7	1	11	1	[0]	2019-06-16 10:00:00	\N	\N	0a70a7cc-f28b-4ede-8f3a-70c3e5fbfae1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
8	1	10	1	[0]	2019-06-16 10:00:00	\N	\N	b610ed72-0df7-47ca-85cf-39fc83d36839	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
9	1	9	1	[0]	2019-06-16 10:00:00	\N	\N	ad1311de-d3f1-4cfc-b019-3231730eef5f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
10	1	8	1	[0.400000006]	2019-06-16 10:00:00	\N	\N	9f3a2f6b-7218-4ac2-9fa5-40819c3db85f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
11	1	12	1	[0.200000003]	2019-06-16 11:00:00	\N	\N	d6a68377-6438-4ae8-9ffb-b8709b6acfa5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
12	1	11	1	[0]	2019-06-16 11:00:00	\N	\N	345a5ec4-90ce-4349-b757-df4e57cb34d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
13	1	10	1	[0]	2019-06-16 11:00:00	\N	\N	49e25476-1ecb-4902-bc6a-e3922d2a968b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
14	1	9	1	[0]	2019-06-16 11:00:00	\N	\N	e5b316f7-7d9b-45f9-a81b-c855e0b01726	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
15	1	8	1	[0]	2019-06-16 11:00:00	\N	\N	1eb316b0-2fa2-4eae-ab2f-0bd94713cd9e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
16	1	12	1	[0]	2019-06-16 12:00:00	\N	\N	4268cbea-37c3-419b-a0eb-6c4a06c939df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
17	1	11	1	[0]	2019-06-16 12:00:00	\N	\N	c56dcb7b-b80a-46f3-965d-d6b719dae0d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
18	1	10	1	[0]	2019-06-16 12:00:00	\N	\N	bc021e54-e129-4f49-9a99-ea7a247ec47a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
19	1	9	1	[0]	2019-06-16 12:00:00	\N	\N	0b1fa534-521b-406d-8577-917a837afd97	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
20	1	8	1	[0]	2019-06-16 12:00:00	\N	\N	6538f18e-d015-4e4d-853b-56a3d636f4a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
21	1	12	1	[0]	2019-06-16 13:00:00	\N	\N	212f8d5f-1e6e-435c-9daa-c949f50e2866	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
22	1	11	1	[0]	2019-06-16 13:00:00	\N	\N	b2076b09-39db-43c5-8d71-e040be3bac6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
23	1	10	1	[0]	2019-06-16 13:00:00	\N	\N	f0cfa39f-28dc-4d79-a130-03308146b98f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
24	1	9	1	[0]	2019-06-16 13:00:00	\N	\N	c6b9c5a0-9ef9-40a6-83a8-68ce8dc7b5c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
25	1	8	1	[0.200000003]	2019-06-16 13:00:00	\N	\N	8a409ae5-a0a1-4b8d-85f1-625df4dcce7e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
26	1	12	1	[0]	2019-06-16 14:00:00	\N	\N	aa2b441b-6628-4e50-94b1-fc92219f526a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
27	1	11	1	[0]	2019-06-16 14:00:00	\N	\N	f86a1481-5d8d-40c5-b4a7-2e25ef7449c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
28	1	10	1	[0.200000003]	2019-06-16 14:00:00	\N	\N	79deeb3a-6baa-447a-8ecd-798a5950c34d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
29	1	9	1	[0]	2019-06-16 14:00:00	\N	\N	2820cafa-9e4d-4169-8a11-5c51ada7ce47	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
30	1	8	1	[0.200000003]	2019-06-16 14:00:00	\N	\N	ae549bdc-028d-4a0a-86ab-86c2b222daef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
31	1	12	1	[0]	2019-06-16 15:00:00	\N	\N	8663106c-d6b8-4ace-b042-6b111c643e8a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
32	1	11	1	[0]	2019-06-16 15:00:00	\N	\N	8c74c25b-2069-43e5-8fe5-23b375b5fb0b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
33	1	10	1	[0]	2019-06-16 15:00:00	\N	\N	24513d96-082f-49f0-84bb-9d0af73b62d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
34	1	9	1	[0]	2019-06-16 15:00:00	\N	\N	aa3d1211-f008-447a-bc0d-f24e806d175b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
35	1	8	1	[0]	2019-06-16 15:00:00	\N	\N	be158e78-0be6-4fa8-ae5b-41493781f94c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
36	1	12	1	[0]	2019-06-16 16:00:00	\N	\N	b2c18b28-4339-4fd3-922f-5009b1232b77	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
37	1	11	1	[0]	2019-06-16 16:00:00	\N	\N	ee12e2ae-0684-4c4e-a675-86c42d61c74b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
38	1	10	1	[0]	2019-06-16 16:00:00	\N	\N	35d6b98f-aef4-4675-a346-d99d5c4a24c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
39	1	9	1	[0]	2019-06-16 16:00:00	\N	\N	aaae4dea-8fd4-4dcd-8e51-966c8cad6bec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
40	1	8	1	[0]	2019-06-16 16:00:00	\N	\N	737bc474-0fd8-4a09-aec7-d973602c804a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
41	1	12	1	[0]	2019-06-16 17:00:00	\N	\N	30ac0c2f-d6fc-4f25-acef-fec84fd0d5a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
42	1	11	1	[0]	2019-06-16 17:00:00	\N	\N	92340a2c-cbff-48f8-b9ac-b65082af6786	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
43	1	10	1	[0]	2019-06-16 17:00:00	\N	\N	9830f88e-aba8-476a-afaf-1faf57739a2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
44	1	9	1	[0]	2019-06-16 17:00:00	\N	\N	4288284e-2ac0-41b5-b4d7-3a1f2558105f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
45	1	8	1	[0]	2019-06-16 17:00:00	\N	\N	0566df11-6a89-41c3-8450-3e120b86cc50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
46	1	12	1	[0]	2019-06-16 18:00:00	\N	\N	f9db0976-d084-47b9-9818-067cacc33942	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
47	1	11	1	[0]	2019-06-16 18:00:00	\N	\N	b9743000-aae7-4499-a602-e7dd240baedd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
48	1	10	1	[0]	2019-06-16 18:00:00	\N	\N	37d307d3-2e8f-4ed6-8417-44b32331e07c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
49	1	9	1	[0]	2019-06-16 18:00:00	\N	\N	9da6a737-982c-4abe-b68d-8c9aa3179350	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
50	1	8	1	[0]	2019-06-16 18:00:00	\N	\N	ce83e5be-c334-4180-85ad-54f20ecff28e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
51	1	12	1	[0]	2019-06-16 19:00:00	\N	\N	6c90bed1-149b-4383-9530-3a6abbad46a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
52	1	11	1	[0]	2019-06-16 19:00:00	\N	\N	3e78846f-01f1-4b37-9afb-bcac01e1286a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
53	1	10	1	[0]	2019-06-16 19:00:00	\N	\N	e039742b-7fcf-49ad-be70-88e64aa7b3fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
54	1	9	1	[0]	2019-06-16 19:00:00	\N	\N	d0ea37db-1a41-4fe1-b41a-367fb98f1ba2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
55	1	8	1	[0]	2019-06-16 19:00:00	\N	\N	1b98f6fb-34dc-42eb-914b-4715bfc501f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
56	1	12	1	[0]	2019-06-16 20:00:00	\N	\N	3489ac28-5ae0-46f4-8b56-28bbe9b36441	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
57	1	11	1	[0]	2019-06-16 20:00:00	\N	\N	30cd5864-8040-412b-8e47-f2d87e77f49f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
58	1	10	1	[0]	2019-06-16 20:00:00	\N	\N	63276d64-2a04-42cb-8a4d-31790b66737a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
59	1	9	1	[0]	2019-06-16 20:00:00	\N	\N	7848f5e6-6395-443d-8320-1a70a9ebfeb4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
60	1	8	1	[0]	2019-06-16 20:00:00	\N	\N	d9e87963-743f-4671-b23b-7b3599621ca0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
61	1	12	1	[0]	2019-06-16 21:00:00	\N	\N	6cf5a47b-4340-4548-bf10-5e1f368d2c01	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
62	1	11	1	[0]	2019-06-16 21:00:00	\N	\N	fe5c8c2c-098a-4f03-8060-30842bf86aaa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
63	1	10	1	[0]	2019-06-16 21:00:00	\N	\N	ce0c408d-6806-4eda-aca0-c36708edd6fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
64	1	9	1	[0]	2019-06-16 21:00:00	\N	\N	11d5e9b0-6e34-49b5-a354-753e352862f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
65	1	8	1	[0]	2019-06-16 21:00:00	\N	\N	64eea6d8-40fa-4627-a95b-5f6d26f52ed2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
66	1	12	1	[0]	2019-06-16 22:00:00	\N	\N	ba0aae35-b5ff-4977-85c1-2377ded8725b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
67	1	11	1	[0]	2019-06-16 22:00:00	\N	\N	572fd367-47bf-4a1c-83c1-f6d2e3f6d9f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
68	1	10	1	[0]	2019-06-16 22:00:00	\N	\N	01b017fe-79d6-4400-99b0-23ad247e2f46	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
69	1	9	1	[0]	2019-06-16 22:00:00	\N	\N	23a2c6de-9e6b-446a-9d23-72832d1e0575	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
70	1	8	1	[0]	2019-06-16 22:00:00	\N	\N	70c8eceb-a16b-469f-b133-7829212eb862	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
71	1	12	1	[0]	2019-06-16 23:00:00	\N	\N	234c4428-0cb1-4210-855b-66d7d0671430	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
72	1	11	1	[0]	2019-06-16 23:00:00	\N	\N	665e889c-3ec7-44de-bfb9-8b99cb5dee0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
73	1	10	1	[0]	2019-06-16 23:00:00	\N	\N	dae96458-4ff8-4ac3-8908-de116b75bff7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
74	1	9	1	[0]	2019-06-16 23:00:00	\N	\N	938a8c9e-c852-434e-abaf-4f7b041af6c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
75	1	8	1	[0]	2019-06-16 23:00:00	\N	\N	63b326b6-267d-4f1c-b2d5-4a95d6bf6fb7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
76	1	12	1	[0]	2019-06-17 00:00:00	\N	\N	845f63eb-81aa-440d-a835-09a7963ab71e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
77	1	11	1	[0]	2019-06-17 00:00:00	\N	\N	78f69747-bc5a-423e-b246-c79644a3915b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
78	1	10	1	[0]	2019-06-17 00:00:00	\N	\N	a21c731b-0afd-4f34-8bcd-806607107e32	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
79	1	9	1	[0]	2019-06-17 00:00:00	\N	\N	451b6b46-22f3-423d-b565-e7206f5e051b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
80	1	8	1	[0]	2019-06-17 00:00:00	\N	\N	7cf764b9-bc0d-46ac-b24f-ba34c26cf48a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
81	1	12	1	[0]	2019-06-17 01:00:00	\N	\N	84c50bc9-e047-415a-bd36-fa4105cc5b88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
82	1	11	1	[0]	2019-06-17 01:00:00	\N	\N	d8c9574c-fc48-409c-97a6-5e9b55452e29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
83	1	10	1	[0]	2019-06-17 01:00:00	\N	\N	267a7bd2-365b-4799-9a3d-20bda8c43db8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
84	1	9	1	[0]	2019-06-17 01:00:00	\N	\N	9c57e5b0-79d2-4fb0-9c8c-ec34a51505ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
85	1	8	1	[0]	2019-06-17 01:00:00	\N	\N	6770dff3-42b7-48d1-a73f-a7d8107ffcfd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
86	1	12	1	[0]	2019-06-17 02:00:00	\N	\N	09a0508e-f046-4dd3-86ab-696ab9b1f201	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
87	1	11	1	[0]	2019-06-17 02:00:00	\N	\N	7836b4c6-9892-42bf-9a97-155eccacb1ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
88	1	10	1	[0]	2019-06-17 02:00:00	\N	\N	b10c98ef-f638-455b-8e1c-be61ba8d0336	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
89	1	9	1	[0]	2019-06-17 02:00:00	\N	\N	39297753-9232-439d-8662-c73e8bde3c5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
90	1	8	1	[0]	2019-06-17 02:00:00	\N	\N	e6aa0452-1c4a-437f-82c2-ef7d363fd34d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
91	1	12	1	[0]	2019-06-17 03:00:00	\N	\N	e76d3347-8568-4807-ad2a-fce547cf5f65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
92	1	11	1	[0]	2019-06-17 03:00:00	\N	\N	295af03c-9aae-4aff-8bd9-6fb70c14743b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
93	1	10	1	[0]	2019-06-17 03:00:00	\N	\N	b650271a-881f-48a4-94b1-89a76d4617be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
94	1	9	1	[0]	2019-06-17 03:00:00	\N	\N	9dd7a82b-6b58-40be-bca5-ea1dfae99335	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
95	1	8	1	[0]	2019-06-17 03:00:00	\N	\N	3c908a2c-2f4c-44d5-8e77-eac50cfd0172	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
96	1	12	1	[0]	2019-06-17 04:00:00	\N	\N	da7baeab-72f2-45d8-9537-e3d66c669810	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
97	1	11	1	[0]	2019-06-17 04:00:00	\N	\N	8b41025e-f26f-4546-8dd3-1f9973df9d81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
98	1	10	1	[0]	2019-06-17 04:00:00	\N	\N	d11dceb5-7f6a-4441-ba90-2c056ef83bb7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
99	1	9	1	[0]	2019-06-17 04:00:00	\N	\N	036c57f3-e8bf-4070-b264-6e3eaaac3736	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
100	1	8	1	[0]	2019-06-17 04:00:00	\N	\N	81908e45-7f86-4986-85ed-16081f43564f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
101	1	12	1	[0]	2019-06-17 05:00:00	\N	\N	ac4e01a9-e8c0-478d-8727-c6a23e345382	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
102	1	11	1	[0]	2019-06-17 05:00:00	\N	\N	655a4883-5efd-4ad1-92b3-9c4675e1ac83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
103	1	10	1	[0]	2019-06-17 05:00:00	\N	\N	fc53bbd3-6612-4ac0-b093-65b4d2fb2f3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
104	1	9	1	[0]	2019-06-17 05:00:00	\N	\N	3a3d92aa-06c3-4111-ae80-075a0893f312	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
105	1	8	1	[0]	2019-06-17 05:00:00	\N	\N	a2a07a36-4e83-4569-82a5-d3979c371a31	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
106	1	12	1	[0]	2019-06-17 06:00:00	\N	\N	b6d0ea0d-91c8-460f-9ddd-a70313d2278e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
107	1	11	1	[0]	2019-06-17 06:00:00	\N	\N	4df995d0-cdd5-4d38-a802-12c0ef714da1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
108	1	10	1	[0]	2019-06-17 06:00:00	\N	\N	e02aabb7-f79b-4440-862f-78afc502ac93	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
109	1	9	1	[0]	2019-06-17 06:00:00	\N	\N	744e83e8-9f1f-480e-b1ff-cbadf6592de6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
110	1	8	1	[0]	2019-06-17 06:00:00	\N	\N	1f14bd21-efbb-42ea-8b40-34b6bcaafb96	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
111	1	12	1	[0]	2019-06-17 07:00:00	\N	\N	98f2367c-5eb6-4622-a884-63b3a4ea2856	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
112	1	11	1	[0]	2019-06-17 07:00:00	\N	\N	4fcd6788-69f8-4e1e-8659-6bcd57bc5568	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
113	1	10	1	[0]	2019-06-17 07:00:00	\N	\N	b197272d-f9bc-47ef-9545-241a7734208a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
114	1	9	1	[0]	2019-06-17 07:00:00	\N	\N	6f734a93-f502-42e2-8700-d82472a43eb6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
115	1	8	1	[0]	2019-06-17 07:00:00	\N	\N	3964548d-d3b9-4c43-99e2-ce05f8d0922c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
116	1	12	1	[0]	2019-06-17 08:00:00	\N	\N	51903a55-d563-4173-aab9-de0871e2d09f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
117	1	11	1	[0]	2019-06-17 08:00:00	\N	\N	8e5bc5f7-0d93-45f6-b03b-70779946f1e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
118	1	10	1	[0]	2019-06-17 08:00:00	\N	\N	d4ebd128-a646-4210-81ba-a9fe7490c212	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
119	1	9	1	[0]	2019-06-17 08:00:00	\N	\N	4faeff3b-8600-4106-817e-de88f5f77eab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
120	1	8	1	[0]	2019-06-17 08:00:00	\N	\N	88c25caa-cfd4-46d5-8298-7bc6ff0828e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
121	1	12	1	[0]	2019-06-17 09:00:00	\N	\N	6092caa8-c7b8-407d-84c8-d97ff7515f7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
122	1	11	1	[0]	2019-06-17 09:00:00	\N	\N	11ba1f77-f4db-45a4-8fd9-3fb4037b8012	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
123	1	10	1	[0]	2019-06-17 09:00:00	\N	\N	ba76a622-efaa-4a58-bb8b-33c712431182	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
124	1	9	1	[0]	2019-06-17 09:00:00	\N	\N	c9bd9619-62b9-4fa6-9032-b553cb0b492f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
125	1	8	1	[0]	2019-06-17 09:00:00	\N	\N	632620db-04ac-4081-8f8f-6b3425222e0d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
126	1	12	1	[0]	2019-06-17 10:00:00	\N	\N	3228509f-1bd6-4783-9969-eed96a0912f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
127	1	11	1	[0]	2019-06-17 10:00:00	\N	\N	d329bdb9-0e51-4a08-b3b2-ddaca9a4f14c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
128	1	10	1	[0]	2019-06-17 10:00:00	\N	\N	999a70f2-f2ac-4799-887f-a9163fa23204	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
129	1	9	1	[0]	2019-06-17 10:00:00	\N	\N	f0a72a0f-b10f-438c-b4ef-4df6e3c2dbf4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
130	1	8	1	[0]	2019-06-17 10:00:00	\N	\N	986da64e-fcd0-472a-aae3-efd56e5428aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
131	1	12	1	[0]	2019-06-17 11:00:00	\N	\N	9fb33271-8aec-4f78-8954-218b14e8cf21	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
132	1	11	1	[0]	2019-06-17 11:00:00	\N	\N	397c7922-f100-4321-b862-46daf3c1644c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
133	1	10	1	[0]	2019-06-17 11:00:00	\N	\N	12a809e2-c882-4023-9d38-fdb5e160adfb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
134	1	9	1	[0]	2019-06-17 11:00:00	\N	\N	9658d963-9059-4a66-bf7a-41eed9a04d4f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
135	1	8	1	[0]	2019-06-17 11:00:00	\N	\N	c05147ed-ac40-48a1-add0-ee1e38e3b465	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
136	1	12	1	[0]	2019-06-17 12:00:00	\N	\N	bda1db44-40b0-4e22-805f-eebacb772782	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
137	1	11	1	[0]	2019-06-17 12:00:00	\N	\N	586990f7-3810-465c-9692-6ef67e97b26d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
138	1	10	1	[0]	2019-06-17 12:00:00	\N	\N	0ce7e092-5234-4b8d-b53e-5ab5108e2d55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
139	1	9	1	[0]	2019-06-17 12:00:00	\N	\N	18d5885d-7df7-4eb6-ade2-e6b889f28d97	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
140	1	8	1	[0]	2019-06-17 12:00:00	\N	\N	94607bfc-53bd-49a7-a5ed-8fefd3325dae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
141	1	12	1	[0]	2019-06-17 13:00:00	\N	\N	454b9e33-6dbd-456a-b26b-beb46e001a4f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
142	1	11	1	[0]	2019-06-17 13:00:00	\N	\N	3a8a6a9e-ef40-43ef-a856-d57df08a56a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
143	1	10	1	[0]	2019-06-17 13:00:00	\N	\N	feaeac28-dc3e-4d9a-896b-cee6c0378fc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
144	1	9	1	[0]	2019-06-17 13:00:00	\N	\N	8d6cfc8a-2a78-4256-99d8-4810f0f13613	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
145	1	8	1	[0]	2019-06-17 13:00:00	\N	\N	1d914cca-ab2f-4c8c-8b86-0dd70baa3618	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
146	1	12	1	[0]	2019-06-17 14:00:00	\N	\N	aa8145ef-a77b-4bd8-b251-40efc9b9c39b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
147	1	11	1	[0]	2019-06-17 14:00:00	\N	\N	98df5a2f-eaaa-4702-921a-660344c2e42a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
148	1	10	1	[0]	2019-06-17 14:00:00	\N	\N	56a6e2bd-53f8-4718-8cb7-5854de089884	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
149	1	9	1	[0]	2019-06-17 14:00:00	\N	\N	68b17f75-a1ad-40e7-bdea-3747da0244cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
150	1	8	1	[0]	2019-06-17 14:00:00	\N	\N	3fab02ed-0cc3-4dae-8b4c-ed50866f3feb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
151	1	12	1	[0]	2019-06-17 15:00:00	\N	\N	18503846-3af6-49c7-9543-a848788c0059	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
152	1	11	1	[0]	2019-06-17 15:00:00	\N	\N	55641ba0-1473-4d6d-9d99-3fd79402f1ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
153	1	10	1	[0]	2019-06-17 15:00:00	\N	\N	0079a053-3225-423c-a2bb-0cf3f7008c7b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
154	1	9	1	[0]	2019-06-17 15:00:00	\N	\N	068ff99a-76c0-4c74-a95b-9bdaeae96b40	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
155	1	8	1	[0]	2019-06-17 15:00:00	\N	\N	5e72c1d0-5fd9-49a6-b7fe-00a3bcf8241f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
156	1	12	1	[0]	2019-06-17 16:00:00	\N	\N	842a26e5-32b9-4cad-83a3-c98fa6da4590	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
157	1	11	1	[0]	2019-06-17 16:00:00	\N	\N	f9fed646-0e68-4913-855b-330216b7c908	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
158	1	10	1	[0]	2019-06-17 16:00:00	\N	\N	32b0514e-4737-45a6-aece-affcc4e98efb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
159	1	9	1	[0]	2019-06-17 16:00:00	\N	\N	5d0e97ee-5d03-4653-bb3f-3a400b80167f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
160	1	8	1	[0]	2019-06-17 16:00:00	\N	\N	ec673f4d-9a4e-42d4-94e5-1a9b4ad6ef81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
161	1	12	1	[0]	2019-06-17 17:00:00	\N	\N	98657e04-05b6-41f6-a39e-cb785263d8ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
162	1	11	1	[0]	2019-06-17 17:00:00	\N	\N	73f9994f-a97a-43f4-a89f-a89f38ec4bce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
163	1	10	1	[0]	2019-06-17 17:00:00	\N	\N	092c6664-5cf0-4bbe-99cd-1a41aef29617	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
164	1	9	1	[0]	2019-06-17 17:00:00	\N	\N	6964361a-a060-4153-bc43-01835790ca67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
165	1	8	1	[0]	2019-06-17 17:00:00	\N	\N	a4c2ed30-f633-46f3-9747-be96a7987e73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
166	1	12	1	[0]	2019-06-17 18:00:00	\N	\N	422aaf17-a9a4-4a78-bf2e-4f3d49f4fd5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
167	1	11	1	[0]	2019-06-17 18:00:00	\N	\N	fec56886-9c2b-4555-8c7b-aeb394c48fbb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
168	1	10	1	[0]	2019-06-17 18:00:00	\N	\N	f48b83f6-60d0-4374-86ac-33e6d7e7d624	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
169	1	9	1	[0]	2019-06-17 18:00:00	\N	\N	9ae8fff7-4547-4c6d-8a86-ba55816545ce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
170	1	8	1	[0]	2019-06-17 18:00:00	\N	\N	1a406469-6c93-4222-b272-49d661d7572c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
171	1	12	1	[0]	2019-06-17 19:00:00	\N	\N	5040e306-fe15-43db-809b-55e0968de323	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
172	1	11	1	[0]	2019-06-17 19:00:00	\N	\N	5ebf0950-75b2-4d0f-a448-30bbf7d8d579	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
173	1	10	1	[0]	2019-06-17 19:00:00	\N	\N	01f78d14-99b7-46c6-a89f-fbbbcb96236c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
174	1	9	1	[0]	2019-06-17 19:00:00	\N	\N	9ff801ff-d115-44c0-9e71-d0024049b2cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
175	1	8	1	[0]	2019-06-17 19:00:00	\N	\N	9f60ed6c-7a17-4ee0-891e-2801040f3c81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
176	1	12	1	[0]	2019-06-17 20:00:00	\N	\N	7d33b1e5-bc3b-44ed-8494-b741817cf768	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
177	1	11	1	[0]	2019-06-17 20:00:00	\N	\N	77bb76d8-b2a7-4a0a-ba65-38c07f47bf00	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
178	1	10	1	[0]	2019-06-17 20:00:00	\N	\N	6b1d18f6-f2d6-48c0-8f4b-524c17924f7d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
179	1	9	1	[0]	2019-06-17 20:00:00	\N	\N	5cdce0c5-38c2-417f-949b-847ab2a89a81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
180	1	8	1	[0]	2019-06-17 20:00:00	\N	\N	6007ca01-bdc7-4203-b404-a0fdfbc62826	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
181	1	12	1	[0]	2019-06-17 21:00:00	\N	\N	19f00557-1524-447a-9810-37262f66fe5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
182	1	11	1	[0]	2019-06-17 21:00:00	\N	\N	928f054f-4963-4be5-9b53-60f1d76695c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
183	1	10	1	[0]	2019-06-17 21:00:00	\N	\N	d0108cd4-3297-4ef3-9c5d-a1038dff4912	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
184	1	9	1	[0]	2019-06-17 21:00:00	\N	\N	d7c58266-8602-443b-ad15-6123fdac45e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
185	1	8	1	[0]	2019-06-17 21:00:00	\N	\N	8a44578e-2864-47e1-b2e0-8e25ea5519d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
186	1	12	1	[0]	2019-06-17 22:00:00	\N	\N	a8fcfbdc-f09c-4aea-8fba-21048bb009cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
187	1	11	1	[0]	2019-06-17 22:00:00	\N	\N	7372aa6c-7869-4726-ba3a-f5cccf616680	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
188	1	10	1	[0]	2019-06-17 22:00:00	\N	\N	a8f410de-70a7-450d-a993-627fe28da6f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
189	1	9	1	[0]	2019-06-17 22:00:00	\N	\N	6f1db9c8-ad3e-4787-bee2-6a9afed4210d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
190	1	8	1	[0]	2019-06-17 22:00:00	\N	\N	4f3d772f-0c5b-4976-bcfc-d9023e1bfa2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
191	1	12	1	[0]	2019-06-17 23:00:00	\N	\N	b1edd2b1-bf11-4c4b-ac51-4a1ecbad6bad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
192	1	11	1	[0]	2019-06-17 23:00:00	\N	\N	567655a3-84af-4507-8b76-9fd18671f578	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
193	1	10	1	[0]	2019-06-17 23:00:00	\N	\N	630479db-9c11-4532-9df7-2835ccc44470	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
194	1	9	1	[0]	2019-06-17 23:00:00	\N	\N	5d24b315-fa56-40ab-9525-708eb80373cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
195	1	8	1	[0]	2019-06-17 23:00:00	\N	\N	7eed45f1-c842-4ab6-bc34-a66799fd4786	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
196	1	12	1	[0]	2019-06-18 00:00:00	\N	\N	6e3ba411-6055-49b0-9a68-f4ff9af6ee51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
197	1	11	1	[0]	2019-06-18 00:00:00	\N	\N	e983284a-dbe0-4ecc-b489-552dc0e9b8eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
198	1	10	1	[0]	2019-06-18 00:00:00	\N	\N	ac6b901f-943e-410b-83cd-c6cbe8f27f75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
199	1	9	1	[0]	2019-06-18 00:00:00	\N	\N	eaca81c7-15b1-45de-909a-953775d968af	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
200	1	8	1	[0]	2019-06-18 00:00:00	\N	\N	9ccc80db-fbf5-4f10-8cf0-21a51e110207	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
201	1	12	1	[0]	2019-06-18 01:00:00	\N	\N	87cc22b3-344a-4007-a29c-40b7c1b710c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
202	1	11	1	[0]	2019-06-18 01:00:00	\N	\N	fc493387-f10b-4873-96e2-99e6e6c11085	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
203	1	10	1	[0]	2019-06-18 01:00:00	\N	\N	06a45c65-d07f-4795-8bad-b63389ce3cd6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
204	1	9	1	[0]	2019-06-18 01:00:00	\N	\N	2b59d11e-8aee-4c46-8a28-5126c881b3a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
205	1	8	1	[0]	2019-06-18 01:00:00	\N	\N	8f00dd81-d069-4805-9d76-2878875a075d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
206	1	12	1	[0]	2019-06-18 02:00:00	\N	\N	91dbdce8-eed0-4cba-991c-90a736067ccf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
207	1	11	1	[0]	2019-06-18 02:00:00	\N	\N	2fb0c683-7150-4349-95f0-f450dd650224	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
208	1	10	1	[0]	2019-06-18 02:00:00	\N	\N	62fece4f-2086-4e59-b0c8-a1e2334091b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
209	1	9	1	[0]	2019-06-18 02:00:00	\N	\N	41fead72-fccf-4d7f-a7cb-1dc2ea9430c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
210	1	8	1	[0]	2019-06-18 02:00:00	\N	\N	1d299526-22c1-4e84-90c1-e0d3e2e03dfa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
211	1	12	1	[0]	2019-06-18 03:00:00	\N	\N	6e446f0c-7309-44c2-9fca-1c2a4abfb93e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
212	1	11	1	[0]	2019-06-18 03:00:00	\N	\N	686461ce-d1c2-497d-96f5-3e175b91bf98	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
213	1	10	1	[0]	2019-06-18 03:00:00	\N	\N	9e9ec938-6cd8-4fd9-80f8-e9b74d0547bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
214	1	9	1	[0]	2019-06-18 03:00:00	\N	\N	c89868d8-265a-4d86-9b75-c1e0db577068	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
215	1	8	1	[0]	2019-06-18 03:00:00	\N	\N	3fd80635-f5c8-4063-8393-94affb48d7e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
216	1	12	1	[0]	2019-06-18 04:00:00	\N	\N	d404e628-2c3b-487b-87f9-948d886d7ca2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
217	1	11	1	[0]	2019-06-18 04:00:00	\N	\N	2ad032f9-2f12-48c2-8fce-44a3731ee1a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
218	1	10	1	[0]	2019-06-18 04:00:00	\N	\N	e2aadcf2-fbf8-4898-8195-1f153617219f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
219	1	9	1	[0]	2019-06-18 04:00:00	\N	\N	c63a7c98-a592-4bc4-9331-e48a693b3950	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
220	1	8	1	[0]	2019-06-18 04:00:00	\N	\N	4a1a7f1b-3ce5-4971-a3df-5e0bf62021b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
221	1	12	1	[0]	2019-06-18 05:00:00	\N	\N	0e538133-f1dd-4248-a5c5-e562d2df4f2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
222	1	11	1	[0]	2019-06-18 05:00:00	\N	\N	50643fec-f35b-449a-8894-ff6edbca202c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
223	1	10	1	[0]	2019-06-18 05:00:00	\N	\N	f7aa3fa3-c10e-46d3-8915-48632d28af47	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
224	1	9	1	[0]	2019-06-18 05:00:00	\N	\N	44486809-72ea-4014-b3d8-76efc564c868	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
225	1	8	1	[0]	2019-06-18 05:00:00	\N	\N	1c27af4e-0fbc-4a07-b937-6ba3ef836c0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
226	1	12	1	[0]	2019-06-18 06:00:00	\N	\N	e9d61ab2-8b5f-4353-870c-9e77c832edb8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
227	1	11	1	[0]	2019-06-18 06:00:00	\N	\N	3181c144-4004-4038-9acf-e8a3a545ff65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
228	1	10	1	[0]	2019-06-18 06:00:00	\N	\N	d58726a1-bdc6-4d13-bf68-286efb155cd4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
229	1	9	1	[0]	2019-06-18 06:00:00	\N	\N	4415224a-edb8-42ce-8fe7-d53008bf72bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
230	1	8	1	[0]	2019-06-18 06:00:00	\N	\N	886d6385-74a3-4bf5-b597-38a7d0016404	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
231	1	12	1	[0]	2019-06-18 07:00:00	\N	\N	e6c78884-c7bb-4a75-881b-9c9408cfe2c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
232	1	11	1	[0]	2019-06-18 07:00:00	\N	\N	c8ed8136-ccee-4215-88f9-cfeb8a70dc70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
233	1	10	1	[0]	2019-06-18 07:00:00	\N	\N	d9e2b868-8401-4195-929b-2c1e76c52e0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
234	1	9	1	[0]	2019-06-18 07:00:00	\N	\N	7310946a-20f2-4cc9-83c8-78909faaf124	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
235	1	8	1	[0]	2019-06-18 07:00:00	\N	\N	e2e76f2a-9c86-4ee6-a0ec-5f7ca11430bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
236	1	12	1	[0]	2019-06-18 08:00:00	\N	\N	9fd99d3e-b2e0-4362-8772-1811729fd133	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
237	1	11	1	[0]	2019-06-18 08:00:00	\N	\N	93748a61-7b5c-47ae-8965-33a8c28ce481	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
238	1	10	1	[0]	2019-06-18 08:00:00	\N	\N	698584ce-1e44-4fc1-be44-b50e01579152	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
239	1	9	1	[0.200000003]	2019-06-18 08:00:00	\N	\N	77f2a3bb-a89c-43ec-89f0-d0066b84cac7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
240	1	8	1	[0]	2019-06-18 08:00:00	\N	\N	0762a9e4-41be-4c42-82a2-d96a71e8676f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
241	1	12	1	[0]	2019-06-18 09:00:00	\N	\N	2f94b8f6-30df-4be5-978b-3984c3060273	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
242	1	11	1	[0]	2019-06-18 09:00:00	\N	\N	2a226bad-3bf9-4f1a-a81e-c0a489fb41cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
243	1	10	1	[0.200000003]	2019-06-18 09:00:00	\N	\N	3cf30c37-6edf-4889-9c9f-3070642f636a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
244	1	9	1	[0]	2019-06-18 09:00:00	\N	\N	d3954486-a459-4cc8-bc8f-c30dbf40d103	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
245	1	8	1	[0]	2019-06-18 09:00:00	\N	\N	86db69f4-708d-48fd-b9cf-7a990b90d5a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
246	1	12	1	[1]	2019-06-18 10:00:00	\N	\N	bd6b37dc-4c91-466f-aed3-208fe97e59de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
247	1	11	1	[0]	2019-06-18 10:00:00	\N	\N	12042d00-801a-4614-a82f-c8a2f9f98ed9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
248	1	10	1	[0.800000012]	2019-06-18 10:00:00	\N	\N	a1ac70a0-ac6d-47dc-8aaf-3e09295b204c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
249	1	9	1	[0.200000003]	2019-06-18 10:00:00	\N	\N	aedf955b-d59b-4b6b-b391-025cebba0411	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
250	1	8	1	[0.200000003]	2019-06-18 10:00:00	\N	\N	c72f0429-9568-46fa-8569-2b8938879f83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
251	1	12	1	[1.20000005]	2019-06-18 11:00:00	\N	\N	17c5d887-810a-40fc-a376-b428df79e4a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
252	1	11	1	[1.79999995]	2019-06-18 11:00:00	\N	\N	b1463501-1449-442b-9a27-fd7ac260a306	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
253	1	10	1	[0.400000006]	2019-06-18 11:00:00	\N	\N	e2819371-3a0a-4c9e-9607-052e96d71be7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
254	1	9	1	[1.20000005]	2019-06-18 11:00:00	\N	\N	bf97777a-6386-4734-bb51-90a30c348841	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
255	1	8	1	[0.200000003]	2019-06-18 11:00:00	\N	\N	0ee91bae-c503-4c22-ac3a-c2bb6438c748	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
256	1	12	1	[0.200000003]	2019-06-18 12:00:00	\N	\N	04b3d8e6-d3ab-4954-8109-842d8d589e85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
257	1	11	1	[0.400000006]	2019-06-18 12:00:00	\N	\N	55385a3d-2f82-4e1e-94df-ed8b43cff767	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
258	1	10	1	[0.400000006]	2019-06-18 12:00:00	\N	\N	ef9f465f-ceb0-4769-a43d-abce6bb49033	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
259	1	9	1	[0.600000024]	2019-06-18 12:00:00	\N	\N	65765d45-2bf9-4442-9b0b-f8ce3353eb50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
260	1	8	1	[0.400000006]	2019-06-18 12:00:00	\N	\N	9014c609-1d7c-40da-8976-df0a6fb39b67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
261	1	12	1	[0]	2019-06-18 13:00:00	\N	\N	6fd90168-d1c5-48d0-860f-504f358b3b75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
262	1	11	1	[0.200000003]	2019-06-18 13:00:00	\N	\N	a1542489-f880-4d37-adbc-f7c59db60330	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
263	1	10	1	[0]	2019-06-18 13:00:00	\N	\N	269c8871-4f3b-4629-800a-f113a1d1d398	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
264	1	9	1	[0.200000003]	2019-06-18 13:00:00	\N	\N	13768d09-5434-4f86-bb8f-cb617d4f72a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
265	1	8	1	[0]	2019-06-18 13:00:00	\N	\N	bbe76d6a-2fe4-4058-ae93-bc7b6d84b9c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
266	1	12	1	[0]	2019-06-18 14:00:00	\N	\N	2e16f7db-b6d1-468f-9aa7-4dd82a15e20f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
267	1	11	1	[0.200000003]	2019-06-18 14:00:00	\N	\N	4c4a7662-02f9-4f7d-9fb0-1063d62787be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
268	1	10	1	[0]	2019-06-18 14:00:00	\N	\N	4e0b8ba1-c6db-4ae2-8b3d-711762dd1650	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
269	1	9	1	[0]	2019-06-18 14:00:00	\N	\N	b31caf76-daab-460b-8949-1f9fa2aaec84	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
270	1	8	1	[0]	2019-06-18 14:00:00	\N	\N	96e73231-02a3-4c9b-b586-2709defc44ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
271	1	12	1	[0]	2019-06-18 15:00:00	\N	\N	65ecff5e-162a-485c-9a60-87e895ba09a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
272	1	11	1	[0]	2019-06-18 15:00:00	\N	\N	f223b390-e24a-44ec-ad1f-ff1c06fa4c08	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
273	1	10	1	[0]	2019-06-18 15:00:00	\N	\N	07409ccb-2d8a-4823-943e-6dbcc5de61b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
274	1	9	1	[0]	2019-06-18 15:00:00	\N	\N	2c758550-cca1-4d70-b6de-198690c4b2de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
275	1	8	1	[0]	2019-06-18 15:00:00	\N	\N	9dc475e2-1195-491e-8d10-b5fe6a5b4494	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
276	1	12	1	[0]	2019-06-18 16:00:00	\N	\N	afb2a2a8-9b71-4c75-9467-6ad01937eb78	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
277	1	11	1	[0]	2019-06-18 16:00:00	\N	\N	5b8d5e13-1398-43f1-ba42-9f5b3320bebe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
278	1	10	1	[0]	2019-06-18 16:00:00	\N	\N	b5caac62-51b3-4c9e-9e59-cf8bdbe6d6bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
279	1	9	1	[0]	2019-06-18 16:00:00	\N	\N	5e083e47-bdaf-4208-b56c-d7105f1651f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
280	1	8	1	[0]	2019-06-18 16:00:00	\N	\N	c25ded5c-6e7b-4e5c-a87b-df268f360e3b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
281	1	12	1	[0]	2019-06-18 17:00:00	\N	\N	fe8762f1-aa51-4e62-83eb-8c552fd2c50a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
282	1	11	1	[0]	2019-06-18 17:00:00	\N	\N	dacd1180-7a10-4ccd-b98a-131def37db74	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
283	1	10	1	[0]	2019-06-18 17:00:00	\N	\N	de49a89b-05b0-4f1b-8421-670da3fc13ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
284	1	9	1	[0]	2019-06-18 17:00:00	\N	\N	920733f1-4c96-4ba1-858c-0e33b50d6604	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
285	1	8	1	[0]	2019-06-18 17:00:00	\N	\N	cb33f2ed-bf4a-4c7a-8406-5b6f85de1484	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
286	1	12	1	[0]	2019-06-18 18:00:00	\N	\N	a608fb7d-1a1a-4ae2-ae95-a3382ccdb66f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
287	1	11	1	[0]	2019-06-18 18:00:00	\N	\N	f10d0512-b348-4125-8e6e-f083b5d4f443	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
288	1	10	1	[0]	2019-06-18 18:00:00	\N	\N	a9b2235c-ac07-4875-97a6-48f56a534afd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
289	1	9	1	[0]	2019-06-18 18:00:00	\N	\N	7fcee190-4a9f-4e36-9047-a56ccae9c128	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
290	1	8	1	[0]	2019-06-18 18:00:00	\N	\N	3287f4e8-0e68-4076-a4ea-130918ad37bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
291	1	12	1	[0]	2019-06-18 19:00:00	\N	\N	67476c01-8463-4ec3-be22-dc7d34910f39	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
292	1	11	1	[0]	2019-06-18 19:00:00	\N	\N	d0af5bdd-01a3-4335-81c2-0075c5ce99d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
293	1	10	1	[0]	2019-06-18 19:00:00	\N	\N	24809e25-6601-4f42-8502-be068cfeab55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
294	1	9	1	[0]	2019-06-18 19:00:00	\N	\N	e6f79eca-cf48-4c71-a52d-ec457f189091	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
295	1	8	1	[0]	2019-06-18 19:00:00	\N	\N	3aced84a-7609-42a6-817e-705ab9b26d93	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
296	1	12	1	[0]	2019-06-18 20:00:00	\N	\N	6f951037-922f-4157-940a-c87790deb8c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
297	1	11	1	[0]	2019-06-18 20:00:00	\N	\N	402fa8e2-3887-452c-a05d-8eb27c35fa4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
298	1	10	1	[0.200000003]	2019-06-18 20:00:00	\N	\N	c7eb325d-65e9-4a82-adc9-cff833d64d68	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
299	1	9	1	[0]	2019-06-18 20:00:00	\N	\N	ce095d25-0011-4da7-9d17-17b42868181d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
300	1	8	1	[0]	2019-06-18 20:00:00	\N	\N	b7bb030f-46c6-4d40-ac8c-e397150fa390	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
301	1	12	1	[0]	2019-06-18 21:00:00	\N	\N	5fedeeb1-845b-49d3-848b-35208696e41d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
302	1	11	1	[0]	2019-06-18 21:00:00	\N	\N	0399477d-4015-4696-bf60-4c506d8cc9a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
303	1	10	1	[0]	2019-06-18 21:00:00	\N	\N	c3c5c24e-21b4-4e46-94c7-2edf1fa36f02	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
304	1	9	1	[0]	2019-06-18 21:00:00	\N	\N	fa94a833-679b-4aef-87fa-b3411edc195b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
305	1	8	1	[0.200000003]	2019-06-18 21:00:00	\N	\N	c077fd0c-4d58-4911-a2e6-c4d5dfbe4895	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
306	1	12	1	[0]	2019-06-18 22:00:00	\N	\N	23c92d49-4df1-445e-9639-e0c8a29ba4ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
307	1	11	1	[0]	2019-06-18 22:00:00	\N	\N	4318f8f7-7e11-4b45-a208-bfe982b20f4a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
308	1	10	1	[0]	2019-06-18 22:00:00	\N	\N	31b88b09-dd85-481d-ac97-6a50926b225c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
309	1	9	1	[0]	2019-06-18 22:00:00	\N	\N	d2236ffd-2b51-4357-805a-7f87a9420112	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
310	1	8	1	[0]	2019-06-18 22:00:00	\N	\N	4a3a0d4f-092b-4131-b5f9-77a482c6c9f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
311	1	12	1	[0]	2019-06-18 23:00:00	\N	\N	66f2a50e-7e08-4b06-b6bd-30333634f0e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
312	1	11	1	[0]	2019-06-18 23:00:00	\N	\N	1ce5e81f-bba9-46a1-af31-778f4b006b89	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
313	1	10	1	[0]	2019-06-18 23:00:00	\N	\N	1affb826-d373-4852-bda2-a6c0023687ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
314	1	9	1	[0]	2019-06-18 23:00:00	\N	\N	81520a56-1963-4b7e-a7b7-0cdb9a60998e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
315	1	8	1	[0]	2019-06-18 23:00:00	\N	\N	17d3e1c5-8d89-42c4-b380-ad6a00cf3738	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
316	1	12	1	[0]	2019-06-19 00:00:00	\N	\N	1c09dfe8-33b7-41ee-9c7f-50096de25244	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
317	1	11	1	[0]	2019-06-19 00:00:00	\N	\N	c30bfbd1-e89a-476d-bf9e-f21e5c05c851	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
318	1	10	1	[0]	2019-06-19 00:00:00	\N	\N	a8b1e5cf-7ffc-43e6-b4ec-64dd3446459f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
319	1	9	1	[0]	2019-06-19 00:00:00	\N	\N	866b5f11-51a4-4cae-8889-55d2e983b820	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
320	1	8	1	[0]	2019-06-19 00:00:00	\N	\N	45bb4fbf-be5a-4f56-bb18-b623dcd3b9a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
321	1	12	1	[0]	2019-06-19 01:00:00	\N	\N	e5489e3b-710f-4319-b2c2-035634db7b85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
322	1	11	1	[0]	2019-06-19 01:00:00	\N	\N	05392e50-dda2-4038-ba0d-b8d38b019ac3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
323	1	10	1	[0]	2019-06-19 01:00:00	\N	\N	116ab703-dbc7-4cf6-a039-30a8889aba55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
324	1	9	1	[0]	2019-06-19 01:00:00	\N	\N	50003dd9-6844-42a9-82ad-64e9f015cee8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
325	1	8	1	[0]	2019-06-19 01:00:00	\N	\N	bc3e14a9-76df-45b2-a8e3-e5804255b78f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
326	1	12	1	[0]	2019-06-19 02:00:00	\N	\N	4954e0f4-a710-42b3-ae5e-c12ef90e9f5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
327	1	11	1	[0]	2019-06-19 02:00:00	\N	\N	92242d86-7d0f-4157-be2e-8cf7e7e9b4d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
328	1	10	1	[0]	2019-06-19 02:00:00	\N	\N	d00b705b-8a20-4ebe-a248-8970fbf37247	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
329	1	9	1	[0]	2019-06-19 02:00:00	\N	\N	660ead1e-2e3f-4abe-be16-12c6292cac1f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
330	1	8	1	[0]	2019-06-19 02:00:00	\N	\N	a48882b1-addd-4046-905d-967e29207559	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
331	1	12	1	[0.200000003]	2019-06-19 03:00:00	\N	\N	952afdbb-e50f-4d9e-9e10-ce70ec6d6a3f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
332	1	11	1	[0]	2019-06-19 03:00:00	\N	\N	182a6bbe-e77c-41e7-aafa-f3f7aa2f20c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
333	1	10	1	[0]	2019-06-19 03:00:00	\N	\N	8f9a303d-37eb-42a3-91aa-19dfd9bc24ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
334	1	9	1	[0]	2019-06-19 03:00:00	\N	\N	e5582fd6-cb5f-4f34-8904-504ed3b5ca36	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
335	1	8	1	[0]	2019-06-19 03:00:00	\N	\N	2e37fca1-125c-494c-9150-b043924665b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
336	1	12	1	[0.200000003]	2019-06-19 04:00:00	\N	\N	562c93a0-4898-40cf-b3be-3b85c16daec5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
337	1	11	1	[0]	2019-06-19 04:00:00	\N	\N	0be60c08-1804-4028-b5ab-999ad382ce15	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
338	1	10	1	[0]	2019-06-19 04:00:00	\N	\N	005a74d4-88da-4dee-8293-66805faa8220	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
339	1	9	1	[0]	2019-06-19 04:00:00	\N	\N	4894437e-2fab-44b5-b11e-7546634d3bdc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
340	1	8	1	[0.200000003]	2019-06-19 04:00:00	\N	\N	519dae97-9b39-455b-b8f6-fd4bd7bcc20e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
341	1	12	1	[0]	2019-06-19 05:00:00	\N	\N	a3efc3dd-8c38-470a-8a86-9a8db243940b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
342	1	11	1	[0]	2019-06-19 05:00:00	\N	\N	eba6594f-6a30-4e66-9fb5-2397710c7e8a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
343	1	10	1	[0]	2019-06-19 05:00:00	\N	\N	3ed7f58b-f291-4b81-a616-fe5de8944826	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
344	1	9	1	[0.200000003]	2019-06-19 05:00:00	\N	\N	2353e02e-16c7-4e8b-818f-a6fd7977298a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
345	1	8	1	[0]	2019-06-19 05:00:00	\N	\N	e8a4c61b-2230-4a2c-b202-d368b2e2f387	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
346	1	12	1	[0]	2019-06-19 06:00:00	\N	\N	f970b016-ce2b-46e4-a1d7-34e794529012	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
347	1	11	1	[0]	2019-06-19 06:00:00	\N	\N	eb9dce9e-b053-46f1-aae7-eb8826354548	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
348	1	10	1	[0]	2019-06-19 06:00:00	\N	\N	ee86bec0-bffc-4196-97b6-0894322d42e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
349	1	9	1	[0]	2019-06-19 06:00:00	\N	\N	a87478e9-de3f-44c7-b5b8-e71d9cf86197	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
350	1	8	1	[0]	2019-06-19 06:00:00	\N	\N	4769ec1a-aa65-490a-b9e1-2e6e06025571	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
351	1	12	1	[0]	2019-06-19 07:00:00	\N	\N	cad57af2-9fa8-4be3-af68-3ab8fd800370	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
352	1	11	1	[0]	2019-06-19 07:00:00	\N	\N	aabfbaac-583e-4580-8c84-19c3123b05fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
353	1	10	1	[0]	2019-06-19 07:00:00	\N	\N	1b96dc0f-6d68-4e0e-a057-f5992160860b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
354	1	9	1	[0]	2019-06-19 07:00:00	\N	\N	78f31717-9a07-4a85-bdd8-eb8b9dce7a5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
355	1	8	1	[0]	2019-06-19 07:00:00	\N	\N	08cd6438-396a-4cd4-9d87-738c9e4e62e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
356	1	12	1	[0]	2019-06-19 08:00:00	\N	\N	1f72421f-2ab3-498a-b053-41a9bd5b0978	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
357	1	11	1	[0.200000003]	2019-06-19 08:00:00	\N	\N	473721bc-1bf5-47ff-b6d1-aa797b8d0cf5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
358	1	10	1	[0.200000003]	2019-06-19 08:00:00	\N	\N	24c45cd0-8d01-41d4-ba1d-bd18bdc469f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
359	1	9	1	[0]	2019-06-19 08:00:00	\N	\N	2aa477aa-27d6-4457-a5dc-886dad7b49b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
360	1	8	1	[0]	2019-06-19 08:00:00	\N	\N	f496f12a-ebb5-4cab-a182-4bae6a8a8af5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
361	1	12	1	[0]	2019-06-19 09:00:00	\N	\N	26985225-1742-4443-95e1-66a8b4056728	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
362	1	11	1	[0.200000003]	2019-06-19 09:00:00	\N	\N	63300839-7ceb-4cbb-ba79-4fbb44d287da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
363	1	10	1	[0]	2019-06-19 09:00:00	\N	\N	5d9e6766-ee8e-43a6-953f-edd3f39484be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
364	1	9	1	[0]	2019-06-19 09:00:00	\N	\N	e089ba7f-ab0f-4b7f-831e-32b502e45842	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
365	1	8	1	[0]	2019-06-19 09:00:00	\N	\N	1ae72314-9c20-44c2-87ca-b04b4575bdb7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
366	1	12	1	[0]	2019-06-19 10:00:00	\N	\N	bc110f7a-a38f-42e0-af2d-42d100f41f54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
367	1	11	1	[0]	2019-06-19 10:00:00	\N	\N	e4f13c89-ad05-4ad0-a863-323921fc9b15	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
368	1	10	1	[0]	2019-06-19 10:00:00	\N	\N	cee712b6-2f4e-4a46-9908-0d47293d3ed7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
369	1	9	1	[0]	2019-06-19 10:00:00	\N	\N	cf7aa0e3-edaa-4e9e-acbc-88eb79199949	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
370	1	8	1	[0]	2019-06-19 10:00:00	\N	\N	1545e4d4-6754-41f5-9bd3-c15bca71e380	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
371	1	12	1	[0]	2019-06-19 11:00:00	\N	\N	5eb5425a-98fd-4d0b-9bbf-6f3cbade9f13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
372	1	11	1	[0]	2019-06-19 11:00:00	\N	\N	ecaf78b9-b86a-42e7-8e75-2761d7d18e96	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
373	1	10	1	[0]	2019-06-19 11:00:00	\N	\N	6de5e72f-fa6c-4d14-aeb1-cae776ff696f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
374	1	9	1	[0]	2019-06-19 11:00:00	\N	\N	e82aba5d-ab3c-4982-99bd-e4d8bb6dce1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
375	1	8	1	[0]	2019-06-19 11:00:00	\N	\N	b0fdec9d-740a-4970-b48d-6f74cb3dd5c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
376	1	12	1	[0.200000003]	2019-06-19 12:00:00	\N	\N	d273f73c-205a-4c2f-a07d-ea667225621a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
377	1	11	1	[0]	2019-06-19 12:00:00	\N	\N	13748cd1-110e-4a94-a305-01c55384cda7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
378	1	10	1	[0]	2019-06-19 12:00:00	\N	\N	31d77205-64b5-4816-a745-a1aec65858b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
379	1	9	1	[0]	2019-06-19 12:00:00	\N	\N	e6281cc8-2fe4-477e-9953-975b9ee85b66	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
380	1	8	1	[0]	2019-06-19 12:00:00	\N	\N	18ed0589-5670-4081-af31-f7402a431b13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
381	1	12	1	[0.600000024]	2019-06-19 13:00:00	\N	\N	065a0616-db59-48de-bb49-53aaa2ce4e9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
382	1	11	1	[0]	2019-06-19 13:00:00	\N	\N	34b3ae19-43e5-446d-9e26-4ffcd449ec23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
383	1	10	1	[0]	2019-06-19 13:00:00	\N	\N	7f8f19d4-9afd-40eb-ac1f-24617b6ca835	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
384	1	9	1	[0.400000006]	2019-06-19 13:00:00	\N	\N	662849e9-264c-4205-ad80-16dc51443103	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
385	1	8	1	[0.400000006]	2019-06-19 13:00:00	\N	\N	4988067d-2222-4d5d-a946-28118541827d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
386	1	12	1	[0]	2019-06-19 14:00:00	\N	\N	f3aa6486-63d1-48ae-9f88-9055ff12dbf2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
387	1	11	1	[0]	2019-06-19 14:00:00	\N	\N	92816609-3e9d-4361-93c0-c4a4f4165f73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
388	1	10	1	[0]	2019-06-19 14:00:00	\N	\N	a3d8c5ff-eaca-48d0-aa17-c1f693cf1c51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
389	1	9	1	[0]	2019-06-19 14:00:00	\N	\N	868ce767-fe6a-46e0-a283-72468b77327b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
390	1	8	1	[0]	2019-06-19 14:00:00	\N	\N	c9c47b2d-2778-4877-bbad-79cb96e8badb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
391	1	12	1	[0]	2019-06-19 15:00:00	\N	\N	b2925dc0-1494-42f4-a650-417c262ee143	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
392	1	11	1	[0]	2019-06-19 15:00:00	\N	\N	21eba534-86c1-4356-a161-8ab77439411c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
393	1	10	1	[0]	2019-06-19 15:00:00	\N	\N	abf859e9-aca6-4224-bb19-8a15c07964e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
394	1	9	1	[0]	2019-06-19 15:00:00	\N	\N	a09fb63d-cfd6-4ecc-acb1-c596dd85f697	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
395	1	8	1	[0]	2019-06-19 15:00:00	\N	\N	b8ac238c-ee45-4bbd-830a-69edf90c3c8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
396	1	12	1	[0]	2019-06-19 16:00:00	\N	\N	f1276709-64a5-496b-9915-45ad3f72c129	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
397	1	11	1	[0]	2019-06-19 16:00:00	\N	\N	6d1dd0f1-1e8d-4dbf-ae64-88c529543e48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
398	1	10	1	[0]	2019-06-19 16:00:00	\N	\N	4bb1ddb2-3779-4005-b4c3-f400846ecd19	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
399	1	9	1	[0]	2019-06-19 16:00:00	\N	\N	5346f94f-4271-4b4d-a3f5-c6d4ea5323c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
400	1	8	1	[0]	2019-06-19 16:00:00	\N	\N	5a5cbfe6-59e4-4b18-b997-01a18a0587b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
401	1	12	1	[0]	2019-06-19 17:00:00	\N	\N	4f05a0c0-81c4-414a-96c2-99e3cc068b47	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
402	1	11	1	[0.200000003]	2019-06-19 17:00:00	\N	\N	f36c8f97-cdc1-4654-928f-3fd6fa6fba18	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
403	1	10	1	[0]	2019-06-19 17:00:00	\N	\N	431ceab2-45f0-4162-8288-11df20fc55f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
404	1	9	1	[0]	2019-06-19 17:00:00	\N	\N	8be60873-7e18-4ee2-a585-94323c601bfc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
405	1	8	1	[0]	2019-06-19 17:00:00	\N	\N	200c4c4a-6c6a-40f1-b208-7e10e00cf81b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
406	1	12	1	[0]	2019-06-19 18:00:00	\N	\N	7b7df952-5e86-49d8-ae16-729e10f6e927	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
407	1	11	1	[0]	2019-06-19 18:00:00	\N	\N	c85d1983-e9cd-4947-8ead-c64a1287e3f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
408	1	10	1	[0]	2019-06-19 18:00:00	\N	\N	e989669c-4d26-49f9-9fe6-8b9ad8d0cfa5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
409	1	9	1	[0]	2019-06-19 18:00:00	\N	\N	fe591fba-b59e-4ec1-973c-97fdd856dfab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
410	1	8	1	[0]	2019-06-19 18:00:00	\N	\N	3b720fed-f1aa-47bf-89d5-4c8f50af872e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
411	1	12	1	[0]	2019-06-19 19:00:00	\N	\N	712523c9-3765-452a-9a5c-1ed282fb8aa2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
412	1	11	1	[0]	2019-06-19 19:00:00	\N	\N	51a2dd54-ce77-42f6-a3e8-007443e06dfe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
413	1	10	1	[0]	2019-06-19 19:00:00	\N	\N	e384cc3e-7591-4f03-91b1-25bf01afbb58	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
414	1	9	1	[0]	2019-06-19 19:00:00	\N	\N	bf08dd21-8e8e-489e-b6e9-23272e9b351c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
415	1	8	1	[0]	2019-06-19 19:00:00	\N	\N	e3cea461-03b3-48f2-821d-62475d29db0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
416	1	12	1	[0]	2019-06-19 20:00:00	\N	\N	aa5ea5ec-da26-460b-9326-45dbf7c231bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
417	1	11	1	[0]	2019-06-19 20:00:00	\N	\N	702f8102-7a35-408b-8f4b-3f821839dac1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
418	1	10	1	[0]	2019-06-19 20:00:00	\N	\N	e8b0fe66-63f9-4d5a-9d5f-fcbbadb517e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
419	1	9	1	[0]	2019-06-19 20:00:00	\N	\N	36a45e9e-b62c-460c-bfc0-c651cce485a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
420	1	8	1	[0]	2019-06-19 20:00:00	\N	\N	4c66738f-c90d-4cdc-b767-3a83d79f19d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
421	1	12	1	[0]	2019-06-19 21:00:00	\N	\N	2429c3f4-b3ba-455a-9e03-cb86b82bc5be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
422	1	11	1	[0]	2019-06-19 21:00:00	\N	\N	52b9bd28-7ade-431d-8a52-3c87b602fd5d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
423	1	10	1	[0]	2019-06-19 21:00:00	\N	\N	7e1d4e05-c62b-41f3-bfd4-94fd8108bd7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
424	1	9	1	[0]	2019-06-19 21:00:00	\N	\N	f4f0c35f-c245-48af-b77f-fc85716efc12	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
425	1	8	1	[0]	2019-06-19 21:00:00	\N	\N	8cad9dee-1d84-4ba3-92e1-89935fe662d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
426	1	12	1	[0]	2019-06-19 22:00:00	\N	\N	7d3f9b44-aafe-4be9-b7ae-54405bd5e869	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
427	1	11	1	[0]	2019-06-19 22:00:00	\N	\N	d5fd7ea9-b577-49e7-bdee-137447618c3b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
428	1	10	1	[0]	2019-06-19 22:00:00	\N	\N	50401b57-1bbb-4487-b5fd-0ca5460237c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
429	1	9	1	[0]	2019-06-19 22:00:00	\N	\N	35cb4d2b-d506-4e76-bbcf-eecb087c5e54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
430	1	8	1	[0]	2019-06-19 22:00:00	\N	\N	d71a9243-2e7c-4e94-b523-21d86a3c59c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
431	1	12	1	[0]	2019-06-19 23:00:00	\N	\N	829a26ed-f3b9-4968-8678-fe30773a71a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
432	1	11	1	[0]	2019-06-19 23:00:00	\N	\N	d5899166-261f-47b0-a975-5bf72ca44088	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
433	1	10	1	[0]	2019-06-19 23:00:00	\N	\N	720220af-df47-4aec-9eeb-572ea015a32c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
434	1	9	1	[0]	2019-06-19 23:00:00	\N	\N	f95ef48c-b47a-4283-b226-e6e8f6f4b837	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
435	1	8	1	[0]	2019-06-19 23:00:00	\N	\N	aa13fbc2-6375-4fc9-9f22-9b75d4ed50fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
436	1	12	1	[0]	2019-06-20 00:00:00	\N	\N	2c7011fc-a86e-4281-ba70-5057a0894d7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
437	1	11	1	[0]	2019-06-20 00:00:00	\N	\N	deffafc2-7d6f-4e8a-9ff3-7c90eceea73e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
438	1	10	1	[0]	2019-06-20 00:00:00	\N	\N	819148b9-f512-461b-8d04-37db606a3eb5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
439	1	9	1	[0]	2019-06-20 00:00:00	\N	\N	e55a5f6d-96f3-4a3f-ab43-5a84513747cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
440	1	8	1	[0]	2019-06-20 00:00:00	\N	\N	24d42259-2327-46ee-b1bb-908f957c8042	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
441	1	12	1	[0]	2019-06-20 01:00:00	\N	\N	4c694784-6ba0-4d61-891e-490b219fc760	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
442	1	11	1	[0]	2019-06-20 01:00:00	\N	\N	538094f0-915e-48a2-bf34-0a61ee9349d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
443	1	10	1	[0]	2019-06-20 01:00:00	\N	\N	c8e0090e-3404-45e2-85ec-6409b089493f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
444	1	9	1	[0]	2019-06-20 01:00:00	\N	\N	a5029586-5427-49f5-a390-60be8ea7671a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
445	1	8	1	[0]	2019-06-20 01:00:00	\N	\N	0da560b2-8f04-4010-8b04-a909a7901881	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
446	1	12	1	[0]	2019-06-20 02:00:00	\N	\N	aee54f2b-fa8b-4a43-b519-02dfe86e503f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
447	1	11	1	[0]	2019-06-20 02:00:00	\N	\N	81e8bdbd-9e6b-4519-81f9-e3c8a23a9c56	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
448	1	10	1	[0]	2019-06-20 02:00:00	\N	\N	097fd416-54b9-4d1d-8bdd-10826062e78d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
449	1	9	1	[0]	2019-06-20 02:00:00	\N	\N	5e705dbf-4a24-4d3c-896e-8b03228b7713	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
450	1	8	1	[0]	2019-06-20 02:00:00	\N	\N	9bca389d-03df-41c8-a4da-4d330688f42c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
451	1	12	1	[0]	2019-06-20 03:00:00	\N	\N	507b4619-2b17-42a8-b2ef-47dfcc31d673	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
452	1	11	1	[0]	2019-06-20 03:00:00	\N	\N	1ae45b53-b3f0-4c04-a252-e5816b36ce10	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
453	1	10	1	[0]	2019-06-20 03:00:00	\N	\N	1cb08a59-cccb-493b-a9aa-5c6f1960c7a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
454	1	9	1	[0]	2019-06-20 03:00:00	\N	\N	ccbab747-989a-49b9-9d65-47f5c498d587	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
455	1	8	1	[0]	2019-06-20 03:00:00	\N	\N	26116262-01df-4637-a5f4-a2cb5b64d458	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
456	1	12	1	[0]	2019-06-20 04:00:00	\N	\N	9d377601-1d7b-4d83-8e7d-657435773ef4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
457	1	11	1	[0]	2019-06-20 04:00:00	\N	\N	8627c61f-8f2b-4d0d-8604-247a5be604ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
458	1	10	1	[0]	2019-06-20 04:00:00	\N	\N	9ccdd9e3-7743-4cc6-90bf-ed96267f6196	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
459	1	9	1	[0]	2019-06-20 04:00:00	\N	\N	1a743c23-1827-4101-b1d6-21afb6f99b11	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
460	1	8	1	[0]	2019-06-20 04:00:00	\N	\N	04b40229-0f20-4b98-924a-61a3766d3ad1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
461	1	12	1	[0]	2019-06-20 05:00:00	\N	\N	b5e1da06-dc70-4a7a-953f-f03eb287b969	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
462	1	11	1	[0]	2019-06-20 05:00:00	\N	\N	90a34852-da5e-47d1-a622-43ef72191275	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
463	1	10	1	[0]	2019-06-20 05:00:00	\N	\N	7817ab4c-4994-4491-a0d4-e0a0595f7e33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
464	1	9	1	[0]	2019-06-20 05:00:00	\N	\N	b215355f-1621-45e0-85c1-fe1fb0a80a97	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
465	1	8	1	[0]	2019-06-20 05:00:00	\N	\N	25d3b212-6a20-4a0d-bdcf-6907d14293ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
466	1	12	1	[0]	2019-06-20 06:00:00	\N	\N	c113be8b-c79b-4367-9283-2575e8618328	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
467	1	11	1	[0]	2019-06-20 06:00:00	\N	\N	1075d915-6488-48d0-9a3a-4cc895ce4e89	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
468	1	10	1	[0]	2019-06-20 06:00:00	\N	\N	76ddc03f-6674-402a-8478-aa89190310d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
469	1	9	1	[0]	2019-06-20 06:00:00	\N	\N	eee7f7c5-42fc-4e35-9084-a784a8ff3658	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
470	1	8	1	[0]	2019-06-20 06:00:00	\N	\N	fe1a29d1-03e8-49ba-ac9a-a1fead1b09a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
471	1	12	1	[0.200000003]	2019-06-20 07:00:00	\N	\N	58c6d95f-e38f-4341-bb67-54b9fc1e07ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
472	1	11	1	[0]	2019-06-20 07:00:00	\N	\N	e85ac3b9-5fd3-41c3-80de-14d1bb72b25e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
473	1	10	1	[0]	2019-06-20 07:00:00	\N	\N	9033f0ec-74c8-4c4b-858b-aad7199d2524	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
474	1	9	1	[0]	2019-06-20 07:00:00	\N	\N	857da571-26cd-4f94-b4eb-8388dc61f6f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
475	1	8	1	[0]	2019-06-20 07:00:00	\N	\N	82a5306e-7cbf-4eba-a4fc-6c431568c7b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
476	1	12	1	[0]	2019-06-20 08:00:00	\N	\N	ad0b7a8e-5e44-43b8-ab4c-122ca3296f9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
477	1	11	1	[0]	2019-06-20 08:00:00	\N	\N	9aa0c0f8-2068-4082-ba68-3dd94b29ddc5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
478	1	10	1	[0]	2019-06-20 08:00:00	\N	\N	d8122538-c729-4dce-8723-14c56aca96ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
479	1	9	1	[0]	2019-06-20 08:00:00	\N	\N	cf0b1c72-d8ab-4e0b-ac6d-b6c94bf64d6d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
480	1	8	1	[0]	2019-06-20 08:00:00	\N	\N	aded4d69-4878-4413-8398-742347c7e4e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
481	1	12	1	[0]	2019-06-20 09:00:00	\N	\N	b89051ec-5786-4e1c-a031-6e45c417fd8f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
482	1	11	1	[0]	2019-06-20 09:00:00	\N	\N	7c030e55-316c-4ede-b75c-738667925d51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
483	1	10	1	[0]	2019-06-20 09:00:00	\N	\N	d060370d-6758-49f7-b2f4-2d11b595f4cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
484	1	9	1	[0]	2019-06-20 09:00:00	\N	\N	11fc2f52-79e8-4f60-a366-f0fe2f741b8f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
485	1	8	1	[0]	2019-06-20 09:00:00	\N	\N	57fc0d1c-8a8d-4a18-9cb1-5955fe9ad3fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
486	1	12	1	[0]	2019-06-20 10:00:00	\N	\N	95fe752f-f31d-4cb0-81cf-7f45ec6202ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
487	1	11	1	[0]	2019-06-20 10:00:00	\N	\N	d2c68501-af71-4781-8295-f807cf2aefd4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
488	1	10	1	[0]	2019-06-20 10:00:00	\N	\N	7c45a753-8e18-470b-8a79-0a01bfcfa566	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
489	1	9	1	[0]	2019-06-20 10:00:00	\N	\N	426c82ec-1665-4986-9c9e-f45c55ce50eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
490	1	8	1	[0]	2019-06-20 10:00:00	\N	\N	537f0879-8cb5-4f50-ad3a-7b107c590353	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
491	1	12	1	[0.600000024]	2019-06-20 11:00:00	\N	\N	b1d54c9c-3588-4a9a-9462-ce6e5d70e67e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
492	1	11	1	[0]	2019-06-20 11:00:00	\N	\N	02c8d28f-ea83-4a48-8791-0c0f3ca65df5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
493	1	10	1	[0]	2019-06-20 11:00:00	\N	\N	83637476-4537-42c8-a468-981ec162ece6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
494	1	9	1	[0]	2019-06-20 11:00:00	\N	\N	2dfc72e7-8b19-4297-a54a-2afaa1bea6fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
495	1	8	1	[0]	2019-06-20 11:00:00	\N	\N	d8c835c6-43f8-46e0-af3f-989cf35b004e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
496	1	12	1	[0]	2019-06-20 12:00:00	\N	\N	7eb518f6-8463-415f-b3c3-8b6cf9831849	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
497	1	11	1	[0]	2019-06-20 12:00:00	\N	\N	0e7a17c5-55ac-444b-bab6-ebdd9f94ac04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
498	1	10	1	[0]	2019-06-20 12:00:00	\N	\N	007864d2-b853-4b07-add3-fd288f159fb1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
499	1	9	1	[0]	2019-06-20 12:00:00	\N	\N	559355af-c7a0-4c68-a245-cf1aae7f84c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
500	1	8	1	[0]	2019-06-20 12:00:00	\N	\N	5c0f64bd-c71a-452c-8b54-2b8e658fe701	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
501	1	12	1	[0]	2019-06-20 13:00:00	\N	\N	3f2e5d3d-89a2-476b-8609-f099cfada148	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
502	1	11	1	[0]	2019-06-20 13:00:00	\N	\N	8bdbe120-929f-47d4-87c9-53d605dd5133	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
503	1	10	1	[0]	2019-06-20 13:00:00	\N	\N	fbb4fe7d-2bf9-40e2-aa59-7e93731631f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
504	1	9	1	[0]	2019-06-20 13:00:00	\N	\N	fd758259-2b2c-42b5-a5fd-d2d30ce2a716	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
505	1	8	1	[0]	2019-06-20 13:00:00	\N	\N	fd4e6023-4c90-4089-a855-529d08129d96	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
506	1	12	1	[0]	2019-06-20 14:00:00	\N	\N	cb48e89f-9853-42a6-a085-990de3407c99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
507	1	11	1	[0]	2019-06-20 14:00:00	\N	\N	bf4a37d4-a8fb-4313-8281-6d2fe2643d63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
508	1	10	1	[0]	2019-06-20 14:00:00	\N	\N	8301e267-e3f2-4f46-8b92-25a50b36be4d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
509	1	9	1	[0]	2019-06-20 14:00:00	\N	\N	1cc885db-6bd1-4d73-8e85-14d0f053f46b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
510	1	8	1	[0]	2019-06-20 14:00:00	\N	\N	f442ebb6-a2ee-404d-b6e0-d44d8162d862	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
511	1	12	1	[0]	2019-06-20 15:00:00	\N	\N	d0669cdd-2a47-4ced-b7b7-f42fe8d19559	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
512	1	11	1	[0]	2019-06-20 15:00:00	\N	\N	0310c524-b145-48be-83b7-072d65d51285	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
513	1	10	1	[0]	2019-06-20 15:00:00	\N	\N	cb41d2ae-ad51-4553-a5f3-26d3efe90589	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
514	1	9	1	[0]	2019-06-20 15:00:00	\N	\N	268394fa-2fe3-4c8a-93a3-c77e5ff6f5f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
515	1	8	1	[0]	2019-06-20 15:00:00	\N	\N	5f9bbf25-9eb9-4bb4-8797-387e93f63cca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
516	1	12	1	[0]	2019-06-20 16:00:00	\N	\N	cfebe704-60fb-496b-b530-27dd02749544	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
517	1	11	1	[0]	2019-06-20 16:00:00	\N	\N	2c392245-87f3-4376-8745-6bb99321e458	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
518	1	10	1	[0]	2019-06-20 16:00:00	\N	\N	9cad51a8-c298-4014-8330-b8b0ccd68a7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
519	1	9	1	[0]	2019-06-20 16:00:00	\N	\N	f47a1a30-73ee-4b58-8033-65bda07d1a0f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
520	1	8	1	[0]	2019-06-20 16:00:00	\N	\N	226089f7-27ee-4073-808a-4b37a5f6ee22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
521	1	12	1	[0]	2019-06-20 17:00:00	\N	\N	1fc7beae-5a8d-4dbe-a485-2855f174fcff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
522	1	11	1	[0]	2019-06-20 17:00:00	\N	\N	e791e01c-7abf-4bae-8300-6bff6f88c1f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
523	1	10	1	[0]	2019-06-20 17:00:00	\N	\N	899092a3-4bb3-40f8-94b6-3f93dfc188d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
524	1	9	1	[0]	2019-06-20 17:00:00	\N	\N	8ce1f835-edfe-406e-a925-d72dae376f57	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
525	1	8	1	[0]	2019-06-20 17:00:00	\N	\N	bbc836e2-9303-4331-8f31-4af41f5bd402	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
526	1	12	1	[0]	2019-06-20 18:00:00	\N	\N	246c6212-d4bc-4f1e-b165-89736c704638	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
527	1	11	1	[0]	2019-06-20 18:00:00	\N	\N	4bc08b49-e047-4a2d-8ce7-dde2999d74db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
528	1	10	1	[0]	2019-06-20 18:00:00	\N	\N	1dbe1693-4dd4-47cd-b828-896675157896	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
529	1	9	1	[0]	2019-06-20 18:00:00	\N	\N	4e6a2db1-383d-4348-a6d5-b8605d761751	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
530	1	8	1	[0]	2019-06-20 18:00:00	\N	\N	9e8cf701-223e-4d6d-9ba1-6267472f1337	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
531	1	12	1	[0]	2019-06-20 19:00:00	\N	\N	748849da-7da3-473e-8905-894e3390155a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
532	1	11	1	[0]	2019-06-20 19:00:00	\N	\N	f3e79a21-d22e-4948-801c-74bd942e4761	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
533	1	10	1	[0]	2019-06-20 19:00:00	\N	\N	9223b8ff-063a-4191-9270-a44218754a56	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
534	1	9	1	[0]	2019-06-20 19:00:00	\N	\N	a5b9be13-54e1-4cf3-9226-000d1017e7f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
535	1	8	1	[0]	2019-06-20 19:00:00	\N	\N	2326e2e3-6743-470f-bef8-28a7b9d9c731	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
536	1	12	1	[0]	2019-06-20 20:00:00	\N	\N	f78ad5e6-3656-4e7e-a1bf-656d023f7bb6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
537	1	11	1	[0]	2019-06-20 20:00:00	\N	\N	dd6727d6-0ae0-4e52-a32c-cab1db7d0660	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
538	1	10	1	[0]	2019-06-20 20:00:00	\N	\N	b1e385b1-0827-44c9-90d1-df6f97df38ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
539	1	9	1	[0]	2019-06-20 20:00:00	\N	\N	a753d666-32c3-46fe-b926-76b99f40b5d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
540	1	8	1	[0]	2019-06-20 20:00:00	\N	\N	ea703426-0231-482e-8c0f-f7a4b4a1cadf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
541	1	12	1	[0]	2019-06-20 21:00:00	\N	\N	49cac5fa-3c93-4460-8c19-fff6b93fdb48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
542	1	11	1	[0]	2019-06-20 21:00:00	\N	\N	bebf2dd7-7587-426b-b196-691fcdc4259e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
543	1	10	1	[0]	2019-06-20 21:00:00	\N	\N	4e3d7707-ec1a-4fcd-b550-f5e605acac48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
544	1	9	1	[0]	2019-06-20 21:00:00	\N	\N	3c17716c-7b7c-482f-a8d7-06aa485339dd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
545	1	8	1	[0]	2019-06-20 21:00:00	\N	\N	b27aca28-22a8-44e1-a240-db9d4bf14094	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
546	1	12	1	[0]	2019-06-20 22:00:00	\N	\N	23bba4c4-f6eb-49af-bfd8-a90370ef2b89	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
547	1	11	1	[0]	2019-06-20 22:00:00	\N	\N	d3c95e3d-7bbd-4e67-b82a-87f068d962a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
548	1	10	1	[0]	2019-06-20 22:00:00	\N	\N	fd0e009d-48b2-4546-936f-f0d47acaf44f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
549	1	9	1	[0]	2019-06-20 22:00:00	\N	\N	622cbdbb-15ce-4d52-b6ef-3399f2374bbd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
550	1	8	1	[0]	2019-06-20 22:00:00	\N	\N	ddd3a5b6-cc21-4e71-aea3-4e87a76174fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
551	1	12	1	[0]	2019-06-20 23:00:00	\N	\N	a69dc42c-3687-4af8-a6c5-c83820db735d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
552	1	11	1	[0]	2019-06-20 23:00:00	\N	\N	58c3fb81-df5d-48b9-af33-7e9d6ba6e590	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
553	1	10	1	[0]	2019-06-20 23:00:00	\N	\N	00e199d9-6919-4b83-a3c2-10c6c2aa76e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
554	1	9	1	[0]	2019-06-20 23:00:00	\N	\N	cb192885-e25d-4e38-8c59-c258cee4c04c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
555	1	8	1	[0]	2019-06-20 23:00:00	\N	\N	9fed6315-691e-4dd5-8397-befd75589b86	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
556	1	12	1	[0]	2019-06-21 00:00:00	\N	\N	e3ec6b6f-2581-4cd1-a30a-f7808f96a723	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
557	1	11	1	[0]	2019-06-21 00:00:00	\N	\N	4223232d-ca1d-4821-83c9-9a7109813378	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
558	1	10	1	[0]	2019-06-21 00:00:00	\N	\N	ecc02629-9a79-4927-9b02-ff403d6aeed7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
559	1	9	1	[0]	2019-06-21 00:00:00	\N	\N	66aef54e-3c90-4fa5-b77a-598708bf6151	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
560	1	8	1	[0]	2019-06-21 00:00:00	\N	\N	44a7e8bf-81a8-4174-8421-7dbddfe2ea19	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
561	1	12	1	[0]	2019-06-21 01:00:00	\N	\N	ca570d40-f772-42c0-94f2-d12bef2216ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
562	1	11	1	[0]	2019-06-21 01:00:00	\N	\N	62142fe5-f593-4727-a41c-4bde32cbc302	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
563	1	10	1	[0]	2019-06-21 01:00:00	\N	\N	7edad987-52c3-42dd-b01b-43aa4bdfdf50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
564	1	9	1	[0]	2019-06-21 01:00:00	\N	\N	4f3e8beb-02fb-4a4f-9802-09464309ff46	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
565	1	8	1	[0]	2019-06-21 01:00:00	\N	\N	9de6b632-d230-4317-9ba0-46c5fd051d2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
566	1	12	1	[0]	2019-06-21 02:00:00	\N	\N	e50d6265-0c3e-4793-847a-23a53b68e9a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
567	1	11	1	[0]	2019-06-21 02:00:00	\N	\N	ca984c68-cd33-46e3-8a9c-e5c537d9ebaf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
568	1	10	1	[0]	2019-06-21 02:00:00	\N	\N	4dd0e959-9d33-4c31-be70-0a048aa1ceec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
569	1	9	1	[0]	2019-06-21 02:00:00	\N	\N	25a4f18d-f337-4134-a6a3-51fed491a1ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
570	1	8	1	[0]	2019-06-21 02:00:00	\N	\N	a063b3af-e027-4e77-9fd7-5e26c8e5016a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
571	1	12	1	[0]	2019-06-21 03:00:00	\N	\N	cb67be57-4a7a-487d-b0ee-bb766541d34b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
572	1	11	1	[0]	2019-06-21 03:00:00	\N	\N	4086fe77-0cfe-430b-8d4c-8b5d00ef329e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
573	1	10	1	[0]	2019-06-21 03:00:00	\N	\N	2a741342-4c9d-41d8-a9fa-5a6e13a4ff9e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
574	1	9	1	[0]	2019-06-21 03:00:00	\N	\N	095d30f6-a0df-464f-ba4e-4abc2edebc1a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
575	1	8	1	[0]	2019-06-21 03:00:00	\N	\N	ae2a54b1-f136-4a77-8048-d5d06fb0364a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
576	1	12	1	[0]	2019-06-21 04:00:00	\N	\N	3fc972fb-f59f-4ebf-a8c8-0270e7a103ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
577	1	11	1	[0]	2019-06-21 04:00:00	\N	\N	71460948-fab9-413f-bad2-c73e579a61f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
578	1	10	1	[0]	2019-06-21 04:00:00	\N	\N	8745dddd-150f-4619-8e2c-2baa03ff6cc1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
579	1	9	1	[0]	2019-06-21 04:00:00	\N	\N	41a4831c-8e15-4513-b839-fe2a17dc5fca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
580	1	8	1	[0]	2019-06-21 04:00:00	\N	\N	c53d81de-304b-4634-ab19-3221db393bfa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
581	1	12	1	[0]	2019-06-21 05:00:00	\N	\N	7bf9f610-b5e3-4294-9a57-a4fc0c742ef3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
582	1	11	1	[0]	2019-06-21 05:00:00	\N	\N	a5b49be7-4712-44c4-bd5a-5c644135bd0b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
583	1	10	1	[0]	2019-06-21 05:00:00	\N	\N	747b065e-5f96-4a5b-9dfb-83c4cace7062	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
584	1	9	1	[0]	2019-06-21 05:00:00	\N	\N	bf4693db-6b46-4e2a-a076-0e272bd5d117	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
585	1	8	1	[0]	2019-06-21 05:00:00	\N	\N	e780d431-d0d4-44f7-bf7c-64be3bcc55f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
586	1	12	1	[0]	2019-06-21 06:00:00	\N	\N	cc8c7756-f188-4b5b-89e3-c1ece18b15a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
587	1	11	1	[0]	2019-06-21 06:00:00	\N	\N	dabba9cd-2e65-4ac5-9c1b-01d7dea1a74e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
588	1	10	1	[0]	2019-06-21 06:00:00	\N	\N	80389d37-3244-4cca-a9cb-5adab7c68d09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
589	1	9	1	[0]	2019-06-21 06:00:00	\N	\N	60a92663-7ae5-401c-a30e-438d1d504611	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
590	1	8	1	[0]	2019-06-21 06:00:00	\N	\N	4462e416-d118-4eae-a183-e17ddc80949b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
591	1	12	1	[0]	2019-06-21 07:00:00	\N	\N	7043e079-164b-4907-be92-72a199c9f1ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
592	1	11	1	[0]	2019-06-21 07:00:00	\N	\N	c14015b3-442d-4be5-964f-525ccedb9dfb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
593	1	10	1	[0]	2019-06-21 07:00:00	\N	\N	c0cfabd4-38bf-49da-84ea-53768c9753e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
594	1	9	1	[0]	2019-06-21 07:00:00	\N	\N	7ab7227d-0523-4eb6-aaa4-a218294bf85c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
595	1	8	1	[0]	2019-06-21 07:00:00	\N	\N	3420da73-62a2-44ee-bcc9-f16c70308bea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
596	1	12	1	[0]	2019-06-21 08:00:00	\N	\N	b2168cf2-181d-4ff5-88e2-189b06715770	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
597	1	11	1	[0]	2019-06-21 08:00:00	\N	\N	5b9c8410-04af-4219-bef2-93b8fc3f1040	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
598	1	10	1	[0]	2019-06-21 08:00:00	\N	\N	578d12d1-ce2c-4e68-9624-8b1ccee4c713	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
599	1	9	1	[0]	2019-06-21 08:00:00	\N	\N	64deecd5-bbc4-4f63-a821-7497f0181e8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
600	1	8	1	[0.200000003]	2019-06-21 08:00:00	\N	\N	e78550de-0115-4f43-b9fa-81505f4e9195	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
601	1	12	1	[0]	2019-06-21 09:00:00	\N	\N	41300424-eb59-4889-bc22-b543483878a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
602	1	11	1	[0]	2019-06-21 09:00:00	\N	\N	f06cc087-7682-422a-ac4a-c9815eac53a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
603	1	10	1	[0]	2019-06-21 09:00:00	\N	\N	f8903211-b0ec-47ff-b543-aad644f3219b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
604	1	9	1	[0]	2019-06-21 09:00:00	\N	\N	43621eb5-b476-4e52-b350-ff8bf9ddfc43	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
605	1	8	1	[0.200000003]	2019-06-21 09:00:00	\N	\N	c9bd3f32-c21f-4920-9cbb-a5a4066b3d6c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
606	1	12	1	[0]	2019-06-21 10:00:00	\N	\N	1bbdd176-58ae-4cf1-8ce7-d22cac50002c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
607	1	11	1	[0]	2019-06-21 10:00:00	\N	\N	76468ed0-3231-4dee-bf53-9f038bdc0180	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
608	1	10	1	[0]	2019-06-21 10:00:00	\N	\N	56ae1a93-bdf0-47c4-a627-a18da32a126a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
609	1	9	1	[0]	2019-06-21 10:00:00	\N	\N	f88cf53b-e17e-43e0-a8fa-8281a79d5c4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
610	1	8	1	[0]	2019-06-21 10:00:00	\N	\N	572b4480-6c8c-4104-9373-3e13f8252809	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
611	1	12	1	[0]	2019-06-21 11:00:00	\N	\N	e6609f05-8c87-40bf-80c0-c42eda5b0372	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
612	1	11	1	[0]	2019-06-21 11:00:00	\N	\N	5546e5d2-5731-402d-94d1-79fec4cefa36	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
613	1	10	1	[0]	2019-06-21 11:00:00	\N	\N	96f952dd-5a22-4a36-a574-35133ed3d644	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
614	1	9	1	[0]	2019-06-21 11:00:00	\N	\N	db7ab243-c47b-4e8d-aac8-e7c82b132815	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
615	1	8	1	[0]	2019-06-21 11:00:00	\N	\N	588a5215-eece-4a9f-9be5-c5312ca8f25a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
616	1	12	1	[0]	2019-06-21 12:00:00	\N	\N	1a9eea49-0e2b-49ed-97d7-6d7ac778a778	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
617	1	11	1	[0]	2019-06-21 12:00:00	\N	\N	3f4dcd2e-5ffb-4e8a-9f03-cde4744c4f6a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
618	1	10	1	[0]	2019-06-21 12:00:00	\N	\N	a91a0ff0-5a48-4a9f-81b0-b1b13860e3e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
619	1	9	1	[0]	2019-06-21 12:00:00	\N	\N	16c90fa0-e02f-4f1f-b4a1-091e5ebd7c37	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
620	1	8	1	[0]	2019-06-21 12:00:00	\N	\N	0cbe4601-62cb-4ba4-bfcb-b904d0c7017e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
621	1	12	1	[0]	2019-06-21 13:00:00	\N	\N	cdee49f8-2651-46e9-9757-c0326c733c7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
622	1	11	1	[0]	2019-06-21 13:00:00	\N	\N	b4f21ed3-118b-47cf-81c1-8407d09ecace	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
623	1	10	1	[0]	2019-06-21 13:00:00	\N	\N	9902f465-6d2f-4055-ba66-44dd392c67cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
624	1	9	1	[0]	2019-06-21 13:00:00	\N	\N	50ce7d29-2bf4-4821-b4c5-4dc2038dfa02	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
625	1	8	1	[0]	2019-06-21 13:00:00	\N	\N	0e08b441-d78a-4f62-bfe0-6c849348cc7a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
626	1	12	1	[0]	2019-06-21 14:00:00	\N	\N	0236e663-7ed5-45ec-98b3-9e8fddeafde1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
627	1	11	1	[0]	2019-06-21 14:00:00	\N	\N	4ac1b85b-74e3-4af6-8779-2569ea28d2f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
628	1	10	1	[0]	2019-06-21 14:00:00	\N	\N	68e74e35-2db8-4ccf-b6d9-5d4206acdd3a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
629	1	9	1	[0]	2019-06-21 14:00:00	\N	\N	19474d50-9418-4ec0-9875-c4f0f963c814	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
630	1	8	1	[0]	2019-06-21 14:00:00	\N	\N	f9f800e0-859a-4183-b748-693d131abcb5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
631	1	12	1	[0]	2019-06-21 15:00:00	\N	\N	7a62c048-36bc-4e67-8a07-5c2ab6289b24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
632	1	11	1	[0]	2019-06-21 15:00:00	\N	\N	3b3f5449-8828-4dc9-bf9c-01d86932e3eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
633	1	10	1	[0]	2019-06-21 15:00:00	\N	\N	d7955421-33fa-4ef7-b986-b1535011735f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
634	1	9	1	[0]	2019-06-21 15:00:00	\N	\N	febe0b87-d6b0-4d6f-ab93-a8de3961d133	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
635	1	8	1	[0]	2019-06-21 15:00:00	\N	\N	3ad5cdf0-d19f-4f9a-be40-1e48fb35abe7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
636	1	12	1	[0]	2019-06-21 16:00:00	\N	\N	34a5a3a3-88ff-4831-bea7-21b9575ca1b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
637	1	11	1	[0]	2019-06-21 16:00:00	\N	\N	fb05aecb-49b8-4d25-9f7a-6bd716e67b07	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
638	1	10	1	[0]	2019-06-21 16:00:00	\N	\N	2bdfc0fa-02fa-4229-b14e-dabe516ebd50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
639	1	9	1	[0]	2019-06-21 16:00:00	\N	\N	1623fe7a-c09e-4095-bfdc-56fa1672f9a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
640	1	8	1	[0]	2019-06-21 16:00:00	\N	\N	d3b5814f-3966-4dcd-ab12-48960325d3bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
641	1	12	1	[0]	2019-06-21 17:00:00	\N	\N	9858f89b-0c1c-4fb8-84dd-8cd2549a3458	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
642	1	11	1	[0]	2019-06-21 17:00:00	\N	\N	e7dcceaa-b581-4571-adcd-a70320cc2f75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
643	1	10	1	[0]	2019-06-21 17:00:00	\N	\N	675f4faf-c5a6-4629-a920-b4aef4b77fb7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
644	1	9	1	[0]	2019-06-21 17:00:00	\N	\N	8cc68b9f-6dd8-47de-9a3d-176248c5ca71	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
645	1	8	1	[0]	2019-06-21 17:00:00	\N	\N	33fecd65-716a-4701-a86c-a0621e2a8631	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
646	1	12	1	[0]	2019-06-21 18:00:00	\N	\N	9da837d4-cc70-42e2-a13b-005f862994c0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
647	1	11	1	[0]	2019-06-21 18:00:00	\N	\N	17c9e914-aec3-4704-8ad3-f91d607afc19	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
648	1	10	1	[0]	2019-06-21 18:00:00	\N	\N	b844b8e9-e4ee-4d52-aac5-17b1a6675528	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
649	1	9	1	[0]	2019-06-21 18:00:00	\N	\N	54f846b0-5779-40ac-9183-a58a89c57d7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
650	1	8	1	[0]	2019-06-21 18:00:00	\N	\N	ac701d50-66b9-4c78-a7bb-71764cace5a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
651	1	12	1	[0]	2019-06-21 19:00:00	\N	\N	ce034896-3c03-4a04-9395-d225dd26ab9e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
652	1	11	1	[0]	2019-06-21 19:00:00	\N	\N	e17204ab-4027-4619-ab27-ae8a5ad29754	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
653	1	10	1	[0]	2019-06-21 19:00:00	\N	\N	eb06c0d1-d7cb-4663-a461-afd3814a66ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
654	1	9	1	[0]	2019-06-21 19:00:00	\N	\N	0bcf708a-64d5-4bdd-a09c-e9b2937ba819	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
655	1	8	1	[0]	2019-06-21 19:00:00	\N	\N	2477b491-e400-4589-8546-affd5a65be5c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
656	1	12	1	[0]	2019-06-21 20:00:00	\N	\N	e963dcdd-1abd-4ef8-8b11-c408bfba7ad7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
657	1	11	1	[0]	2019-06-21 20:00:00	\N	\N	534ea601-6d3a-46c0-9ebc-c2eac9fc6656	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
658	1	10	1	[0]	2019-06-21 20:00:00	\N	\N	a9447c6d-d1c7-4be0-ae46-30417a2af58a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
659	1	9	1	[0]	2019-06-21 20:00:00	\N	\N	48260fb6-f581-4ac1-9220-8700702cb1e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
660	1	8	1	[0]	2019-06-21 20:00:00	\N	\N	fe5353de-3f7b-43a7-a101-31a8f7626e9a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
661	1	12	1	[0]	2019-06-21 21:00:00	\N	\N	6ef49b8a-9c67-4748-bcbe-c36957a3fd70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
662	1	11	1	[0]	2019-06-21 21:00:00	\N	\N	e5d4db11-d5b0-4683-945b-6c35f1ddb2f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
663	1	10	1	[0]	2019-06-21 21:00:00	\N	\N	862aa3f6-7357-4f70-834f-1dcb0ab36e32	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
664	1	9	1	[0]	2019-06-21 21:00:00	\N	\N	0d8284c1-e317-409e-8ef1-df6e21f6adad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
665	1	8	1	[0]	2019-06-21 21:00:00	\N	\N	2211699a-9182-4cd2-950a-9765e3a69bd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
666	1	12	1	[0]	2019-06-21 22:00:00	\N	\N	be177bde-2344-4538-b1cd-c92859f5d1c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
667	1	11	1	[0]	2019-06-21 22:00:00	\N	\N	c2d88dd7-bdd6-4054-949d-a365a90e9f58	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
668	1	10	1	[0]	2019-06-21 22:00:00	\N	\N	ba1f1ba6-fff2-48c6-962e-351b44a06fbe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
669	1	9	1	[0]	2019-06-21 22:00:00	\N	\N	a68e55dd-0e05-4d42-8ac8-d347dec80c3d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
670	1	8	1	[0]	2019-06-21 22:00:00	\N	\N	6f3db06b-1d4c-484c-9fbf-b2d41f3a81fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
671	1	12	1	[0]	2019-06-21 23:00:00	\N	\N	c08d08c8-cfde-40ec-aff2-1682dac6b409	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
672	1	11	1	[0]	2019-06-21 23:00:00	\N	\N	cd19869f-47a8-4da0-9953-4dafb838c96d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
673	1	10	1	[0]	2019-06-21 23:00:00	\N	\N	b16a6966-c8cd-4cd1-84f9-a2a843656b59	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
674	1	9	1	[0]	2019-06-21 23:00:00	\N	\N	0e3e8467-a875-47f2-bc22-d212d227ea57	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
675	1	8	1	[0]	2019-06-21 23:00:00	\N	\N	89be9cb9-c7cf-4965-b29b-ad0b3bb53223	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
676	1	12	1	[0]	2019-06-22 00:00:00	\N	\N	8c307b5c-0200-46db-a760-a37020caed7a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
677	1	11	1	[0]	2019-06-22 00:00:00	\N	\N	b77b948c-7dd0-450b-8616-88155f0f493f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
678	1	10	1	[0]	2019-06-22 00:00:00	\N	\N	aab4aad7-69a7-4078-89f0-e8194c6aca7d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
679	1	9	1	[0]	2019-06-22 00:00:00	\N	\N	f9287b9b-3bbb-40f1-89e2-d4b22e1f194e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
680	1	8	1	[0]	2019-06-22 00:00:00	\N	\N	7f7c0c23-d62d-4e03-8067-1d8da23c5e3e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
681	1	12	1	[0]	2019-06-22 01:00:00	\N	\N	0fedf8db-bd66-4f2b-95b8-6ff814e7597b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
682	1	11	1	[0]	2019-06-22 01:00:00	\N	\N	4cd2ef1a-2f25-440d-80fb-2a89bbae6b19	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
683	1	10	1	[0]	2019-06-22 01:00:00	\N	\N	48c8ab8b-de31-4c69-a00b-41a6ccf7535d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
684	1	9	1	[0]	2019-06-22 01:00:00	\N	\N	32fe8cfa-b032-469d-9eab-4ef38400c78b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
685	1	8	1	[0]	2019-06-22 01:00:00	\N	\N	f97b8e1c-c49a-4516-9866-023b0929f093	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
686	1	12	1	[0]	2019-06-22 02:00:00	\N	\N	d5738627-69ed-4245-b2f0-c4139914815e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
687	1	11	1	[0]	2019-06-22 02:00:00	\N	\N	c87073b9-9ab0-499d-a8e3-de8e50a226f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
688	1	10	1	[0]	2019-06-22 02:00:00	\N	\N	9e86d54e-6fec-4151-888c-6d2a0deb3804	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
689	1	9	1	[0]	2019-06-22 02:00:00	\N	\N	6b2e00dd-36e5-4e27-b9b3-c177ddaaaa1a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
690	1	8	1	[0]	2019-06-22 02:00:00	\N	\N	e6f2583a-c0eb-42a6-9333-bcdea904d9e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
691	1	12	1	[0]	2019-06-22 03:00:00	\N	\N	282a05a2-0724-46eb-aefa-96734711760c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
692	1	11	1	[0]	2019-06-22 03:00:00	\N	\N	c3ed4f93-3552-49a8-9210-878586767fc8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
693	1	10	1	[0]	2019-06-22 03:00:00	\N	\N	0d24a018-11f2-40ee-92e1-30712d9b294b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
694	1	9	1	[0]	2019-06-22 03:00:00	\N	\N	03a1de1d-da2c-48ef-8dfe-4129c66a9d21	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
695	1	8	1	[0]	2019-06-22 03:00:00	\N	\N	c25a596c-eafd-41ff-8856-3b0d7b16df8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
696	1	12	1	[0.200000003]	2019-06-22 04:00:00	\N	\N	dea5e4df-4273-4d21-8107-134573778561	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
697	1	11	1	[0]	2019-06-22 04:00:00	\N	\N	c9150391-2c01-4c82-a47c-d468d4a02d37	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
698	1	10	1	[0]	2019-06-22 04:00:00	\N	\N	465d8714-d3a7-4370-8ff7-4b4144706198	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
699	1	9	1	[0]	2019-06-22 04:00:00	\N	\N	cb38fe16-8649-4a16-b595-f3f7d1361fc8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
700	1	8	1	[0]	2019-06-22 04:00:00	\N	\N	f747fb89-05c3-4613-a895-9169f95d1f91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
701	1	12	1	[0]	2019-06-22 05:00:00	\N	\N	608daf34-9f42-4436-857a-db2049a81aab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
702	1	11	1	[0]	2019-06-22 05:00:00	\N	\N	cd55a5dd-1f85-438c-a945-cd24d250ba95	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
703	1	10	1	[0]	2019-06-22 05:00:00	\N	\N	7a3ce191-6a44-4eb0-9704-cd17ef4955f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
704	1	9	1	[0]	2019-06-22 05:00:00	\N	\N	2dd7ed68-6d37-4119-b1a1-57081d41c056	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
705	1	8	1	[0]	2019-06-22 05:00:00	\N	\N	62531de4-e7b6-4163-afe1-fbde1cc8bebf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
706	1	12	1	[0]	2019-06-22 06:00:00	\N	\N	b0281d69-ec6b-4ead-a3f8-b2a8b4893914	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
707	1	11	1	[0]	2019-06-22 06:00:00	\N	\N	728ce48f-e205-4d04-9ae7-036b6e06c270	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
708	1	10	1	[0]	2019-06-22 06:00:00	\N	\N	cc76031c-6761-4711-9cd6-2e816c95265c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
709	1	9	1	[0]	2019-06-22 06:00:00	\N	\N	f9fc3070-000f-40cf-93e2-7a63ca997a1f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
710	1	8	1	[0]	2019-06-22 06:00:00	\N	\N	c95bfb70-fe99-4655-82b8-bd72b7540c40	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
711	1	12	1	[0]	2019-06-22 07:00:00	\N	\N	65f7d30c-f19d-44a0-b919-342a50a48c6a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
712	1	11	1	[0]	2019-06-22 07:00:00	\N	\N	835ed900-36ea-4cc4-a657-517de61bc1b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
713	1	10	1	[0]	2019-06-22 07:00:00	\N	\N	be7c02f2-6f67-4fd5-a095-174d5d2852c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
714	1	9	1	[0]	2019-06-22 07:00:00	\N	\N	70239509-8f85-432f-a835-d22c08022f48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
715	1	8	1	[0]	2019-06-22 07:00:00	\N	\N	a8ba3ae5-9b3d-436e-9692-ebc7820d21fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
716	1	12	1	[0]	2019-06-22 08:00:00	\N	\N	e3fd9f05-84c0-479e-a8e8-1b7898f715b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
717	1	11	1	[0]	2019-06-22 08:00:00	\N	\N	72fd77ab-1b1b-427e-92f0-64e1b32146fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
718	1	10	1	[0]	2019-06-22 08:00:00	\N	\N	fd6740ce-fdcd-4bed-92bf-e85017301482	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
719	1	9	1	[0]	2019-06-22 08:00:00	\N	\N	53ace336-8de4-45df-a7b3-d82deb6ccd66	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
720	1	8	1	[0]	2019-06-22 08:00:00	\N	\N	3528c6e1-01e7-410a-b7d3-0506c1349c01	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
721	1	12	1	[0]	2019-06-22 09:00:00	\N	\N	219fe0e1-d0b7-4ae5-9907-1936ab3d4519	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
722	1	11	1	[0]	2019-06-22 09:00:00	\N	\N	b082eac2-ab3c-4f0b-bc7f-0d46ee274ac0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
723	1	10	1	[0]	2019-06-22 09:00:00	\N	\N	ced55dd1-b61e-40ec-9a3f-27ee918d2282	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
724	1	9	1	[0]	2019-06-22 09:00:00	\N	\N	7b41dcf3-17d0-4fc1-bc94-761760914e2e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
725	1	8	1	[0]	2019-06-22 09:00:00	\N	\N	ae4b3bf5-d895-4034-be54-31c528d37d25	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
726	1	12	1	[0]	2019-06-22 10:00:00	\N	\N	cb20c5de-a71e-401e-af0b-8baed5e3cf72	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
727	1	11	1	[0]	2019-06-22 10:00:00	\N	\N	ff350597-29f0-4ddf-bea9-0afcdf589270	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
728	1	10	1	[0]	2019-06-22 10:00:00	\N	\N	831f51ed-532f-4bc1-b3f7-c1296b370a26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
729	1	9	1	[0]	2019-06-22 10:00:00	\N	\N	aed133f9-baf6-45a3-96b2-6fb62b409896	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
730	1	8	1	[0]	2019-06-22 10:00:00	\N	\N	42aea4af-bfb6-4689-a41f-509447519b22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
731	1	12	1	[0]	2019-06-22 11:00:00	\N	\N	38f9268c-3cbd-433b-9f64-7ce6d3533ce6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
732	1	11	1	[0]	2019-06-22 11:00:00	\N	\N	803d782e-55ce-478d-898d-6b8c277dd318	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
733	1	10	1	[0]	2019-06-22 11:00:00	\N	\N	ba865d9c-b291-4d56-89be-be28ca3bf8d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
734	1	9	1	[0]	2019-06-22 11:00:00	\N	\N	13d47767-6738-4723-b801-5b81be4642da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
735	1	8	1	[0]	2019-06-22 11:00:00	\N	\N	8eb36cf6-e962-4a1a-986c-45a6f5fad922	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
736	1	12	1	[0]	2019-06-22 12:00:00	\N	\N	690b4b88-65af-4747-87fb-2c3fe0a76ad0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
737	1	11	1	[0]	2019-06-22 12:00:00	\N	\N	3ff3357c-6c93-4bca-b9fc-24a004bb9cfd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
738	1	10	1	[0]	2019-06-22 12:00:00	\N	\N	663cc40e-ceea-4578-a4bd-2d727b0e4c82	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
739	1	9	1	[0]	2019-06-22 12:00:00	\N	\N	a0e25e6d-2004-42ff-a71a-6d6676793afc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
740	1	8	1	[0]	2019-06-22 12:00:00	\N	\N	50e2d0ec-ad55-4d15-a815-7adad6601c4c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
741	1	12	1	[0]	2019-06-22 13:00:00	\N	\N	a7839ab3-a174-4e92-9e74-698c457a11e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
742	1	11	1	[0]	2019-06-22 13:00:00	\N	\N	14614326-87c1-4e75-ab00-a37d62685861	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
743	1	10	1	[0]	2019-06-22 13:00:00	\N	\N	1a8386e6-8412-4167-a61c-8f437bb03812	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
744	1	9	1	[0]	2019-06-22 13:00:00	\N	\N	9e6bf09e-765d-48a8-b5dc-5175100f1d0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
745	1	8	1	[0]	2019-06-22 13:00:00	\N	\N	db6cc7a5-481e-491f-af47-e0f5d85e28fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
746	1	12	1	[0]	2019-06-22 14:00:00	\N	\N	097bcfb0-51da-46b2-8bf2-d29a82ab3939	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
747	1	11	1	[0]	2019-06-22 14:00:00	\N	\N	3acc0362-229f-4253-b053-136ea5d0a2e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
748	1	10	1	[0]	2019-06-22 14:00:00	\N	\N	29a2ce6d-5d25-426f-9b1e-2732b69d6b55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
749	1	9	1	[0]	2019-06-22 14:00:00	\N	\N	f0d25113-9666-4119-ad86-1cc2ec9e88c9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
750	1	8	1	[0]	2019-06-22 14:00:00	\N	\N	7ce604e2-e22d-449e-99ed-d5a3642d42ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
751	1	12	1	[0]	2019-06-22 15:00:00	\N	\N	30659267-3a13-4ff8-ba18-7afb2d9c6108	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
752	1	11	1	[0]	2019-06-22 15:00:00	\N	\N	077a1a1e-2bea-4b18-b1dd-3af94939ca70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
753	1	10	1	[0]	2019-06-22 15:00:00	\N	\N	79f52e07-2737-4416-bc61-b4aad69a7709	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
754	1	9	1	[0]	2019-06-22 15:00:00	\N	\N	8c7a01e3-eefe-4fed-982c-c0cc77ce59e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
755	1	8	1	[0]	2019-06-22 15:00:00	\N	\N	5912ed5c-64d5-4de9-9355-7d2dbec0ea98	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
756	1	12	1	[0]	2019-06-22 16:00:00	\N	\N	50fc4fae-65b3-4690-80eb-68b4da40f2fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
757	1	11	1	[0]	2019-06-22 16:00:00	\N	\N	e3fb6c2d-44fb-496d-b67d-de0877628b7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
758	1	10	1	[0]	2019-06-22 16:00:00	\N	\N	4da63850-7a90-4622-a235-4bdd32df4eec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
759	1	9	1	[0]	2019-06-22 16:00:00	\N	\N	96fce0f3-abd3-4f5c-ad3f-8baf7295ef4f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
760	1	8	1	[0]	2019-06-22 16:00:00	\N	\N	a62bef7a-449e-4f25-8ec7-61d7b7173113	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
761	1	12	1	[0]	2019-06-22 17:00:00	\N	\N	1cc7855f-227f-458b-8d7b-763e4b58dab7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
762	1	11	1	[0]	2019-06-22 17:00:00	\N	\N	6161f181-40e2-4a4c-bc38-028edfacb5cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
763	1	10	1	[0]	2019-06-22 17:00:00	\N	\N	f3d01683-f8c3-4110-b939-f317479c2d6a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
764	1	9	1	[0]	2019-06-22 17:00:00	\N	\N	3128a790-1526-4f15-b8f4-0804563bec7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
765	1	8	1	[0]	2019-06-22 17:00:00	\N	\N	2727d501-85c1-448f-8460-557fe4bb3677	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
766	1	12	1	[0]	2019-06-22 18:00:00	\N	\N	5181f244-2e67-4456-962e-e36dd903dfbc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
767	1	11	1	[0]	2019-06-22 18:00:00	\N	\N	44268a4d-4285-4f44-bb3f-e358ed785a6f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
768	1	10	1	[0]	2019-06-22 18:00:00	\N	\N	eb0864b9-31f9-48e5-a011-88e117771694	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
769	1	9	1	[0]	2019-06-22 18:00:00	\N	\N	4a192d75-3449-47db-acca-f34bb8e02643	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
770	1	8	1	[0]	2019-06-22 18:00:00	\N	\N	39f08abf-21dd-4989-b029-79db3c477037	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
771	1	12	1	[0]	2019-06-22 19:00:00	\N	\N	0ab0495d-d9de-48dc-9157-5c6aff597cc2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
772	1	11	1	[0]	2019-06-22 19:00:00	\N	\N	521aec7a-2c9d-485b-9180-c47ed68f5080	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
773	1	10	1	[0]	2019-06-22 19:00:00	\N	\N	63f0e833-ea67-4384-be3b-fd93eef07aa0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
774	1	9	1	[0]	2019-06-22 19:00:00	\N	\N	4b9060df-9fdb-4407-9717-e9838baeab3d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
775	1	8	1	[0]	2019-06-22 19:00:00	\N	\N	c07f20ae-49c3-45f2-8740-56dad5111e42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
776	1	12	1	[0]	2019-06-22 20:00:00	\N	\N	0d4e1d0b-27d6-4e49-b2aa-bb9718930b2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
777	1	11	1	[0]	2019-06-22 20:00:00	\N	\N	9d1d9327-c7fd-4d05-8145-82de283f1d94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
778	1	10	1	[0]	2019-06-22 20:00:00	\N	\N	6c0d9829-ee87-446d-a8ba-897b4e4a1322	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
779	1	9	1	[0]	2019-06-22 20:00:00	\N	\N	aa85ab97-6a48-4e07-a648-45967a342243	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
780	1	8	1	[0]	2019-06-22 20:00:00	\N	\N	fb7f31dc-a6cc-4681-a58f-7d0dcec912d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
781	1	12	1	[0]	2019-06-22 21:00:00	\N	\N	50609a51-10d0-4e8a-ae89-5fd5f5bb7680	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
782	1	11	1	[0]	2019-06-22 21:00:00	\N	\N	2e374c20-8a6f-479f-abdf-2dae0cd2490f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
783	1	10	1	[0]	2019-06-22 21:00:00	\N	\N	0d34c09a-4496-435a-8ead-47d97e4fea39	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
784	1	9	1	[0]	2019-06-22 21:00:00	\N	\N	092d80aa-f2c7-44a4-8884-2397dcb4eaef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
785	1	8	1	[0]	2019-06-22 21:00:00	\N	\N	2011cd18-4c7f-44db-8e8f-e282c59211b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
786	1	12	1	[0]	2019-06-22 22:00:00	\N	\N	02bc70d0-fd6b-4bb5-b54a-432d83a525d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
787	1	11	1	[0]	2019-06-22 22:00:00	\N	\N	36e69715-b2cc-4270-9cde-192a5839c123	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
788	1	10	1	[0]	2019-06-22 22:00:00	\N	\N	03a7dd6d-9273-45b3-8516-d07e00423060	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
789	1	9	1	[0]	2019-06-22 22:00:00	\N	\N	db2b3617-5a03-477f-9d81-743e143e576c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
790	1	8	1	[0]	2019-06-22 22:00:00	\N	\N	58cbe326-f92e-4c39-b4e7-7123b05ebbbe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
791	1	12	1	[0]	2019-06-22 23:00:00	\N	\N	05d8f6a2-556e-4431-a0e8-6991a89bca57	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
792	1	11	1	[0]	2019-06-22 23:00:00	\N	\N	dc833cd9-6d80-4eaf-b2f1-9f23662585f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
793	1	10	1	[0]	2019-06-22 23:00:00	\N	\N	24b88184-08b9-47a5-a5fe-032c0d7d4549	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
794	1	9	1	[0]	2019-06-22 23:00:00	\N	\N	8971bbff-b9aa-4199-83ca-7cfd1661c69b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
795	1	8	1	[0]	2019-06-22 23:00:00	\N	\N	1522ffae-848a-4268-935a-9f3fffca2f2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
796	1	12	1	[0]	2019-06-23 00:00:00	\N	\N	5402f7be-08dd-43c9-83c0-208e3f64aada	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
797	1	11	1	[0]	2019-06-23 00:00:00	\N	\N	b4c25413-d1eb-46ac-a9e5-c88c84e97e0b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
798	1	10	1	[0]	2019-06-23 00:00:00	\N	\N	5e7abe10-e3a4-46a7-9581-809022f23536	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
799	1	9	1	[0]	2019-06-23 00:00:00	\N	\N	0a245629-fe39-438c-ad6e-84413a1493ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
800	1	8	1	[0]	2019-06-23 00:00:00	\N	\N	33a9dc08-2a58-4fc9-bc15-49b5b8558762	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
801	1	12	1	[0]	2019-06-23 01:00:00	\N	\N	3b18b72d-3921-459a-9ca1-73ad3c4d1d07	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
802	1	11	1	[0]	2019-06-23 01:00:00	\N	\N	511615d3-d307-4152-b3fb-945ad6ae913d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
803	1	10	1	[0]	2019-06-23 01:00:00	\N	\N	790227bf-87d1-4f55-963e-e1d1ce5faa3a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
804	1	9	1	[0]	2019-06-23 01:00:00	\N	\N	ac55e89b-8669-4e16-86d4-78dda7f0d76b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
805	1	8	1	[0]	2019-06-23 01:00:00	\N	\N	ae669073-f7e8-417b-9dfd-afc36cd63a53	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
806	1	12	1	[0]	2019-06-23 02:00:00	\N	\N	4bcadee4-b39a-4776-aa8f-169be1ce8f63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
807	1	11	1	[0]	2019-06-23 02:00:00	\N	\N	dfc264ed-f95c-436c-abba-6d03a539383b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
808	1	10	1	[0]	2019-06-23 02:00:00	\N	\N	89cb605a-c3ca-4ac9-af7c-da5c2121ee51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
809	1	9	1	[0]	2019-06-23 02:00:00	\N	\N	0f29d18c-86ab-4178-9b75-b2af4d264cba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
810	1	8	1	[0]	2019-06-23 02:00:00	\N	\N	7ec8f508-d966-4228-a0d3-64cf1f370870	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
811	1	12	1	[0]	2019-06-23 03:00:00	\N	\N	025465bb-ce03-4606-9dbb-895dfcd4e956	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
812	1	11	1	[0]	2019-06-23 03:00:00	\N	\N	b7fc7c15-bcc3-4d9a-b889-7cb0e25287a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
813	1	10	1	[0]	2019-06-23 03:00:00	\N	\N	f0ccf235-418a-4879-9eff-d302e0d577c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
814	1	9	1	[0]	2019-06-23 03:00:00	\N	\N	023948fd-9304-4e9d-a515-6c82de08b754	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
815	1	8	1	[0]	2019-06-23 03:00:00	\N	\N	b504aae7-386a-4089-b043-e1696f926182	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
816	1	12	1	[0]	2019-06-23 04:00:00	\N	\N	01a39309-bdaf-4904-a71e-766381409e2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
817	1	11	1	[0]	2019-06-23 04:00:00	\N	\N	7c325aac-bbc0-44ea-b599-22b972cc8fd9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
818	1	10	1	[0]	2019-06-23 04:00:00	\N	\N	ac8bb757-ec32-4e5d-a1a5-9831b4a790af	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
819	1	9	1	[0]	2019-06-23 04:00:00	\N	\N	181a06fb-4523-43ad-a222-b177b481242e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
820	1	8	1	[0]	2019-06-23 04:00:00	\N	\N	4b84d9bd-64f5-45c8-b998-494e3179eb90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
821	1	12	1	[0]	2019-06-23 05:00:00	\N	\N	9dd10f48-6c5d-4565-87ea-017a25897586	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
822	1	11	1	[0]	2019-06-23 05:00:00	\N	\N	a608e263-408d-4457-affc-192883089d3e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
823	1	10	1	[0]	2019-06-23 05:00:00	\N	\N	199a0082-bb74-4587-9bd3-0e3c8e351e82	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
824	1	9	1	[0]	2019-06-23 05:00:00	\N	\N	5d5530be-b2c7-4f73-a391-004ad0d6e5f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
825	1	8	1	[0]	2019-06-23 05:00:00	\N	\N	c16050be-593e-4f89-b8d4-c7d04efcef38	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
826	1	12	1	[0]	2019-06-23 06:00:00	\N	\N	c7f489f6-b1c0-449e-9261-367be15513f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
827	1	11	1	[0]	2019-06-23 06:00:00	\N	\N	01e40368-9c28-4c8c-847b-af015239dce6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
828	1	10	1	[0]	2019-06-23 06:00:00	\N	\N	23649ea6-3e7c-476f-8e24-daf7e445de51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
829	1	9	1	[0]	2019-06-23 06:00:00	\N	\N	6bc3a98a-3a0a-4c0a-a715-894472163bbb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
830	1	8	1	[0]	2019-06-23 06:00:00	\N	\N	b5bdcf92-1ce9-495d-9e48-976a803f27f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
831	1	12	1	[0]	2019-06-23 07:00:00	\N	\N	a2a9c03c-70ff-41ef-9e47-e3a2445fab3a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
832	1	11	1	[0]	2019-06-23 07:00:00	\N	\N	2c702dd0-62a1-425d-b38e-e5f33fd5bed7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
833	1	10	1	[0]	2019-06-23 07:00:00	\N	\N	a26f2376-9338-47d1-86b3-65d702e3c736	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
834	1	9	1	[0]	2019-06-23 07:00:00	\N	\N	def2854a-ca8c-4fdf-909f-6dc0268323d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
835	1	8	1	[0]	2019-06-23 07:00:00	\N	\N	055f47c5-fbdf-499c-884c-b2532876d169	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
836	1	12	1	[0]	2019-06-23 08:00:00	\N	\N	bd8e169b-79b7-4c5f-a1b7-908f92bd79c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
837	1	11	1	[0]	2019-06-23 08:00:00	\N	\N	cb393db3-780d-4820-8de6-7503dd51e807	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
838	1	10	1	[0]	2019-06-23 08:00:00	\N	\N	69a369ad-85e5-4554-92b2-ec401dde7e0f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
839	1	9	1	[0]	2019-06-23 08:00:00	\N	\N	8838c567-4649-4fd0-85e6-92e50cf9fb15	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
840	1	8	1	[0]	2019-06-23 08:00:00	\N	\N	794f4644-bd0c-4a42-9227-6426dd79b28d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
841	1	12	1	[0]	2019-06-23 09:00:00	\N	\N	cca1c65f-cf65-44df-a275-4ecbe0518fc3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
842	1	11	1	[0]	2019-06-23 09:00:00	\N	\N	e9715449-cf3a-4b94-b0cb-376ec4c33340	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
843	1	10	1	[0]	2019-06-23 09:00:00	\N	\N	96b7e8c0-d591-438d-93dc-44c8e397c427	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
844	1	9	1	[0]	2019-06-23 09:00:00	\N	\N	9e5bca0b-cf3e-4caf-83fd-75e75f1aa5f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
845	1	8	1	[0]	2019-06-23 09:00:00	\N	\N	65982c42-b507-436b-8521-0a4c7d46311b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
846	1	12	1	[0]	2019-06-23 10:00:00	\N	\N	cae45cff-e4e7-4882-826d-e8fab2bf19b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
847	1	11	1	[0]	2019-06-23 10:00:00	\N	\N	07a7b230-7eae-4cbc-be44-a5e956fcf726	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
848	1	10	1	[0]	2019-06-23 10:00:00	\N	\N	fadab163-4aea-4287-a607-f98f09d139f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
849	1	9	1	[0]	2019-06-23 10:00:00	\N	\N	3db4860e-96fa-4ba7-929c-6804f8567f29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
850	1	8	1	[0]	2019-06-23 10:00:00	\N	\N	ffa1c0b4-f2a3-45ab-9edc-bd2d1bffaffd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
851	1	12	1	[0.800000012]	2019-06-23 11:00:00	\N	\N	1e9d775b-9f6b-4184-bffe-4ab6ca83d7cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
852	1	11	1	[0]	2019-06-23 11:00:00	\N	\N	77b15732-7a4a-4dda-9946-c775af3e79c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
853	1	10	1	[0.200000003]	2019-06-23 11:00:00	\N	\N	2160b8fa-c641-4d90-b796-38ca1dc9c4d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
854	1	9	1	[0.400000006]	2019-06-23 11:00:00	\N	\N	bba8fb8f-c567-4df8-a18f-89a7f4100bfe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
855	1	8	1	[0]	2019-06-23 11:00:00	\N	\N	7bdd6338-c4e8-4896-a210-25423f359efe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
856	1	12	1	[1]	2019-06-23 12:00:00	\N	\N	c0d0bc9e-80b1-470a-8391-0f0cc343c5d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
857	1	11	1	[0.600000024]	2019-06-23 12:00:00	\N	\N	ce0c7c52-1132-455d-b554-9dc127674b03	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
858	1	10	1	[0.600000024]	2019-06-23 12:00:00	\N	\N	4f596cad-ec1c-4157-ab32-a056cfbd74b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
859	1	9	1	[0.600000024]	2019-06-23 12:00:00	\N	\N	df355664-8d13-4871-8eb3-a8e9cee9a462	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
860	1	8	1	[0.600000024]	2019-06-23 12:00:00	\N	\N	9a554e42-d73c-47c7-8c18-d03b896675e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
861	1	12	1	[0.200000003]	2019-06-23 13:00:00	\N	\N	e437cdf1-ba2e-48c2-bc91-274609b6c57f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
862	1	11	1	[0.400000006]	2019-06-23 13:00:00	\N	\N	faff8020-7121-485e-815b-e5a65217a7eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
863	1	10	1	[0.200000003]	2019-06-23 13:00:00	\N	\N	99a3d05b-ed30-4ced-9aee-33a8b0a621ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
864	1	9	1	[0.400000006]	2019-06-23 13:00:00	\N	\N	c1fc1a3f-c490-404a-ab49-234c92bb824a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
865	1	8	1	[0.200000003]	2019-06-23 13:00:00	\N	\N	73193770-1dfe-49e7-b870-a7f0c4bff416	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
866	1	12	1	[0]	2019-06-23 14:00:00	\N	\N	9736f54d-bab2-4db4-bfa6-b7281a3970be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
867	1	11	1	[0.200000003]	2019-06-23 14:00:00	\N	\N	fc50c404-9376-4dd2-9149-b6e5f43e9e43	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
868	1	10	1	[0]	2019-06-23 14:00:00	\N	\N	16b44e61-d9ce-448b-8208-92310eed6f10	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
869	1	9	1	[0.200000003]	2019-06-23 14:00:00	\N	\N	488c6a20-2fd7-468e-9584-988a35b042a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
870	1	8	1	[0]	2019-06-23 14:00:00	\N	\N	106fb52c-df5c-4acf-be75-a298a48ba4d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
871	1	12	1	[0]	2019-06-23 15:00:00	\N	\N	2d90fb21-8147-41d9-92a8-5e64b3c987c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
872	1	11	1	[0.200000003]	2019-06-23 15:00:00	\N	\N	b1e85069-6c2d-4715-b0dd-ee977251cdbf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
873	1	10	1	[0]	2019-06-23 15:00:00	\N	\N	1686a8ce-62a2-4cd4-b1df-7fae6a9a9fc5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
874	1	9	1	[0]	2019-06-23 15:00:00	\N	\N	657d3032-253b-4e8b-bfc3-8981bd4eec2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
875	1	8	1	[0]	2019-06-23 15:00:00	\N	\N	016c5bbf-52f8-46b1-8570-553797197f58	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
876	1	12	1	[0]	2019-06-23 16:00:00	\N	\N	72b90ab1-9306-4e26-b90a-230a92048db9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
877	1	11	1	[0]	2019-06-23 16:00:00	\N	\N	28de87ec-6930-4505-ab4a-b9ce3f7f8dce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
878	1	10	1	[0]	2019-06-23 16:00:00	\N	\N	ac071c28-3c5f-41f2-b60e-201b008488ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
879	1	9	1	[0]	2019-06-23 16:00:00	\N	\N	1b503913-c2de-4cb1-a247-7faa2ff03c9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
880	1	8	1	[0]	2019-06-23 16:00:00	\N	\N	d2a8aad2-a838-4559-b116-c097487dc2d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
881	1	12	1	[0]	2019-06-23 17:00:00	\N	\N	d4636fbf-d933-4b56-bf70-dc305350998c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
882	1	11	1	[0]	2019-06-23 17:00:00	\N	\N	a4ccf2dd-2c36-4c88-a878-4e51fe20f97e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
883	1	10	1	[0]	2019-06-23 17:00:00	\N	\N	3cf570a6-faa3-41bf-bc19-a06b0ad822cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
884	1	9	1	[0]	2019-06-23 17:00:00	\N	\N	6ada0b8f-7f28-4a7b-91c8-3695fbe14fe5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
885	1	8	1	[0]	2019-06-23 17:00:00	\N	\N	989452ae-bc22-446a-bbbe-2572475569bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
886	1	12	1	[0]	2019-06-23 18:00:00	\N	\N	95cce82d-7c1c-4dc1-a0f1-ff8eac400dba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
887	1	11	1	[0]	2019-06-23 18:00:00	\N	\N	130b5814-be4b-46c9-8797-8c8168ddc165	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
888	1	10	1	[0]	2019-06-23 18:00:00	\N	\N	c40b2640-8ae4-4c58-a854-5fc6ae969197	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
889	1	9	1	[0]	2019-06-23 18:00:00	\N	\N	4bfc1167-dacf-4cd5-86b8-377c6ff8d4e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
890	1	8	1	[0]	2019-06-23 18:00:00	\N	\N	326f4293-308a-4558-854a-67d99d1ee336	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
891	1	12	1	[0]	2019-06-23 19:00:00	\N	\N	2e21bd95-12bf-452a-9953-db4c72f1046a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
892	1	11	1	[0]	2019-06-23 19:00:00	\N	\N	8cb403f9-ac28-4929-ac25-04c377807951	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
893	1	10	1	[0]	2019-06-23 19:00:00	\N	\N	96858ac8-3f3b-49fe-8541-ad1072e7c8ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
894	1	9	1	[0]	2019-06-23 19:00:00	\N	\N	3e6759ec-8662-4588-888f-f08133f9a1d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
895	1	8	1	[0]	2019-06-23 19:00:00	\N	\N	1256b252-8a1a-4127-a68b-474cf3f64c9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
896	1	12	1	[0]	2019-06-23 20:00:00	\N	\N	8a99f15e-07eb-416d-8e5b-0d1fbbc358ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
897	1	11	1	[0]	2019-06-23 20:00:00	\N	\N	bb2b9659-192f-40ea-a4c7-dc50a179173b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
898	1	10	1	[0]	2019-06-23 20:00:00	\N	\N	1f783b98-24da-4104-9792-025e7f4abe7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
899	1	9	1	[0]	2019-06-23 20:00:00	\N	\N	bc5648e5-a3ca-4a60-bde3-cf6f4125523f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
900	1	8	1	[0]	2019-06-23 20:00:00	\N	\N	35cba603-b9b5-4193-b68e-37c8db52e590	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
901	1	12	1	[0]	2019-06-23 21:00:00	\N	\N	4f37e437-5f6c-463b-b680-b5f5f734ba05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
902	1	11	1	[0]	2019-06-23 21:00:00	\N	\N	a460787a-1ed9-4c7d-aef9-c0c05ae53c80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
903	1	10	1	[0]	2019-06-23 21:00:00	\N	\N	3bfd343d-30b4-4b97-bf30-d4bec5f14e50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
904	1	9	1	[0]	2019-06-23 21:00:00	\N	\N	861130f7-1343-4a64-9e94-a3050a889ab0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
905	1	8	1	[0]	2019-06-23 21:00:00	\N	\N	2a67a15c-cff5-4de8-a748-5223d76806c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
906	1	12	1	[0]	2019-06-23 22:00:00	\N	\N	85ef1ba2-f886-4c81-8e94-0eb5d13e4e5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
907	1	11	1	[0]	2019-06-23 22:00:00	\N	\N	2c1c1351-114d-472f-9552-1e11756f3268	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
908	1	10	1	[0]	2019-06-23 22:00:00	\N	\N	88bec5e7-b16d-4825-9586-55fffd40de29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
909	1	9	1	[0]	2019-06-23 22:00:00	\N	\N	5109ab8a-fdb2-48bf-a99f-5028b4baed34	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
910	1	8	1	[0]	2019-06-23 22:00:00	\N	\N	7ce59705-04af-4a0a-be1d-d938911db114	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
911	1	12	1	[0]	2019-06-23 23:00:00	\N	\N	d2dbb8dc-ee82-46b0-b2f3-11215ca63854	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
912	1	11	1	[0]	2019-06-23 23:00:00	\N	\N	34b631fa-2176-439b-9d36-8888b64b98a1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
913	1	10	1	[0]	2019-06-23 23:00:00	\N	\N	c6588098-f25c-4eaa-9b92-e851b247113c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
914	1	9	1	[0]	2019-06-23 23:00:00	\N	\N	b6bf848a-c43d-415d-bb05-786d41f82468	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
915	1	8	1	[0]	2019-06-23 23:00:00	\N	\N	6ad8e908-01c9-4542-9de2-538f5b9733a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
916	1	12	1	[0]	2019-06-24 00:00:00	\N	\N	cf55db8e-5407-4847-8d4c-c209fda7a54e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
917	1	11	1	[0]	2019-06-24 00:00:00	\N	\N	56edc623-5a38-4eec-8d36-3daee91e48db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
918	1	10	1	[0]	2019-06-24 00:00:00	\N	\N	a993aeab-b5c7-4a6e-a1f2-dd5003efc8f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
919	1	9	1	[0]	2019-06-24 00:00:00	\N	\N	add3e52c-e5a9-4a7e-bc06-4e3dcae7eab2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
920	1	8	1	[0]	2019-06-24 00:00:00	\N	\N	87fe0d71-849d-44e8-a0fb-8927fa288d21	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
921	1	12	1	[0]	2019-06-24 01:00:00	\N	\N	4ad8196e-3bfc-4d0f-98b5-6f1e73e06ac3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
922	1	11	1	[0]	2019-06-24 01:00:00	\N	\N	7d19b301-4f4f-41d6-ab6a-25e5f2fc5e87	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
923	1	10	1	[0]	2019-06-24 01:00:00	\N	\N	12903ce1-e06b-466c-8a88-84c74e070977	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
924	1	9	1	[0]	2019-06-24 01:00:00	\N	\N	3f384cbc-e6ac-4a60-860e-a3335771af75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
925	1	8	1	[0]	2019-06-24 01:00:00	\N	\N	844ec38f-7f45-4e99-b5a6-b664becb7a9b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
926	1	12	1	[0]	2019-06-24 02:00:00	\N	\N	ada6196a-0ff2-4056-a2d4-2af8c2f97b0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
927	1	11	1	[0]	2019-06-24 02:00:00	\N	\N	3e587881-4dfc-4f3d-8632-2e102fa6ca7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
928	1	10	1	[0]	2019-06-24 02:00:00	\N	\N	33e798e0-b3cb-43e3-9a14-ee1b922382db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
929	1	9	1	[0]	2019-06-24 02:00:00	\N	\N	816ad9d1-9457-480c-9f51-ec61a2f7f39d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
930	1	8	1	[0]	2019-06-24 02:00:00	\N	\N	98a858ce-f661-4bcd-8563-b4ec0e451b69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
931	1	12	1	[0]	2019-06-24 03:00:00	\N	\N	ac9c8be8-1e61-4cc6-b9ec-5032e9b5ae33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
932	1	11	1	[0]	2019-06-24 03:00:00	\N	\N	2c9d9af4-0a16-4c2d-92b3-69d8f9f8265f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
933	1	10	1	[0]	2019-06-24 03:00:00	\N	\N	ba1c48d2-ad8b-4d2b-9523-c93fa4b972c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
934	1	9	1	[0]	2019-06-24 03:00:00	\N	\N	c2c59215-21e2-4700-9215-152c56172900	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
935	1	8	1	[0]	2019-06-24 03:00:00	\N	\N	549c9e65-be95-432b-9dbb-27b45dbe5612	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
936	1	12	1	[0]	2019-06-24 04:00:00	\N	\N	911d6779-5ced-4bef-820d-938fa1989d52	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
937	1	11	1	[0]	2019-06-24 04:00:00	\N	\N	24ba876a-3694-48be-ab4e-1e49b87dd3e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
938	1	10	1	[0]	2019-06-24 04:00:00	\N	\N	2952f0dd-722f-4105-879c-8d5969069175	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
939	1	9	1	[0]	2019-06-24 04:00:00	\N	\N	a2d7d3c9-ec7e-4e35-b1bd-b2ae95a5219f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
940	1	8	1	[0]	2019-06-24 04:00:00	\N	\N	da5367d6-531a-4d6a-94fb-96559093d53c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
941	1	12	1	[0]	2019-06-24 05:00:00	\N	\N	2fa7265c-51bf-4e89-8892-639f418decad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
942	1	11	1	[0]	2019-06-24 05:00:00	\N	\N	a7eb2d23-2c3e-48cf-9acc-11a690aab214	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
943	1	10	1	[0]	2019-06-24 05:00:00	\N	\N	13d10cb0-1761-4820-bd5d-1f573f918af5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
944	1	9	1	[0]	2019-06-24 05:00:00	\N	\N	f49a9431-a150-49d7-b42b-bdb5b47c6c83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
945	1	8	1	[0]	2019-06-24 05:00:00	\N	\N	88cf5b8c-02f7-480b-a42b-882c4777105c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
946	1	12	1	[0]	2019-06-24 06:00:00	\N	\N	61c3f1ce-fd76-4678-8b44-f93ac91fb70d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
947	1	11	1	[0]	2019-06-24 06:00:00	\N	\N	b54c22b7-1e01-4838-9046-3ad6bf574beb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
948	1	10	1	[0]	2019-06-24 06:00:00	\N	\N	48bd0ae1-e583-4294-bb16-5d0142ad40c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
949	1	9	1	[0]	2019-06-24 06:00:00	\N	\N	96d33fd8-119c-44a8-83a2-4d8ee5cab19b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
950	1	8	1	[0]	2019-06-24 06:00:00	\N	\N	56e81e38-43d0-45ec-ae71-e4764e9b708f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
951	1	12	1	[0]	2019-06-24 07:00:00	\N	\N	5d92eb76-1d40-49f6-9c56-1df5346d1426	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
952	1	11	1	[0]	2019-06-24 07:00:00	\N	\N	9f6d9527-dbea-4cd6-9804-fbfbfee026fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
953	1	10	1	[0]	2019-06-24 07:00:00	\N	\N	46fdd062-a6d0-4da2-88e3-3f00000cfae0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
954	1	9	1	[0]	2019-06-24 07:00:00	\N	\N	e1cbf194-3674-48db-8767-eb034b3bd902	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
955	1	8	1	[0]	2019-06-24 07:00:00	\N	\N	332d7a16-771d-46e9-9163-3af7f9780af6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
956	1	12	1	[0]	2019-06-24 08:00:00	\N	\N	69027036-1ee6-4849-808f-87e57835d6e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
957	1	11	1	[0]	2019-06-24 08:00:00	\N	\N	016edb92-3d61-4d8f-9a97-69f3965d728d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
958	1	10	1	[0]	2019-06-24 08:00:00	\N	\N	a12cc2e5-2626-444f-8cb6-c4878d408922	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
959	1	9	1	[0]	2019-06-24 08:00:00	\N	\N	1ca21bd5-746d-4810-8126-89eba1a56573	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
960	1	8	1	[0]	2019-06-24 08:00:00	\N	\N	756d06d7-aeb0-4b2d-bde5-b195f6e8e18b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
961	1	12	1	[0]	2019-06-24 09:00:00	\N	\N	39da47ac-3e74-4aa4-a03c-7fc0aacf03d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
962	1	11	1	[0]	2019-06-24 09:00:00	\N	\N	91dc339f-146e-4e5d-8016-80bef5cc5957	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
963	1	10	1	[0]	2019-06-24 09:00:00	\N	\N	f5964ceb-f34e-4758-bf6c-5caae78454a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
964	1	9	1	[0]	2019-06-24 09:00:00	\N	\N	4abbaf3b-a511-43ff-af34-eebe95c4eeb3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
965	1	8	1	[0]	2019-06-24 09:00:00	\N	\N	610eb858-afdf-4460-b834-8dad1cb39a26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
966	1	12	1	[0]	2019-06-24 10:00:00	\N	\N	9275558b-9c4d-4c05-b45f-6701d2a2b5b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
967	1	11	1	[0]	2019-06-24 10:00:00	\N	\N	904dc164-c64f-4698-b0a7-3ff0e7ef1fe8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
968	1	10	1	[0]	2019-06-24 10:00:00	\N	\N	1642f9e5-1647-4399-b84b-c88b9afa911a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
969	1	9	1	[0]	2019-06-24 10:00:00	\N	\N	ebd736c7-342f-46c5-9c07-f6263738225a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
970	1	8	1	[0]	2019-06-24 10:00:00	\N	\N	0502168d-1fce-4e79-aee5-aefc6cd9043f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
971	1	12	1	[0]	2019-06-24 11:00:00	\N	\N	b9c388e7-d071-4b31-8181-df360e2cc626	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
972	1	11	1	[0]	2019-06-24 11:00:00	\N	\N	a0215756-851e-4543-a183-d013edabd07a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
973	1	10	1	[0]	2019-06-24 11:00:00	\N	\N	a6030f6c-b43b-44c3-90f9-f475da243dd5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
974	1	9	1	[0]	2019-06-24 11:00:00	\N	\N	e407856f-6bf7-4eb5-8d6e-1f8bdb77e1ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
975	1	8	1	[0]	2019-06-24 11:00:00	\N	\N	f7e084e9-756f-4341-ae3f-de9e2b073e1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
976	1	12	1	[0]	2019-06-24 12:00:00	\N	\N	149a6e75-30ae-4435-8553-ee517d5f664d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
977	1	11	1	[0]	2019-06-24 12:00:00	\N	\N	3885a8b4-ff2a-4bfb-9225-81c49e56179c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
978	1	10	1	[0]	2019-06-24 12:00:00	\N	\N	58c73c39-be88-4667-bac2-a69fb66a7bde	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
979	1	9	1	[0]	2019-06-24 12:00:00	\N	\N	f7b740bf-29df-48e6-a963-a4f299aaed0f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
980	1	8	1	[0]	2019-06-24 12:00:00	\N	\N	b56d98e9-81eb-400a-986f-70d5a1496ed0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
981	1	12	1	[0]	2019-06-24 13:00:00	\N	\N	d16ee99b-1842-4799-a832-8cb8b6094727	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
982	1	11	1	[0]	2019-06-24 13:00:00	\N	\N	cf1e25a7-afe0-4f9d-9c3d-ffc829efcd80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
983	1	10	1	[0]	2019-06-24 13:00:00	\N	\N	0ca09260-2407-42e2-996d-61e88da11f04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
984	1	9	1	[0]	2019-06-24 13:00:00	\N	\N	b60bbca4-26bc-4956-9c4b-f8e4ca6859ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
985	1	8	1	[0]	2019-06-24 13:00:00	\N	\N	f70191a4-be0f-45b3-ac53-49abbde77b57	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
986	1	12	1	[0]	2019-06-24 14:00:00	\N	\N	0d9dbb3d-0f59-4912-980f-eecc4af801e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
987	1	11	1	[0]	2019-06-24 14:00:00	\N	\N	d9cd0c5e-7dcc-45c5-9d32-3d26226982cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
988	1	10	1	[0]	2019-06-24 14:00:00	\N	\N	3e612608-c0b4-4bd9-9e2a-546922446378	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
989	1	9	1	[0]	2019-06-24 14:00:00	\N	\N	44933226-482c-429d-bd8d-2b72d706eda4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
990	1	8	1	[0]	2019-06-24 14:00:00	\N	\N	8e47310d-9b37-441f-9a52-a59c5af32793	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
991	1	12	1	[0]	2019-06-24 15:00:00	\N	\N	4185f589-03c1-4616-9af5-7036c56fbaf4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
992	1	11	1	[0]	2019-06-24 15:00:00	\N	\N	307b142e-a549-41f7-a784-a91e04cc5865	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
993	1	10	1	[0]	2019-06-24 15:00:00	\N	\N	812ac96f-03a4-45c5-ab4f-682413d53dd6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
994	1	9	1	[0]	2019-06-24 15:00:00	\N	\N	760bf19e-f564-4e66-888c-ae22da972e15	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
995	1	8	1	[0]	2019-06-24 15:00:00	\N	\N	2954c904-dc8e-46f7-8220-35e46d066f63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
996	1	12	1	[0]	2019-06-24 16:00:00	\N	\N	bec0d07b-554b-4e9d-a2b0-e218d36b67ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
997	1	11	1	[0]	2019-06-24 16:00:00	\N	\N	cd464906-0d83-406a-9a6b-7b350fecd019	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
998	1	10	1	[0]	2019-06-24 16:00:00	\N	\N	4445d6f6-26f4-4727-a536-57b411a69f26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
999	1	9	1	[0]	2019-06-24 16:00:00	\N	\N	c0f02467-998c-42cb-91d6-a5a10e6eeba3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1000	1	8	1	[0]	2019-06-24 16:00:00	\N	\N	860d2cd4-3088-433c-b557-2ab2d2cc0248	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1001	1	12	1	[0.600000024]	2019-06-24 17:00:00	\N	\N	fe898d3d-2887-4942-964d-9722eb47ceb6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1002	1	11	1	[0]	2019-06-24 17:00:00	\N	\N	f0c02bb4-c6ba-4fc9-8501-138de3314144	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1003	1	10	1	[0.400000006]	2019-06-24 17:00:00	\N	\N	83e762ed-c254-475a-908f-877149383b2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1004	1	9	1	[0.600000024]	2019-06-24 17:00:00	\N	\N	2495ac67-deb5-4de0-9e91-b6400e6ab8c0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1005	1	8	1	[0.400000006]	2019-06-24 17:00:00	\N	\N	e95bba21-e196-4f78-9325-b7d2cffd896f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1006	1	12	1	[0.200000003]	2019-06-24 18:00:00	\N	\N	aa5341e1-dcc7-4cf0-bb75-c173b0d9ac07	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1007	1	11	1	[0]	2019-06-24 18:00:00	\N	\N	596b9ce9-a539-43c3-aad9-f01ee13737cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1008	1	10	1	[0.600000024]	2019-06-24 18:00:00	\N	\N	91834b9f-1a87-45cd-afa4-2a84a238608e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1009	1	9	1	[0]	2019-06-24 18:00:00	\N	\N	8bf8aa5c-6b67-4284-9dfb-e058c2c694e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1010	1	8	1	[0.800000012]	2019-06-24 18:00:00	\N	\N	809ac70a-1e8f-4f81-91a2-629893dd3b6f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1011	1	12	1	[0.600000024]	2019-06-24 19:00:00	\N	\N	7a92770d-f20d-474f-988d-e413390efdeb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1012	1	11	1	[0.200000003]	2019-06-24 19:00:00	\N	\N	db3fdbfc-fc17-497b-8b70-d0e17fc7dd12	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1013	1	10	1	[1]	2019-06-24 19:00:00	\N	\N	a26dcd7a-6151-4ce0-8499-2d70bcd43eda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1014	1	9	1	[0.600000024]	2019-06-24 19:00:00	\N	\N	0b662b4b-ccf5-4fa5-b2c5-6a8c7df21eb1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1015	1	8	1	[1]	2019-06-24 19:00:00	\N	\N	7c8ba56d-472c-4df4-8117-628d72cfc596	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1016	1	12	1	[0.400000006]	2019-06-24 20:00:00	\N	\N	8ee75e4c-1029-4984-ad08-4aab1abc176b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1017	1	11	1	[0]	2019-06-24 20:00:00	\N	\N	4822f53b-cfc1-4dbb-a96f-73a577718965	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1018	1	10	1	[0.400000006]	2019-06-24 20:00:00	\N	\N	4b5dff3e-0d34-4602-a878-8382ba718721	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1019	1	9	1	[0.200000003]	2019-06-24 20:00:00	\N	\N	99c9adad-68b5-409d-89c8-f31d25e37c55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1020	1	8	1	[0.400000006]	2019-06-24 20:00:00	\N	\N	387090ea-6c66-4220-b040-dc3d8e8e6314	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1021	1	12	1	[0.200000003]	2019-06-24 21:00:00	\N	\N	50d62350-124e-4276-b667-9be439f63677	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1022	1	11	1	[0.200000003]	2019-06-24 21:00:00	\N	\N	104ab436-59a5-4067-96e2-3d4469db5ff0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1023	1	10	1	[0]	2019-06-24 21:00:00	\N	\N	6c0b8f26-fbad-4b42-b819-46795a7fd479	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1024	1	9	1	[0.200000003]	2019-06-24 21:00:00	\N	\N	be112308-076a-434a-9f5d-7f509b2fb647	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1025	1	8	1	[0.200000003]	2019-06-24 21:00:00	\N	\N	c55ef9f2-1787-4e2b-8e0a-65e1bf0a8cac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1026	1	12	1	[0.200000003]	2019-06-24 22:00:00	\N	\N	3749e512-e4eb-4520-9c4b-b772279f791b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1027	1	11	1	[0]	2019-06-24 22:00:00	\N	\N	29a84201-5ca1-4b6b-9a5c-baba07abac18	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1028	1	10	1	[0.200000003]	2019-06-24 22:00:00	\N	\N	e8aea734-0429-4dbd-970c-f12d9b87c9a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1029	1	9	1	[0]	2019-06-24 22:00:00	\N	\N	cad2d149-c6e3-4547-868a-1e9b6ef3c6b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1030	1	8	1	[0.200000003]	2019-06-24 22:00:00	\N	\N	cbd6a25a-1ef1-4ba6-912c-68a5efa2aa62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1031	1	12	1	[0]	2019-06-24 23:00:00	\N	\N	b14dd51d-bec1-4ad0-b5ec-db35aca05060	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1032	1	11	1	[0]	2019-06-24 23:00:00	\N	\N	dec0490c-df44-4287-9ea9-14fe770d22c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1033	1	10	1	[0.200000003]	2019-06-24 23:00:00	\N	\N	b04fcc1e-5fe3-432c-a725-f2ee5d8a3975	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1034	1	9	1	[0.200000003]	2019-06-24 23:00:00	\N	\N	a03fa345-2720-4708-a818-9ffb8b728e23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1035	1	8	1	[0]	2019-06-24 23:00:00	\N	\N	bba2bd2d-9f8e-4c93-ba33-bea8c2c79605	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1036	1	12	1	[0.200000003]	2019-06-25 00:00:00	\N	\N	8d8c570c-8e67-4d67-9120-c2027eac2a39	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1037	1	11	1	[0]	2019-06-25 00:00:00	\N	\N	f1bb2934-e316-4583-ad22-373ca5f5a33f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1038	1	10	1	[0]	2019-06-25 00:00:00	\N	\N	7ddb6da0-2c59-4ad8-a10a-aedf6c14f444	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1039	1	9	1	[0]	2019-06-25 00:00:00	\N	\N	78209832-b50b-4245-8ea0-8ead97542c3f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1040	1	8	1	[0.200000003]	2019-06-25 00:00:00	\N	\N	f8462554-bb9a-4204-8230-5cb6af411f97	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1041	1	12	1	[0]	2019-06-25 01:00:00	\N	\N	e92a7224-fb1a-4774-98b1-ab826eb429c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1042	1	11	1	[0.200000003]	2019-06-25 01:00:00	\N	\N	73da4e67-4a91-4067-b607-709c18aaa80a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1043	1	10	1	[0]	2019-06-25 01:00:00	\N	\N	636b584c-f010-413b-ae77-ae8a4230f9ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1044	1	9	1	[0.200000003]	2019-06-25 01:00:00	\N	\N	7fd30f19-ee10-4461-a0d0-e07aaae7536b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1045	1	8	1	[0]	2019-06-25 01:00:00	\N	\N	c244bf21-d373-4f67-8794-cdc9b5490b5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1046	1	12	1	[0]	2019-06-25 02:00:00	\N	\N	6c53c80c-12a2-4278-87ee-cfd125c5be7e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1047	1	11	1	[0.200000003]	2019-06-25 02:00:00	\N	\N	a01325b3-a073-47dd-8ac3-cdd9fd3e9cd9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1048	1	10	1	[0.200000003]	2019-06-25 02:00:00	\N	\N	4c9a6c23-cf39-410e-8e1c-2f80a3b8fb31	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1049	1	9	1	[0]	2019-06-25 02:00:00	\N	\N	ccaad000-ed87-4188-ac33-543b83b32068	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1050	1	8	1	[0.200000003]	2019-06-25 02:00:00	\N	\N	cb93bec7-567b-40c7-a26b-7393ca820398	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1051	1	12	1	[0.400000006]	2019-06-25 03:00:00	\N	\N	4f00f509-c072-4a4a-b5c2-a95a54f3a501	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1052	1	11	1	[0]	2019-06-25 03:00:00	\N	\N	ecc31fda-67f2-475a-a79a-9f2c4ae22e2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1053	1	10	1	[0.200000003]	2019-06-25 03:00:00	\N	\N	460067da-36cc-492f-b557-cffbecd20ab3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1054	1	9	1	[0]	2019-06-25 03:00:00	\N	\N	2be9aaa5-cdcb-46b6-ac59-f0a4254a3039	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1055	1	8	1	[1]	2019-06-25 03:00:00	\N	\N	6c8e75dc-e45c-448b-9a63-9ddc091b1a6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1056	1	12	1	[0]	2019-06-25 04:00:00	\N	\N	958936d4-2d4b-4c3a-819f-fb93546e794d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1057	1	11	1	[0.400000006]	2019-06-25 04:00:00	\N	\N	b70fc51e-50fe-4e49-8c73-f951c2479151	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1058	1	10	1	[1.39999998]	2019-06-25 04:00:00	\N	\N	ef4299cc-3147-42c4-af6d-36c4031a4d52	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1059	1	9	1	[0.200000003]	2019-06-25 04:00:00	\N	\N	88e6321e-6946-4175-98dc-421aa9cbf12c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1060	1	8	1	[2]	2019-06-25 04:00:00	\N	\N	e2f905b7-1b93-46bf-b339-a0656156ec25	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1061	1	12	1	[0]	2019-06-25 05:00:00	\N	\N	c13c8de9-ee2d-442a-abd4-f06e4e753ff8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1062	1	11	1	[0]	2019-06-25 05:00:00	\N	\N	9f7d01f6-02cf-4cf0-9028-a5beaa4a42ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1063	1	10	1	[0.200000003]	2019-06-25 05:00:00	\N	\N	801cac9e-0da2-4a27-8e30-997a81833542	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1064	1	9	1	[0]	2019-06-25 05:00:00	\N	\N	8dd9c945-4f62-4ac3-932a-cf23f4ddcbf3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1065	1	8	1	[0.200000003]	2019-06-25 05:00:00	\N	\N	a30609ae-231b-4d6e-9858-905402c365a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1066	1	12	1	[0.400000006]	2019-06-25 06:00:00	\N	\N	635d70bf-4a62-47c3-83fd-5f6ba4d59ad3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1067	1	11	1	[0.200000003]	2019-06-25 06:00:00	\N	\N	024486f7-efca-4c24-82ee-220e1537e56b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1068	1	10	1	[0.200000003]	2019-06-25 06:00:00	\N	\N	0f83509c-5b38-4e52-aaf0-72e331e58b39	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1069	1	9	1	[0.400000006]	2019-06-25 06:00:00	\N	\N	0abad158-f19a-4e27-bd86-af9196482638	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1070	1	8	1	[0.400000006]	2019-06-25 06:00:00	\N	\N	e272baa6-9414-4335-bcea-1a728503ab95	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1071	1	12	1	[0.200000003]	2019-06-25 07:00:00	\N	\N	a37311d7-2949-42ae-96b2-f51075942449	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1072	1	11	1	[0.200000003]	2019-06-25 07:00:00	\N	\N	01b5f7a5-05c2-4b75-8b7c-42032e1b8dec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1073	1	10	1	[0]	2019-06-25 07:00:00	\N	\N	c0f9bdcb-de00-46f8-a4bd-684a78955e6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1074	1	9	1	[0.200000003]	2019-06-25 07:00:00	\N	\N	855daff4-eb80-4ac2-9833-2d91fb2c66de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1075	1	8	1	[0.200000003]	2019-06-25 07:00:00	\N	\N	5fa55e5f-3ce3-48da-bbde-ef07a47ca59f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1076	1	12	1	[0.200000003]	2019-06-25 08:00:00	\N	\N	b220f1d0-7c0b-43e2-959d-b0bcbad508c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1077	1	11	1	[0]	2019-06-25 08:00:00	\N	\N	8d80078e-07b6-4874-bcbd-177d7151f19c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1078	1	10	1	[0.200000003]	2019-06-25 08:00:00	\N	\N	43df5626-7edc-4fbf-9457-3747b346d580	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1079	1	9	1	[0]	2019-06-25 08:00:00	\N	\N	cc1eddb4-c39a-4cd6-afb5-05f328a821b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1080	1	8	1	[0]	2019-06-25 08:00:00	\N	\N	0cb0875f-3abc-4f3a-b376-e56bb6e40425	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1081	1	12	1	[0]	2019-06-25 09:00:00	\N	\N	3c1b9169-ef60-4275-87d0-fc3404e08ad7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1082	1	11	1	[0]	2019-06-25 09:00:00	\N	\N	6732b552-7551-4fac-a175-4a240c4ef90c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1083	1	10	1	[0]	2019-06-25 09:00:00	\N	\N	77280275-05f6-494a-9a42-1c4db7e8cc10	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1084	1	9	1	[0]	2019-06-25 09:00:00	\N	\N	f1a0f3d8-6ab3-4736-b2ec-362bacac36a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1085	1	8	1	[0]	2019-06-25 09:00:00	\N	\N	b5f4bc4f-ca95-4931-9ab9-e4bd969518cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1086	1	12	1	[0]	2019-06-25 10:00:00	\N	\N	31bb23a6-38d7-488f-82ea-d78e463180ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1087	1	11	1	[0.200000003]	2019-06-25 10:00:00	\N	\N	9bd109f3-a6c7-4ab7-9c50-29a560482721	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1088	1	10	1	[0]	2019-06-25 10:00:00	\N	\N	87dc9340-8d63-4fa6-a4e5-3f8488322293	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1089	1	9	1	[0]	2019-06-25 10:00:00	\N	\N	f84fb9db-7c6e-41a5-946c-a92b056c0624	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1090	1	8	1	[0]	2019-06-25 10:00:00	\N	\N	d6554d6d-f241-4725-b9c3-e7a5a0a72ff8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1091	1	12	1	[0]	2019-06-25 11:00:00	\N	\N	8f5327ab-220f-447a-9254-39907b717774	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1092	1	11	1	[0.200000003]	2019-06-25 11:00:00	\N	\N	7801bcc6-c0c7-4ad6-855e-0e070dd22615	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1093	1	10	1	[0]	2019-06-25 11:00:00	\N	\N	43cb08ee-165e-47e2-9da8-016a2d896139	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1094	1	9	1	[0]	2019-06-25 11:00:00	\N	\N	4dac621c-53ec-4f65-a4cb-72b9baf30f2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1095	1	8	1	[0]	2019-06-25 11:00:00	\N	\N	8a15f7f9-b9a5-4f3e-93cb-a61e181c550d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1096	1	12	1	[0]	2019-06-25 12:00:00	\N	\N	3bd37d9a-1625-4a41-819b-3d6df28de16c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1097	1	11	1	[0]	2019-06-25 12:00:00	\N	\N	5edb7cfc-e32b-4a2f-80de-fe32f51af3fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1098	1	10	1	[0]	2019-06-25 12:00:00	\N	\N	a228d2ca-ff5a-4a32-9b59-094a2d435f2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1099	1	9	1	[0]	2019-06-25 12:00:00	\N	\N	4c762d8a-ecf6-4daa-9464-73f3be960355	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1100	1	8	1	[0]	2019-06-25 12:00:00	\N	\N	0d6b5abf-4956-4301-a392-3940052f10c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1101	1	12	1	[0]	2019-06-25 13:00:00	\N	\N	6174e946-5511-41e2-bcb3-f101ab5ef02d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1102	1	11	1	[0]	2019-06-25 13:00:00	\N	\N	62c29e9e-e5bd-4fac-a52b-1e97688e25a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1103	1	10	1	[0]	2019-06-25 13:00:00	\N	\N	ce0c3278-490d-4690-9de0-6c37423ec6d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1104	1	9	1	[0]	2019-06-25 13:00:00	\N	\N	45d84e7c-da96-4633-849e-ebd8d6b56808	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1105	1	8	1	[0]	2019-06-25 13:00:00	\N	\N	2eba9adb-45ce-4afb-93cc-0c5d2f5e6203	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1106	1	12	1	[0]	2019-06-25 14:00:00	\N	\N	6c56c2ed-f6c3-49a0-a93b-a8667a79a401	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1107	1	11	1	[0]	2019-06-25 14:00:00	\N	\N	46fd4f1d-14dc-4cae-a43e-1dcb8afaa852	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1108	1	10	1	[0]	2019-06-25 14:00:00	\N	\N	363c6fdb-02bb-4328-9494-ee18046bc369	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1109	1	9	1	[0]	2019-06-25 14:00:00	\N	\N	e27e126b-506b-43c0-8d12-4aad0bb4dc8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1110	1	8	1	[0]	2019-06-25 14:00:00	\N	\N	ec712a49-a336-4f0f-afb1-1e29562b7703	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1111	1	12	1	[0]	2019-06-25 15:00:00	\N	\N	5392895a-64e6-453a-accb-7efeb1d32bf8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1112	1	11	1	[0]	2019-06-25 15:00:00	\N	\N	310fc2a4-0aaf-4c71-936e-17cc3594187b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1113	1	10	1	[0]	2019-06-25 15:00:00	\N	\N	4ebebf2b-4a24-49a2-8d06-44d74666a5fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1114	1	9	1	[0]	2019-06-25 15:00:00	\N	\N	2e2886ac-dacd-4d4b-9214-43febe82daa0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1115	1	8	1	[0]	2019-06-25 15:00:00	\N	\N	e18c6b7f-bf4c-4d04-9e1e-3138969d275c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1116	1	12	1	[0]	2019-06-25 16:00:00	\N	\N	c8ac5a67-3fec-4d43-b95b-874ec1733353	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1117	1	11	1	[0]	2019-06-25 16:00:00	\N	\N	b337aa18-bcb0-4d59-8cb1-320a4f82dc69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1118	1	10	1	[0]	2019-06-25 16:00:00	\N	\N	beff17af-96e2-442f-a781-3da90d429ed5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1119	1	9	1	[0]	2019-06-25 16:00:00	\N	\N	27ec6044-cf7d-4b31-a38c-0abda882803b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1120	1	8	1	[0]	2019-06-25 16:00:00	\N	\N	3e144172-4e49-442c-b664-42aed4ef946b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1121	1	12	1	[0]	2019-06-25 17:00:00	\N	\N	d39c7f8a-3710-48c4-909a-19f209cb5641	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1122	1	11	1	[0]	2019-06-25 17:00:00	\N	\N	d797fe1b-08bb-4b73-b3d5-120aa4e0df8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1123	1	10	1	[0]	2019-06-25 17:00:00	\N	\N	462955d7-5cb1-4d6b-870c-99a32a74e9f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1124	1	9	1	[0]	2019-06-25 17:00:00	\N	\N	990e0d3a-29e4-4000-92d3-a7517ae993bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1125	1	8	1	[0]	2019-06-25 17:00:00	\N	\N	d43132a8-fdb9-40d9-91f2-7afa37eb1809	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1126	1	12	1	[0]	2019-06-25 18:00:00	\N	\N	cc6ee727-2c91-4750-93e7-d356016376ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1127	1	11	1	[0]	2019-06-25 18:00:00	\N	\N	116a3aec-12e2-4be7-b602-6bd3c14969b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1128	1	10	1	[0]	2019-06-25 18:00:00	\N	\N	f661ad25-c8eb-4cb8-a84e-dbb04bb7f2d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1129	1	9	1	[0]	2019-06-25 18:00:00	\N	\N	9d26fd9d-1849-48b7-b832-f21370015813	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1130	1	8	1	[0]	2019-06-25 18:00:00	\N	\N	8493d2a4-563a-44c4-b79e-1c93747150f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1131	1	12	1	[0]	2019-06-25 19:00:00	\N	\N	566a0cc7-7548-4f7c-85a4-b98ebd67fb91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1132	1	11	1	[0]	2019-06-25 19:00:00	\N	\N	ba8e8c14-9c29-40ec-9b5e-e5cd8ca45f6d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1133	1	10	1	[0]	2019-06-25 19:00:00	\N	\N	8e9fdac6-0608-47d8-acf1-47c02c5ff474	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1134	1	9	1	[0]	2019-06-25 19:00:00	\N	\N	6133935e-6f7c-4095-8d41-43d6ab6e1cfa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1135	1	8	1	[0]	2019-06-25 19:00:00	\N	\N	db9b11ce-abe1-4322-b202-8fdfe5db4ab1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1136	1	12	1	[0]	2019-06-25 20:00:00	\N	\N	160b320f-2f4e-4eac-b843-c6b0bb060056	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1137	1	11	1	[0]	2019-06-25 20:00:00	\N	\N	7eb1b0e6-0ca0-4aac-8fd1-83f521c8ac43	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1138	1	10	1	[0]	2019-06-25 20:00:00	\N	\N	5657abc7-06cf-4a05-8c75-bab7fa34801a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1139	1	9	1	[0]	2019-06-25 20:00:00	\N	\N	40702f31-c07e-4c98-ab07-ed0f49d5abad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1140	1	8	1	[0]	2019-06-25 20:00:00	\N	\N	54bf0d20-ed7d-4be7-845a-f5f7b8a9b9ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1141	1	12	1	[0]	2019-06-25 21:00:00	\N	\N	edaa3a34-4b05-4a09-909d-d98256944eaa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1142	1	11	1	[0]	2019-06-25 21:00:00	\N	\N	c76b53a7-f56f-49a4-8273-e75f84ae1916	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1143	1	10	1	[0]	2019-06-25 21:00:00	\N	\N	518bbdd4-c8c4-4ee2-8dbe-58076bb0cfb4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1144	1	9	1	[0]	2019-06-25 21:00:00	\N	\N	aece7c50-0016-443d-8e52-364e389c5116	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1145	1	8	1	[0]	2019-06-25 21:00:00	\N	\N	4357ab3c-10fc-457c-8f86-5773464e72fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1146	1	12	1	[0]	2019-06-25 22:00:00	\N	\N	8c818e44-2f0e-4137-beb8-01f9f5f7aefd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1147	1	11	1	[0]	2019-06-25 22:00:00	\N	\N	1edb9e43-b0a1-4510-8b6c-0ceb60c463bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1148	1	10	1	[0]	2019-06-25 22:00:00	\N	\N	62ddcd41-148f-45e1-8d1d-50fe7273f4cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1149	1	9	1	[0]	2019-06-25 22:00:00	\N	\N	9b55b600-8690-4904-bf52-24a90f34f6bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1150	1	8	1	[0]	2019-06-25 22:00:00	\N	\N	d739ca7c-1a74-49a8-a08f-764f26d201d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1151	1	12	1	[0]	2019-06-25 23:00:00	\N	\N	df057bb6-eff2-4b53-b461-4362dcf52019	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1152	1	11	1	[0]	2019-06-25 23:00:00	\N	\N	b371ae99-368b-41bb-b24a-69ac08b9ff26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1153	1	10	1	[0]	2019-06-25 23:00:00	\N	\N	26f3760d-a3cb-49d6-9e65-8f2c7674fe4a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1154	1	9	1	[0]	2019-06-25 23:00:00	\N	\N	4e3c2691-ab19-44e3-9be2-31b873b3ed09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1155	1	8	1	[0]	2019-06-25 23:00:00	\N	\N	3d5576a4-eeeb-4ac2-ac7d-44cd262126c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1156	1	12	1	[0]	2019-06-26 00:00:00	\N	\N	7b4fedbd-81b3-4ded-ac25-ad508ef56a4c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1157	1	11	1	[0]	2019-06-26 00:00:00	\N	\N	3620809e-c70e-4984-88eb-381309464f57	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1158	1	10	1	[0]	2019-06-26 00:00:00	\N	\N	106811bf-9c01-4fd3-91a7-9c8cf68a5064	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1159	1	9	1	[0]	2019-06-26 00:00:00	\N	\N	f6c67dbf-96f3-4a2a-b989-df24adadcc51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1160	1	8	1	[0]	2019-06-26 00:00:00	\N	\N	baafaa0c-b8d5-48a4-9fae-6fa3bcb5075f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1161	1	12	1	[0]	2019-06-26 01:00:00	\N	\N	928b56c9-547f-4fa0-a30e-3a5d90bc99fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1162	1	11	1	[0]	2019-06-26 01:00:00	\N	\N	f117ca1b-7ffb-494b-8093-957c88fcf6d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1163	1	10	1	[0]	2019-06-26 01:00:00	\N	\N	39294e7c-f426-4058-93f7-d33e92c7465e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1164	1	9	1	[0]	2019-06-26 01:00:00	\N	\N	e6ab9fe8-9f80-4244-baff-422633d0210a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1165	1	8	1	[0]	2019-06-26 01:00:00	\N	\N	bbb1900a-938b-4bb1-9e5e-5c41e75760ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1166	1	12	1	[0]	2019-06-26 02:00:00	\N	\N	06697980-f061-469f-96cc-c397b2af3966	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1167	1	11	1	[0]	2019-06-26 02:00:00	\N	\N	26f0ec83-f7ea-42f8-af7d-a1a349ed28d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1168	1	10	1	[0]	2019-06-26 02:00:00	\N	\N	504b301d-b646-4b4f-8489-53eea6a41524	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1169	1	9	1	[0]	2019-06-26 02:00:00	\N	\N	0a713943-ebe8-4fab-90b1-fc6d2fecd9a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1170	1	8	1	[0]	2019-06-26 02:00:00	\N	\N	a92ac63c-f4da-4b12-a61f-4b3457352aac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1171	1	12	1	[0]	2019-06-26 03:00:00	\N	\N	3ab8ecc2-eedd-403d-8d55-ba5f16d98af9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1172	1	11	1	[0]	2019-06-26 03:00:00	\N	\N	be0e9572-b11e-4be3-b155-1ebf29ef67b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1173	1	10	1	[0]	2019-06-26 03:00:00	\N	\N	47de8fc7-6644-48f4-bafc-6fb53cce28fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1174	1	9	1	[0]	2019-06-26 03:00:00	\N	\N	f235e7b7-e234-419f-8ce7-04a9546ef167	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1175	1	8	1	[0]	2019-06-26 03:00:00	\N	\N	11bc5e24-add2-4690-99af-bedb58eda3aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1176	1	12	1	[0]	2019-06-26 04:00:00	\N	\N	be97de78-23fb-4b03-9f3e-a8e703e81723	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1177	1	11	1	[0]	2019-06-26 04:00:00	\N	\N	405f87fa-89cc-4447-9394-e7953edda5aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1178	1	10	1	[0]	2019-06-26 04:00:00	\N	\N	00e49388-1914-42e0-a0d5-7a15f715357a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1179	1	9	1	[0]	2019-06-26 04:00:00	\N	\N	20f4c754-6e4f-448f-ae2f-6962ecda6aa0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1180	1	8	1	[0]	2019-06-26 04:00:00	\N	\N	e4662c5e-ac15-481d-8d71-7d33a954fbc0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1181	1	12	1	[0]	2019-06-26 05:00:00	\N	\N	52b006bb-5ec5-4b20-bbdf-789889ae3b92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1182	1	11	1	[0]	2019-06-26 05:00:00	\N	\N	cecdcb04-de13-439b-b0d7-4fb20b9765d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1183	1	10	1	[0]	2019-06-26 05:00:00	\N	\N	d3d730a9-6fdc-4f2a-a350-3f463efc39c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1184	1	9	1	[0]	2019-06-26 05:00:00	\N	\N	aa75f558-8e67-4abe-8687-d0f3a1a3470c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1185	1	8	1	[0]	2019-06-26 05:00:00	\N	\N	175d6bbd-2136-4a73-ab7f-75a7c17c4183	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1186	1	12	1	[0]	2019-06-26 06:00:00	\N	\N	f665bb46-7eec-4ec6-8875-4204da3b0774	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1187	1	11	1	[0]	2019-06-26 06:00:00	\N	\N	029172ef-f29e-4a63-b055-014516375356	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1188	1	10	1	[0]	2019-06-26 06:00:00	\N	\N	0179a8ff-41c6-4a87-9ff7-bcc54ddfe86f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1189	1	9	1	[0]	2019-06-26 06:00:00	\N	\N	bc6effca-ae27-4027-a60b-827d90f03750	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1190	1	8	1	[0]	2019-06-26 06:00:00	\N	\N	76873793-b9ff-40fd-b93d-cf6ef4311b26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1191	1	12	1	[0.200000003]	2019-06-26 07:00:00	\N	\N	5c151f72-ab9e-46ec-a799-2ca20ce2a1f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1192	1	11	1	[0]	2019-06-26 07:00:00	\N	\N	a4723485-5a18-49d8-9be8-31c5794a2e71	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1193	1	10	1	[0.400000006]	2019-06-26 07:00:00	\N	\N	a6a2e3b3-165c-4d14-8ea8-0fa703deabcd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1194	1	9	1	[0.200000003]	2019-06-26 07:00:00	\N	\N	25fd2598-6c95-4b3f-b095-0dd09e362cd4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1195	1	8	1	[0.400000006]	2019-06-26 07:00:00	\N	\N	4c273f47-247c-4712-b59f-13ce2d2a85b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1196	1	12	1	[0.200000003]	2019-06-26 08:00:00	\N	\N	c5252b66-8929-402b-9272-41ab7f909d03	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1197	1	11	1	[0.200000003]	2019-06-26 08:00:00	\N	\N	fe542b58-bfe7-4b51-9ed5-09b1381c006f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1198	1	10	1	[0.200000003]	2019-06-26 08:00:00	\N	\N	edb2e604-a6a9-4fb9-9242-83dc8822477f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1199	1	9	1	[0.400000006]	2019-06-26 08:00:00	\N	\N	413015ac-76bf-4033-a46c-4fe26da82bb5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1200	1	8	1	[0]	2019-06-26 08:00:00	\N	\N	222b96ab-c044-44ad-8034-6695b55fde88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1201	1	12	1	[0]	2019-06-26 09:00:00	\N	\N	4bebe8a0-ad6d-45b3-8db7-50eefed5b6c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1202	1	11	1	[0]	2019-06-26 09:00:00	\N	\N	0c24e62d-8318-476c-8157-41ae6e8ea885	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1203	1	10	1	[0]	2019-06-26 09:00:00	\N	\N	e26c7355-9844-4faa-9999-e5ec942c5ff0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1204	1	9	1	[0.200000003]	2019-06-26 09:00:00	\N	\N	fdc3e7c0-d0ef-48f1-a799-b94090023918	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1205	1	8	1	[0]	2019-06-26 09:00:00	\N	\N	c453756b-2c92-4e74-a986-10eb97ce854f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1206	1	12	1	[0.400000006]	2019-06-26 10:00:00	\N	\N	b8e19cd8-bd8a-4124-9232-891eba977fce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1207	1	11	1	[0]	2019-06-26 10:00:00	\N	\N	99991cfc-25f9-4c6c-8873-7ba24cad981a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1208	1	10	1	[0.200000003]	2019-06-26 10:00:00	\N	\N	45bcb337-f707-481a-a7b9-90beedcfb8b8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1209	1	9	1	[0.200000003]	2019-06-26 10:00:00	\N	\N	bba6b2a6-932b-42a0-b7e1-fea225124b6d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1210	1	8	1	[0.400000006]	2019-06-26 10:00:00	\N	\N	7b73a020-345d-4cd6-b47b-0224a9f7bb51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1211	1	12	1	[0]	2019-06-26 11:00:00	\N	\N	c4b151db-6ec1-4197-b1d8-2d75c5dbf91a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1212	1	11	1	[0]	2019-06-26 11:00:00	\N	\N	834cab66-e439-4f5e-bf9f-d8569eecce8a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1213	1	10	1	[0]	2019-06-26 11:00:00	\N	\N	14b5db8a-aaaa-4fa3-bfb7-63ce31905d39	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1214	1	9	1	[0]	2019-06-26 11:00:00	\N	\N	996c75fe-129c-47fc-b8cf-755782a95726	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1215	1	8	1	[0]	2019-06-26 11:00:00	\N	\N	073ea4d2-c9bd-49ab-9c8b-0b8522de3728	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1216	1	12	1	[0]	2019-06-26 12:00:00	\N	\N	92fbc30a-9d70-4adb-8853-eccd70116161	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1217	1	11	1	[0]	2019-06-26 12:00:00	\N	\N	ba682a58-d5b7-433c-82b2-afa2222d6d49	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1218	1	10	1	[0]	2019-06-26 12:00:00	\N	\N	eec0df4f-e3af-4759-ae75-b61087c30521	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1219	1	9	1	[0]	2019-06-26 12:00:00	\N	\N	68c1e41a-3d48-442c-8cd9-a336eef53039	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1220	1	8	1	[0]	2019-06-26 12:00:00	\N	\N	b6c8a8b6-3fe9-4113-ad18-2930d5ea29ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1221	1	12	1	[0]	2019-06-26 13:00:00	\N	\N	9b3440cf-ffdf-4f8e-928b-d8df909277ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1222	1	11	1	[0]	2019-06-26 13:00:00	\N	\N	b1d09905-a175-4c8f-bb2e-42e343c68bae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1223	1	10	1	[0]	2019-06-26 13:00:00	\N	\N	81904c2d-f4e4-4ecb-bba9-35bdaa5a0765	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1224	1	9	1	[0]	2019-06-26 13:00:00	\N	\N	b8124aaf-db93-4dfe-ae69-b2f343bfbe1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1225	1	8	1	[0]	2019-06-26 13:00:00	\N	\N	aca6416c-44b5-4ca8-8129-2990454c1efd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1226	1	12	1	[0]	2019-06-26 14:00:00	\N	\N	198c8fda-a422-4767-8fa9-a9d3e53cbdd2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1227	1	11	1	[0]	2019-06-26 14:00:00	\N	\N	7039e840-41b1-42a9-9e1d-047e26970434	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1228	1	10	1	[0]	2019-06-26 14:00:00	\N	\N	74b1adba-4cda-4274-b952-140cc2d9ed4c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1229	1	9	1	[0]	2019-06-26 14:00:00	\N	\N	8fd93d20-2da2-44f9-85af-3051a8c6c84d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1230	1	8	1	[0]	2019-06-26 14:00:00	\N	\N	b45a3f0c-334d-42c7-8cf3-562b8454f283	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1231	1	12	1	[0]	2019-06-26 15:00:00	\N	\N	1f7fcb20-c882-4807-8f75-dc8c36d1a38b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1232	1	11	1	[0]	2019-06-26 15:00:00	\N	\N	1d896b71-fa53-4ace-a46d-f8ebde371368	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1233	1	10	1	[0]	2019-06-26 15:00:00	\N	\N	3e671b36-7647-44f0-a6d5-4082ced0b883	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1234	1	9	1	[0]	2019-06-26 15:00:00	\N	\N	c60d9f9b-2f3d-44e0-ad80-3225683fc7bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1235	1	8	1	[0]	2019-06-26 15:00:00	\N	\N	a0ad571d-4b85-469e-ba9f-9781d981e8cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1236	1	12	1	[0]	2019-06-26 16:00:00	\N	\N	c892b8f0-bcdd-4c52-a507-202d8d679d11	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1237	1	11	1	[0]	2019-06-26 16:00:00	\N	\N	61c7633c-2a88-4586-afec-05622b92dfd6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1238	1	10	1	[0]	2019-06-26 16:00:00	\N	\N	f4844508-d5b9-4599-882e-c08015059792	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1239	1	9	1	[0]	2019-06-26 16:00:00	\N	\N	d56bea42-1c98-4d12-a6dd-94dedd225322	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1240	1	8	1	[0]	2019-06-26 16:00:00	\N	\N	64999702-b5a0-4d6e-89b2-f9fa7734f948	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1241	1	12	1	[0]	2019-06-26 17:00:00	\N	\N	56727233-62e4-4e1f-8140-a670754c0b0a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1242	1	11	1	[0]	2019-06-26 17:00:00	\N	\N	2549e967-9f2d-40f7-88d3-e33d926e1bb6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1243	1	10	1	[0]	2019-06-26 17:00:00	\N	\N	ca2b6115-7295-412b-9e25-88c8c906e6ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1244	1	9	1	[0]	2019-06-26 17:00:00	\N	\N	fcddfd99-9be6-4613-9f5f-7f83448460fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1245	1	8	1	[0]	2019-06-26 17:00:00	\N	\N	422b6d25-f23f-4a35-85c0-6b1f6d1b54d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1246	1	12	1	[0]	2019-06-26 18:00:00	\N	\N	b497829f-ba33-4641-b87d-b44503e8ccf2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1247	1	11	1	[0]	2019-06-26 18:00:00	\N	\N	5f856de1-c286-4400-92d1-901c8192e129	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1248	1	10	1	[0]	2019-06-26 18:00:00	\N	\N	317b260e-fa33-4a73-87f3-b7e788007363	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1249	1	9	1	[0]	2019-06-26 18:00:00	\N	\N	8df53995-fbc8-4b03-95f8-2e25f2b6963c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1250	1	8	1	[0]	2019-06-26 18:00:00	\N	\N	924c598e-6e59-4b6b-b714-02abe065a15c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1251	1	12	1	[0]	2019-06-26 19:00:00	\N	\N	23d13a77-2a38-4fe7-b897-53f137f1844c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1252	1	11	1	[0]	2019-06-26 19:00:00	\N	\N	a31a05bd-f4a4-4ca4-b6b0-f66b3188578a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1253	1	10	1	[0]	2019-06-26 19:00:00	\N	\N	bfe0f9dc-df6a-4e0e-a991-25bb6221e51a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1254	1	9	1	[0]	2019-06-26 19:00:00	\N	\N	f6ded436-ef9d-403b-ba03-b71000bc78e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1255	1	8	1	[0]	2019-06-26 19:00:00	\N	\N	38a58116-ccd9-4b99-a364-1f6e62a23a5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1256	1	12	1	[0]	2019-06-26 20:00:00	\N	\N	9b93a2fd-f5de-4c2c-a572-511f6673b38d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1257	1	11	1	[0]	2019-06-26 20:00:00	\N	\N	8474498c-5999-47ef-8cae-75b1527b1de7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1258	1	10	1	[0]	2019-06-26 20:00:00	\N	\N	9d29c78d-6e07-4256-9142-fd5a07b085aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1259	1	9	1	[0]	2019-06-26 20:00:00	\N	\N	9947e7b6-b7e5-4877-9936-fbea96fe6a6c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1260	1	8	1	[0]	2019-06-26 20:00:00	\N	\N	89c493ba-d339-461f-b7e8-3b0163e1f38e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1261	1	12	1	[0]	2019-06-26 21:00:00	\N	\N	c5fa3b79-cbf7-4fad-96b6-ea5b2d198902	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1262	1	11	1	[0]	2019-06-26 21:00:00	\N	\N	f6179c33-e345-4890-b7c4-16dc02d889b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1263	1	10	1	[0]	2019-06-26 21:00:00	\N	\N	428f1b9d-f684-4f72-95ac-b8e80f745d48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1264	1	9	1	[0]	2019-06-26 21:00:00	\N	\N	8a3c1581-6d83-4525-ae32-090d34fa51ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1265	1	8	1	[0]	2019-06-26 21:00:00	\N	\N	1418b123-7c07-4879-b646-afd27ff1dc79	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1266	1	12	1	[0]	2019-06-26 22:00:00	\N	\N	be224248-0a90-48c6-aae0-8ac1aaa6afea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1267	1	11	1	[0]	2019-06-26 22:00:00	\N	\N	cd0639a9-5afb-4c91-bd7a-abfe70fb8d80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1268	1	10	1	[0]	2019-06-26 22:00:00	\N	\N	10403721-ae35-4366-8bbd-568f61523e90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1269	1	9	1	[0]	2019-06-26 22:00:00	\N	\N	485ca196-ca9f-411e-9606-eb60af6c2726	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1270	1	8	1	[0]	2019-06-26 22:00:00	\N	\N	4d5e2c85-5cbe-47b1-8b4f-66aa41a280cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1271	1	12	1	[0]	2019-06-26 23:00:00	\N	\N	a2658ae3-34fa-4602-adca-705d42e7cb30	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1272	1	11	1	[0]	2019-06-26 23:00:00	\N	\N	4e15b328-1f93-4c26-9e83-be9ad990263d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1273	1	10	1	[0]	2019-06-26 23:00:00	\N	\N	56c437bc-1995-427a-9300-5b5363958aee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1274	1	9	1	[0]	2019-06-26 23:00:00	\N	\N	a38c0855-a8af-436a-95d8-b564d45bafad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1275	1	8	1	[0]	2019-06-26 23:00:00	\N	\N	62b6697b-dc63-4cf6-a5f2-62b3fde66367	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1276	1	12	1	[0]	2019-06-27 00:00:00	\N	\N	9bf14e00-0c94-4271-be6b-e77f2ffc351d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1277	1	11	1	[0]	2019-06-27 00:00:00	\N	\N	0e57a55b-eb55-4ae4-9e35-0cf662f3d723	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1278	1	10	1	[0]	2019-06-27 00:00:00	\N	\N	31e64c46-97f1-46f2-aa9d-4398143f2408	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1279	1	9	1	[0]	2019-06-27 00:00:00	\N	\N	eff90f9d-ba7b-4fa1-b452-21f37fedbe23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1280	1	8	1	[0]	2019-06-27 00:00:00	\N	\N	d38f4b6c-cb26-4540-b2a8-e5d901755ef8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1281	1	12	1	[0]	2019-06-27 01:00:00	\N	\N	43f135aa-546c-4077-9b02-0a6293e10a10	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1282	1	11	1	[0]	2019-06-27 01:00:00	\N	\N	263fd99f-52b9-4065-908f-5d6c1af434df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1283	1	10	1	[0]	2019-06-27 01:00:00	\N	\N	17c1fcff-48ef-4870-9fa8-a7c8616385ae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1284	1	9	1	[0]	2019-06-27 01:00:00	\N	\N	5766465a-1b38-4657-a071-47b0e49ca7a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1285	1	8	1	[0]	2019-06-27 01:00:00	\N	\N	dbda4203-decd-45de-8bac-488deda35126	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1286	1	12	1	[0]	2019-06-27 02:00:00	\N	\N	224b42bd-4ffc-49e6-b06f-d19448356108	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1287	1	11	1	[0]	2019-06-27 02:00:00	\N	\N	31b84532-3f90-4eac-809c-1d9fe2c5a895	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1288	1	10	1	[0]	2019-06-27 02:00:00	\N	\N	ac2508f4-ad24-45be-9e62-5171d64b5b55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1289	1	9	1	[0]	2019-06-27 02:00:00	\N	\N	867ce45b-1b75-4ae6-a0a6-0cd7d7c7c772	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1290	1	8	1	[0]	2019-06-27 02:00:00	\N	\N	a2422b07-becd-46fd-8454-5ba523709505	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1291	1	12	1	[0]	2019-06-27 03:00:00	\N	\N	37dca288-b495-4bea-8f93-f0f15ef11134	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1292	1	11	1	[0]	2019-06-27 03:00:00	\N	\N	76ccb6f4-5329-45c8-90ee-8458e32763ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1293	1	10	1	[0]	2019-06-27 03:00:00	\N	\N	2063a972-5361-4bc0-aefd-9e54b845fdea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1294	1	9	1	[0]	2019-06-27 03:00:00	\N	\N	4dd7bc5b-b8a8-4a64-9c12-0f1b38c2812b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1295	1	8	1	[0]	2019-06-27 03:00:00	\N	\N	18a12e90-ae19-4bbd-b1cd-ed65e1242d33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1296	1	12	1	[0]	2019-06-27 04:00:00	\N	\N	b269e354-ffc3-4690-a177-f3710dd4d41c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1297	1	11	1	[0]	2019-06-27 04:00:00	\N	\N	f257701b-1edf-4b8a-9193-2e5b22ea2f06	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1298	1	10	1	[0]	2019-06-27 04:00:00	\N	\N	37b4dfe3-6487-4d2d-be55-3b24bd90b679	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1299	1	9	1	[0]	2019-06-27 04:00:00	\N	\N	4ee711cf-441f-42ec-a0e5-7ce94ebd4ce6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1300	1	8	1	[0]	2019-06-27 04:00:00	\N	\N	380e3f31-446e-49d4-97ff-30b782cc78c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1301	1	12	1	[0]	2019-06-27 05:00:00	\N	\N	60e5990f-e346-4708-ac55-1f15a782092e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1302	1	11	1	[0]	2019-06-27 05:00:00	\N	\N	f5b71eb5-ae80-43f9-b8fc-4174deb51be1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1303	1	10	1	[0]	2019-06-27 05:00:00	\N	\N	f386c2fd-385d-4af9-a4ee-9e70d04cdb3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1304	1	9	1	[0]	2019-06-27 05:00:00	\N	\N	7fcc7e1b-5eee-44a1-b5cc-06ba33b775b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1305	1	8	1	[0]	2019-06-27 05:00:00	\N	\N	cea2acd1-51ca-471e-b483-fc52c6f3a4c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1306	1	12	1	[0]	2019-06-27 06:00:00	\N	\N	893ab387-7aa4-44a6-9079-8b10e60511aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1307	1	11	1	[0]	2019-06-27 06:00:00	\N	\N	69a9ee13-0351-4249-823b-0971c0e8cfe7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1308	1	10	1	[0]	2019-06-27 06:00:00	\N	\N	994bd033-c0ea-4f8b-aae6-454c7600c1ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1309	1	9	1	[0]	2019-06-27 06:00:00	\N	\N	df0f19b5-8d32-4e2e-a0ee-9d2f95375f92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1310	1	8	1	[0]	2019-06-27 06:00:00	\N	\N	c1c65338-4a91-44c9-9291-a9315d459a63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1311	1	12	1	[0]	2019-06-27 07:00:00	\N	\N	1c33f3a7-264b-4d8b-ae9d-fb396e0d00bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1312	1	11	1	[0]	2019-06-27 07:00:00	\N	\N	7823c5fa-3418-461f-85f7-215e41e8aec7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1313	1	10	1	[0]	2019-06-27 07:00:00	\N	\N	8ea3d1b9-bbf5-4b2a-9219-3030fea27a99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1314	1	9	1	[0]	2019-06-27 07:00:00	\N	\N	912906f3-e4ea-4331-b60a-1b5cc49d840f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1315	1	8	1	[0]	2019-06-27 07:00:00	\N	\N	79da38dc-9842-4ae4-9c4f-3a7f939f91c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1316	1	12	1	[0]	2019-06-27 08:00:00	\N	\N	c8dc1ee8-d98d-4e31-8271-c2b4d4509444	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1317	1	11	1	[0]	2019-06-27 08:00:00	\N	\N	bf0645c4-189a-497f-b136-1b41c9ab78e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1318	1	10	1	[0]	2019-06-27 08:00:00	\N	\N	33b66faf-d48f-4306-a949-3e26ce9febc1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1319	1	9	1	[0]	2019-06-27 08:00:00	\N	\N	b1d85ab4-8d71-41f4-b722-06259838d3a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1320	1	8	1	[0]	2019-06-27 08:00:00	\N	\N	bfc78bc5-12a9-4e1c-b1c1-2f3e588119d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1321	1	12	1	[0]	2019-06-27 09:00:00	\N	\N	286bb94e-ed36-493f-8117-9f867a810228	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1322	1	11	1	[0]	2019-06-27 09:00:00	\N	\N	be5bec2b-7b31-4da9-b9ef-0bc78ae0ce21	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1323	1	10	1	[0]	2019-06-27 09:00:00	\N	\N	f01f87d8-774f-403f-80b8-9115aa718641	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1324	1	9	1	[0]	2019-06-27 09:00:00	\N	\N	10fc26f6-ae97-42a2-b0af-7ec9242defd0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1325	1	8	1	[0]	2019-06-27 09:00:00	\N	\N	e87a4df6-53c3-4abb-91bb-9a0d964a6647	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1326	1	12	1	[0]	2019-06-27 10:00:00	\N	\N	8f96654c-102b-44f2-a529-fb2d0c12cea8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1327	1	11	1	[0]	2019-06-27 10:00:00	\N	\N	42997251-ff88-4306-8924-387edd22216f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1328	1	10	1	[0]	2019-06-27 10:00:00	\N	\N	f3e0f5fb-2e4b-4a75-93e7-eb2f4af8b15a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1329	1	9	1	[0]	2019-06-27 10:00:00	\N	\N	918377e6-5ffb-4159-84d2-5a5ddebd52a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1330	1	8	1	[0]	2019-06-27 10:00:00	\N	\N	b20abe74-22f4-4db6-96b6-66de9a938d42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1331	1	12	1	[0]	2019-06-27 11:00:00	\N	\N	14f11e3d-996e-4f7d-af89-58c727914c5d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1332	1	11	1	[0]	2019-06-27 11:00:00	\N	\N	f9862b47-e1d9-430a-96cd-aa85314f0a01	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1333	1	10	1	[0]	2019-06-27 11:00:00	\N	\N	b4588c65-4b0c-4911-8195-e9cf8dfb5dc2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1334	1	9	1	[0]	2019-06-27 11:00:00	\N	\N	cc83455b-7758-4e51-ad38-4d4fb15c15ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1335	1	8	1	[0]	2019-06-27 11:00:00	\N	\N	dc84dc77-8424-4bb2-81ac-88ffb211d780	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1336	1	12	1	[0]	2019-06-27 12:00:00	\N	\N	ca63b261-8004-47f9-b540-3260170de60f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1337	1	11	1	[0]	2019-06-27 12:00:00	\N	\N	21fb0e28-597e-48d0-b263-0f3451ed00e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1338	1	10	1	[0]	2019-06-27 12:00:00	\N	\N	4cfcd444-050e-447f-a6de-7b34d42f0b5f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1339	1	9	1	[0]	2019-06-27 12:00:00	\N	\N	0e38e234-13c9-402d-bb3c-a26ef34f782b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1340	1	8	1	[0]	2019-06-27 12:00:00	\N	\N	c9a4f935-939f-492f-a3b5-65495a781777	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1341	1	12	1	[0]	2019-06-27 13:00:00	\N	\N	036f857b-c8a9-4997-bedb-f92cc185ce1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1342	1	11	1	[0]	2019-06-27 13:00:00	\N	\N	0096c6e6-926a-4a89-8480-e6e80073e4d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1343	1	10	1	[0]	2019-06-27 13:00:00	\N	\N	28d4c7fe-86e0-47af-b36e-61f984f67781	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1344	1	9	1	[0]	2019-06-27 13:00:00	\N	\N	ae177a65-7782-4b85-b800-d2084b48ee9b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1345	1	8	1	[0]	2019-06-27 13:00:00	\N	\N	e0b9ce6c-c737-41f1-8463-2791f4f5aff4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1346	1	12	1	[0]	2019-06-27 14:00:00	\N	\N	1324d5c9-df18-478b-ac0f-85ed5931da11	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1347	1	11	1	[0]	2019-06-27 14:00:00	\N	\N	4078964b-e46b-4573-a632-4213f72cc399	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1348	1	10	1	[0]	2019-06-27 14:00:00	\N	\N	1d736e77-2a06-469a-b256-918be138ffd7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1349	1	9	1	[0]	2019-06-27 14:00:00	\N	\N	02e58f0b-a93e-4372-9ee8-a8b66ae01539	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1350	1	8	1	[0]	2019-06-27 14:00:00	\N	\N	a6c2473e-8fbd-4c1c-afd7-927e526c501c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1351	1	12	1	[0]	2019-06-27 15:00:00	\N	\N	8e651b2f-d7c2-4808-8762-303415ae19c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1352	1	11	1	[0]	2019-06-27 15:00:00	\N	\N	e0026ae5-c9fe-43cf-a553-14907864af30	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1353	1	10	1	[0]	2019-06-27 15:00:00	\N	\N	e288d982-1412-4d7b-88b6-6422bb546927	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1354	1	9	1	[0]	2019-06-27 15:00:00	\N	\N	3683d0a2-9633-466d-8a78-a447c32534d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1355	1	8	1	[0]	2019-06-27 15:00:00	\N	\N	87b2bd42-718b-4e1c-ae77-9b9db1b352ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1356	1	12	1	[0]	2019-06-27 16:00:00	\N	\N	eba5fcf8-181b-490a-8c4f-bc75c6fca013	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1357	1	11	1	[0]	2019-06-27 16:00:00	\N	\N	953effda-dc25-47ad-a6e1-ad95e7ad7f2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1358	1	10	1	[0]	2019-06-27 16:00:00	\N	\N	0a3420b5-0162-4449-91b7-06133e082ea2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1359	1	9	1	[0]	2019-06-27 16:00:00	\N	\N	f87bfa1d-5818-4628-9409-0f15c914e6d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1360	1	8	1	[0]	2019-06-27 16:00:00	\N	\N	e09262b2-7b49-4c0b-9caf-a1857d0b766d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1361	1	12	1	[0]	2019-06-27 17:00:00	\N	\N	7bf6f0ac-6f1d-4c30-85b5-b182efd53702	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1362	1	11	1	[0]	2019-06-27 17:00:00	\N	\N	42049df2-53ac-4d52-9925-2a5c7b7c3c2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1363	1	10	1	[0]	2019-06-27 17:00:00	\N	\N	21061f12-c490-4b70-854b-252a606963b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1364	1	9	1	[0]	2019-06-27 17:00:00	\N	\N	47e8b3a2-449e-46d8-bfde-85b375d7ae8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1365	1	8	1	[0]	2019-06-27 17:00:00	\N	\N	03de4f76-6353-4f74-91a0-63a3913c53c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1366	1	12	1	[0]	2019-06-27 18:00:00	\N	\N	159d2c35-4b47-44ea-9e75-2514e6c23aba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1367	1	11	1	[0]	2019-06-27 18:00:00	\N	\N	651cb659-2c76-4fca-80bb-44f7909a8c4c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1368	1	10	1	[0]	2019-06-27 18:00:00	\N	\N	eec6c5ab-e75d-49b4-a858-70b5917846a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1369	1	9	1	[0]	2019-06-27 18:00:00	\N	\N	a60b57e6-b1fa-444a-b871-1abbfd7f0ee2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1370	1	8	1	[0]	2019-06-27 18:00:00	\N	\N	51b0a744-837f-4679-a89e-ce3cadcab7b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1371	1	12	1	[0]	2019-06-27 19:00:00	\N	\N	15419831-1f93-44f6-89e6-89ee7a2485d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1372	1	11	1	[0]	2019-06-27 19:00:00	\N	\N	70614ac5-4734-4bc0-89e1-286bc214a86b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1373	1	10	1	[0]	2019-06-27 19:00:00	\N	\N	a790b8a9-c6e2-43df-b88a-9445bbe878f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1374	1	9	1	[0]	2019-06-27 19:00:00	\N	\N	b6558064-d204-4a28-8d18-79d87f0f48e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1375	1	8	1	[0]	2019-06-27 19:00:00	\N	\N	327277ec-f180-4b2d-88cc-4072a48e0c4a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1376	1	12	1	[0]	2019-06-27 20:00:00	\N	\N	69449249-fa3c-42e4-87c4-b1c70d394468	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1377	1	11	1	[0]	2019-06-27 20:00:00	\N	\N	d60a3ebf-f89a-436f-8407-d224aab2d13f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1378	1	10	1	[0]	2019-06-27 20:00:00	\N	\N	cad35d82-2fb4-4220-9468-cf05239e81f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1379	1	9	1	[0]	2019-06-27 20:00:00	\N	\N	1f11a293-5c4d-44d1-8f97-45e3599c1ef2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1380	1	8	1	[0]	2019-06-27 20:00:00	\N	\N	767f78e0-9ccc-4a2b-8705-c6b40775b7b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1381	1	12	1	[0]	2019-06-27 21:00:00	\N	\N	463e8d22-90c6-4850-b88e-786bcb8cd81c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1382	1	11	1	[0]	2019-06-27 21:00:00	\N	\N	e30e2ed9-7a06-4c68-b6f0-b1d4cd543862	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1383	1	10	1	[0]	2019-06-27 21:00:00	\N	\N	ef847bef-e952-4427-8f7b-29898c442900	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1384	1	9	1	[0]	2019-06-27 21:00:00	\N	\N	77bf2483-c140-4bfa-90e9-ff441a268eca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1385	1	8	1	[0]	2019-06-27 21:00:00	\N	\N	ee2976a1-4075-43f6-bc26-17262a408edf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1386	1	12	1	[0]	2019-06-27 22:00:00	\N	\N	0e3753fb-07e1-4299-a0ea-0e6b92ed97b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1387	1	11	1	[0]	2019-06-27 22:00:00	\N	\N	6665af52-bd38-4694-8628-6b6f44056c7e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1388	1	10	1	[0]	2019-06-27 22:00:00	\N	\N	ae49e015-09c3-410e-8633-dba487e34446	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1389	1	9	1	[0]	2019-06-27 22:00:00	\N	\N	3835f1a4-b3d2-444a-85b5-34e02c8aa955	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1390	1	8	1	[0]	2019-06-27 22:00:00	\N	\N	607fdc10-baa0-4b5d-a122-db372a47a12a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1391	1	12	1	[0]	2019-06-27 23:00:00	\N	\N	2123b097-cc91-4f13-b729-d9913956e20a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1392	1	11	1	[0]	2019-06-27 23:00:00	\N	\N	2cb79ad7-a668-4aaf-9285-6448a71dc3d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1393	1	10	1	[0]	2019-06-27 23:00:00	\N	\N	8b9098a2-9dff-4290-9d6e-07ea3243a6c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1394	1	9	1	[0]	2019-06-27 23:00:00	\N	\N	3f1017d2-f6a4-4f0c-a09c-d5f7b0b3f645	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1395	1	8	1	[0]	2019-06-27 23:00:00	\N	\N	8bee0d12-e05c-4420-a437-472459e43ec6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1396	1	12	1	[0]	2019-06-28 00:00:00	\N	\N	2ffefc8f-a1b3-478b-b6ec-bbddd73edf65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1397	1	11	1	[0]	2019-06-28 00:00:00	\N	\N	e2b600d9-740c-4320-8f1c-b3fca6308479	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1398	1	10	1	[0]	2019-06-28 00:00:00	\N	\N	88e86c14-72d7-4373-bc2b-50361b3781d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1399	1	9	1	[0]	2019-06-28 00:00:00	\N	\N	eeef5b49-749d-48de-912d-aeead9e2e6c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1400	1	8	1	[0]	2019-06-28 00:00:00	\N	\N	76f8358b-9f44-42e4-8288-18895c9e0137	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1401	1	12	1	[0]	2019-06-28 01:00:00	\N	\N	73281424-d328-4d12-912d-d1af6f479567	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1402	1	11	1	[0]	2019-06-28 01:00:00	\N	\N	d4b1c677-a23b-47b9-a8ed-117e8ef79cc0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1403	1	10	1	[0]	2019-06-28 01:00:00	\N	\N	ee377c67-9bca-459c-b1d3-ff317f416fca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1404	1	9	1	[0]	2019-06-28 01:00:00	\N	\N	8263b771-a233-426c-9a86-3119ae0c19ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1405	1	8	1	[0]	2019-06-28 01:00:00	\N	\N	7ce6f3e8-8b1b-4fa1-b444-33e0a5ad9e2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1406	1	12	1	[0]	2019-06-28 02:00:00	\N	\N	aec567ff-bd9e-46e0-aaee-da012942c97a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1407	1	11	1	[0]	2019-06-28 02:00:00	\N	\N	5167d3cc-5c40-4801-94c0-34cc3cc150e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1408	1	10	1	[0]	2019-06-28 02:00:00	\N	\N	2cee5952-34d0-47d4-912c-c7f5931e6927	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1409	1	9	1	[0]	2019-06-28 02:00:00	\N	\N	d2e4e759-90df-4a3d-a80e-2fc6777b1392	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1410	1	8	1	[0]	2019-06-28 02:00:00	\N	\N	9fb68e62-83a7-4bba-b844-e29c0192b420	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1411	1	12	1	[0]	2019-06-28 03:00:00	\N	\N	0e4cca7e-8926-4191-95d5-d253b90a8efd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1412	1	11	1	[0]	2019-06-28 03:00:00	\N	\N	a52741d6-fe56-4ebe-bba6-bc2b8ceceb48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1413	1	10	1	[0]	2019-06-28 03:00:00	\N	\N	4e7cf80d-5905-4296-8a6d-10526375f531	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1414	1	9	1	[0]	2019-06-28 03:00:00	\N	\N	e4ee6bad-a45f-450c-a4f7-08d3e400182f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1415	1	8	1	[0]	2019-06-28 03:00:00	\N	\N	57730d3a-531b-4a2d-be19-422234abdef9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1416	1	12	1	[0]	2019-06-28 04:00:00	\N	\N	d3a42dfe-a5dc-4f37-91e1-a80eec1da137	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1417	1	11	1	[0]	2019-06-28 04:00:00	\N	\N	ef67557c-859e-4407-8d5a-f47f5f77ed83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1418	1	10	1	[0]	2019-06-28 04:00:00	\N	\N	15f0a9f9-8d49-4f29-98dc-1d8377d5a77f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1419	1	9	1	[0]	2019-06-28 04:00:00	\N	\N	3fe4628d-6577-458e-bad3-a6b3de56feaf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1420	1	8	1	[0]	2019-06-28 04:00:00	\N	\N	b5e1eceb-85b8-4b0e-8d21-c774f98cb5c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1421	1	12	1	[0]	2019-06-28 05:00:00	\N	\N	f528f38b-9474-45a7-8892-9153e217dd41	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1422	1	11	1	[0]	2019-06-28 05:00:00	\N	\N	5421d3ae-d992-4eef-a123-deb8ffbcf1de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1423	1	10	1	[0]	2019-06-28 05:00:00	\N	\N	bccb6687-1975-4aa8-9471-1bc5f1aa255a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1424	1	9	1	[0]	2019-06-28 05:00:00	\N	\N	4e950ae0-bf29-4908-9de6-c354010c1027	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1425	1	8	1	[0]	2019-06-28 05:00:00	\N	\N	a627dbc9-2a9c-45f3-863a-ba993b56b5ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1426	1	12	1	[0]	2019-06-28 06:00:00	\N	\N	5e3bc3b5-000e-4f3e-9b06-03ee8f6cb994	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1427	1	11	1	[0]	2019-06-28 06:00:00	\N	\N	20d91986-3fa2-46c0-9689-d47e2f24d4e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1428	1	10	1	[0]	2019-06-28 06:00:00	\N	\N	1ed8b761-5f8f-43f8-ae96-b4e150926625	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1429	1	9	1	[0]	2019-06-28 06:00:00	\N	\N	536f8ec1-a4f4-4aa4-a951-e3f8dfdde9e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1430	1	8	1	[0]	2019-06-28 06:00:00	\N	\N	0ea047ba-7c3e-4163-9e02-96371c816d7e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1431	1	12	1	[0]	2019-06-28 07:00:00	\N	\N	e26172ea-4c1d-4049-b984-456e8cec3edb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1432	1	11	1	[0]	2019-06-28 07:00:00	\N	\N	d459dbb8-1200-4337-a26f-288eeb3d27fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1433	1	10	1	[0]	2019-06-28 07:00:00	\N	\N	0aed1033-456e-4135-ae8e-3919d2c9a9e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1434	1	9	1	[0]	2019-06-28 07:00:00	\N	\N	9a4533d4-c5e0-4a43-934c-e6132b844fb6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1435	1	8	1	[0]	2019-06-28 07:00:00	\N	\N	ebb03c63-bee9-4e4d-85dc-a1aab55d5543	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1436	1	12	1	[0]	2019-06-28 08:00:00	\N	\N	7a5a0185-899d-4aec-b47f-023b49fa01a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1437	1	11	1	[0]	2019-06-28 08:00:00	\N	\N	9f589335-ac69-481f-9074-4fdfde6c14fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1438	1	10	1	[0]	2019-06-28 08:00:00	\N	\N	59bcdde4-c810-4503-b19c-e03a3e111cf7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1439	1	9	1	[0]	2019-06-28 08:00:00	\N	\N	91bd5734-93da-40b7-bfac-6d609eacb04d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1440	1	8	1	[0]	2019-06-28 08:00:00	\N	\N	2dbd3879-7a7a-4d23-bbb4-6c201e9ab1f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1441	1	12	1	[0]	2019-06-28 09:00:00	\N	\N	89426284-a9f6-4fb2-8ca1-397abe3bca86	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1442	1	11	1	[0]	2019-06-28 09:00:00	\N	\N	6352480e-60f0-40d8-98ab-b00542a34a6d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1443	1	10	1	[0]	2019-06-28 09:00:00	\N	\N	b7116107-520d-46f3-b9bf-71d4e290938d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1444	1	9	1	[0]	2019-06-28 09:00:00	\N	\N	89062d44-9658-4d18-8afd-7fdb54aeadb1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1445	1	8	1	[0]	2019-06-28 09:00:00	\N	\N	bcba71be-bab2-4bde-b074-0c4160b37fc3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1446	1	12	1	[0]	2019-06-28 10:00:00	\N	\N	24bd1c33-5e2e-4fbb-8545-21adb40ea707	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1447	1	11	1	[0]	2019-06-28 10:00:00	\N	\N	3b2fe02c-1711-4aa5-a027-fe454162bd90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1448	1	10	1	[0]	2019-06-28 10:00:00	\N	\N	a03ceea6-0834-4edc-af09-2cda1e379a78	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1449	1	9	1	[0]	2019-06-28 10:00:00	\N	\N	d3a7fb00-903d-4028-b9ea-ab624df05037	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1450	1	8	1	[0]	2019-06-28 10:00:00	\N	\N	004b85d7-999f-4247-a315-8e96fd86dfad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1451	1	12	1	[0]	2019-06-28 11:00:00	\N	\N	d6c1d28d-951d-4bc3-ade3-316a92e5c94c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1452	1	11	1	[0]	2019-06-28 11:00:00	\N	\N	bb8077f1-99c5-4d81-a7e5-886acbb53d42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1453	1	10	1	[0]	2019-06-28 11:00:00	\N	\N	a46a9de7-b924-477c-aec2-d02eaaf435e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1454	1	9	1	[0]	2019-06-28 11:00:00	\N	\N	d2fc8d72-0d11-405d-a7cc-7c4ada6dde40	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1455	1	8	1	[0]	2019-06-28 11:00:00	\N	\N	8bfad746-c3dc-4ba8-b3f9-dc31dad13724	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1456	1	12	1	[0]	2019-06-28 12:00:00	\N	\N	a98e5ffd-523a-4ffa-ba76-e3f838445c5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1457	1	11	1	[0]	2019-06-28 12:00:00	\N	\N	56e70e57-6a43-4b40-ae13-f33be79ed188	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1458	1	10	1	[0]	2019-06-28 12:00:00	\N	\N	9b524b1a-c629-4296-b2b7-50c44851ec72	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1459	1	9	1	[0]	2019-06-28 12:00:00	\N	\N	70055e26-fcd8-47cf-a08e-ed9b6a727493	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1460	1	8	1	[0]	2019-06-28 12:00:00	\N	\N	8c4a526d-ca69-4bdd-909e-985cf1e9ea0d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1461	1	12	1	[0]	2019-06-28 13:00:00	\N	\N	19fa2ae5-80f5-4f70-a63f-72dac112b8fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1462	1	11	1	[0]	2019-06-28 13:00:00	\N	\N	eb3438f7-56ed-4339-bfee-2b5e3685300f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1463	1	10	1	[0]	2019-06-28 13:00:00	\N	\N	d824d271-7fee-452b-8598-d98b7a4a0722	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1464	1	9	1	[0]	2019-06-28 13:00:00	\N	\N	316a15d3-fac6-4085-8913-8a4293d2e4a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1465	1	8	1	[0]	2019-06-28 13:00:00	\N	\N	359c8d8f-462d-4091-96c3-b6f69344639f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1466	1	12	1	[0]	2019-06-28 14:00:00	\N	\N	6231b466-07a6-4aed-8f1d-c6cf578a9f57	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1467	1	11	1	[0]	2019-06-28 14:00:00	\N	\N	b867c08e-b336-4e84-a074-c9e3c8b93b05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1468	1	10	1	[0]	2019-06-28 14:00:00	\N	\N	e807bd29-b456-4184-88b0-8ee7ad9eee46	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1469	1	9	1	[0]	2019-06-28 14:00:00	\N	\N	d38b383d-acb7-4682-af7c-c0a566e99cdb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1470	1	8	1	[0]	2019-06-28 14:00:00	\N	\N	ee2f68eb-cca6-409e-8fc8-c226f19e322e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1471	1	12	1	[0]	2019-06-28 15:00:00	\N	\N	d67e1e6b-72ba-4895-916a-a4c817c9fdfe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1472	1	11	1	[0]	2019-06-28 15:00:00	\N	\N	bd048e2c-5586-4e2b-8e5e-6bcdae718d52	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1473	1	10	1	[0]	2019-06-28 15:00:00	\N	\N	82c1521f-4fb5-4cf9-ad29-037926f453e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1474	1	9	1	[0]	2019-06-28 15:00:00	\N	\N	d236a093-be09-4e73-9117-4f0d680fca58	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1475	1	8	1	[0]	2019-06-28 15:00:00	\N	\N	2e74d00f-970f-4f08-bbf9-9c8f7c0ddb27	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1476	1	12	1	[0]	2019-06-28 16:00:00	\N	\N	e2f160cd-12bb-445a-930a-3b768dac77b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1477	1	11	1	[0]	2019-06-28 16:00:00	\N	\N	1f9e7bf3-c448-401f-b008-dd578b2f03a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1478	1	10	1	[0]	2019-06-28 16:00:00	\N	\N	a7cf88bf-e41d-4693-bb36-949b5253950e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1479	1	9	1	[0]	2019-06-28 16:00:00	\N	\N	2e7d93de-a81c-441a-920c-5df15b5e26db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1480	1	8	1	[0]	2019-06-28 16:00:00	\N	\N	64e166ad-c29e-4084-85e4-b3d9010dbc96	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1481	1	12	1	[0]	2019-06-28 17:00:00	\N	\N	3d6d092e-6c4a-49ef-b87d-05c09a388112	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1482	1	11	1	[0]	2019-06-28 17:00:00	\N	\N	fcb68141-2bb5-4d4b-b11f-e3dca60e0391	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1483	1	10	1	[0]	2019-06-28 17:00:00	\N	\N	40148e4b-49e6-4179-8a96-f1807da117ae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1484	1	9	1	[0]	2019-06-28 17:00:00	\N	\N	a48baee8-1dab-4db5-a06a-563e0c003f53	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1485	1	8	1	[0]	2019-06-28 17:00:00	\N	\N	16b9fa31-8d32-4619-9348-8a1ed657f732	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1486	1	12	1	[0]	2019-06-28 18:00:00	\N	\N	126f6212-de43-4324-b783-249952efc674	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1487	1	11	1	[0]	2019-06-28 18:00:00	\N	\N	ac00902f-7913-49da-ae9c-368858ae09e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1488	1	10	1	[0]	2019-06-28 18:00:00	\N	\N	6287b055-d807-4716-ad5d-14f194219567	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1489	1	9	1	[0]	2019-06-28 18:00:00	\N	\N	34bec64a-be4a-41e6-8ccd-6c4a5d5c5570	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1490	1	8	1	[0]	2019-06-28 18:00:00	\N	\N	256133eb-aac1-4cda-add8-4639f0c352b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1491	1	12	1	[0]	2019-06-28 19:00:00	\N	\N	f9513439-090e-408f-8af3-c5688ec779e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1492	1	11	1	[0]	2019-06-28 19:00:00	\N	\N	ecb40614-9787-4e4e-a8e0-1f1c1650fa49	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1493	1	10	1	[0]	2019-06-28 19:00:00	\N	\N	66a5e6eb-55fb-4f0d-99bc-9a0e8233d6ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1494	1	9	1	[0]	2019-06-28 19:00:00	\N	\N	b33049f2-aa3f-40c4-ae99-4a774e2d8919	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1495	1	8	1	[0]	2019-06-28 19:00:00	\N	\N	367c16f1-811e-4c37-833d-333f75d60831	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1496	1	12	1	[0]	2019-06-28 20:00:00	\N	\N	4a0b8f54-02b3-44ed-8ccc-1f04d9815299	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1497	1	11	1	[0]	2019-06-28 20:00:00	\N	\N	0791c92d-3c38-4c23-9ce0-cb82cd572ec3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1498	1	10	1	[0]	2019-06-28 20:00:00	\N	\N	8c349b71-4764-47d3-a780-b110a1ad6733	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1499	1	9	1	[0]	2019-06-28 20:00:00	\N	\N	bf2a1528-607c-49c7-a150-7c321507a6ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1500	1	8	1	[0]	2019-06-28 20:00:00	\N	\N	1ce816a4-9001-4ac5-9a8f-b036243763ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1501	1	12	1	[0]	2019-06-28 21:00:00	\N	\N	c7f525c0-5f61-47c9-b8ad-94a84dc5b6af	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1502	1	11	1	[0]	2019-06-28 21:00:00	\N	\N	c5bb1822-2aed-4850-978d-898f0eb9be0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1503	1	10	1	[0]	2019-06-28 21:00:00	\N	\N	7658903f-bf80-4bf5-af1a-00bde81985c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1504	1	9	1	[0]	2019-06-28 21:00:00	\N	\N	c60363e8-9bb2-4a40-b914-55f50ff60621	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1505	1	8	1	[0]	2019-06-28 21:00:00	\N	\N	5119a52f-e83e-48a9-bc75-bac168c8f2fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1506	1	12	1	[0]	2019-06-28 22:00:00	\N	\N	b076312d-a210-44f0-88c5-3415a883e82f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1507	1	11	1	[0]	2019-06-28 22:00:00	\N	\N	db539922-81ed-4795-96ce-6aaa0a486196	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1508	1	10	1	[0]	2019-06-28 22:00:00	\N	\N	cf1f32ee-7328-422c-806f-598faa3edda8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1509	1	9	1	[0]	2019-06-28 22:00:00	\N	\N	d01774c8-139c-405a-9075-649665120bd9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1510	1	8	1	[0]	2019-06-28 22:00:00	\N	\N	2e1ad91c-6e31-44ac-85bc-dad0128ec99e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1511	1	12	1	[0]	2019-06-28 23:00:00	\N	\N	4a47a7e4-ea62-4809-ae96-1719dcea8999	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1512	1	11	1	[0]	2019-06-28 23:00:00	\N	\N	8c545daa-3869-4a56-8329-5307ec9720b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1513	1	10	1	[0]	2019-06-28 23:00:00	\N	\N	549df781-1cdb-4639-a11b-e6cfee3b374d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1514	1	9	1	[0]	2019-06-28 23:00:00	\N	\N	dd6a8a83-fc7a-41c7-abfd-62e24015bb5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1515	1	8	1	[0]	2019-06-28 23:00:00	\N	\N	bf99c612-f417-48d7-ad69-7129aa746c07	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1516	1	12	1	[0]	2019-06-29 00:00:00	\N	\N	c2c9c2e4-d29d-435d-b134-9aeb99359919	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1517	1	11	1	[0]	2019-06-29 00:00:00	\N	\N	7ba3dfe5-0452-4f7b-a729-8c65815ce88f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1518	1	10	1	[0]	2019-06-29 00:00:00	\N	\N	be9b1076-ad74-4f4f-993f-cc32262a01b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1519	1	9	1	[0]	2019-06-29 00:00:00	\N	\N	d741a7ee-e334-46d7-9ab6-8cd1202f08b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1520	1	8	1	[0]	2019-06-29 00:00:00	\N	\N	6026d92f-a355-4e62-aea4-c9e650d62829	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1521	1	12	1	[0]	2019-06-29 01:00:00	\N	\N	d84cb161-2d75-4141-a10b-4e688598a43a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1522	1	11	1	[0]	2019-06-29 01:00:00	\N	\N	6d8a010b-ff32-486f-a1ad-ae318606e8a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1523	1	10	1	[0]	2019-06-29 01:00:00	\N	\N	d1830abb-9aaf-43f1-8a68-af5722a6ab7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1524	1	9	1	[0]	2019-06-29 01:00:00	\N	\N	3b8d94f4-5779-49d9-8395-4931f560d855	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1525	1	8	1	[0]	2019-06-29 01:00:00	\N	\N	e0c5b3dd-be80-44c7-b619-517d703f9bc5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1526	1	12	1	[0]	2019-06-29 02:00:00	\N	\N	08c3ad6f-1841-4975-bfe4-b16363d744eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1527	1	11	1	[0]	2019-06-29 02:00:00	\N	\N	e3be5489-a8c5-43d0-adae-35e0caa68cac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1528	1	10	1	[0]	2019-06-29 02:00:00	\N	\N	d3070b1f-3fd2-4ab4-bcb8-ac100d0e21db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1529	1	9	1	[0]	2019-06-29 02:00:00	\N	\N	236e9976-a811-4893-8b0c-3a1b08cf7dcc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1530	1	8	1	[0]	2019-06-29 02:00:00	\N	\N	4ac6cf89-1491-4c1b-8042-aac61cc4d119	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1531	1	12	1	[0]	2019-06-29 03:00:00	\N	\N	61de956b-be82-4c6b-a03a-9a259421ffbe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1532	1	11	1	[0]	2019-06-29 03:00:00	\N	\N	1c604b90-5770-49ab-a6e9-a025e0670948	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1533	1	10	1	[0]	2019-06-29 03:00:00	\N	\N	fec1ae2c-ba15-4449-bad4-5e872367dfe1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1534	1	9	1	[0]	2019-06-29 03:00:00	\N	\N	bc6b239b-aeb3-4f15-b110-d6adac98150c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1535	1	8	1	[0]	2019-06-29 03:00:00	\N	\N	48d50d66-e576-44a2-ace7-a44eb15233d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1536	1	12	1	[0]	2019-06-29 04:00:00	\N	\N	8be96d02-31da-4d18-b592-f5af4253d660	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1537	1	11	1	[0]	2019-06-29 04:00:00	\N	\N	e1aeacb5-b172-4276-954a-20b78f2ef2c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1538	1	10	1	[0]	2019-06-29 04:00:00	\N	\N	7d420e6f-1a69-4e71-b5a5-563d25084cd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1539	1	9	1	[0]	2019-06-29 04:00:00	\N	\N	614b8624-cde3-48a2-b4b0-293c6a6cb0cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1540	1	8	1	[0]	2019-06-29 04:00:00	\N	\N	dc595c34-6dde-49f0-bdd5-09c7ddf60a7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1541	1	12	1	[0]	2019-06-29 05:00:00	\N	\N	2b82ecc4-ca57-49ba-bd97-f38537511260	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1542	1	11	1	[0]	2019-06-29 05:00:00	\N	\N	c083527e-ccb6-4b85-ae33-59ee77316b66	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1543	1	10	1	[0]	2019-06-29 05:00:00	\N	\N	c3a1c45c-479c-499b-b30e-38608abd3672	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1544	1	9	1	[0]	2019-06-29 05:00:00	\N	\N	2059e965-e8ca-4946-8d95-1527f06b29fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1545	1	8	1	[0]	2019-06-29 05:00:00	\N	\N	217a07c2-8bc4-4642-96af-567750d3e6b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1546	1	12	1	[0]	2019-06-29 06:00:00	\N	\N	cccca805-b3c7-41b2-bd83-8fc1c8d589bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1547	1	11	1	[0]	2019-06-29 06:00:00	\N	\N	dd314179-db51-4c94-9f8e-aba08e5d886c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1548	1	10	1	[0]	2019-06-29 06:00:00	\N	\N	96014e4e-c1e5-4ad1-8e22-376019fc87a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1549	1	9	1	[0]	2019-06-29 06:00:00	\N	\N	22f0da00-3059-465b-9d70-337a2137ab33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1550	1	8	1	[0]	2019-06-29 06:00:00	\N	\N	5fcaf142-1690-4329-b7e6-06405c0ebbe7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1551	1	12	1	[0]	2019-06-29 07:00:00	\N	\N	7fb85e6f-0751-46a5-9675-801b4891f60d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1552	1	11	1	[0]	2019-06-29 07:00:00	\N	\N	b1becd25-34a7-4f4f-852d-223bbd97c4e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1553	1	10	1	[0]	2019-06-29 07:00:00	\N	\N	76a28e88-a593-4d78-b81d-4886cafd4aa3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1554	1	9	1	[0]	2019-06-29 07:00:00	\N	\N	2fa8a932-9ab0-4bf7-8847-1c8b1daacdd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1555	1	8	1	[0]	2019-06-29 07:00:00	\N	\N	568d07d9-5339-42f6-9c46-ba2faba555cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1556	1	12	1	[0]	2019-06-29 08:00:00	\N	\N	b76338f3-ebe3-4f97-9a7b-2821cc44ff8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1557	1	11	1	[0]	2019-06-29 08:00:00	\N	\N	bfd46bd6-725a-41e6-880a-63c52c7f046f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1558	1	10	1	[0]	2019-06-29 08:00:00	\N	\N	b09c3789-3879-43ad-92d5-4083b8f5ffc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1559	1	9	1	[0]	2019-06-29 08:00:00	\N	\N	762cf817-2eaf-4043-aaed-1660e9ba6a53	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1560	1	8	1	[0]	2019-06-29 08:00:00	\N	\N	9c169c53-adf1-4f49-8532-c402aa9856cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1561	1	12	1	[0]	2019-06-29 09:00:00	\N	\N	210197d0-4fc3-450b-a636-331ca1385482	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1562	1	11	1	[0]	2019-06-29 09:00:00	\N	\N	4bb4b26e-1c53-4d69-b2f4-90987483eec2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1563	1	10	1	[0]	2019-06-29 09:00:00	\N	\N	cdec74b5-37fc-469a-84ba-370f6fd0b9cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1564	1	9	1	[0]	2019-06-29 09:00:00	\N	\N	6481063a-3f7f-4f3b-9bcd-a4d69c93bb73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1565	1	8	1	[0]	2019-06-29 09:00:00	\N	\N	91426473-18e2-48e1-a97a-9b87c1213802	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1566	1	12	1	[0]	2019-06-29 10:00:00	\N	\N	6f832895-bf88-4a88-b557-358653da009b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1567	1	11	1	[0]	2019-06-29 10:00:00	\N	\N	1db5111c-6f58-4d22-9bcc-7bb0df718104	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1568	1	10	1	[0]	2019-06-29 10:00:00	\N	\N	27e9fa44-6cde-4ebd-a37c-4d8b0ef7af7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1569	1	9	1	[0]	2019-06-29 10:00:00	\N	\N	15105521-5632-4177-8cfe-16eed140b60e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1570	1	8	1	[0]	2019-06-29 10:00:00	\N	\N	8933f697-b7cd-4b87-92fa-7ac1b42a1fdc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1571	1	12	1	[0]	2019-06-29 11:00:00	\N	\N	03a5fb3d-e0ad-4782-98fb-c816af473769	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1572	1	11	1	[0]	2019-06-29 11:00:00	\N	\N	2df46cd6-7472-4e73-9342-cb865140c06c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1573	1	10	1	[0]	2019-06-29 11:00:00	\N	\N	7b6fe933-6396-416e-a497-664698a79a45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1574	1	9	1	[0]	2019-06-29 11:00:00	\N	\N	6ec9f020-8a49-4a8d-9a91-66249367dc51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1575	1	8	1	[0]	2019-06-29 11:00:00	\N	\N	987474fa-4e03-4678-9a4c-5b1d8c330ff4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1576	1	12	1	[0]	2019-06-29 12:00:00	\N	\N	3ad591d4-4cbb-4e30-8175-b5d5d6fa9999	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1577	1	11	1	[0]	2019-06-29 12:00:00	\N	\N	1be1c1f2-d516-4422-9140-85970b5615b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1578	1	10	1	[0]	2019-06-29 12:00:00	\N	\N	a0f65d57-a418-474f-b7aa-f07eb8b0a224	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1579	1	9	1	[0]	2019-06-29 12:00:00	\N	\N	5d057192-656e-45c0-8a75-d55c000772ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1580	1	8	1	[0]	2019-06-29 12:00:00	\N	\N	98f3c124-cd41-4054-ab2a-d4f67c56080a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1581	1	12	1	[0]	2019-06-29 13:00:00	\N	\N	5b50f27f-ae8c-47cc-9a1c-88dc92863b4a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1582	1	11	1	[0]	2019-06-29 13:00:00	\N	\N	6c4c569f-e367-4ffa-b91c-7f49a4c2510b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1583	1	10	1	[0]	2019-06-29 13:00:00	\N	\N	f58cb7b3-d9ef-42f6-b4b8-70cf0dd5d136	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1584	1	9	1	[0]	2019-06-29 13:00:00	\N	\N	05d75ed3-48cc-46cc-b6fa-54da7bbd331c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1585	1	8	1	[0]	2019-06-29 13:00:00	\N	\N	5aeb4fc3-1839-4362-be32-b700c385e12e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1586	1	12	1	[0]	2019-06-29 14:00:00	\N	\N	534ea44d-c361-4c84-88b0-1e93e5d283bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1587	1	11	1	[0]	2019-06-29 14:00:00	\N	\N	0fa8c831-6051-4f39-a4de-5df34257a9f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1588	1	10	1	[0]	2019-06-29 14:00:00	\N	\N	ee7dcdb5-5604-4bed-8c58-305f3c11c546	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1589	1	9	1	[0]	2019-06-29 14:00:00	\N	\N	c292b7bd-6e01-48cf-ae49-8b2156f8add4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1590	1	8	1	[0]	2019-06-29 14:00:00	\N	\N	5cb20f4d-4138-416a-a922-fca091b620b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1591	1	12	1	[0]	2019-06-29 15:00:00	\N	\N	177f8f4a-7bd8-4d73-8b21-16b8a1cf2f5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1592	1	11	1	[0]	2019-06-29 15:00:00	\N	\N	26b0e517-8110-4bcb-b757-2e903687dcc3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1593	1	10	1	[0]	2019-06-29 15:00:00	\N	\N	212c78fe-4396-4fe6-9208-e07014f694f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1594	1	9	1	[0]	2019-06-29 15:00:00	\N	\N	41dd25e1-4150-4472-a92f-54bddc034ef7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1595	1	8	1	[0]	2019-06-29 15:00:00	\N	\N	808c8ad5-b922-4048-9816-8c2614f4f9f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1596	1	12	1	[0]	2019-06-29 16:00:00	\N	\N	e3053f98-7913-48de-9aaa-b92b53d25a48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1597	1	11	1	[0]	2019-06-29 16:00:00	\N	\N	6cf3754b-868f-421f-878d-161c172d5d1c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1598	1	10	1	[0]	2019-06-29 16:00:00	\N	\N	9a9d51ec-2a00-4221-be7a-126045a1fe67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1599	1	9	1	[0]	2019-06-29 16:00:00	\N	\N	842d183d-76c3-4c37-84a1-72177b07e575	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1600	1	8	1	[0]	2019-06-29 16:00:00	\N	\N	fca0566f-4a10-42c9-b6a6-40d2bae28993	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1601	1	12	1	[0]	2019-06-29 17:00:00	\N	\N	41f7499a-b27c-4fe8-ac25-245c942341bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1602	1	11	1	[0]	2019-06-29 17:00:00	\N	\N	d2772d61-32d8-4f8f-9e74-0ec91417e395	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1603	1	10	1	[0]	2019-06-29 17:00:00	\N	\N	66783864-9e06-4f00-b705-516af2c2bc3e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1604	1	9	1	[0]	2019-06-29 17:00:00	\N	\N	4d158a39-586f-4cc5-a79e-ffa544d19c36	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1605	1	8	1	[0]	2019-06-29 17:00:00	\N	\N	af9d958e-e6af-452d-999e-812477c88486	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1606	1	12	1	[0]	2019-06-29 18:00:00	\N	\N	3358e096-4165-41f3-9ae1-966ed3859930	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1607	1	11	1	[0]	2019-06-29 18:00:00	\N	\N	29d2672b-4e3c-4f82-a005-e1471ffb6039	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1608	1	10	1	[0]	2019-06-29 18:00:00	\N	\N	1ca112c0-01fb-4664-b95e-ae669204dc4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1609	1	9	1	[0]	2019-06-29 18:00:00	\N	\N	d17b4fe9-cc81-4258-bd7b-0b1050425701	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1610	1	8	1	[0]	2019-06-29 18:00:00	\N	\N	98210175-ca9c-4e06-b640-ba65b2d174e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1611	1	12	1	[0]	2019-06-29 19:00:00	\N	\N	876dd2c8-9336-460c-aeca-09a33fd16bfc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1612	1	11	1	[0]	2019-06-29 19:00:00	\N	\N	f713975d-5c86-4951-a6e4-d8744df31697	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1613	1	10	1	[0]	2019-06-29 19:00:00	\N	\N	289dd5b4-710a-4c06-a940-2199a41bdba4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1614	1	9	1	[0]	2019-06-29 19:00:00	\N	\N	47d771b0-408c-4539-b0cf-e8d7d494b310	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1615	1	8	1	[0]	2019-06-29 19:00:00	\N	\N	14970e69-cc5f-4a0b-944d-80915baae160	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1616	1	12	1	[0]	2019-06-29 20:00:00	\N	\N	75473274-9ad0-489d-b39e-c7a554b3c1d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1617	1	11	1	[0]	2019-06-29 20:00:00	\N	\N	8535238a-1e80-4e87-9c94-d693971eed02	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1618	1	10	1	[0]	2019-06-29 20:00:00	\N	\N	475bfde3-718a-43ca-b9aa-d60defe155b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1619	1	9	1	[0]	2019-06-29 20:00:00	\N	\N	c7f7082c-45c9-47ae-803e-f080771e1618	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1620	1	8	1	[0]	2019-06-29 20:00:00	\N	\N	c7ab59c1-eac3-4e0e-9d21-c8a362bbc5f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1621	1	12	1	[0]	2019-06-29 21:00:00	\N	\N	816598f8-e827-4599-9a9e-2b91e21f62b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1622	1	11	1	[0]	2019-06-29 21:00:00	\N	\N	d7884222-3d3e-4f30-9743-e60cbde99eed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1623	1	10	1	[0]	2019-06-29 21:00:00	\N	\N	c3a00ed0-a0f6-4bbc-aa0b-7a2070aff36c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1624	1	9	1	[0]	2019-06-29 21:00:00	\N	\N	8016ede3-21a2-4d78-a216-520c7e7d4ea6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1625	1	8	1	[0]	2019-06-29 21:00:00	\N	\N	7e67aac0-4b6d-4f5d-b6d1-abb045538c7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1626	1	12	1	[0]	2019-06-29 22:00:00	\N	\N	033e9521-72ea-43c2-8305-fef63e497cee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1627	1	11	1	[0]	2019-06-29 22:00:00	\N	\N	53f8a180-639b-445f-b941-b6e23f366753	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1628	1	10	1	[0]	2019-06-29 22:00:00	\N	\N	7cac5548-ddb5-46d5-b012-c04c65758c05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1629	1	9	1	[0]	2019-06-29 22:00:00	\N	\N	7378ff40-aebe-44ef-b23b-1b3782adbe9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1630	1	8	1	[0]	2019-06-29 22:00:00	\N	\N	9f4f0bb8-6860-46d3-ac2d-b5cf0a5d3aab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1631	1	12	1	[0]	2019-06-29 23:00:00	\N	\N	7e0ea4a1-7aab-4d27-9333-195d2fc23e6d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1632	1	11	1	[0]	2019-06-29 23:00:00	\N	\N	6ce7b665-01b9-483a-9543-3a9f12053598	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1633	1	10	1	[0]	2019-06-29 23:00:00	\N	\N	9c953e3f-d675-4716-94f2-19ba9aba06c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1634	1	9	1	[0]	2019-06-29 23:00:00	\N	\N	448364cd-757a-4935-bd7e-5cda0c58b914	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1635	1	8	1	[0]	2019-06-29 23:00:00	\N	\N	16328062-c56e-46f5-8377-a9f91536f633	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1636	1	12	1	[0]	2019-06-30 00:00:00	\N	\N	0d9e5692-a6a7-47a1-910f-bad59a980b52	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1637	1	11	1	[0]	2019-06-30 00:00:00	\N	\N	8c82d8ba-d7fa-4450-b1a0-76bd8dfc803d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1638	1	10	1	[0]	2019-06-30 00:00:00	\N	\N	7cdb21e4-099e-4ded-86d8-f46ce028b9a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1639	1	9	1	[0]	2019-06-30 00:00:00	\N	\N	6475fc4f-dd64-4b12-ad38-d8e70314297e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1640	1	8	1	[0]	2019-06-30 00:00:00	\N	\N	b413a75f-60f2-43c0-9e72-bcb299ff27fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1641	1	12	1	[0]	2019-06-30 01:00:00	\N	\N	d7a6b40a-a1b1-445c-9a83-313194fa4477	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1642	1	11	1	[0]	2019-06-30 01:00:00	\N	\N	14a0a1d4-7807-4105-ac57-e280474af313	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1643	1	10	1	[0]	2019-06-30 01:00:00	\N	\N	7b797af1-1ea0-4e82-9667-897ed6352072	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1644	1	9	1	[0]	2019-06-30 01:00:00	\N	\N	0e959ad0-f3c0-4818-8594-1b427fbc5640	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1645	1	8	1	[0]	2019-06-30 01:00:00	\N	\N	e531e174-8349-461e-a044-1d00e7a45097	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1646	1	12	1	[0]	2019-06-30 02:00:00	\N	\N	501de40a-4e87-41b7-b518-b4231d9dc173	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1647	1	11	1	[0]	2019-06-30 02:00:00	\N	\N	3c8c723c-de2a-4d55-85b1-c0fec7939543	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1648	1	10	1	[0]	2019-06-30 02:00:00	\N	\N	33d6aa6e-7f77-44b7-bce1-e01a78cd0f93	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1649	1	9	1	[0]	2019-06-30 02:00:00	\N	\N	582d1e2f-eb9e-4a8c-9510-45afaa186a35	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1650	1	8	1	[0]	2019-06-30 02:00:00	\N	\N	6009e22e-ecc1-4635-b2c9-99281d3659e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1651	1	12	1	[0]	2019-06-30 03:00:00	\N	\N	34b550aa-9322-49f1-ac94-29258d52210d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1652	1	11	1	[0]	2019-06-30 03:00:00	\N	\N	2faffc3a-fba0-4c02-9587-312b3112dcb5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1653	1	10	1	[0]	2019-06-30 03:00:00	\N	\N	b07ac5d0-3b65-462b-9663-437a508287f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1654	1	9	1	[0]	2019-06-30 03:00:00	\N	\N	1843a0e0-ac71-4b7c-a745-9a44abde4a23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1655	1	8	1	[0]	2019-06-30 03:00:00	\N	\N	c506b6b0-882a-461c-a1a2-a17746acb6b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1656	1	12	1	[0]	2019-06-30 04:00:00	\N	\N	f1c43488-d92f-4c25-8f1f-61148a0a0553	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1657	1	11	1	[0]	2019-06-30 04:00:00	\N	\N	1df03d3d-0d6e-4b34-a2c6-38e46da4af2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1658	1	10	1	[0]	2019-06-30 04:00:00	\N	\N	1e035aa8-8a06-4cf9-bbf4-ee253336e8f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1659	1	9	1	[0]	2019-06-30 04:00:00	\N	\N	45023a57-6ece-4fad-8d9a-0172a871d2d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1660	1	8	1	[0]	2019-06-30 04:00:00	\N	\N	f2fcf781-0d9b-4670-b6f0-8177c52a1614	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1661	1	12	1	[0]	2019-06-30 05:00:00	\N	\N	842225ca-85ad-42d8-8005-272c38c7467e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1662	1	11	1	[0]	2019-06-30 05:00:00	\N	\N	7a56c7e1-7adf-414d-aafd-f7b634fead91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1663	1	10	1	[0]	2019-06-30 05:00:00	\N	\N	583aabe0-5c21-4e6e-a9a9-20e72bcd44f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1664	1	9	1	[0]	2019-06-30 05:00:00	\N	\N	1d9bda15-cefb-40bf-b770-67873ee9b4ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1665	1	8	1	[0]	2019-06-30 05:00:00	\N	\N	b77d386d-09fc-403d-8998-b076bba9dd8b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1666	1	12	1	[0]	2019-06-30 06:00:00	\N	\N	0ad9532f-6ea7-4471-8092-5068961a29da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1667	1	11	1	[0]	2019-06-30 06:00:00	\N	\N	d56f4c75-b616-4c4f-94a7-0230ea67622e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1668	1	10	1	[0]	2019-06-30 06:00:00	\N	\N	06efe253-83cc-4221-800e-116593af092c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1669	1	9	1	[0]	2019-06-30 06:00:00	\N	\N	fe80b653-0a83-4a64-895c-9881fb0f1189	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1670	1	8	1	[0]	2019-06-30 06:00:00	\N	\N	aa6f2f82-eb43-44ed-8c59-af650df91ba9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1671	1	12	1	[0]	2019-06-30 07:00:00	\N	\N	1409ab32-5655-417d-bf3b-f1981d09bfbe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1672	1	11	1	[0]	2019-06-30 07:00:00	\N	\N	6ee9f426-619c-4efd-94ee-d5684916fb2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1673	1	10	1	[0]	2019-06-30 07:00:00	\N	\N	4d22ad68-4609-49e0-9ad4-64d7955e7dd5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1674	1	9	1	[0]	2019-06-30 07:00:00	\N	\N	e69c72fd-500f-4710-947f-dd0b2da7a0aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1675	1	8	1	[0]	2019-06-30 07:00:00	\N	\N	80e3d291-fac3-4417-b03d-c838a95fe31f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1676	1	12	1	[0]	2019-06-30 08:00:00	\N	\N	a5bcd186-3585-4874-bae7-4007dc2944a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1677	1	11	1	[0]	2019-06-30 08:00:00	\N	\N	f11e6279-9a76-4fba-b954-645b0183313c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1678	1	10	1	[0]	2019-06-30 08:00:00	\N	\N	484918ef-f61e-43da-9c45-5706db53ebed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1679	1	9	1	[0]	2019-06-30 08:00:00	\N	\N	d0b1dd91-ee03-4b7a-982d-2c2096c5a62b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1680	1	8	1	[0]	2019-06-30 08:00:00	\N	\N	fb1d4bf1-31d9-4dbc-b352-94cd4aa4560c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1681	1	12	1	[0]	2019-06-30 09:00:00	\N	\N	036ac7bb-c01c-43f7-a4c5-9c56e6c7c783	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1682	1	11	1	[0]	2019-06-30 09:00:00	\N	\N	d6b1e3c9-b5d8-4974-aa59-603dc68b3434	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1683	1	10	1	[0]	2019-06-30 09:00:00	\N	\N	e5c8563e-1afc-4276-b726-a5d6a8615000	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1684	1	9	1	[0]	2019-06-30 09:00:00	\N	\N	8a4e6278-30f6-4a69-b6fa-e5e1e2e3e67f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1685	1	8	1	[0]	2019-06-30 09:00:00	\N	\N	2e21a03c-493e-4597-bab1-ebf3eb7ea19a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1686	1	12	1	[0]	2019-06-30 10:00:00	\N	\N	6893f921-dab4-4786-914b-f29e87701bc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1687	1	11	1	[0]	2019-06-30 10:00:00	\N	\N	ab5b840e-633a-4a05-9388-49076bdb44f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1688	1	10	1	[0]	2019-06-30 10:00:00	\N	\N	646418ee-95a8-4ff5-9c39-8917d5e13e7b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1689	1	9	1	[0]	2019-06-30 10:00:00	\N	\N	287a56e9-427c-4903-9689-69a08249f714	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1690	1	8	1	[0]	2019-06-30 10:00:00	\N	\N	8b2ff4ae-6643-4582-a176-1cf452fe1726	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1691	1	12	1	[0]	2019-06-30 11:00:00	\N	\N	2efe17c1-2539-422f-a4c6-33fee6d9b7ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1692	1	11	1	[0]	2019-06-30 11:00:00	\N	\N	9ce07942-35bc-45e2-a935-b0c5404080e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1693	1	10	1	[0]	2019-06-30 11:00:00	\N	\N	a6814a75-1f49-4c37-a0bf-b2f743d7da5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1694	1	9	1	[0]	2019-06-30 11:00:00	\N	\N	52f313c6-bfff-4301-8cde-7aebedfbacfa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1695	1	8	1	[0]	2019-06-30 11:00:00	\N	\N	d0a2382e-edc6-493a-8f74-9970901801c9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1696	1	12	1	[0]	2019-06-30 12:00:00	\N	\N	62194d82-49ad-456a-898a-0c1813687375	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1697	1	11	1	[0]	2019-06-30 12:00:00	\N	\N	4c1e7a8c-1d0b-4129-97f4-08f32b3b55c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1698	1	10	1	[0]	2019-06-30 12:00:00	\N	\N	d3996dab-0aee-49dd-8935-28b0c15280cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1699	1	9	1	[0]	2019-06-30 12:00:00	\N	\N	3720a36b-542b-4ffc-a7da-fdc1e3054c00	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1700	1	8	1	[0]	2019-06-30 12:00:00	\N	\N	657d93d7-cc35-4ccc-a86a-a24f08c793ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1701	1	12	1	[0]	2019-06-30 13:00:00	\N	\N	e0c457de-65bf-4ba5-b414-290ce5cba1da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1702	1	11	1	[0]	2019-06-30 13:00:00	\N	\N	234aefb1-45f1-48ec-94b6-43ced3138809	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1703	1	10	1	[0]	2019-06-30 13:00:00	\N	\N	c94e40ac-c337-4495-afbd-1a0253148e63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1704	1	9	1	[0]	2019-06-30 13:00:00	\N	\N	66bac207-9437-4caa-8e61-e768cc63abd9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1705	1	8	1	[0]	2019-06-30 13:00:00	\N	\N	28de4b68-6720-4a6c-9a93-1f089305f3e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1706	1	12	1	[0]	2019-06-30 14:00:00	\N	\N	c0ec66ec-7a86-4ece-98a5-400814fd38b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1707	1	11	1	[0]	2019-06-30 14:00:00	\N	\N	10bf154c-0429-4bfa-9ad6-1df433abad0a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1708	1	10	1	[0]	2019-06-30 14:00:00	\N	\N	52c7b79f-ae45-4ee4-a72a-045b59738b85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1709	1	9	1	[0]	2019-06-30 14:00:00	\N	\N	b670758a-f11a-4762-82fa-327e250882a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1710	1	8	1	[0]	2019-06-30 14:00:00	\N	\N	555d88a5-fdb5-4de5-bfa6-b5795eca4bf5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1711	1	12	1	[0]	2019-06-30 15:00:00	\N	\N	03edd234-5e22-4334-af37-8d3c68b15f6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1712	1	11	1	[0]	2019-06-30 15:00:00	\N	\N	134e685c-f570-4228-859a-684f9891f08a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1713	1	10	1	[0]	2019-06-30 15:00:00	\N	\N	7f186d01-8050-4906-b56a-df3efa41672e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1714	1	9	1	[0]	2019-06-30 15:00:00	\N	\N	18eb2274-a758-478a-b1b0-6abaccb9c511	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1715	1	8	1	[0]	2019-06-30 15:00:00	\N	\N	86bca25d-7510-454a-84ad-bb5ccc279443	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1716	1	12	1	[0]	2019-06-30 16:00:00	\N	\N	b83724e1-0741-42e3-8245-0e73b8b621f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1717	1	11	1	[0]	2019-06-30 16:00:00	\N	\N	2f62bdd0-0c2d-4de5-95f2-ce042db72a88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1718	1	10	1	[0]	2019-06-30 16:00:00	\N	\N	3ad62455-8312-4c70-ae54-298b6d465d41	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1719	1	9	1	[0]	2019-06-30 16:00:00	\N	\N	6422520c-65dd-4339-825e-8ca9610320cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1720	1	8	1	[0]	2019-06-30 16:00:00	\N	\N	fbf3d103-8398-483c-85be-a5de50c88cac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1721	1	12	1	[0]	2019-06-30 17:00:00	\N	\N	3ba6154b-d72f-46a0-bec5-b5b79d039d52	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1722	1	11	1	[0]	2019-06-30 17:00:00	\N	\N	ccd18ffc-05d1-4c79-b76c-12901249f31d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1723	1	10	1	[0]	2019-06-30 17:00:00	\N	\N	5f068ea0-23e3-42dd-80b5-31f9a9c00819	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1724	1	9	1	[0]	2019-06-30 17:00:00	\N	\N	89e885ef-8361-4c54-a5c2-66bc90be8140	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1725	1	8	1	[0]	2019-06-30 17:00:00	\N	\N	d2e6510c-55e8-4a40-978c-23f443239f5c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1726	1	12	1	[0]	2019-06-30 18:00:00	\N	\N	e8888258-4b01-4983-864f-355aa4d27d80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1727	1	11	1	[0]	2019-06-30 18:00:00	\N	\N	fbd37899-d7d4-4912-92f9-b357b9611921	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1728	1	10	1	[0]	2019-06-30 18:00:00	\N	\N	3c643f56-9be1-423f-b947-18f8096831d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1729	1	9	1	[0]	2019-06-30 18:00:00	\N	\N	b4edb23e-aae4-4254-9391-5eaaca56940d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1730	1	8	1	[0]	2019-06-30 18:00:00	\N	\N	868dbd5d-08b8-4d6d-934f-d0f148b28eb6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1731	1	12	1	[0]	2019-06-30 19:00:00	\N	\N	ec769c1a-f236-4f41-b34c-9e905cbeedcf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1732	1	11	1	[0]	2019-06-30 19:00:00	\N	\N	637777fa-33f0-4c48-93a7-3156e17d0058	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1733	1	10	1	[0]	2019-06-30 19:00:00	\N	\N	9c0652a9-96f0-4315-a82b-fd174cfc7c2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1734	1	9	1	[0]	2019-06-30 19:00:00	\N	\N	7c26342f-5f0c-478d-955b-15b55c3715db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1735	1	8	1	[0]	2019-06-30 19:00:00	\N	\N	7e2bfb17-2e5d-4d13-9de5-e6bd189ede90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1736	1	12	1	[0]	2019-06-30 20:00:00	\N	\N	687c8afa-3c72-4e20-a051-f462b03ffeb0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1737	1	11	1	[0]	2019-06-30 20:00:00	\N	\N	824d6837-a764-4e22-bbec-e332cd30a65e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1738	1	10	1	[0]	2019-06-30 20:00:00	\N	\N	c6db7d2a-34f6-4665-85ce-99ae577beda6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1739	1	9	1	[0]	2019-06-30 20:00:00	\N	\N	6355607c-1397-4ba4-98ac-f3dd8c02fb87	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1740	1	8	1	[0]	2019-06-30 20:00:00	\N	\N	86814985-7f14-4e44-b64c-a317fc1641f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1741	1	12	1	[0]	2019-06-30 21:00:00	\N	\N	0026b7c8-8001-4f3e-93c9-1e74ebe07028	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1742	1	11	1	[0]	2019-06-30 21:00:00	\N	\N	9e0b719d-4b7c-41b0-b02b-9f8a732b63e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1743	1	10	1	[0]	2019-06-30 21:00:00	\N	\N	d1ea1231-d4fe-40f3-b76a-4034c0d1d764	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1744	1	9	1	[0]	2019-06-30 21:00:00	\N	\N	b30d2ebe-fbd6-4ac5-83ca-453c6bb2c248	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1745	1	8	1	[0]	2019-06-30 21:00:00	\N	\N	c1bf0a6f-56cb-4703-aad6-217f5d6ebe92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1746	1	12	1	[0]	2019-06-30 22:00:00	\N	\N	a361beec-bc70-4b8b-9ef1-0c0db0d7d23d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1747	1	11	1	[0]	2019-06-30 22:00:00	\N	\N	8b6032fc-c6c8-49c2-b6b0-ae3de1d9dfaa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1748	1	10	1	[0]	2019-06-30 22:00:00	\N	\N	a1dcc3da-40ac-43b0-b672-40212c640f9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1749	1	9	1	[0]	2019-06-30 22:00:00	\N	\N	14bc3e1d-8b8b-43a4-a991-e86732c247b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1750	1	8	1	[0]	2019-06-30 22:00:00	\N	\N	4b1b12ec-54cf-437c-afe2-4cd56f7aa859	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1751	1	12	1	[0]	2019-06-30 23:00:00	\N	\N	b276ed6e-2f71-4640-8f60-e6f84b2222c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1752	1	11	1	[0]	2019-06-30 23:00:00	\N	\N	b4abd1c0-e18e-4b70-87eb-fc19233a98d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1753	1	10	1	[0]	2019-06-30 23:00:00	\N	\N	e51955ed-a22d-4cef-8c26-72250dadb41d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1754	1	9	1	[0]	2019-06-30 23:00:00	\N	\N	ab471760-ea2a-439d-808d-dbbf8384b014	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1755	1	8	1	[0]	2019-06-30 23:00:00	\N	\N	3c850608-2ac4-4af0-892e-008d90086f2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1756	1	12	1	[0]	2019-07-01 00:00:00	\N	\N	04a58a09-e125-4a87-982e-fe12ee9bd7d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1757	1	11	1	[0]	2019-07-01 00:00:00	\N	\N	21f06f62-d3b2-44a3-95fc-1b32eb1f558c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1758	1	10	1	[0]	2019-07-01 00:00:00	\N	\N	2d519271-2ddd-4aa5-880d-a10a6de0dd67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1759	1	9	1	[0]	2019-07-01 00:00:00	\N	\N	b0d60912-ff50-4cf1-90c1-e46d5f06f21f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1760	1	8	1	[0]	2019-07-01 00:00:00	\N	\N	63b34786-4e7a-420e-8804-d0a833c4de0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1761	1	12	1	[0]	2019-07-01 01:00:00	\N	\N	0b9ddb62-0b89-41fd-a032-d05a3ce6b67f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1762	1	11	1	[0]	2019-07-01 01:00:00	\N	\N	6fad4eb9-59c3-4ff5-a034-f3cb0c0d41ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1763	1	10	1	[0]	2019-07-01 01:00:00	\N	\N	d90243da-d21d-4905-94fc-4e107d059c29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1764	1	9	1	[0]	2019-07-01 01:00:00	\N	\N	b7874002-34df-4a33-94dd-a8e1d8e74e7a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1765	1	8	1	[0]	2019-07-01 01:00:00	\N	\N	e378d52d-a8fb-4fa5-99a0-216d0d4a49f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1766	1	12	1	[0]	2019-07-01 02:00:00	\N	\N	60490005-8c52-4715-be4f-073fe3324406	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1767	1	11	1	[0]	2019-07-01 02:00:00	\N	\N	fcd58593-fddc-4779-aa8c-3fcf153fc9d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1768	1	10	1	[0]	2019-07-01 02:00:00	\N	\N	84d4dc3e-87c2-40b3-ae1b-6dbc508e9db1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1769	1	9	1	[0]	2019-07-01 02:00:00	\N	\N	1dee94f1-0027-4f92-90b2-27a7b78651f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1770	1	8	1	[0]	2019-07-01 02:00:00	\N	\N	2da226b4-410e-4615-a01c-57e6651e7081	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1771	1	12	1	[0]	2019-07-01 03:00:00	\N	\N	35b056cf-35ea-4c80-b9ec-3862053f79c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1772	1	11	1	[0]	2019-07-01 03:00:00	\N	\N	633daaa1-6c5f-445b-b163-2b81ee9fc4ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1773	1	10	1	[0]	2019-07-01 03:00:00	\N	\N	0ca25ac7-a743-45e1-819d-cc0cde8e9975	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1774	1	9	1	[0]	2019-07-01 03:00:00	\N	\N	c5cedaff-2af4-4fb8-99ab-ed2dfe691e22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1775	1	8	1	[0]	2019-07-01 03:00:00	\N	\N	5d99eff1-64b8-4b6b-9b94-c8f292fdc00f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1776	1	12	1	[0]	2019-07-01 04:00:00	\N	\N	b5c1aa53-7413-4f85-9b5a-c503b814e6a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1777	1	11	1	[0]	2019-07-01 04:00:00	\N	\N	9c2e3f59-0fbd-4592-b9dc-f34ff9e3469b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1778	1	10	1	[0]	2019-07-01 04:00:00	\N	\N	aede09e8-afdd-4872-bc7f-056ca5fafed0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1779	1	9	1	[0]	2019-07-01 04:00:00	\N	\N	7e945cb8-276c-4e12-bf88-541863312171	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1780	1	8	1	[0]	2019-07-01 04:00:00	\N	\N	f48f5cdc-a056-4165-9b52-8165ac7ca85d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1781	1	12	1	[0]	2019-07-01 05:00:00	\N	\N	50c71e2b-1d6d-4cd1-9bee-8cd37ca5578b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1782	1	11	1	[0]	2019-07-01 05:00:00	\N	\N	4e9433b3-da2d-40db-8c18-819a77044fa2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1783	1	10	1	[0]	2019-07-01 05:00:00	\N	\N	3743fdc0-cae8-45b8-9938-af02ebfd664f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1784	1	9	1	[0]	2019-07-01 05:00:00	\N	\N	378729d7-76f8-4e70-a727-869fb43c62f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1785	1	8	1	[0]	2019-07-01 05:00:00	\N	\N	b6fee685-2b2f-4d6c-9f52-0a51fdc28457	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1786	1	12	1	[0]	2019-07-01 06:00:00	\N	\N	2d4b3ddf-4a0f-42bb-a229-538054b861de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1787	1	11	1	[0]	2019-07-01 06:00:00	\N	\N	95b723d2-b867-4997-a4c9-9cab37a3c7cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1788	1	10	1	[0]	2019-07-01 06:00:00	\N	\N	0977c2c4-c106-4e21-8f9e-7a253bab9bae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1789	1	9	1	[0]	2019-07-01 06:00:00	\N	\N	7089d89c-0849-4886-89ef-a58158bc4b5d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1790	1	8	1	[0]	2019-07-01 06:00:00	\N	\N	8356c812-8ab1-4f1c-ae3c-13e8e2b7bcb2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1791	1	12	1	[0]	2019-07-01 07:00:00	\N	\N	e341f223-5630-4f2a-978f-6698142c50f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1792	1	11	1	[0]	2019-07-01 07:00:00	\N	\N	102ab3b0-beae-4b56-aeec-34be8a50122f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1793	1	10	1	[0]	2019-07-01 07:00:00	\N	\N	1c9e6d9f-ac8f-44d5-9656-8f3845c9d834	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1794	1	9	1	[0]	2019-07-01 07:00:00	\N	\N	854de5f9-a168-48c1-9af2-f5159356e0a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1795	1	8	1	[0]	2019-07-01 07:00:00	\N	\N	915d2abb-0745-4e7a-9ccc-2741b1a68949	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1796	1	12	1	[0]	2019-07-01 08:00:00	\N	\N	b86b80ea-6e65-4e37-b409-7c287211db2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1797	1	11	1	[0]	2019-07-01 08:00:00	\N	\N	9121ca81-6f3f-4b60-bc93-0afcb80c6443	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1798	1	10	1	[0]	2019-07-01 08:00:00	\N	\N	b516eccd-8d08-49ac-931c-a853468cfd42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1799	1	9	1	[0]	2019-07-01 08:00:00	\N	\N	9bd3a513-be57-4745-998e-00befcef30f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1800	1	8	1	[0]	2019-07-01 08:00:00	\N	\N	8a94a752-af5e-49ec-a774-2b866ba3c753	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1801	1	12	1	[0]	2019-07-01 09:00:00	\N	\N	c521c3ff-9a80-4ca3-96e3-840cd0671847	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1802	1	11	1	[0]	2019-07-01 09:00:00	\N	\N	214278dc-8987-4bf7-b47c-5ab3f593b455	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1803	1	10	1	[0]	2019-07-01 09:00:00	\N	\N	fe903143-4cee-4b3b-8e7e-b4c8fdb3a546	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1804	1	9	1	[0]	2019-07-01 09:00:00	\N	\N	2639a672-47e3-42ae-b930-309a4a6d299b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1805	1	8	1	[0]	2019-07-01 09:00:00	\N	\N	9a385bf0-8b20-45c3-9745-b3c47e8056d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1806	1	12	1	[0]	2019-07-01 10:00:00	\N	\N	a6fbdd71-78d2-42e0-bca5-c4718fc17f6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1807	1	11	1	[0]	2019-07-01 10:00:00	\N	\N	7afd8e5a-db11-4b77-a5d8-a0b4de26f60b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1808	1	10	1	[0]	2019-07-01 10:00:00	\N	\N	c4f1631d-8f1d-474c-9108-16a871b63abd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1809	1	9	1	[0]	2019-07-01 10:00:00	\N	\N	e722d41d-55f7-4cd4-97cd-fa7f944cd920	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1810	1	8	1	[0]	2019-07-01 10:00:00	\N	\N	d29a5ab3-964d-441b-aa93-46e39e0554e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1811	1	12	1	[0]	2019-07-01 11:00:00	\N	\N	358ddfd7-5f0d-4cfa-b83e-975a43bf1fd1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1812	1	11	1	[0]	2019-07-01 11:00:00	\N	\N	926d5813-dfc1-426a-a8e4-164862d71b2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1813	1	10	1	[0]	2019-07-01 11:00:00	\N	\N	a352c77e-13c0-49cb-b318-84510a1e1779	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1814	1	9	1	[0]	2019-07-01 11:00:00	\N	\N	640b1bfd-24b6-4b2f-81f5-0fbaec217d1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1815	1	8	1	[0]	2019-07-01 11:00:00	\N	\N	395e72be-0239-4e19-a56d-7d9d0a402610	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1816	1	12	1	[0]	2019-07-01 12:00:00	\N	\N	636b1e1a-a3f0-4e05-bae6-e1474a333b90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1817	1	11	1	[0.200000003]	2019-07-01 12:00:00	\N	\N	c8a27c90-1040-4ccc-989d-b594df090403	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1818	1	10	1	[0]	2019-07-01 12:00:00	\N	\N	c6de9045-58e3-4021-8261-7074c0fffdf7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1819	1	9	1	[0]	2019-07-01 12:00:00	\N	\N	47b0634f-30e0-4d1b-941d-6914458c38fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1820	1	8	1	[0]	2019-07-01 12:00:00	\N	\N	5e97fa91-3008-4bf9-81a3-bb39323db023	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1821	1	12	1	[0]	2019-07-01 13:00:00	\N	\N	2e5d288b-df33-4970-ba04-46f26ddc6385	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1822	1	11	1	[0]	2019-07-01 13:00:00	\N	\N	6ae44815-4f59-4f40-b999-807c1efd3ea0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1823	1	10	1	[0]	2019-07-01 13:00:00	\N	\N	db496d29-f445-415f-a9ce-0c1b910051c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1824	1	9	1	[0]	2019-07-01 13:00:00	\N	\N	ae6c616f-b23f-447f-8f16-a7f9445b4f8c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1825	1	8	1	[0]	2019-07-01 13:00:00	\N	\N	f9d688d9-4ac8-43d8-a49e-7ca53ae8564e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1826	1	12	1	[0]	2019-07-01 14:00:00	\N	\N	c322df17-2760-4c6b-a5fc-4b68b0c2b28b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1827	1	11	1	[0]	2019-07-01 14:00:00	\N	\N	f1f0b426-2281-47a7-8b8d-4756a5f13382	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1828	1	10	1	[0]	2019-07-01 14:00:00	\N	\N	ebf6a36c-55fc-4033-90cb-62f10eea8cdd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1829	1	9	1	[0]	2019-07-01 14:00:00	\N	\N	7d7ef47b-9158-4eb6-9cb1-65a7ca602f12	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1830	1	8	1	[0]	2019-07-01 14:00:00	\N	\N	6c7691be-e72d-4d71-8e0f-8069343c24e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1831	1	12	1	[0]	2019-07-01 15:00:00	\N	\N	9e3a4490-82a2-42d4-b478-4fdac1eed894	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1832	1	11	1	[0]	2019-07-01 15:00:00	\N	\N	2d4c78cd-0c12-413c-964e-25c1d961d4e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1833	1	10	1	[0]	2019-07-01 15:00:00	\N	\N	6e1d6926-8472-40b4-8717-bd9f40694ad4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1834	1	9	1	[0]	2019-07-01 15:00:00	\N	\N	eb575cd5-50c1-4c92-b99d-eb7c23094171	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1835	1	8	1	[0]	2019-07-01 15:00:00	\N	\N	df393041-6248-4d6a-9121-651e123ccd4f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1836	1	12	1	[0]	2019-07-01 16:00:00	\N	\N	1de4ace6-e998-46e5-94a0-0be4128573d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1837	1	11	1	[0]	2019-07-01 16:00:00	\N	\N	ecb3065a-7146-4ee3-a11e-6129de428299	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1838	1	10	1	[0]	2019-07-01 16:00:00	\N	\N	11d6e21a-6a88-413f-bf64-04899ae60829	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1839	1	9	1	[0]	2019-07-01 16:00:00	\N	\N	93e8c331-b8eb-4d08-8820-12eb2cc04ad4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1840	1	8	1	[0]	2019-07-01 16:00:00	\N	\N	29900283-3829-4b70-a911-ed05edd7bd5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1841	1	12	1	[0]	2019-07-01 17:00:00	\N	\N	d1703350-3008-41b9-977c-0471995a5af2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1842	1	11	1	[0]	2019-07-01 17:00:00	\N	\N	2a77cea6-2818-4121-8b7a-e4d97080adbf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1843	1	10	1	[0]	2019-07-01 17:00:00	\N	\N	70a25775-a54f-4dc5-96a8-aef8b42812da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1844	1	9	1	[0]	2019-07-01 17:00:00	\N	\N	c1709ff8-0492-45b4-960f-3b473f9b83f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1845	1	8	1	[0]	2019-07-01 17:00:00	\N	\N	1bcb4a85-5511-4455-a50d-67f613ad8a62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1846	1	12	1	[0]	2019-07-01 18:00:00	\N	\N	ef9aafa8-43d0-4638-af73-f5f74e684a03	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1847	1	11	1	[0]	2019-07-01 18:00:00	\N	\N	47df4fa7-4a49-4eb5-82ac-7f74ac82d627	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1848	1	10	1	[0]	2019-07-01 18:00:00	\N	\N	6cc01063-1bc5-412b-8c41-c43485c92b1b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1849	1	9	1	[0]	2019-07-01 18:00:00	\N	\N	28e7d078-762f-4e6e-addf-0d05340314af	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1850	1	8	1	[0]	2019-07-01 18:00:00	\N	\N	739a4379-8d14-4706-b507-eb294e328a51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1851	1	12	1	[0]	2019-07-01 19:00:00	\N	\N	0814b424-252a-4e3d-8e98-1fb557860b01	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1852	1	11	1	[0]	2019-07-01 19:00:00	\N	\N	4c119e62-652f-4a5b-8bd2-567eecd460d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1853	1	10	1	[0]	2019-07-01 19:00:00	\N	\N	4fef3c4e-6467-4879-994a-dc2ffd9aa532	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1854	1	9	1	[0]	2019-07-01 19:00:00	\N	\N	4d3674fd-5e30-45bc-8a07-95651eca889e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1855	1	8	1	[0]	2019-07-01 19:00:00	\N	\N	a50b1005-e66d-4433-81bd-02fae4691685	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1856	1	12	1	[0]	2019-07-01 20:00:00	\N	\N	ebeaf1d8-1f15-44d3-9da4-792671574816	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1857	1	11	1	[0]	2019-07-01 20:00:00	\N	\N	288da63d-3e11-4b55-832b-8bf86251f590	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1858	1	10	1	[0]	2019-07-01 20:00:00	\N	\N	674d30ec-573c-484b-ae1d-9d3a8ea204e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1859	1	9	1	[0]	2019-07-01 20:00:00	\N	\N	0a1a6766-b14f-47ab-935a-ca4270f0220d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1860	1	8	1	[0]	2019-07-01 20:00:00	\N	\N	f3593bd5-5cc5-4a0f-9639-3d9fc6cffea5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1861	1	12	1	[0]	2019-07-01 21:00:00	\N	\N	cb5c6228-3ab2-41bd-a852-541a0c30ae3a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1862	1	11	1	[0]	2019-07-01 21:00:00	\N	\N	b564a553-14a2-45ab-a774-c017c0b53990	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1863	1	10	1	[0]	2019-07-01 21:00:00	\N	\N	c6da7632-e070-4bfe-ac19-1b41f4293c99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1864	1	9	1	[0]	2019-07-01 21:00:00	\N	\N	2bf2528e-bb12-4ce5-bd42-53f8acbf7d29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1865	1	8	1	[0]	2019-07-01 21:00:00	\N	\N	59cd3130-e0ac-4f19-8e21-cc644cce1b9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1866	1	12	1	[0]	2019-07-01 22:00:00	\N	\N	5b272c86-9ac7-4b29-8436-095ad668d176	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1867	1	11	1	[0]	2019-07-01 22:00:00	\N	\N	b09c19d8-badf-463d-8861-ec0f78682a37	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1868	1	10	1	[0]	2019-07-01 22:00:00	\N	\N	75987baa-33da-4145-8a76-90aa0d21e538	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1869	1	9	1	[0]	2019-07-01 22:00:00	\N	\N	dc5209d7-74c4-47e6-b699-bf0fb9047268	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1870	1	8	1	[0]	2019-07-01 22:00:00	\N	\N	fa775e0d-d82e-4760-85c2-815697a44a3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1871	1	12	1	[0]	2019-07-01 23:00:00	\N	\N	870e7545-fc84-4a52-bce1-198f40e2fa2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1872	1	11	1	[0]	2019-07-01 23:00:00	\N	\N	b2b8fd98-b7b5-4fdc-b976-41abc6ac44e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1873	1	10	1	[0]	2019-07-01 23:00:00	\N	\N	c91cee15-33a2-4fd9-aa61-613b02cce95e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1874	1	9	1	[0]	2019-07-01 23:00:00	\N	\N	5697b2b3-d6f9-413a-b820-66d0de1cc109	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1875	1	8	1	[0]	2019-07-01 23:00:00	\N	\N	eb29dccb-4843-4078-80f2-ac7d44d4a4a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1876	1	12	1	[0]	2019-07-02 00:00:00	\N	\N	2f3dcd74-2ff1-4d7f-995f-bfbaf3eec87f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1877	1	11	1	[0]	2019-07-02 00:00:00	\N	\N	93dce31b-6af1-4365-b456-4d0522090a14	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1878	1	10	1	[0]	2019-07-02 00:00:00	\N	\N	9f991a1d-c6e6-483c-81c2-1fff66bc533f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1879	1	9	1	[0]	2019-07-02 00:00:00	\N	\N	b010e414-bab8-4542-a409-377de7eb9d54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1880	1	8	1	[0]	2019-07-02 00:00:00	\N	\N	b89d760b-1c45-423a-9c66-8cc13197586f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1881	1	12	1	[0]	2019-07-02 01:00:00	\N	\N	624b2980-e7a2-4fa5-a970-dadf4b499712	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1882	1	11	1	[0]	2019-07-02 01:00:00	\N	\N	8ff7dbec-24cb-4289-98e7-2448cd6e992b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1883	1	10	1	[0]	2019-07-02 01:00:00	\N	\N	ef1a13bb-c36c-4827-96c4-3f598ed9aa86	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1884	1	9	1	[0]	2019-07-02 01:00:00	\N	\N	76ccc429-1775-4541-90c6-cb75385dc4d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1885	1	8	1	[0]	2019-07-02 01:00:00	\N	\N	915233d6-0e49-4e46-a851-dd9383babf09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1886	1	12	1	[0]	2019-07-02 02:00:00	\N	\N	578eac2a-3a9d-4c00-a954-94570e614900	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1887	1	11	1	[0]	2019-07-02 02:00:00	\N	\N	3115e087-ba78-47a3-ab24-d1c2ccaff884	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1888	1	10	1	[0]	2019-07-02 02:00:00	\N	\N	bd1e3bdd-46c3-4d53-b239-02ad144db99d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1889	1	9	1	[0]	2019-07-02 02:00:00	\N	\N	ae814f90-e6f3-47ee-9d78-4752f973be96	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1890	1	8	1	[0]	2019-07-02 02:00:00	\N	\N	29530351-a4ad-4d60-b853-b617d965f5a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1891	1	12	1	[0]	2019-07-02 03:00:00	\N	\N	d1970f39-15ad-4703-901b-a5998861d52d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1892	1	11	1	[0]	2019-07-02 03:00:00	\N	\N	6dc94f6a-ba4e-4e57-bffd-325fec5435b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1893	1	10	1	[0]	2019-07-02 03:00:00	\N	\N	ede8b1b2-d559-4a93-9f5c-6fbab24d5ca0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1894	1	9	1	[0]	2019-07-02 03:00:00	\N	\N	8f1d5410-caa1-48fd-a3fc-475684f2300c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1895	1	8	1	[0]	2019-07-02 03:00:00	\N	\N	20060a27-581b-4de9-8136-4de72e35a636	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1896	1	12	1	[0]	2019-07-02 04:00:00	\N	\N	b369d336-b619-44ae-b882-ab00baf53408	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1897	1	11	1	[0]	2019-07-02 04:00:00	\N	\N	2b1adb53-218f-476c-ad9c-39db5e15149b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1898	1	10	1	[0]	2019-07-02 04:00:00	\N	\N	874c1149-e99f-4546-bf4b-c863609d79d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1899	1	9	1	[0]	2019-07-02 04:00:00	\N	\N	cdaed7ac-53cb-4eb7-a606-2eab43c09a0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1900	1	8	1	[0]	2019-07-02 04:00:00	\N	\N	75f733b9-86ef-4ce4-bdac-4431bdc833f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1901	1	12	1	[0]	2019-07-02 05:00:00	\N	\N	84629391-9e3a-4a75-91c4-6367c66b8601	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1902	1	11	1	[0]	2019-07-02 05:00:00	\N	\N	40526806-1048-46f4-8cdc-8113cdbed31f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1903	1	10	1	[0]	2019-07-02 05:00:00	\N	\N	e2bd153e-9f3d-4f16-bc5d-bdc10613b47d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1904	1	9	1	[0]	2019-07-02 05:00:00	\N	\N	f8b0e058-5e32-43bc-a370-77ec357cd6f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1905	1	8	1	[0]	2019-07-02 05:00:00	\N	\N	e6ccf6b3-7488-49b0-a2e9-611a7a15ae59	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1906	1	12	1	[0]	2019-07-02 06:00:00	\N	\N	a0aadcfe-3733-48c8-b880-69bfa6cd7553	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1907	1	11	1	[0]	2019-07-02 06:00:00	\N	\N	b80f3c0d-761a-4fc9-b296-00733f0a25b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1908	1	10	1	[0]	2019-07-02 06:00:00	\N	\N	f37304be-2466-4660-b7d9-0db0a136862e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1909	1	9	1	[0]	2019-07-02 06:00:00	\N	\N	e73d111c-8979-4d39-a8d3-972b9ff69d7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1910	1	8	1	[0]	2019-07-02 06:00:00	\N	\N	96c4b831-1897-4ef3-86f9-3da2dbfdbe53	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1911	1	12	1	[0.200000003]	2019-07-02 07:00:00	\N	\N	f7054606-ad3a-46c1-b05c-9eb98110f471	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1912	1	11	1	[0]	2019-07-02 07:00:00	\N	\N	0ac350d7-4a98-42a5-9c19-0d76f3e450f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1913	1	10	1	[0]	2019-07-02 07:00:00	\N	\N	ac98faec-d65a-4b24-82da-e8519115d27d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1914	1	9	1	[0]	2019-07-02 07:00:00	\N	\N	59f0375e-59f3-4776-a62c-6f907d2c7746	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1915	1	8	1	[0]	2019-07-02 07:00:00	\N	\N	777c9a56-b109-4bfa-8e6f-daf7a52badce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1916	1	12	1	[0]	2019-07-02 08:00:00	\N	\N	c61ee1ae-e07b-4f42-bba7-e5e38e6c510f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1917	1	11	1	[0]	2019-07-02 08:00:00	\N	\N	aaf82950-1099-4c98-83d8-8fad92179840	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1918	1	10	1	[0]	2019-07-02 08:00:00	\N	\N	8234bcb1-efb1-40b3-8bff-f96900087500	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1919	1	9	1	[0]	2019-07-02 08:00:00	\N	\N	09f9d830-b513-408a-8984-c9596334137e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1920	1	8	1	[0]	2019-07-02 08:00:00	\N	\N	63dbce18-7a51-4527-8c51-ba263cbe7bc2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1921	1	12	1	[0]	2019-07-02 09:00:00	\N	\N	b242632e-5ca3-446b-bd03-f2f7df948934	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1922	1	11	1	[0]	2019-07-02 09:00:00	\N	\N	fab0c101-6d9a-491f-86bb-760431cc9c36	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1923	1	10	1	[0]	2019-07-02 09:00:00	\N	\N	275e3dd5-4a46-472d-b1a9-4491b2873b4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1924	1	9	1	[0]	2019-07-02 09:00:00	\N	\N	55a93458-8195-4cf5-8bb0-40f5f53d2f8c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1925	1	8	1	[0]	2019-07-02 09:00:00	\N	\N	88d78d96-3ecd-4658-8c7e-326551c87708	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1926	1	12	1	[0]	2019-07-02 10:00:00	\N	\N	e8132be0-05db-4514-8c1e-5c925bca3543	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1927	1	11	1	[0]	2019-07-02 10:00:00	\N	\N	1ebfcf70-ab04-4f52-a973-3009c8628ee1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1928	1	10	1	[0]	2019-07-02 10:00:00	\N	\N	38ff5960-5f80-4fb5-ad18-ff1131712f98	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1929	1	9	1	[0]	2019-07-02 10:00:00	\N	\N	6bf7b9e4-f736-4b4c-bce0-e1002aa7bcbd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1930	1	8	1	[0]	2019-07-02 10:00:00	\N	\N	6088f21c-ea80-4c90-bcdd-d4797ac8bd17	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1931	1	12	1	[0]	2019-07-02 11:00:00	\N	\N	c877c16d-1382-4465-a2b6-c52969739203	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1932	1	11	1	[0]	2019-07-02 11:00:00	\N	\N	c2295ea1-2f44-4926-a727-a6406e1b45f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1933	1	10	1	[0]	2019-07-02 11:00:00	\N	\N	205d10e7-fd70-436c-9512-f172983a3cd7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1934	1	9	1	[0]	2019-07-02 11:00:00	\N	\N	2a7159ff-f892-4fa2-9365-b4095d73f584	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1935	1	8	1	[0]	2019-07-02 11:00:00	\N	\N	9e798fe7-7bf0-430b-b8d0-36ef1579ea26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1936	1	12	1	[0]	2019-07-02 12:00:00	\N	\N	8038c6e1-de6b-45d3-9ecd-48036323b1c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1937	1	11	1	[0]	2019-07-02 12:00:00	\N	\N	ef0a35ab-0e58-4075-84ee-7f8d32394b05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1938	1	10	1	[0]	2019-07-02 12:00:00	\N	\N	7427affe-9cd7-4a3d-85e9-08690c812a23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1939	1	9	1	[0]	2019-07-02 12:00:00	\N	\N	0157ebad-56be-469e-b9bc-bffeeec61e62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1940	1	8	1	[0]	2019-07-02 12:00:00	\N	\N	42026e2c-5b25-40b6-915a-8bd39950a871	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1941	1	12	1	[0]	2019-07-02 13:00:00	\N	\N	6d80f7f8-1bf5-4274-9873-4b014d0f2fc4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1942	1	11	1	[0]	2019-07-02 13:00:00	\N	\N	7c251067-2b92-4cd7-b215-a01733edfab1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1943	1	10	1	[0]	2019-07-02 13:00:00	\N	\N	dcd85f56-1004-47e4-8517-2458d5f8d258	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1944	1	9	1	[0]	2019-07-02 13:00:00	\N	\N	8d0aa908-8c66-4bee-a54b-bcc939a0649f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1945	1	8	1	[0]	2019-07-02 13:00:00	\N	\N	d501a07a-96e0-4b25-b962-0fdbd87fc5ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1946	1	12	1	[0]	2019-07-02 14:00:00	\N	\N	69bc642c-7b79-4292-a0ba-f7818c39fd39	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1947	1	11	1	[0]	2019-07-02 14:00:00	\N	\N	832915a5-2370-4cd0-98d6-4c71c9756869	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1948	1	10	1	[0]	2019-07-02 14:00:00	\N	\N	ad3748bd-4c59-40c0-8ee0-66958a91bdfe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1949	1	9	1	[0]	2019-07-02 14:00:00	\N	\N	b4740d19-f01f-4061-828b-04a4de5d10d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1950	1	8	1	[0]	2019-07-02 14:00:00	\N	\N	bb1a7a55-b4d3-40be-bdd0-89d150d46779	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1951	1	12	1	[0]	2019-07-02 15:00:00	\N	\N	3e191706-aaf4-4f45-8eab-a3d31fa35df5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1952	1	11	1	[0]	2019-07-02 15:00:00	\N	\N	2f781efb-b848-4e6a-8c18-0205efe23a3e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1953	1	10	1	[0]	2019-07-02 15:00:00	\N	\N	128d8324-47bd-472e-88f2-eb4f010e3313	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1954	1	9	1	[0]	2019-07-02 15:00:00	\N	\N	a3c51912-19be-4617-a215-7c3edc4fcd91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1955	1	8	1	[0]	2019-07-02 15:00:00	\N	\N	e0d47847-2bd5-45db-b85e-0519f505218e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1956	1	12	1	[0]	2019-07-02 16:00:00	\N	\N	be6a335a-9249-447b-91bb-1d550e0b2c87	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1957	1	11	1	[0]	2019-07-02 16:00:00	\N	\N	a0a71540-6d77-49ed-9e4a-860f2d421a7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1958	1	10	1	[0]	2019-07-02 16:00:00	\N	\N	5c7e146d-2a9a-46b1-b234-a439bbd53832	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1959	1	9	1	[0]	2019-07-02 16:00:00	\N	\N	e92dcb60-3916-473c-9ac7-c0bb5ab7af32	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1960	1	8	1	[0]	2019-07-02 16:00:00	\N	\N	95a4b57b-24fb-4bd6-af7c-dd1a138fb538	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1961	1	12	1	[0]	2019-07-02 17:00:00	\N	\N	91371a1f-da71-4beb-9df8-7ca46a87aeba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1962	1	11	1	[0]	2019-07-02 17:00:00	\N	\N	cc5f045d-4964-436b-805e-bfe27bd809ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1963	1	10	1	[0]	2019-07-02 17:00:00	\N	\N	88460c2d-fc2e-44ef-b8f8-11d075056631	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1964	1	9	1	[0]	2019-07-02 17:00:00	\N	\N	d6a25bf1-490a-4ed9-be38-20ea33120eed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1965	1	8	1	[0]	2019-07-02 17:00:00	\N	\N	153a9124-6f1d-49df-af65-c2445ac853ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1966	1	12	1	[0]	2019-07-02 18:00:00	\N	\N	bee09310-d484-41d8-a8b4-924dc875bfa6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1967	1	11	1	[0]	2019-07-02 18:00:00	\N	\N	cabfc2c3-4df1-41d8-aaf7-ec47974d4ebc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1968	1	10	1	[0]	2019-07-02 18:00:00	\N	\N	bc6155e7-7230-4c47-a56f-ef606b857955	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1969	1	9	1	[0]	2019-07-02 18:00:00	\N	\N	e758bdba-7552-4330-9ac2-0518fd689048	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1970	1	8	1	[0]	2019-07-02 18:00:00	\N	\N	111dfdca-efdf-4de8-a180-fbc3bc8458b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1971	1	12	1	[0]	2019-07-02 19:00:00	\N	\N	72c03f60-e58a-49bf-8b9c-ffa9e17d35ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1972	1	11	1	[0]	2019-07-02 19:00:00	\N	\N	378ea050-b159-4673-8839-367e2dc7d14a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1973	1	10	1	[0]	2019-07-02 19:00:00	\N	\N	28888d67-3ae7-411d-95f2-44be8793cdea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1974	1	9	1	[0]	2019-07-02 19:00:00	\N	\N	59c8ab80-66b1-4764-9c00-a8953c2376e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1975	1	8	1	[0]	2019-07-02 19:00:00	\N	\N	d3c3d904-04f0-4f95-8e80-7067d11658a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1976	1	12	1	[0]	2019-07-02 20:00:00	\N	\N	a5fce47d-c886-476d-93d4-766ac798b98c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1977	1	11	1	[0]	2019-07-02 20:00:00	\N	\N	b7ce5ccf-0760-4624-a311-94e2dfd72e0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1978	1	10	1	[0]	2019-07-02 20:00:00	\N	\N	bb59a6bd-4aab-4787-a3d1-96da1c8b2c4f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1979	1	9	1	[0]	2019-07-02 20:00:00	\N	\N	358acf64-e950-4b3e-b8fa-53ddeba96803	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1980	1	8	1	[0]	2019-07-02 20:00:00	\N	\N	7d50496a-8cc0-423d-9977-22dcce58d541	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1981	1	12	1	[0]	2019-07-02 21:00:00	\N	\N	f9a86c19-41a4-4dae-ab19-6029c313fb80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1982	1	11	1	[0]	2019-07-02 21:00:00	\N	\N	5c9a7195-3413-4fac-9fe6-283c0b32e6bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1983	1	10	1	[0]	2019-07-02 21:00:00	\N	\N	047678c9-8872-40c6-a749-694a4d5507f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1984	1	9	1	[0]	2019-07-02 21:00:00	\N	\N	c7597d08-d18e-4226-99ce-2214a4eb58c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1985	1	8	1	[0]	2019-07-02 21:00:00	\N	\N	f89d6deb-083d-4977-99e5-554ffe223180	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1986	1	12	1	[0]	2019-07-02 22:00:00	\N	\N	42671562-9177-4300-9e10-feaadf2c5c3b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1987	1	11	1	[0]	2019-07-02 22:00:00	\N	\N	4f097669-309b-4c2b-b716-067012d39f4d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1988	1	10	1	[0]	2019-07-02 22:00:00	\N	\N	7a7c1f6c-f893-436a-bdce-db3a94a51df6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1989	1	9	1	[0]	2019-07-02 22:00:00	\N	\N	a70e4c57-4665-4338-b589-a4350a6bd509	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1990	1	8	1	[0]	2019-07-02 22:00:00	\N	\N	7d64ee80-b509-4d8d-98a7-654fee459bb7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1991	1	12	1	[0]	2019-07-02 23:00:00	\N	\N	636d97ff-0c65-46b3-938f-e6297a4a61e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1992	1	11	1	[0]	2019-07-02 23:00:00	\N	\N	3d4976fa-b3f4-4404-8895-d8c004116edd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1993	1	10	1	[0]	2019-07-02 23:00:00	\N	\N	aee9c53c-e101-4574-bf4c-54f08f2af4fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1994	1	9	1	[0]	2019-07-02 23:00:00	\N	\N	6bc164d9-2586-4d43-8d90-b0cdc33eca7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1995	1	8	1	[0]	2019-07-02 23:00:00	\N	\N	996ba2a2-84aa-49bb-a533-0d09e4c6a210	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1996	1	12	1	[0]	2019-07-03 00:00:00	\N	\N	6d1089fa-829f-4da0-8635-e9449a12aaf0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1997	1	11	1	[0]	2019-07-03 00:00:00	\N	\N	5760e89b-30aa-4491-a342-90dc0862bce8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1998	1	10	1	[0]	2019-07-03 00:00:00	\N	\N	0b1da89d-4adb-4595-8441-4936cb7a4791	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1999	1	9	1	[0]	2019-07-03 00:00:00	\N	\N	3a76743d-4250-4cc4-b9ad-67529d86a7ae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2000	1	8	1	[0]	2019-07-03 00:00:00	\N	\N	0d26eb19-7073-4c96-a4dc-44ccedd1b7a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2001	1	12	1	[0]	2019-07-03 01:00:00	\N	\N	62cf6eab-c156-4353-b558-ba10cda9974a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2002	1	11	1	[0]	2019-07-03 01:00:00	\N	\N	f0d67916-bd2f-43a4-bb10-8c19282c1ee4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2003	1	10	1	[0]	2019-07-03 01:00:00	\N	\N	dd469f1a-260c-4a70-98c3-8646ddc04db4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2004	1	9	1	[0]	2019-07-03 01:00:00	\N	\N	e2f86085-dbf7-4599-ad51-4900194967bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2005	1	8	1	[0]	2019-07-03 01:00:00	\N	\N	b2690f5b-b836-4f94-90d7-276db2a17c24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2006	1	12	1	[0]	2019-07-03 02:00:00	\N	\N	8c566f6d-00f3-44b6-b87f-b1373cc98b3a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2007	1	11	1	[0]	2019-07-03 02:00:00	\N	\N	04fe63a4-9d5b-4f5f-9549-5af875dafb55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2008	1	10	1	[0]	2019-07-03 02:00:00	\N	\N	1c45f1c9-cda8-4035-b891-6e6f2d58f63c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2009	1	9	1	[0]	2019-07-03 02:00:00	\N	\N	5590ffcc-64b5-4f06-93a4-cd404fabae05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2010	1	8	1	[0]	2019-07-03 02:00:00	\N	\N	ca1d9ef6-9538-4f22-bc26-2dc920facfaf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2011	1	12	1	[0]	2019-07-03 03:00:00	\N	\N	1c2a5884-d540-4886-ba00-5875dffdd35a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2012	1	11	1	[0]	2019-07-03 03:00:00	\N	\N	b80cdbaf-3280-4f2b-bc00-27a09f877ca4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2013	1	10	1	[0]	2019-07-03 03:00:00	\N	\N	9bb76824-c9c8-4b5d-a70f-0e614ecfe5ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2014	1	9	1	[0]	2019-07-03 03:00:00	\N	\N	80cc8cea-18cd-4e21-ac60-7ee1a37ef090	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2015	1	8	1	[0]	2019-07-03 03:00:00	\N	\N	df028ede-27d8-431c-92bf-6334d1d3c93b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2016	1	12	1	[0]	2019-07-03 04:00:00	\N	\N	c85c96eb-2d41-41a8-9821-c7612cc9444c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2017	1	11	1	[0]	2019-07-03 04:00:00	\N	\N	22fc1a45-933c-4d71-9c63-40b6fca88de5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2018	1	10	1	[0]	2019-07-03 04:00:00	\N	\N	54153017-672d-4ae8-9bcc-ba666f20375f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2019	1	9	1	[0]	2019-07-03 04:00:00	\N	\N	f393f86c-c9ec-499d-810e-32a2aed2cf95	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2020	1	8	1	[0]	2019-07-03 04:00:00	\N	\N	bc6eaa03-5009-4616-9a1f-b252505cb2e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2021	1	12	1	[0]	2019-07-03 05:00:00	\N	\N	d03b1c9d-cd72-41c3-a2cb-762d13562b70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2022	1	11	1	[0]	2019-07-03 05:00:00	\N	\N	e99ab6a3-1bef-4685-b066-6efeae3e05a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2023	1	10	1	[0]	2019-07-03 05:00:00	\N	\N	03365781-2ec4-4b76-ab9d-8bb1f6ec3816	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2024	1	9	1	[0]	2019-07-03 05:00:00	\N	\N	2b707157-2754-43e5-8da5-2d571f8f8b18	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2025	1	8	1	[0]	2019-07-03 05:00:00	\N	\N	f29aa75e-92b9-47d2-b8a3-70e50d29a3b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2026	1	12	1	[0]	2019-07-03 06:00:00	\N	\N	c22cfeb6-aa99-40b1-bcdd-c8578b1563c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2027	1	11	1	[0]	2019-07-03 06:00:00	\N	\N	d53637f1-14f5-4317-adc3-c789370c70a1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2028	1	10	1	[0]	2019-07-03 06:00:00	\N	\N	8eecec60-62c9-4d50-a2e6-e9f9eeaf425d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2029	1	9	1	[0]	2019-07-03 06:00:00	\N	\N	d1fe785d-91b5-4a86-bb82-5d67078317d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2030	1	8	1	[0]	2019-07-03 06:00:00	\N	\N	f38fdd89-3276-45d7-9902-28f0944180bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2031	1	12	1	[0]	2019-07-03 07:00:00	\N	\N	5e6e98b1-6a25-44e5-a8c4-564dd56efb86	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2032	1	11	1	[0]	2019-07-03 07:00:00	\N	\N	088e6881-b82a-4889-abb2-16c89bca5464	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2033	1	10	1	[0]	2019-07-03 07:00:00	\N	\N	e6cd175d-6225-417f-a639-a91f2045380d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2034	1	9	1	[0]	2019-07-03 07:00:00	\N	\N	1c9e9529-451a-444a-b6b0-35daab10009c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2035	1	8	1	[0]	2019-07-03 07:00:00	\N	\N	1b0bdc42-f383-4a6f-bb21-6d7aa510916b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2036	1	12	1	[0]	2019-07-03 08:00:00	\N	\N	17a01d5b-786c-45d5-aa9b-e93f7931fbde	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2037	1	11	1	[0]	2019-07-03 08:00:00	\N	\N	232eb353-7116-48c2-bf85-9c2f04d01de0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2038	1	10	1	[0]	2019-07-03 08:00:00	\N	\N	f80a687f-8b32-4046-b7e5-e79e122077d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2039	1	9	1	[0]	2019-07-03 08:00:00	\N	\N	c555b744-36ad-421a-afb3-c4e2b09175e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2040	1	8	1	[0]	2019-07-03 08:00:00	\N	\N	67573a6e-ac1b-4c97-83ef-58583ad1a66a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2041	1	12	1	[0]	2019-07-03 09:00:00	\N	\N	4c000699-02f4-4df4-9e51-35c0ac8e6b13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2042	1	11	1	[0]	2019-07-03 09:00:00	\N	\N	15c721aa-503f-4bcc-b363-74c271c85cc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2043	1	10	1	[0]	2019-07-03 09:00:00	\N	\N	a3390eaf-8def-493c-9623-b1b0aa4e28c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2044	1	9	1	[0]	2019-07-03 09:00:00	\N	\N	eaf2fa23-64da-472f-93c0-b61c36d72014	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2045	1	8	1	[0]	2019-07-03 09:00:00	\N	\N	3c8a61aa-6664-4f6b-81de-ae5cf704d70e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2046	1	12	1	[0]	2019-07-03 10:00:00	\N	\N	471892a0-7483-4b44-85de-6a3cceea9022	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2047	1	11	1	[0]	2019-07-03 10:00:00	\N	\N	6a095d40-7bef-4af4-96f9-e9ea86a151cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2048	1	10	1	[0]	2019-07-03 10:00:00	\N	\N	0e40f794-603d-4f9d-a798-be955f283591	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2049	1	9	1	[0]	2019-07-03 10:00:00	\N	\N	53e11b77-84e6-4e9b-b9d9-689d016840c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2050	1	8	1	[0]	2019-07-03 10:00:00	\N	\N	41284fb4-a82c-4598-a2fc-b1fa31586324	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2051	1	12	1	[0]	2019-07-03 11:00:00	\N	\N	086f3849-c5a3-4255-b742-07b17537ef25	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2052	1	11	1	[0]	2019-07-03 11:00:00	\N	\N	a4f4f578-a48f-473a-8cec-5471b2445057	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2053	1	10	1	[0]	2019-07-03 11:00:00	\N	\N	8d413b85-4bc9-4e83-9b07-8e4047c64e13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2054	1	9	1	[0]	2019-07-03 11:00:00	\N	\N	647b2d93-8088-41f1-b946-4b737107ff91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2055	1	8	1	[0]	2019-07-03 11:00:00	\N	\N	5283f413-5352-4e26-8bf3-39ce827b5809	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2056	1	12	1	[0]	2019-07-03 12:00:00	\N	\N	8ea6aafd-fef6-42b1-a477-40dcbe399f7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2057	1	11	1	[0]	2019-07-03 12:00:00	\N	\N	06e6808e-1c4d-4306-9c73-0a1becea84d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2058	1	10	1	[0]	2019-07-03 12:00:00	\N	\N	52254f75-8add-472c-80f3-c7efde36c298	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2059	1	9	1	[0]	2019-07-03 12:00:00	\N	\N	757cd249-f6bb-4fd6-a802-29c08062089b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2060	1	8	1	[0]	2019-07-03 12:00:00	\N	\N	90bc7f2e-8958-484e-85a2-af99a2887c45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2061	1	12	1	[0]	2019-07-03 13:00:00	\N	\N	d53c6c3f-4df5-4c0a-93d4-430070dbbf35	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2062	1	11	1	[0]	2019-07-03 13:00:00	\N	\N	92872827-c2db-45bb-9702-f7286c511787	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2063	1	10	1	[0]	2019-07-03 13:00:00	\N	\N	ed1aa774-1a96-4449-9474-abdb9b4927b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2064	1	9	1	[0]	2019-07-03 13:00:00	\N	\N	2a3d59fa-bb13-48f6-b555-cc73cec7c97e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2065	1	8	1	[0]	2019-07-03 13:00:00	\N	\N	3ed5fc0a-bac1-4755-965d-0097902015bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2066	1	12	1	[0]	2019-07-03 14:00:00	\N	\N	24bde7e7-b56c-4ae0-8190-fa7bf8365adb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2067	1	11	1	[0]	2019-07-03 14:00:00	\N	\N	24ba7780-ea24-440f-bbf2-37d5f96809f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2068	1	10	1	[0]	2019-07-03 14:00:00	\N	\N	e2db98da-bffb-4aea-b009-36a1ef8ee4e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2069	1	9	1	[0]	2019-07-03 14:00:00	\N	\N	fd0daed6-4478-4b49-abbe-150468b64eab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2070	1	8	1	[0]	2019-07-03 14:00:00	\N	\N	bef447d4-6f30-44b8-b3ff-b68ebf496de7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2071	1	12	1	[0]	2019-07-03 15:00:00	\N	\N	626af13c-a6e7-4c72-9166-2a468abd8a3b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2072	1	11	1	[0]	2019-07-03 15:00:00	\N	\N	fe445b4b-9a0c-494e-8bbc-0a744bf5d85d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2073	1	10	1	[0]	2019-07-03 15:00:00	\N	\N	0dec948a-f77e-47a5-af25-c0e4d66c09d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2074	1	9	1	[0]	2019-07-03 15:00:00	\N	\N	fea2a9a2-8fe7-4551-a545-8401dc47ac90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2075	1	8	1	[0]	2019-07-03 15:00:00	\N	\N	e242ae03-22d8-4881-aa29-e38798ecf94d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2076	1	12	1	[0]	2019-07-03 16:00:00	\N	\N	4a3d21ac-55dc-4507-ba2f-6993917d30b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2077	1	11	1	[0]	2019-07-03 16:00:00	\N	\N	34a7fbc2-9ca1-4727-9101-754dc4ca7716	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2078	1	10	1	[0]	2019-07-03 16:00:00	\N	\N	504fff23-3023-4170-a0b6-b7eed8b66a54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2079	1	9	1	[0]	2019-07-03 16:00:00	\N	\N	9851fc20-f839-4da6-ac4a-5ad598cf8d3e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2080	1	8	1	[0]	2019-07-03 16:00:00	\N	\N	8b8b49b5-5d8a-4329-9ca6-4ebfe5be20ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2081	1	12	1	[0]	2019-07-03 17:00:00	\N	\N	dc1778a9-1d76-447d-b3ac-5bc29a9911d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2082	1	11	1	[0]	2019-07-03 17:00:00	\N	\N	63b4a916-ca3f-4419-9f58-b9b3922fb86c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2083	1	10	1	[0]	2019-07-03 17:00:00	\N	\N	08b11dab-8a5a-4728-9bae-465b19e5a76e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2084	1	9	1	[0]	2019-07-03 17:00:00	\N	\N	a5f70cb9-5171-4386-9505-cb07c2543f8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2085	1	8	1	[0]	2019-07-03 17:00:00	\N	\N	26e2764c-f448-4e4f-abb5-196b6c94633d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2086	1	12	1	[0]	2019-07-03 18:00:00	\N	\N	70b6f5dc-a666-44f1-9d3a-980f4c6424d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2087	1	11	1	[0]	2019-07-03 18:00:00	\N	\N	95e60d07-2f86-4d0c-a292-e2fa7971fd0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2088	1	10	1	[0]	2019-07-03 18:00:00	\N	\N	bdd2f657-c18c-4dbb-8847-6aafd1df2638	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2089	1	9	1	[0]	2019-07-03 18:00:00	\N	\N	623c71f4-9b6c-4520-993e-246da400453d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2090	1	8	1	[0]	2019-07-03 18:00:00	\N	\N	5b781d43-5e0b-43cb-b74a-7e50daa95d22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2091	1	12	1	[0]	2019-07-03 19:00:00	\N	\N	935dda8c-e225-4dee-af12-d9a33ad75587	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2092	1	11	1	[0]	2019-07-03 19:00:00	\N	\N	cfc2f8da-9709-4f99-80fe-a06aee3a6704	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2093	1	10	1	[0]	2019-07-03 19:00:00	\N	\N	16e350bc-7426-42d8-ac35-7f54c9300163	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2094	1	9	1	[0]	2019-07-03 19:00:00	\N	\N	c422ee8c-85f3-4fa6-aff2-fc0291fd17fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2095	1	8	1	[0]	2019-07-03 19:00:00	\N	\N	dd99d4e0-cc74-4734-8666-1d4860d5f43f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2096	1	12	1	[0]	2019-07-03 20:00:00	\N	\N	b7535089-38ca-4d7c-badd-377d2accb6cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2097	1	11	1	[0]	2019-07-03 20:00:00	\N	\N	150d5c53-b892-4404-92a0-a05b98c4a824	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2098	1	10	1	[0]	2019-07-03 20:00:00	\N	\N	bad999ea-3bba-42f3-9d65-b5524f4fc781	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2099	1	9	1	[0]	2019-07-03 20:00:00	\N	\N	f8f8a81d-a07f-48e3-a67a-41182f912b87	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2100	1	8	1	[0]	2019-07-03 20:00:00	\N	\N	2d6e1590-607b-4986-a00f-603f19802ca9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2101	1	12	1	[0]	2019-07-03 21:00:00	\N	\N	a14adda8-5a71-4d9c-afab-25232abe5835	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2102	1	11	1	[0]	2019-07-03 21:00:00	\N	\N	7d757ebf-a213-41f7-b27e-8c9b87b465e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2103	1	10	1	[0]	2019-07-03 21:00:00	\N	\N	cdd9b3a7-9e91-471a-80a8-fe8b385b9575	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2104	1	9	1	[0]	2019-07-03 21:00:00	\N	\N	8554ad9e-d208-4c42-88d1-eb5486cdadd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2105	1	8	1	[0]	2019-07-03 21:00:00	\N	\N	20a89265-f935-4aeb-806f-858046874058	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2106	1	12	1	[0]	2019-07-03 22:00:00	\N	\N	e24477f8-2c31-45c7-a990-f461c2a9d15c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2107	1	11	1	[0]	2019-07-03 22:00:00	\N	\N	2525ccd0-5160-4bdc-9756-8ecdadc439b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2108	1	10	1	[0]	2019-07-03 22:00:00	\N	\N	33f089aa-e91d-43fb-9db4-26c1c330f283	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2109	1	9	1	[0]	2019-07-03 22:00:00	\N	\N	0bbbea88-6c2d-4d9f-ba84-2b5d8f12a13b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2110	1	8	1	[0]	2019-07-03 22:00:00	\N	\N	405b92a5-c414-4dd4-81b1-5f7fcdfa2267	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2111	1	12	1	[0]	2019-07-03 23:00:00	\N	\N	2a6aa9cc-a2d1-45bf-b743-7301ca1b20e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2112	1	11	1	[0]	2019-07-03 23:00:00	\N	\N	ccfad613-039f-4bcd-8bc3-678112b51d5c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2113	1	10	1	[0]	2019-07-03 23:00:00	\N	\N	02b330c3-ebf2-4507-8576-36c7bacb0b94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2114	1	9	1	[0]	2019-07-03 23:00:00	\N	\N	9f810e69-0c02-4035-8f62-50cf11955d91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2115	1	8	1	[0]	2019-07-03 23:00:00	\N	\N	60715997-3a14-4a9d-a7f5-2fd7095f9776	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2116	1	12	1	[0]	2019-07-04 00:00:00	\N	\N	492cb10c-c459-4ee9-8156-22d983db316f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2117	1	11	1	[0]	2019-07-04 00:00:00	\N	\N	70d83f34-40dd-4bbe-8d90-5163c3dcb2ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2118	1	10	1	[0]	2019-07-04 00:00:00	\N	\N	b630f08c-e888-4b5e-abc7-164a5d2810d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2119	1	9	1	[0]	2019-07-04 00:00:00	\N	\N	f5dba324-2856-4088-ae71-0ff51fb05b52	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2120	1	8	1	[0]	2019-07-04 00:00:00	\N	\N	558a3d0c-fc12-41ab-b637-dd94e74292fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2121	1	12	1	[0]	2019-07-04 01:00:00	\N	\N	92d081fd-9ec8-4d34-913f-358a5072ed72	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2122	1	11	1	[0]	2019-07-04 01:00:00	\N	\N	2f176772-f55b-4a71-b755-677c0a2969f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2123	1	10	1	[0]	2019-07-04 01:00:00	\N	\N	c02c45ec-78ff-4cb2-9b6d-6a74b3e91abf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2124	1	9	1	[0]	2019-07-04 01:00:00	\N	\N	c770971f-7738-431a-8298-286e7f1461df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2125	1	8	1	[0]	2019-07-04 01:00:00	\N	\N	29f38b43-9484-4a19-babb-5151110c3fef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2126	1	12	1	[0]	2019-07-04 02:00:00	\N	\N	015d7166-ac7e-4a36-b137-2cfac7611cd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2127	1	11	1	[0]	2019-07-04 02:00:00	\N	\N	e3663abf-087c-4c0f-a02a-2703170a3f0a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2128	1	10	1	[0]	2019-07-04 02:00:00	\N	\N	fd6c0cc9-0c8f-4845-8269-b2ccba264b50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2129	1	9	1	[0]	2019-07-04 02:00:00	\N	\N	347bd81c-36f5-40ee-8d26-0c86193923fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2130	1	8	1	[0]	2019-07-04 02:00:00	\N	\N	35904568-0e00-458e-9653-2f27e31dd67c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2131	1	12	1	[0]	2019-07-04 03:00:00	\N	\N	89d0ab6f-89df-4138-80d9-13168c9f5eec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2132	1	11	1	[0]	2019-07-04 03:00:00	\N	\N	46784e9d-4d9a-4bd8-b40b-5d5a17408670	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2133	1	10	1	[0]	2019-07-04 03:00:00	\N	\N	7d500d25-e468-4361-b23a-1b2a4342a657	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2134	1	9	1	[0]	2019-07-04 03:00:00	\N	\N	31a54aa9-afb4-4dfe-8283-032f74a8e17b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2135	1	8	1	[0]	2019-07-04 03:00:00	\N	\N	1aeecf3d-b37b-4b7a-ae18-c3cd31af6dd1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2136	1	12	1	[0]	2019-07-04 04:00:00	\N	\N	b15e94cb-c707-46d0-8c68-c813207e5f99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2137	1	11	1	[0]	2019-07-04 04:00:00	\N	\N	228b42e1-13f3-4301-9a51-4573ca3398d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2138	1	10	1	[0]	2019-07-04 04:00:00	\N	\N	55f5183b-e479-485e-9203-c3b9acf67cae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2139	1	9	1	[0]	2019-07-04 04:00:00	\N	\N	4f8ec424-c7d4-432a-9503-67b22db6ecc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2140	1	8	1	[0]	2019-07-04 04:00:00	\N	\N	286c8739-9d6d-495a-b5aa-4e2cff51bf45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2141	1	12	1	[0]	2019-07-04 05:00:00	\N	\N	68b91705-680a-4306-a5f8-c3e7164444ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2142	1	11	1	[0]	2019-07-04 05:00:00	\N	\N	e068f84e-da32-4a63-9ae8-7f4d5cbd7820	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2143	1	10	1	[0]	2019-07-04 05:00:00	\N	\N	9c7377e4-7977-4fc1-af67-e2af32053649	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2144	1	9	1	[0]	2019-07-04 05:00:00	\N	\N	7f317c0e-3184-40dd-9e00-d7adbeafc80b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2145	1	8	1	[0]	2019-07-04 05:00:00	\N	\N	562e38aa-959c-423a-bc90-0b11ff40ab8c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2146	1	12	1	[0]	2019-07-04 06:00:00	\N	\N	8e1fb7c0-a7e4-44e5-804d-8972e8c560a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2147	1	11	1	[0]	2019-07-04 06:00:00	\N	\N	079d5b38-a10b-49f7-b481-6a7e5647c4e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2148	1	10	1	[0]	2019-07-04 06:00:00	\N	\N	ed65043c-7ed2-4c16-a8b4-d1b1b16d62cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2149	1	9	1	[0]	2019-07-04 06:00:00	\N	\N	51c3a5b8-07de-4feb-8a76-c38672811af8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2150	1	8	1	[0]	2019-07-04 06:00:00	\N	\N	417e0a1e-c901-400a-b556-66ed16cb75cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2151	1	12	1	[0]	2019-07-04 07:00:00	\N	\N	fb8344eb-14d2-45f8-be79-c9077035a9b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2152	1	11	1	[0]	2019-07-04 07:00:00	\N	\N	1a94fbcf-3f9e-4e53-bc41-1b9124ab126b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2153	1	10	1	[0]	2019-07-04 07:00:00	\N	\N	3b5805aa-93e9-49bc-8db3-5b5e90f40052	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2154	1	9	1	[0]	2019-07-04 07:00:00	\N	\N	3fe657d5-db86-47aa-9412-61be757dae2e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2155	1	8	1	[0]	2019-07-04 07:00:00	\N	\N	575b3fea-254c-4e59-ac05-287b17ba1c4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2156	1	12	1	[0]	2019-07-04 08:00:00	\N	\N	cd99cbcd-eb0f-42c6-bd83-37a6a9870ed7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2157	1	11	1	[0]	2019-07-04 08:00:00	\N	\N	9a3e2fb4-2995-4152-8e1b-4b4310926f91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2158	1	10	1	[0]	2019-07-04 08:00:00	\N	\N	1b8819ed-39af-4a5b-b422-75e95a0cb4e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2159	1	9	1	[0]	2019-07-04 08:00:00	\N	\N	c4ec8a46-1585-429d-ae42-7710641b7519	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2160	1	8	1	[0]	2019-07-04 08:00:00	\N	\N	e50442c6-12db-4f19-a4da-e603d9ecf26c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2161	1	12	1	[0]	2019-07-04 09:00:00	\N	\N	2790d1ef-4826-47ed-a3c7-36d9b0f645eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2162	1	11	1	[0]	2019-07-04 09:00:00	\N	\N	38750c88-5b20-4dfa-9634-5373773ed88d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2163	1	10	1	[0]	2019-07-04 09:00:00	\N	\N	4f8c93b1-02ee-43fb-b268-b392504d00e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2164	1	9	1	[0]	2019-07-04 09:00:00	\N	\N	af1197e9-30fd-43dc-8eb1-490b7f1758d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2165	1	8	1	[0]	2019-07-04 09:00:00	\N	\N	62ff049f-beb4-46b6-a0eb-a10076c844b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2166	1	12	1	[0]	2019-07-04 10:00:00	\N	\N	0acf41be-2b26-4670-b525-912eaa69b20a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2167	1	11	1	[0]	2019-07-04 10:00:00	\N	\N	daefdb8a-95ba-4a91-9acf-566fc0db2379	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2168	1	10	1	[0]	2019-07-04 10:00:00	\N	\N	db2580f8-9476-435f-8e5c-6edb70d7e54f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2169	1	9	1	[0]	2019-07-04 10:00:00	\N	\N	f735bdcb-1e3c-4b3f-b593-5b81c5069158	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2170	1	8	1	[0]	2019-07-04 10:00:00	\N	\N	6bed1604-b51e-41d3-874f-eaa32e9e8af2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2171	1	12	1	[0]	2019-07-04 11:00:00	\N	\N	26627631-5c28-4e03-9591-9ea18b8d3997	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2172	1	11	1	[0]	2019-07-04 11:00:00	\N	\N	3f2b6b85-a89f-47b0-bd4c-eac4125abecd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2173	1	10	1	[0]	2019-07-04 11:00:00	\N	\N	ef4d859b-8748-4a2e-90f5-280eb0fb25c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2174	1	9	1	[0]	2019-07-04 11:00:00	\N	\N	e476f791-bfb3-4ed9-a04a-75a3ce287e65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2175	1	8	1	[0]	2019-07-04 11:00:00	\N	\N	6bccdcf0-5425-4a19-b148-9dffcc9b550c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2176	1	12	1	[0]	2019-07-04 12:00:00	\N	\N	1606296d-3b3e-4940-820b-1db8e288b8cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2177	1	11	1	[0]	2019-07-04 12:00:00	\N	\N	cb2b7723-8462-4c85-9056-fc9d85ce9882	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2178	1	10	1	[0]	2019-07-04 12:00:00	\N	\N	0599e46d-4cc7-415d-b28e-21ae274699b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2179	1	9	1	[0]	2019-07-04 12:00:00	\N	\N	1160fa6e-30ab-488f-8b0a-7e43d0990b79	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2180	1	8	1	[0]	2019-07-04 12:00:00	\N	\N	6ffe6bd6-8497-44af-99e8-4eb803b1858f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2181	1	12	1	[0]	2019-07-04 13:00:00	\N	\N	124eb1c7-bcf3-44c0-be9e-8819029b77ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2182	1	11	1	[0]	2019-07-04 13:00:00	\N	\N	d65f6869-1902-4293-9398-ebcc9559a341	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2183	1	10	1	[0]	2019-07-04 13:00:00	\N	\N	0ade5a39-ec48-4d0c-ae50-b73838229485	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2184	1	9	1	[0]	2019-07-04 13:00:00	\N	\N	34a1ab9d-8e2e-4988-92ee-2810d07f9316	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2185	1	8	1	[0]	2019-07-04 13:00:00	\N	\N	4eb22bc0-200b-4970-9498-f50a2e00c0b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2186	1	12	1	[0]	2019-07-04 14:00:00	\N	\N	8ae366f3-c439-4b11-8598-3d479d5432ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2187	1	11	1	[0]	2019-07-04 14:00:00	\N	\N	e58358c0-c9e6-4286-9a18-f0e3869546b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2188	1	10	1	[0]	2019-07-04 14:00:00	\N	\N	ecd464b6-e8a9-403c-a0da-9eb3d2e0be3d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2189	1	9	1	[0]	2019-07-04 14:00:00	\N	\N	08cc18e6-6936-423f-b51c-7082f87f9e30	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2190	1	8	1	[0]	2019-07-04 14:00:00	\N	\N	2d03ab98-9632-422c-b3bb-c971afa80b22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2191	1	12	1	[0]	2019-07-04 15:00:00	\N	\N	fc7c922f-9dd4-4bae-822e-b7b7cb11c546	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2192	1	11	1	[0]	2019-07-04 15:00:00	\N	\N	ec1ccf04-b6c0-407a-aab2-1cef088a1f1a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2193	1	10	1	[0]	2019-07-04 15:00:00	\N	\N	2c45fe7f-2e4d-4ab6-8a34-375817c2fa3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2194	1	9	1	[0]	2019-07-04 15:00:00	\N	\N	332aebd9-515c-4ae5-a8b7-25fbcc99f34d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2195	1	8	1	[0]	2019-07-04 15:00:00	\N	\N	c3870cd7-5f94-4729-ba42-c270514ee0c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2196	1	12	1	[0]	2019-07-04 16:00:00	\N	\N	7d35eee0-5c8a-4b61-81ae-6adfbecd281a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2197	1	11	1	[0]	2019-07-04 16:00:00	\N	\N	7bb65be8-dbfa-4440-9235-71bb86968801	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2198	1	10	1	[0]	2019-07-04 16:00:00	\N	\N	64304a91-6282-444e-aa1f-d591b5d74710	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2199	1	9	1	[0]	2019-07-04 16:00:00	\N	\N	8f7478b5-c491-4193-8386-0d59e5ae2db3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2200	1	8	1	[0]	2019-07-04 16:00:00	\N	\N	de07e0c0-3961-4042-9b1e-b7f35b2f282e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2201	1	12	1	[0]	2019-07-04 17:00:00	\N	\N	d3e60901-c88f-4ca4-8126-6b025b41f84b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2202	1	11	1	[0]	2019-07-04 17:00:00	\N	\N	774e56f8-199e-4ed6-ae2a-e8a9d085d26b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2203	1	10	1	[0]	2019-07-04 17:00:00	\N	\N	09a0287b-8a4f-4ea0-bb13-ee11c60575b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2204	1	9	1	[0]	2019-07-04 17:00:00	\N	\N	20b4fda7-da61-403e-b78f-366b04002c74	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2205	1	8	1	[0]	2019-07-04 17:00:00	\N	\N	b6eeca64-69d6-49a7-ab29-1c63c2f79855	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2206	1	12	1	[0]	2019-07-04 18:00:00	\N	\N	ec6da39e-fa03-4064-a3f6-57464d191b9e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2207	1	11	1	[0]	2019-07-04 18:00:00	\N	\N	e2b5f543-2103-430e-b9de-fa2f46fc49e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2208	1	10	1	[0]	2019-07-04 18:00:00	\N	\N	439c07cf-8ed5-4d93-a2b6-4268edff202e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2209	1	9	1	[0]	2019-07-04 18:00:00	\N	\N	05c34cbb-ce3e-43c9-b16e-2642cf302ade	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2210	1	8	1	[0]	2019-07-04 18:00:00	\N	\N	1b6696ac-acdf-4320-a82f-dc7ef6a27325	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2211	1	12	1	[0]	2019-07-04 19:00:00	\N	\N	968be12f-091d-4881-9716-2311c3cb25c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2212	1	11	1	[0]	2019-07-04 19:00:00	\N	\N	9375f697-4343-426a-af3c-a20d27a2879f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2213	1	10	1	[0]	2019-07-04 19:00:00	\N	\N	443af369-5687-4472-b71f-29bfc2b5b6b8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2214	1	9	1	[0]	2019-07-04 19:00:00	\N	\N	41ae75fa-d69d-4f00-99f2-80abf9f73a6f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2215	1	8	1	[0]	2019-07-04 19:00:00	\N	\N	934ee5b3-66c4-43bf-bfc4-303a65c9e5d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2216	1	12	1	[0]	2019-07-04 20:00:00	\N	\N	b4cfb212-3931-43e8-9fef-8404a2a6382a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2217	1	11	1	[0]	2019-07-04 20:00:00	\N	\N	23e13ff3-a191-4e19-baed-c52e04769643	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2218	1	10	1	[0]	2019-07-04 20:00:00	\N	\N	d7f660d5-7594-44c1-afd1-7a3166087914	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2219	1	9	1	[0]	2019-07-04 20:00:00	\N	\N	7b4dcc09-4028-48c7-bed7-889b2a141df2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2220	1	8	1	[0]	2019-07-04 20:00:00	\N	\N	6de23528-21ea-40cd-8182-79c8612d4dba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2221	1	12	1	[0]	2019-07-04 21:00:00	\N	\N	8e7e1055-2c4f-4762-885b-9da90fe186a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2222	1	11	1	[0]	2019-07-04 21:00:00	\N	\N	cae161d2-2a8b-44d6-906f-c879899766a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2223	1	10	1	[0]	2019-07-04 21:00:00	\N	\N	666367b0-24bd-4b8b-a917-4784e0439bf4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2224	1	9	1	[0]	2019-07-04 21:00:00	\N	\N	c3dfd085-8745-4b73-9342-7dc31290636a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2225	1	8	1	[0]	2019-07-04 21:00:00	\N	\N	fd661865-2d8e-4ca9-8acb-0809b1a4831a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2226	1	12	1	[0]	2019-07-04 22:00:00	\N	\N	70d4d52c-9a6b-4661-bb21-d267d204e313	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2227	1	11	1	[0]	2019-07-04 22:00:00	\N	\N	e6d3faa5-3402-4c3d-b13e-08d1bf6a289d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2228	1	10	1	[0]	2019-07-04 22:00:00	\N	\N	10ff6217-8c5d-47ed-8ce9-3fdc811f8498	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2229	1	9	1	[0]	2019-07-04 22:00:00	\N	\N	508e92ba-8e49-40c2-897d-f7dfb1225e8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2230	1	8	1	[0]	2019-07-04 22:00:00	\N	\N	c7f285c4-2c3f-4eff-b564-3fa413f625c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2231	1	12	1	[0]	2019-07-04 23:00:00	\N	\N	54dc53f3-a2ad-42ef-865f-f013df179c28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2232	1	11	1	[0]	2019-07-04 23:00:00	\N	\N	0f0959e7-1693-4479-95ad-bf7da961488f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2233	1	10	1	[0]	2019-07-04 23:00:00	\N	\N	504e2306-01c7-47a7-9938-f724717d8b4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2234	1	9	1	[0]	2019-07-04 23:00:00	\N	\N	58b3d1e9-9e44-4c5e-b084-0d4f49867629	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2235	1	8	1	[0]	2019-07-04 23:00:00	\N	\N	afb66cd0-34ef-413d-b5f3-4d9a1bfd3197	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2236	1	12	1	[0]	2019-07-05 00:00:00	\N	\N	44764223-4ba2-4ea7-9956-70dfb9cd65ce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2237	1	11	1	[0]	2019-07-05 00:00:00	\N	\N	1fa9e4bb-ba75-44dc-be4e-bf127bac14c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2238	1	10	1	[0]	2019-07-05 00:00:00	\N	\N	8dfe676e-c870-4dcf-af4a-7c791f5b1502	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2239	1	9	1	[0]	2019-07-05 00:00:00	\N	\N	45a09479-547a-4bee-bee6-16af1303edaf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2240	1	8	1	[0]	2019-07-05 00:00:00	\N	\N	297fe7d0-f723-4cf5-a6e2-145db6ba86c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2241	1	12	1	[0]	2019-07-05 01:00:00	\N	\N	5a811649-4a6d-4d9e-945b-ea1b7b474836	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2242	1	11	1	[0]	2019-07-05 01:00:00	\N	\N	d2eb0cc2-2421-426b-8cde-2f392e402a34	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2243	1	10	1	[0]	2019-07-05 01:00:00	\N	\N	36a5723b-f6fb-475e-9de5-6f29335c3eb5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2244	1	9	1	[0]	2019-07-05 01:00:00	\N	\N	4871bb3a-e3c8-4b72-9b78-c98196186d7d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2245	1	8	1	[0]	2019-07-05 01:00:00	\N	\N	67e71bc8-d9d9-4f14-9447-a152756d28c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2246	1	12	1	[0]	2019-07-05 02:00:00	\N	\N	66f03e01-3f8c-4a11-9589-81561f9b9136	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2247	1	11	1	[0]	2019-07-05 02:00:00	\N	\N	def8fa4f-18fd-4b6b-bfc9-d0ec137ff8a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2248	1	10	1	[0]	2019-07-05 02:00:00	\N	\N	2226edf7-d587-4757-be95-4854865b7a6a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2249	1	9	1	[0]	2019-07-05 02:00:00	\N	\N	484efb5b-007a-4162-b636-dea84d0633d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2250	1	8	1	[0]	2019-07-05 02:00:00	\N	\N	17fe8e6f-e83c-44bf-a234-220e146b6b61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2251	1	12	1	[0]	2019-07-05 03:00:00	\N	\N	520db435-2602-4ea7-ba94-c8b3a4670e5c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2252	1	11	1	[0]	2019-07-05 03:00:00	\N	\N	214b943c-070c-40a1-a0ab-fa2b03b1283a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2253	1	10	1	[0]	2019-07-05 03:00:00	\N	\N	0797b2ad-8e96-4575-85ad-5b37e3ef4bac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2254	1	9	1	[0]	2019-07-05 03:00:00	\N	\N	d831de8c-699c-4b6a-8665-c648314abcef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2255	1	8	1	[0]	2019-07-05 03:00:00	\N	\N	9cd81dfc-5e16-4f9b-ad2d-5eaa50939a80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2256	1	12	1	[0]	2019-07-05 04:00:00	\N	\N	0e833d0b-b2ab-4729-90e4-22182a0509cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2257	1	11	1	[0]	2019-07-05 04:00:00	\N	\N	c90c378e-4ab6-422f-98d5-e1864c2da071	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2258	1	10	1	[0]	2019-07-05 04:00:00	\N	\N	414602ca-ded0-4e01-9baa-f1d55d3ac9e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2259	1	9	1	[0]	2019-07-05 04:00:00	\N	\N	057e7764-20a2-4bc4-ac95-97d60e83a00c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2260	1	8	1	[0]	2019-07-05 04:00:00	\N	\N	ba05348f-c7d8-4b3d-8349-4884cd49d08a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2261	1	12	1	[0]	2019-07-05 05:00:00	\N	\N	e26283db-03d4-41dd-b292-f015330a801b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2262	1	11	1	[0]	2019-07-05 05:00:00	\N	\N	725579eb-943c-4e1d-8241-7f605acf228e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2263	1	10	1	[0]	2019-07-05 05:00:00	\N	\N	45b623cb-1e82-4cff-8897-240218004eee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2264	1	9	1	[0]	2019-07-05 05:00:00	\N	\N	16f40596-6f9d-4eef-938f-6626f70a1020	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2265	1	8	1	[0]	2019-07-05 05:00:00	\N	\N	68cbf895-d29c-4285-b2ab-cb9db7687ace	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2266	1	12	1	[0]	2019-07-05 06:00:00	\N	\N	2edf071f-e49e-4c18-b611-542298c344bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2267	1	11	1	[0]	2019-07-05 06:00:00	\N	\N	e8a73559-d776-4017-bbbe-285a761edc09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2268	1	10	1	[0]	2019-07-05 06:00:00	\N	\N	87cbae58-5bc6-4b05-9902-8f2e08bd035a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2269	1	9	1	[0]	2019-07-05 06:00:00	\N	\N	aab26d4b-fd59-4a73-91ef-bef3c566c745	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2270	1	8	1	[0]	2019-07-05 06:00:00	\N	\N	501f21ab-ef4b-4e14-9ec1-2d1e13ef9569	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2271	1	12	1	[0]	2019-07-05 07:00:00	\N	\N	5a89517f-acf6-47a6-b50f-be5826fe3f6f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2272	1	11	1	[0]	2019-07-05 07:00:00	\N	\N	c4e033b4-a9ae-4a61-be5b-33dd345cce8c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2273	1	10	1	[0]	2019-07-05 07:00:00	\N	\N	b343702f-268e-4a28-8166-134505b72789	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2274	1	9	1	[0]	2019-07-05 07:00:00	\N	\N	554f6a0b-ffe4-4fbd-9aaf-1ff7eda39450	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2275	1	8	1	[0]	2019-07-05 07:00:00	\N	\N	8add0364-134c-4c7a-aa9d-6334247ba78d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2276	1	12	1	[0]	2019-07-05 08:00:00	\N	\N	df1df168-8120-4e1b-9bd7-28c63402b5d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2277	1	11	1	[0]	2019-07-05 08:00:00	\N	\N	b71fb9bd-7961-4d18-96bc-2a1a35425bd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2278	1	10	1	[0]	2019-07-05 08:00:00	\N	\N	e52abbb3-5da6-42fe-92af-2326297a8160	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2279	1	9	1	[0]	2019-07-05 08:00:00	\N	\N	720f95d9-bbd5-4e3d-b9c2-b5135c85d754	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2280	1	8	1	[0]	2019-07-05 08:00:00	\N	\N	6e38a2d7-76ff-4df8-88ff-eaf823ad06bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2281	1	12	1	[0]	2019-07-05 09:00:00	\N	\N	e41969f3-3ece-4b65-b216-8479a78b213a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2282	1	11	1	[0]	2019-07-05 09:00:00	\N	\N	8798c57b-730f-42a4-b344-fd854cf63620	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2283	1	10	1	[0]	2019-07-05 09:00:00	\N	\N	06d15c67-b4c0-4bbf-8793-b919cb981dda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2284	1	9	1	[0]	2019-07-05 09:00:00	\N	\N	2b59cb5a-95e5-4a98-a6a5-1335e0511442	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2285	1	8	1	[0]	2019-07-05 09:00:00	\N	\N	3e1d9099-7d0c-40fb-9e84-eef76ce6fbb9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2286	1	12	1	[0]	2019-07-05 10:00:00	\N	\N	ae976b0f-8177-4458-8828-39957c46ee9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2287	1	11	1	[0]	2019-07-05 10:00:00	\N	\N	9bfe37a0-51cc-4bb0-bf79-674b4e4f02cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2288	1	10	1	[0]	2019-07-05 10:00:00	\N	\N	aff966eb-164d-4971-90e1-474cb271a75a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2289	1	9	1	[0]	2019-07-05 10:00:00	\N	\N	5cbbc41e-0bdf-465a-8a9c-3c0696c7afa6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2290	1	8	1	[0]	2019-07-05 10:00:00	\N	\N	eb41d019-4820-4b21-9fe9-007c6eb9d5bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2291	1	12	1	[0]	2019-07-05 11:00:00	\N	\N	15d9be62-da42-4ad1-8879-204767ae1fa7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2292	1	11	1	[0]	2019-07-05 11:00:00	\N	\N	2a4c6d92-5e67-4389-8efb-419249647e7e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2293	1	10	1	[0]	2019-07-05 11:00:00	\N	\N	df687cb3-1039-40c3-99df-75cdb1aafe69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2294	1	9	1	[0]	2019-07-05 11:00:00	\N	\N	00d2d45d-c2ab-4ac9-be8f-b89c7c448151	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2295	1	8	1	[0]	2019-07-05 11:00:00	\N	\N	333d2b71-e9d6-44db-bcc1-6b36625c5f68	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2296	1	12	1	[0]	2019-07-05 12:00:00	\N	\N	6bef8062-1a41-4393-a132-c4428a84c9f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2297	1	11	1	[0]	2019-07-05 12:00:00	\N	\N	f70ba8f3-3dae-4a8f-a368-a2f190aa6cc0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2298	1	10	1	[0]	2019-07-05 12:00:00	\N	\N	183523e8-8538-4719-a3e2-8e84e312e21c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2299	1	9	1	[0]	2019-07-05 12:00:00	\N	\N	7446b0f0-7d74-40e0-a35d-9c0a0fa734b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2300	1	8	1	[0]	2019-07-05 12:00:00	\N	\N	c4c52715-5e92-4772-94de-5fb2caae9cc2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2301	1	12	1	[0]	2019-07-05 13:00:00	\N	\N	fbb35ebc-cb8c-4757-bdda-f3674fd8ca1a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2302	1	11	1	[0]	2019-07-05 13:00:00	\N	\N	80863593-60ff-4c6f-b873-6a3fa011203a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2303	1	10	1	[0]	2019-07-05 13:00:00	\N	\N	8c432045-fc3d-4670-b158-97fded61a0b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2304	1	9	1	[0]	2019-07-05 13:00:00	\N	\N	62c529ae-665c-4a9e-acac-ae70cf4999f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2305	1	8	1	[0]	2019-07-05 13:00:00	\N	\N	8696a80a-7526-42ec-a318-0c402a72f44a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2306	1	12	1	[0]	2019-07-05 14:00:00	\N	\N	4670ba7c-275f-43ad-91de-1ff98fa6c421	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2307	1	11	1	[0]	2019-07-05 14:00:00	\N	\N	62597e57-b9d4-4c37-ae43-c61a92cd8425	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2308	1	10	1	[0]	2019-07-05 14:00:00	\N	\N	40843364-a82f-4c58-a926-f2fd45d8d105	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2309	1	9	1	[0]	2019-07-05 14:00:00	\N	\N	f6ad7d1d-2270-4819-9b5c-c7a413252edd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2310	1	8	1	[0]	2019-07-05 14:00:00	\N	\N	6bdc5093-73c9-41cb-ad9c-258ff5f62619	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2311	1	12	1	[0]	2019-07-05 15:00:00	\N	\N	835603e9-48fb-4e4e-a74b-a8b0564d8705	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2312	1	11	1	[0]	2019-07-05 15:00:00	\N	\N	58aac128-fab7-4f88-8618-d8e93cf7dbe4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2313	1	10	1	[0]	2019-07-05 15:00:00	\N	\N	770671d9-4722-4ed8-b07d-60f8b9555a6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2314	1	9	1	[0]	2019-07-05 15:00:00	\N	\N	4b0d4980-feb7-4b8e-9a3b-366d53fc8a00	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2315	1	8	1	[0]	2019-07-05 15:00:00	\N	\N	c9c59f0c-ae2c-465c-8111-edcf8eb4391b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2316	1	12	1	[0]	2019-07-05 16:00:00	\N	\N	0a5c8a95-f0c8-4dc3-a9f2-6c3d9e464676	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2317	1	11	1	[0]	2019-07-05 16:00:00	\N	\N	fad72c1d-c8af-4a42-9be9-680f8a0dd5f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2318	1	10	1	[0]	2019-07-05 16:00:00	\N	\N	1723f8af-8fcb-48e0-91ee-0e2fae3e7382	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2319	1	9	1	[0]	2019-07-05 16:00:00	\N	\N	2b8942de-8b23-4ddd-bfe9-c1946afd979d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2320	1	8	1	[0]	2019-07-05 16:00:00	\N	\N	61d3e57c-8807-4f10-9374-5be25ff02d83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2321	1	12	1	[0]	2019-07-05 17:00:00	\N	\N	a1f1207e-7656-464c-852c-d195b56dade1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2322	1	11	1	[0]	2019-07-05 17:00:00	\N	\N	8f49df51-f4c5-4be2-9ff1-38266cdeb01b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2323	1	10	1	[0]	2019-07-05 17:00:00	\N	\N	dd2942bd-5aad-4b60-bcb8-7ea48b2a9a0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2324	1	9	1	[0]	2019-07-05 17:00:00	\N	\N	af42fa03-909e-421d-99ed-5f84fd9b7984	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2325	1	8	1	[0]	2019-07-05 17:00:00	\N	\N	7ca5570e-0840-4501-9100-e70414d42ac0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2326	1	12	1	[0]	2019-07-05 18:00:00	\N	\N	3400132a-be6d-4fb9-8332-07acfbce23f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2327	1	11	1	[0]	2019-07-05 18:00:00	\N	\N	5243b392-9bd7-4bff-9a94-10ef4fe2ff4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2328	1	10	1	[0]	2019-07-05 18:00:00	\N	\N	0236a50e-6570-40f7-9681-1f2c9e14e6d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2329	1	9	1	[0]	2019-07-05 18:00:00	\N	\N	8067e828-f51e-4503-82f2-95a27e2a0aac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2330	1	8	1	[0]	2019-07-05 18:00:00	\N	\N	97314eb1-76ba-4f04-b73d-25bf47a61fc2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2331	1	12	1	[0]	2019-07-05 19:00:00	\N	\N	61e7eb33-128d-4a3a-8795-47803d4e5fe0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2332	1	11	1	[0]	2019-07-05 19:00:00	\N	\N	1cf0e09c-1e9a-43fe-a9b2-3fbe3ef4ac1c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2333	1	10	1	[0]	2019-07-05 19:00:00	\N	\N	2631dc45-b08e-4530-ab89-4d11a100c279	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2334	1	9	1	[0]	2019-07-05 19:00:00	\N	\N	47e5525c-f53e-4332-a570-90fbb5d46592	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2335	1	8	1	[0]	2019-07-05 19:00:00	\N	\N	491ba7f9-f868-4f4f-8463-0a5045ad20b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2336	1	12	1	[0]	2019-07-05 20:00:00	\N	\N	af2fe155-eb9c-452b-92b6-60ae09e30f2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2337	1	11	1	[0]	2019-07-05 20:00:00	\N	\N	423bab61-5015-4c30-94f2-58a726b25336	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2338	1	10	1	[0]	2019-07-05 20:00:00	\N	\N	9301ae00-139c-472e-96f8-840ba9ff0903	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2339	1	9	1	[0]	2019-07-05 20:00:00	\N	\N	501650e2-5807-4bb8-b241-ef5c83d3cac7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2340	1	8	1	[0]	2019-07-05 20:00:00	\N	\N	00587226-c43b-4f3a-88bb-1fbfb6c81331	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2341	1	12	1	[0]	2019-07-05 21:00:00	\N	\N	7aa26206-793a-4bca-8cdd-c5eecef6aeb0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2342	1	11	1	[0]	2019-07-05 21:00:00	\N	\N	aeb593ae-75cf-4d62-b172-285c616ac6bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2343	1	10	1	[0]	2019-07-05 21:00:00	\N	\N	c240e3f8-0c1c-4d39-80d4-723946dbaad9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2344	1	9	1	[0]	2019-07-05 21:00:00	\N	\N	a35717da-aca9-4790-81e7-575322ce59f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2345	1	8	1	[0]	2019-07-05 21:00:00	\N	\N	a37720a0-5bb4-49ee-b3d0-3a73c8c1b769	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2346	1	12	1	[0]	2019-07-05 22:00:00	\N	\N	85b94d08-6a17-481f-8e5d-8b22dd615114	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2347	1	11	1	[0]	2019-07-05 22:00:00	\N	\N	5b87aa57-2aee-4845-b78f-d47e5513018b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2348	1	10	1	[0]	2019-07-05 22:00:00	\N	\N	8da422dd-a2ea-4c3e-bcad-d3d4069adb09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2349	1	9	1	[0]	2019-07-05 22:00:00	\N	\N	df4e9420-078c-40c0-899e-1c8b7b8c0b9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2350	1	8	1	[0]	2019-07-05 22:00:00	\N	\N	5876c68e-4db4-401e-9509-8576740b05c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2351	1	12	1	[0]	2019-07-05 23:00:00	\N	\N	f81a9aa8-a748-40b4-8bfd-da59b67608e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2352	1	11	1	[0]	2019-07-05 23:00:00	\N	\N	a041594a-d314-4dea-8117-50ed271b92fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2353	1	10	1	[0]	2019-07-05 23:00:00	\N	\N	56c5eede-5dae-4cc9-87c4-dc2bdcadf35d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2354	1	9	1	[0]	2019-07-05 23:00:00	\N	\N	6e2a90fd-1d4c-402f-9942-3bff4b5cf317	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2355	1	8	1	[0]	2019-07-05 23:00:00	\N	\N	fdbcb957-1c4b-4f9c-b8bd-2bb167a588a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2356	1	12	1	[0]	2019-07-06 00:00:00	\N	\N	6aa9c7c2-8b07-4159-a569-ee05aef17511	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2357	1	11	1	[0]	2019-07-06 00:00:00	\N	\N	5138196d-2797-4d95-9d5e-de88b1b324b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2358	1	10	1	[0]	2019-07-06 00:00:00	\N	\N	b9487213-15a7-4e12-a672-1c7befeceba5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2359	1	9	1	[0]	2019-07-06 00:00:00	\N	\N	2656e20f-cdee-44ba-b3ac-4d270d95dac8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2360	1	8	1	[0]	2019-07-06 00:00:00	\N	\N	aacfc79a-763d-4dac-ba7f-8a774e59c884	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2361	1	12	1	[0]	2019-07-06 01:00:00	\N	\N	7673697c-96ec-42bf-8c0b-ece36a78e307	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2362	1	11	1	[0]	2019-07-06 01:00:00	\N	\N	40d61903-b066-4488-88d5-c060cf4a4d51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2363	1	10	1	[0]	2019-07-06 01:00:00	\N	\N	4ca0bc89-f734-405e-ac47-133a13ac8f0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2364	1	9	1	[0]	2019-07-06 01:00:00	\N	\N	8bc09d63-7093-48bc-9017-c45013b5ca6a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2365	1	8	1	[0]	2019-07-06 01:00:00	\N	\N	e8e1170d-8103-43f6-bfe4-0a7312e145f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2366	1	12	1	[0]	2019-07-06 02:00:00	\N	\N	37ab9a85-4db1-41ad-ae9e-ba905c52c551	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2367	1	11	1	[0]	2019-07-06 02:00:00	\N	\N	95afd88f-199a-4180-adbf-1900aa7624a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2368	1	10	1	[0]	2019-07-06 02:00:00	\N	\N	4bb35070-a32f-4a7b-a3d1-2688531b9c78	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2369	1	9	1	[0]	2019-07-06 02:00:00	\N	\N	3aa80ebf-75ca-4553-8416-104a23834aae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2370	1	8	1	[0]	2019-07-06 02:00:00	\N	\N	71226cd0-db6a-4a36-9c05-e15e3cd5b210	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2371	1	12	1	[0]	2019-07-06 03:00:00	\N	\N	15ada776-2556-4d61-8c7b-2d59409ee106	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2372	1	11	1	[0]	2019-07-06 03:00:00	\N	\N	7ca52d39-28c1-42e8-b907-e201921453fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2373	1	10	1	[0]	2019-07-06 03:00:00	\N	\N	45ca8698-7197-473e-9041-022928002038	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2374	1	9	1	[0]	2019-07-06 03:00:00	\N	\N	a81afaae-7db9-4ab0-b3ad-62ad0907b9f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2375	1	8	1	[0]	2019-07-06 03:00:00	\N	\N	e45b04dd-66d5-43b0-ad9f-fbeda2a20c62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2376	1	12	1	[0]	2019-07-06 04:00:00	\N	\N	f84dbf58-58b8-4045-98b4-24e4b4ba89a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2377	1	11	1	[0]	2019-07-06 04:00:00	\N	\N	c0ed5549-68f7-4764-af16-8b0e72dc672b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2378	1	10	1	[0]	2019-07-06 04:00:00	\N	\N	766b040d-f10d-4867-bddd-3ee6600a62e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2379	1	9	1	[0]	2019-07-06 04:00:00	\N	\N	04fada70-96f0-49c3-907e-67588e2fcd82	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2380	1	8	1	[0]	2019-07-06 04:00:00	\N	\N	578a3739-a623-411e-94f3-6d1968c973e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2381	1	12	1	[0]	2019-07-06 05:00:00	\N	\N	58412cbb-6620-47d2-a097-28326699064d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2382	1	11	1	[0]	2019-07-06 05:00:00	\N	\N	825ecc9e-90be-4e27-9f67-c8fa94905840	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2383	1	10	1	[0]	2019-07-06 05:00:00	\N	\N	b4cf57f7-e6b8-4130-8a78-383765fd6a67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2384	1	9	1	[0]	2019-07-06 05:00:00	\N	\N	6c62e9a1-d926-4cee-8753-de3c00e3f117	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2385	1	8	1	[0]	2019-07-06 05:00:00	\N	\N	d565d6ce-22a8-4d61-9463-44344e13fc9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2386	1	12	1	[0]	2019-07-06 06:00:00	\N	\N	788cf73d-8b61-4219-94cb-08d5be73f02e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2387	1	11	1	[0]	2019-07-06 06:00:00	\N	\N	16c202ae-e03d-4925-ae76-640b63d0b4ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2388	1	10	1	[0]	2019-07-06 06:00:00	\N	\N	6e1a7414-fbde-4d4f-90f0-959fab82a611	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2389	1	9	1	[0]	2019-07-06 06:00:00	\N	\N	cd53ae30-9f96-41ca-8fc0-eb8ef86bb1df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2390	1	8	1	[0]	2019-07-06 06:00:00	\N	\N	cdaa25de-d629-407b-aa63-d073ed6beefc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2391	1	12	1	[0]	2019-07-06 07:00:00	\N	\N	cb37db55-e35d-470d-978e-bac1ed5c0928	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2392	1	11	1	[0]	2019-07-06 07:00:00	\N	\N	2f5a9ba7-0332-4f91-8f7e-6564d73314a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2393	1	10	1	[0]	2019-07-06 07:00:00	\N	\N	5625855f-6cd8-4d37-8228-6141e9b228b8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2394	1	9	1	[0]	2019-07-06 07:00:00	\N	\N	4b0bd0f8-977e-4982-835f-327843483dbe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2395	1	8	1	[0]	2019-07-06 07:00:00	\N	\N	71c98f57-c5f5-4ed3-9d97-36dfb38873f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2396	1	12	1	[0]	2019-07-06 08:00:00	\N	\N	86cc09d8-c0af-4cad-8850-17933b9f2578	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2397	1	11	1	[0]	2019-07-06 08:00:00	\N	\N	95beb1f5-b11b-41f7-a99f-15511f4339d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2398	1	10	1	[0]	2019-07-06 08:00:00	\N	\N	26a329e8-b566-4209-9781-82794e18504d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2399	1	9	1	[0]	2019-07-06 08:00:00	\N	\N	01520fc9-7a99-49c4-99ed-0d91540ce812	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2400	1	8	1	[0]	2019-07-06 08:00:00	\N	\N	5537db12-89cf-4028-a6d2-b1cab8b1d492	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2401	1	12	1	[0]	2019-07-06 09:00:00	\N	\N	f6010f7f-c750-4227-823d-4070d27ef8c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2402	1	11	1	[0]	2019-07-06 09:00:00	\N	\N	7b8df538-cb94-41b3-bb8e-1d5bc60ad17b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2403	1	10	1	[0]	2019-07-06 09:00:00	\N	\N	2cb4af5c-a0a1-4882-ada3-107bbd0ee1c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2404	1	9	1	[0]	2019-07-06 09:00:00	\N	\N	b2276bfc-3c9a-4f74-a6b4-e6277c13a2a1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2405	1	8	1	[0]	2019-07-06 09:00:00	\N	\N	29644039-64f9-464d-8cbe-8a1daa614c9b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2406	1	12	1	[0]	2019-07-06 10:00:00	\N	\N	47515bd9-65a0-44f4-b752-f5c3abff0461	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2407	1	11	1	[0]	2019-07-06 10:00:00	\N	\N	1fffc374-3685-4867-996d-38712ceee637	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2408	1	10	1	[0]	2019-07-06 10:00:00	\N	\N	e0fd4363-f383-4034-a58f-4ea814e300a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2409	1	9	1	[0]	2019-07-06 10:00:00	\N	\N	dad09b27-157a-4ee9-b78c-dd540583a267	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2410	1	8	1	[0]	2019-07-06 10:00:00	\N	\N	b804ec0d-bb6d-44dd-b85a-235f7ec84f99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2411	1	12	1	[0]	2019-07-06 11:00:00	\N	\N	4b80c597-06c8-4fb2-a825-b9fd59787898	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2412	1	11	1	[0]	2019-07-06 11:00:00	\N	\N	c7d94122-1bf8-4413-b0bc-2290dc7fec28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2413	1	10	1	[0]	2019-07-06 11:00:00	\N	\N	08d48b9d-5d22-41ac-9d70-66ef03cde050	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2414	1	9	1	[0]	2019-07-06 11:00:00	\N	\N	670a5a22-2342-4721-8c52-bdf6747b96d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2415	1	8	1	[0]	2019-07-06 11:00:00	\N	\N	d1d9b858-5c0a-470d-93b3-6b13f05e2af6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2416	1	12	1	[0]	2019-07-06 12:00:00	\N	\N	33b14dad-fadd-4ec5-aefa-5106acfc500d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2417	1	11	1	[0]	2019-07-06 12:00:00	\N	\N	221c2b50-0a13-45b0-ae4d-37d61a7ec970	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2418	1	10	1	[0]	2019-07-06 12:00:00	\N	\N	2553ebb6-ca04-404a-9d83-4e020f7d4866	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2419	1	9	1	[0]	2019-07-06 12:00:00	\N	\N	665324d2-9862-4efd-b762-97fb467bbc26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2420	1	8	1	[0]	2019-07-06 12:00:00	\N	\N	2669dc41-7b83-4dc4-a8c3-46c54e319e2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2421	1	12	1	[0]	2019-07-06 13:00:00	\N	\N	aa580dbc-3d42-4f6a-9ee5-bcc2d223f50a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2422	1	11	1	[0]	2019-07-06 13:00:00	\N	\N	7d30e289-3b56-4d6d-b607-f46be6919717	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2423	1	10	1	[0]	2019-07-06 13:00:00	\N	\N	af34c4b6-33b8-4bf7-bfce-fe290c3e8c66	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2424	1	9	1	[0]	2019-07-06 13:00:00	\N	\N	eeb04d2a-bda5-4495-9e7c-ab5da61c0e3a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2425	1	8	1	[0]	2019-07-06 13:00:00	\N	\N	b5aaca06-fbfd-4a04-811e-9c51f928768f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2426	1	12	1	[0]	2019-07-06 14:00:00	\N	\N	b2b61ce0-2682-4852-9e92-4e187239219e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2427	1	11	1	[0]	2019-07-06 14:00:00	\N	\N	1fc72517-a1ce-424c-a523-6a47e990117d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2428	1	10	1	[0]	2019-07-06 14:00:00	\N	\N	c6ad7c6c-9d67-48ea-bd9f-6315183059c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2429	1	9	1	[0]	2019-07-06 14:00:00	\N	\N	fa05d116-52d0-4e23-81e4-06df7159cb5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2430	1	8	1	[0]	2019-07-06 14:00:00	\N	\N	6880686a-b584-4f75-bfec-b8c7c6e9f0be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2431	1	12	1	[0]	2019-07-06 15:00:00	\N	\N	b0a53879-1a85-41bf-8d0f-4d00d8cc22e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2432	1	11	1	[0]	2019-07-06 15:00:00	\N	\N	4a711d17-d01a-4fc1-8129-14e830bc91bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2433	1	10	1	[0]	2019-07-06 15:00:00	\N	\N	7f48d68f-e421-4984-b037-93560ae96d67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2434	1	9	1	[0]	2019-07-06 15:00:00	\N	\N	2fc2b096-d4c5-4bd9-bb24-c273e75fc2b8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2435	1	8	1	[0]	2019-07-06 15:00:00	\N	\N	e1b48c5e-e4af-4216-8e8f-b66e178c38bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2436	1	12	1	[0]	2019-07-06 16:00:00	\N	\N	3476eb0d-0908-47f3-8204-e67740fcfc69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2437	1	11	1	[0]	2019-07-06 16:00:00	\N	\N	a460fa0e-fdbd-47b7-8136-a896e76a83ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2438	1	10	1	[0]	2019-07-06 16:00:00	\N	\N	2efe297b-2b95-43ec-b6ef-5f1aec8b8d8c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2439	1	9	1	[0]	2019-07-06 16:00:00	\N	\N	395f5aeb-1f85-470a-b089-54f85385ad4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2440	1	8	1	[0]	2019-07-06 16:00:00	\N	\N	27b7b4cb-4b10-4eee-a1fb-c8b99266fd61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2441	1	12	1	[0]	2019-07-06 17:00:00	\N	\N	386dfe3f-bf50-4d58-9535-813986c52503	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2442	1	11	1	[0]	2019-07-06 17:00:00	\N	\N	67bac2ef-46e3-4bda-a411-f9f2ad258b9f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2443	1	10	1	[0]	2019-07-06 17:00:00	\N	\N	96eb1cc2-8be5-415c-a362-6f45a31f1c53	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2444	1	9	1	[0]	2019-07-06 17:00:00	\N	\N	1cebafd0-d2d0-438f-b4b6-3a40c9831f23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2445	1	8	1	[0]	2019-07-06 17:00:00	\N	\N	fa6918fa-1521-41ac-8514-75c0ccc2b6ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2446	1	12	1	[0]	2019-07-06 18:00:00	\N	\N	f12dde79-215f-4393-8c0b-3d395427ad4a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2447	1	11	1	[0]	2019-07-06 18:00:00	\N	\N	f3d66a1b-cc35-4975-8330-1da0938d19ce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2448	1	10	1	[0]	2019-07-06 18:00:00	\N	\N	0475d1f8-f09d-410b-8b08-c7655d835ba0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2449	1	9	1	[0]	2019-07-06 18:00:00	\N	\N	200a4b25-6a85-4257-bc5f-6c7b700e35ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2450	1	8	1	[0]	2019-07-06 18:00:00	\N	\N	a2577581-ae75-426d-ab73-fe061865c728	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2451	1	12	1	[0]	2019-07-06 19:00:00	\N	\N	7b3dcde3-d5bf-4045-97fb-5f7ec75a3606	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2452	1	11	1	[0]	2019-07-06 19:00:00	\N	\N	24a10c2b-a3a4-4d0e-839c-ed738b1d3ab3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2453	1	10	1	[0]	2019-07-06 19:00:00	\N	\N	875538aa-2ac1-48ff-81ad-5add1e5e5ec3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2454	1	9	1	[0]	2019-07-06 19:00:00	\N	\N	64418451-101e-432a-8da6-26196560977c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2455	1	8	1	[0]	2019-07-06 19:00:00	\N	\N	4c9a2a39-c4b9-4975-86f3-dbc90b4e1d36	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2456	1	12	1	[0]	2019-07-06 20:00:00	\N	\N	b15a96ef-7a13-4753-a554-d30a39041bb9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2457	1	11	1	[0]	2019-07-06 20:00:00	\N	\N	257e054c-1320-4bb8-977e-07d6d8227a47	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2458	1	10	1	[0]	2019-07-06 20:00:00	\N	\N	05a34ebc-13e9-40cd-bb29-8ec10d2988a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2459	1	9	1	[0]	2019-07-06 20:00:00	\N	\N	c71c9ae0-484d-4fe4-b9a5-d23dba44f2fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2460	1	8	1	[0]	2019-07-06 20:00:00	\N	\N	367a4484-f523-45a6-a6fb-af26455b6154	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2461	1	12	1	[0]	2019-07-06 21:00:00	\N	\N	f0fc08da-3669-41d8-8250-6acd8ae75bd3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2462	1	11	1	[0]	2019-07-06 21:00:00	\N	\N	da11dc36-59d8-480b-aab4-9846a86f7b59	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2463	1	10	1	[0]	2019-07-06 21:00:00	\N	\N	3b03afef-e2d4-4dea-af0e-94faa44e20dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2464	1	9	1	[0]	2019-07-06 21:00:00	\N	\N	c5d51071-63e7-472c-99df-32f5cdaaf0fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2465	1	8	1	[0]	2019-07-06 21:00:00	\N	\N	76baa06d-f939-4ae5-9649-4f35c4f407f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2466	1	12	1	[0]	2019-07-06 22:00:00	\N	\N	714d9bda-2577-4104-885f-9b16628c5f85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2467	1	11	1	[0]	2019-07-06 22:00:00	\N	\N	4d981a0d-e282-4d5f-85c3-32676ef85a55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2468	1	10	1	[0]	2019-07-06 22:00:00	\N	\N	1ef6c3a2-fb15-41d7-b3c0-1378253375bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2469	1	9	1	[0]	2019-07-06 22:00:00	\N	\N	f7e75c24-c708-4e4f-ace0-7fcde30d38e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2470	1	8	1	[0]	2019-07-06 22:00:00	\N	\N	fb92c4a8-2359-4072-be24-d8ac610e8ac8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2471	1	12	1	[0]	2019-07-06 23:00:00	\N	\N	c7e3d423-4953-42d1-9414-eca6c8252b9f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2472	1	11	1	[0]	2019-07-06 23:00:00	\N	\N	33d0bcc8-71bc-4f29-aae9-40a287284386	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2473	1	10	1	[0]	2019-07-06 23:00:00	\N	\N	b843641c-dc1f-4713-ae1e-07878f2743db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2474	1	9	1	[0]	2019-07-06 23:00:00	\N	\N	44b33fee-0485-40a9-bb49-03bc6446942f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2475	1	8	1	[0]	2019-07-06 23:00:00	\N	\N	13a66417-a559-479a-95c5-3f1a97cf1048	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2476	1	12	1	[0]	2019-07-07 00:00:00	\N	\N	f3dc052a-7881-413d-a2be-52fd21221482	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2477	1	11	1	[0]	2019-07-07 00:00:00	\N	\N	441a56e7-1fd8-4767-a5fe-42c74725b3c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2478	1	10	1	[0]	2019-07-07 00:00:00	\N	\N	9a9aa1a4-e28c-4be2-b92f-1953989c5f76	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2479	1	9	1	[0]	2019-07-07 00:00:00	\N	\N	8690db59-a78c-4356-b46e-73319498fd89	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2480	1	8	1	[0]	2019-07-07 00:00:00	\N	\N	9fd2ea2a-3bad-4ab5-b25d-bd140f2d5fc6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2481	1	12	1	[0]	2019-07-07 01:00:00	\N	\N	0da150ea-e7b9-4390-a1ad-8214ed94e73d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2482	1	11	1	[0]	2019-07-07 01:00:00	\N	\N	9f63adcb-876d-42f5-8588-e04d45d6b5b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2483	1	10	1	[0]	2019-07-07 01:00:00	\N	\N	b1967803-69fa-4a3a-94af-f3f86f3c27db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2484	1	9	1	[0]	2019-07-07 01:00:00	\N	\N	d313f29f-4df7-438e-af40-528bdc22e6a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2485	1	8	1	[0]	2019-07-07 01:00:00	\N	\N	1d17d9ad-6000-428f-bc4e-d11ec87ed8d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2486	1	12	1	[0]	2019-07-07 02:00:00	\N	\N	0ca2149a-b70e-4b3a-9a14-9ef78a058065	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2487	1	11	1	[0]	2019-07-07 02:00:00	\N	\N	3a043578-d398-4bf3-87be-be7a604f9330	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2488	1	10	1	[0]	2019-07-07 02:00:00	\N	\N	ddb82e61-1704-46ac-88da-45dac82fdbef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2489	1	9	1	[0]	2019-07-07 02:00:00	\N	\N	45980eb6-0577-4395-bc02-5195760b3d75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2490	1	8	1	[0]	2019-07-07 02:00:00	\N	\N	099cd633-9f1e-406b-804b-5eba753b9b61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2491	1	12	1	[0]	2019-07-07 03:00:00	\N	\N	fa93de31-07c1-4004-9afb-8017405af294	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2492	1	11	1	[0]	2019-07-07 03:00:00	\N	\N	17842d65-ee72-411b-9733-a4ab9e805b86	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2493	1	10	1	[0]	2019-07-07 03:00:00	\N	\N	ae4d7b3d-8fc5-4a60-aed3-678a4677f802	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2494	1	9	1	[0]	2019-07-07 03:00:00	\N	\N	ae6db54e-acd1-49c3-919f-8abac94628fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2495	1	8	1	[0]	2019-07-07 03:00:00	\N	\N	9a11180d-64e2-413a-be5b-ab6f72d84304	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2496	1	12	1	[0]	2019-07-07 04:00:00	\N	\N	f29735cf-a853-4023-8f10-3760f92575c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2497	1	11	1	[0]	2019-07-07 04:00:00	\N	\N	05d1bcbe-0a7b-4a78-853b-1eba37f7490c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2498	1	10	1	[0]	2019-07-07 04:00:00	\N	\N	ddd3db44-5d78-48ac-8f37-257bb70cad54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2499	1	9	1	[0]	2019-07-07 04:00:00	\N	\N	fb3e7a3a-1a01-4c02-8013-3602942b647e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2500	1	8	1	[0]	2019-07-07 04:00:00	\N	\N	165cc180-b8ae-4e25-bd64-dd79f5cdd833	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2501	1	12	1	[0]	2019-07-07 05:00:00	\N	\N	4f4ae863-b958-4ef5-91c9-9f62150e8e74	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2502	1	11	1	[0]	2019-07-07 05:00:00	\N	\N	1501dc0e-9727-4a8b-8a00-d519d4e51a3a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2503	1	10	1	[0]	2019-07-07 05:00:00	\N	\N	af805021-fac4-4139-a218-052088d536e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2504	1	9	1	[0]	2019-07-07 05:00:00	\N	\N	3a8026c8-211b-4902-b639-e3c7f8e2f056	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2505	1	8	1	[0]	2019-07-07 05:00:00	\N	\N	768a1aed-72be-4c7a-bea1-31b10857a779	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2506	1	12	1	[0]	2019-07-07 06:00:00	\N	\N	4ef98f6f-e699-41bb-88b3-3b01a5dafff5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2507	1	11	1	[0]	2019-07-07 06:00:00	\N	\N	8d10bb4d-6a81-484e-9955-a78ef7ee8a5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2508	1	10	1	[0]	2019-07-07 06:00:00	\N	\N	c7bc3449-c6a7-4311-afb9-88180918d0be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2509	1	9	1	[0]	2019-07-07 06:00:00	\N	\N	0727d942-fa9e-4957-9536-f709dcd1d922	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2510	1	8	1	[0]	2019-07-07 06:00:00	\N	\N	a9fe6524-c36c-40fb-8291-ac127729d3b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2511	1	12	1	[0]	2019-07-07 07:00:00	\N	\N	d166f461-b480-4ffe-afdf-fd2daf36d549	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2512	1	11	1	[0]	2019-07-07 07:00:00	\N	\N	7abf626a-4b77-4b38-b50d-07acc109baad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2513	1	10	1	[0]	2019-07-07 07:00:00	\N	\N	a857675c-fa56-46b0-875b-e5c0603cf3b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2514	1	9	1	[0]	2019-07-07 07:00:00	\N	\N	8767d1de-78e4-4018-9f50-f78d68cf4ac0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2515	1	8	1	[0]	2019-07-07 07:00:00	\N	\N	19fb2d7c-7f34-48a2-9f62-908fcce3f1f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2516	1	12	1	[0]	2019-07-07 08:00:00	\N	\N	f356e6ab-8416-4b0b-96bd-66360f11286f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2517	1	11	1	[0]	2019-07-07 08:00:00	\N	\N	c9b6c6ff-3572-445e-a172-03dd095832f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2518	1	10	1	[0]	2019-07-07 08:00:00	\N	\N	9f4fe1fa-05b1-454d-811d-356e61c4d197	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2519	1	9	1	[0]	2019-07-07 08:00:00	\N	\N	48685c5d-9e83-42bf-b8c6-39de2a58d7fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2520	1	8	1	[0]	2019-07-07 08:00:00	\N	\N	9fdbe208-201e-4e1f-a6a0-c55f0a05e0ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2521	1	12	1	[0]	2019-07-07 09:00:00	\N	\N	6124f6ea-7c94-460a-af65-9bc727d78c56	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2522	1	11	1	[0]	2019-07-07 09:00:00	\N	\N	736ffd56-f167-4aab-8b31-aa2942d905e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2523	1	10	1	[0]	2019-07-07 09:00:00	\N	\N	d220b6c7-06e5-436f-a669-679283e44702	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2524	1	9	1	[0]	2019-07-07 09:00:00	\N	\N	fb867d59-d8bb-4ab5-937c-ac32e6362473	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2525	1	8	1	[0]	2019-07-07 09:00:00	\N	\N	cf8d66d2-5232-4992-ba89-239769cbee91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2526	1	12	1	[0]	2019-07-07 10:00:00	\N	\N	5b7bd915-62d8-429e-bb9e-0b4ac9c22fd3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2527	1	11	1	[0]	2019-07-07 10:00:00	\N	\N	416e7f7b-63d9-4e91-b9a6-0220a3af4a8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2528	1	10	1	[0]	2019-07-07 10:00:00	\N	\N	51810270-3309-4707-9820-cc91dec508db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2529	1	9	1	[0]	2019-07-07 10:00:00	\N	\N	6885e8d8-8e5a-45ed-ac8d-ca6a0660849b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2530	1	8	1	[0]	2019-07-07 10:00:00	\N	\N	6d6bf2ab-95b3-4262-acc9-6d4b182f56b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2531	1	12	1	[0]	2019-07-07 11:00:00	\N	\N	7490ca0c-686a-445f-b979-8975875191c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2532	1	11	1	[0]	2019-07-07 11:00:00	\N	\N	bd1a5501-1a2c-4371-993a-2fdc6d984403	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2533	1	10	1	[0]	2019-07-07 11:00:00	\N	\N	08cceb85-7ff1-4c55-a792-533c8ef52f20	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2534	1	9	1	[0]	2019-07-07 11:00:00	\N	\N	6c8a2764-d54c-40f8-960e-e6aaad4942bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2535	1	8	1	[0]	2019-07-07 11:00:00	\N	\N	78c5f565-4cbe-4de3-9e22-26b4c596b1e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2536	1	12	1	[0]	2019-07-07 12:00:00	\N	\N	270f201b-98d8-4c53-a7d2-dff911fc2f2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2537	1	11	1	[0]	2019-07-07 12:00:00	\N	\N	0ad40818-7444-455b-97df-ff85549db96c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2538	1	10	1	[0]	2019-07-07 12:00:00	\N	\N	8272bdaf-11a5-422e-a975-a485c783694c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2539	1	9	1	[0]	2019-07-07 12:00:00	\N	\N	eef63900-1b0b-4f40-9d5a-097812c34f02	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2540	1	8	1	[0]	2019-07-07 12:00:00	\N	\N	1825b711-8cd6-463c-bc71-51c73bc8ad84	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2541	1	12	1	[0]	2019-07-07 13:00:00	\N	\N	aa817fe6-52f6-4303-ab61-4587fe37b64b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2542	1	11	1	[0]	2019-07-07 13:00:00	\N	\N	081c6d95-70bb-443f-bdb8-7df768e5bd5c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2543	1	10	1	[0]	2019-07-07 13:00:00	\N	\N	0499c8d7-f01d-477e-8b56-e4334819ed0d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2544	1	9	1	[0]	2019-07-07 13:00:00	\N	\N	f82661d8-cb54-4708-bc04-9baa897574f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2545	1	8	1	[0]	2019-07-07 13:00:00	\N	\N	734c534a-1f7b-40f4-9a60-56119f034c06	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2546	1	12	1	[0]	2019-07-07 14:00:00	\N	\N	8597ec45-24c7-42fb-b8c8-c7c5dbab619f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2547	1	11	1	[0]	2019-07-07 14:00:00	\N	\N	e3ae8bc9-af1c-4f51-a337-3e27e4c62d21	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2548	1	10	1	[0]	2019-07-07 14:00:00	\N	\N	34eea211-ef54-4ea7-b64e-d81312155aec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2549	1	9	1	[0]	2019-07-07 14:00:00	\N	\N	61e61b56-6157-4db4-9085-84cc9284dd0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2550	1	8	1	[0]	2019-07-07 14:00:00	\N	\N	1682225b-790b-454e-8acc-64ba8cd026ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2551	1	12	1	[0]	2019-07-07 15:00:00	\N	\N	d3b3f604-b35c-40e4-b002-2698a44f328e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2552	1	11	1	[0]	2019-07-07 15:00:00	\N	\N	761d4124-94f2-4048-a683-cda73d84a710	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2553	1	10	1	[0]	2019-07-07 15:00:00	\N	\N	2e8ff58a-3684-4b46-bbc6-df8c9a5d75cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2554	1	9	1	[0]	2019-07-07 15:00:00	\N	\N	724bcde4-aa15-480e-a9fb-783cb5b129af	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2555	1	8	1	[0]	2019-07-07 15:00:00	\N	\N	f722a176-306a-49ba-aac0-49be190fa19d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2556	1	12	1	[0]	2019-07-07 16:00:00	\N	\N	716662ef-7ef5-42a7-a05c-78efab4aa98c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2557	1	11	1	[0]	2019-07-07 16:00:00	\N	\N	fb3e0b2c-9d3a-4eb7-adbf-0ecf556995e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2558	1	10	1	[0]	2019-07-07 16:00:00	\N	\N	37b784d2-1add-4a7d-abf9-c2b20a84a548	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2559	1	9	1	[0]	2019-07-07 16:00:00	\N	\N	4622b99d-c022-4c93-8581-9fc29e6b13c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2560	1	8	1	[0]	2019-07-07 16:00:00	\N	\N	9bfc09d6-ae5a-4dfd-adab-aa8a71392590	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2561	1	12	1	[0]	2019-07-07 17:00:00	\N	\N	30bd9c7e-01e0-4769-bfdc-33c71673bdd1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2562	1	11	1	[0]	2019-07-07 17:00:00	\N	\N	b99be05a-fd61-40c1-80c1-2b51cc5780eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2563	1	10	1	[0]	2019-07-07 17:00:00	\N	\N	c26ae4ea-2432-4341-8e09-41bcadd799ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2564	1	9	1	[0]	2019-07-07 17:00:00	\N	\N	03fb3318-f52b-47a7-a184-2bab61ce1d9b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2565	1	8	1	[0]	2019-07-07 17:00:00	\N	\N	1f880219-1b06-4c0b-ae79-3ab2627150ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2566	1	12	1	[0]	2019-07-07 18:00:00	\N	\N	1f8cec02-44ab-44c4-8764-2353ab38c034	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2567	1	11	1	[0]	2019-07-07 18:00:00	\N	\N	f69e2222-5091-45f0-abe3-759b811a0cd5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2568	1	10	1	[0]	2019-07-07 18:00:00	\N	\N	ee65aa73-4cd0-4744-a964-0d9e81374843	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2569	1	9	1	[0]	2019-07-07 18:00:00	\N	\N	71c870c1-42ec-4b44-aefa-dcf724d0bae6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2570	1	8	1	[0]	2019-07-07 18:00:00	\N	\N	6080a71e-6cdf-4b8b-aee7-db1de5910e24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2571	1	12	1	[0]	2019-07-07 19:00:00	\N	\N	e9da910d-0549-49cc-861e-84d0e1938fcd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2572	1	11	1	[0]	2019-07-07 19:00:00	\N	\N	f98686ff-d31b-477b-92e8-4748baca7054	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2573	1	10	1	[0]	2019-07-07 19:00:00	\N	\N	6305e01d-2315-48d0-95dc-5430b35e3999	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2574	1	9	1	[0]	2019-07-07 19:00:00	\N	\N	46cbf499-f402-4f50-a932-f907f45e0957	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2575	1	8	1	[0]	2019-07-07 19:00:00	\N	\N	04a27f48-c651-483c-bcf2-520eb1593865	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2576	1	12	1	[0]	2019-07-07 20:00:00	\N	\N	c5e74fa5-e9a7-49cb-8564-3e2459faca11	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2577	1	11	1	[0]	2019-07-07 20:00:00	\N	\N	54ba2bbe-af50-4f34-a5c9-fd7485d841f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2578	1	10	1	[0]	2019-07-07 20:00:00	\N	\N	7be8e639-a330-424a-8ac8-056e6aed46bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2579	1	9	1	[0]	2019-07-07 20:00:00	\N	\N	992eae14-4603-4e3c-974a-65ae36d3c7ae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2580	1	8	1	[0]	2019-07-07 20:00:00	\N	\N	90c44c1b-6523-4810-b7d7-989548c72972	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2581	1	12	1	[0]	2019-07-07 21:00:00	\N	\N	9bb72c84-1dc4-4a59-a1f4-b0ebc8f9bf21	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2582	1	11	1	[0]	2019-07-07 21:00:00	\N	\N	34607c81-e1b9-4d87-81a7-a395af8190b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2583	1	10	1	[0]	2019-07-07 21:00:00	\N	\N	7fbcae62-1f7a-475a-8fa3-9ea4399a89a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2584	1	9	1	[0]	2019-07-07 21:00:00	\N	\N	71da4ebf-bd2c-4df3-abaf-5c9ff7d42b1a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2585	1	8	1	[0]	2019-07-07 21:00:00	\N	\N	4be63f53-bb07-4c6d-abc0-dcfb932a5fce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2586	1	12	1	[0]	2019-07-07 22:00:00	\N	\N	7201702c-e632-4c2e-9bf6-1b6362e484a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2587	1	11	1	[0]	2019-07-07 22:00:00	\N	\N	d930173e-c6e3-458f-8a24-5f5297d697e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2588	1	10	1	[0]	2019-07-07 22:00:00	\N	\N	e8e12e85-a6d1-4c74-a20e-20421e04df92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2589	1	9	1	[0]	2019-07-07 22:00:00	\N	\N	1b592839-504f-43b1-8ff2-ac6af595316f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2590	1	8	1	[0]	2019-07-07 22:00:00	\N	\N	4d0c19e2-a0f2-4c3a-9fa8-4db5076377d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2591	1	12	1	[0]	2019-07-07 23:00:00	\N	\N	41f35718-ab12-4465-ace7-f40594288ac8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2592	1	11	1	[0]	2019-07-07 23:00:00	\N	\N	3863de33-efc0-4dbe-bd3a-42527c6a4bc1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2593	1	10	1	[0]	2019-07-07 23:00:00	\N	\N	d635510e-cd47-4ca3-bcaf-baadc629b6db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2594	1	9	1	[0]	2019-07-07 23:00:00	\N	\N	45707e4b-cfc1-4999-b105-8194f37a07b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2595	1	8	1	[0]	2019-07-07 23:00:00	\N	\N	3fcf4e75-0575-40d0-9e88-a3ac4a61cb47	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2596	1	12	1	[0]	2019-07-08 00:00:00	\N	\N	71c4897b-4275-445f-b97f-f8d57c8576ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2597	1	11	1	[0]	2019-07-08 00:00:00	\N	\N	9d47bd23-74a2-4bea-9192-eec173c6d654	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2598	1	10	1	[0]	2019-07-08 00:00:00	\N	\N	1b47c720-d669-405b-bb23-25834a38c1db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2599	1	9	1	[0]	2019-07-08 00:00:00	\N	\N	2a965866-8000-4fd7-927f-934b1d4ffa33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2600	1	8	1	[0]	2019-07-08 00:00:00	\N	\N	6bb51cd3-7607-4ddd-93f5-8fcb97cdda6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2601	1	12	1	[0]	2019-07-08 01:00:00	\N	\N	657741fe-a741-4f55-931f-a42dd75974f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2602	1	11	1	[0]	2019-07-08 01:00:00	\N	\N	fe8169bf-fcff-4a76-9c58-fda419c3b061	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2603	1	10	1	[0]	2019-07-08 01:00:00	\N	\N	3584b98f-2317-4f33-95dc-8c9f1c79b315	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2604	1	9	1	[0]	2019-07-08 01:00:00	\N	\N	dd77b0be-bbd8-4493-86bf-3e8ff67a27bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2605	1	8	1	[0]	2019-07-08 01:00:00	\N	\N	2560d5b0-648f-4e90-b210-263df1411f1f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2606	1	12	1	[0]	2019-07-08 02:00:00	\N	\N	7a7348a5-20ee-4cc3-b0a5-d577bdcba293	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2607	1	11	1	[0]	2019-07-08 02:00:00	\N	\N	8d73be46-fb2b-41d4-bb9b-17bd650c74eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2608	1	10	1	[0]	2019-07-08 02:00:00	\N	\N	ab5e3a03-a0a7-4cc6-aebf-adf750c7a56c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2609	1	9	1	[0]	2019-07-08 02:00:00	\N	\N	ecf25d22-e3be-4783-9fe7-15388041af1f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2610	1	8	1	[0]	2019-07-08 02:00:00	\N	\N	10466488-7eba-464c-b1fb-b9d5d963786c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2611	1	12	1	[0]	2019-07-08 03:00:00	\N	\N	9c759eb0-cfd3-4dda-b747-7453e1c6043c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2612	1	11	1	[0]	2019-07-08 03:00:00	\N	\N	a2a2fe38-376e-4423-a1de-2f7a6346d231	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2613	1	10	1	[0]	2019-07-08 03:00:00	\N	\N	49d14d27-ca1c-4bcb-98b3-eb8ae5971318	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2614	1	9	1	[0]	2019-07-08 03:00:00	\N	\N	8d5a770f-65ef-4d9f-9c33-2c92f5f3b95e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2615	1	8	1	[0]	2019-07-08 03:00:00	\N	\N	02cacfe7-9d10-4a79-a0e0-19ace685db2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2616	1	12	1	[0]	2019-07-08 04:00:00	\N	\N	10b1d512-fa27-486e-92a7-16ba816d3e88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2617	1	11	1	[0]	2019-07-08 04:00:00	\N	\N	a5bea1c9-7ba4-4aa4-bda7-7f7d138dc667	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2618	1	10	1	[0]	2019-07-08 04:00:00	\N	\N	799fd4e9-c99f-476b-a9db-7b38e9df279d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2619	1	9	1	[0]	2019-07-08 04:00:00	\N	\N	fdd621ab-5bbc-488d-b872-85b88a400b34	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2620	1	8	1	[0]	2019-07-08 04:00:00	\N	\N	ea7a91f1-d1c1-41cf-9273-4d1d9d58f823	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2621	1	12	1	[0]	2019-07-08 05:00:00	\N	\N	a2ace982-0853-48a1-9761-7ef8434d3736	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2622	1	11	1	[0]	2019-07-08 05:00:00	\N	\N	ac814588-e590-4cbf-b8a8-06cecb41fa56	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2623	1	10	1	[0]	2019-07-08 05:00:00	\N	\N	761d3f88-2ef9-448b-8b50-182f975e5db4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2624	1	9	1	[0]	2019-07-08 05:00:00	\N	\N	985cddcd-6ad3-49e0-b6be-e723f365ae00	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2625	1	8	1	[0]	2019-07-08 05:00:00	\N	\N	d5a18b97-28cc-4e62-abc7-730d0e72dbb1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2626	1	12	1	[0]	2019-07-08 06:00:00	\N	\N	cc460fe2-5a25-400a-80e9-d2038e0e7ba5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2627	1	11	1	[0]	2019-07-08 06:00:00	\N	\N	2c4b25fa-d17a-4b74-8541-14ee9a14b8f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2628	1	10	1	[0]	2019-07-08 06:00:00	\N	\N	40771b80-d48f-44a7-8e43-d5bf5124bda5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2629	1	9	1	[0]	2019-07-08 06:00:00	\N	\N	ae8ef9eb-7825-4b2b-9108-ff9937223ff5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2630	1	8	1	[0]	2019-07-08 06:00:00	\N	\N	a98abd39-e760-4b1b-946c-d8c663bb454e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2631	1	12	1	[0]	2019-07-08 07:00:00	\N	\N	ad4aa350-ea61-4232-a62a-5503be72aa50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2632	1	11	1	[0]	2019-07-08 07:00:00	\N	\N	9e84be6f-4ec1-4948-9bf6-17f28615e98f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2633	1	10	1	[0]	2019-07-08 07:00:00	\N	\N	b8447458-ab61-4616-8bc4-79f7e4b62248	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2634	1	9	1	[0]	2019-07-08 07:00:00	\N	\N	cefa823d-cbcf-43b8-927e-b28356446af9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2635	1	8	1	[0]	2019-07-08 07:00:00	\N	\N	29d5c222-83b1-42dd-aa33-7bda210ffff6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2636	1	12	1	[0]	2019-07-08 08:00:00	\N	\N	4e101769-1c31-4677-afcc-d5303702da8f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2637	1	11	1	[0]	2019-07-08 08:00:00	\N	\N	b0678a00-fda8-4617-82ad-df0e96516940	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2638	1	10	1	[0]	2019-07-08 08:00:00	\N	\N	f5c0b6cd-d287-40ca-a973-94806746b6ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2639	1	9	1	[0]	2019-07-08 08:00:00	\N	\N	e7c6dcf8-da77-4306-88e2-88a817e00012	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2640	1	8	1	[0]	2019-07-08 08:00:00	\N	\N	c3248f5a-fc4a-44d2-b964-9b3dd1fdd013	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2641	1	12	1	[0]	2019-07-08 09:00:00	\N	\N	b1fa08eb-1234-4b3f-91a1-8d563d3a01b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2642	1	11	1	[0]	2019-07-08 09:00:00	\N	\N	a0910541-3dce-482e-8c96-84b3e0574b9a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2643	1	10	1	[0]	2019-07-08 09:00:00	\N	\N	c3ec3279-d302-4efc-a3eb-b3fb1c085f8f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2644	1	9	1	[0]	2019-07-08 09:00:00	\N	\N	cec1028c-cb75-4b54-8203-cb2d336ccbde	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2645	1	8	1	[0]	2019-07-08 09:00:00	\N	\N	73d781a7-8c76-44c9-b4b2-42926e70a264	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2646	1	12	1	[0]	2019-07-08 10:00:00	\N	\N	b196f539-2404-4c5e-98a5-dc53379b52b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2647	1	11	1	[0]	2019-07-08 10:00:00	\N	\N	72328e3f-fffe-443d-bfd7-1594a1bc5e35	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2648	1	10	1	[0]	2019-07-08 10:00:00	\N	\N	81f928a5-d22b-43dc-b8bb-8434440bf427	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2649	1	9	1	[0]	2019-07-08 10:00:00	\N	\N	c12a0469-c225-4f58-a85b-ee9f5acbef28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2650	1	8	1	[0]	2019-07-08 10:00:00	\N	\N	202836b5-553b-4510-8192-f4c6900857da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2651	1	12	1	[0]	2019-07-08 11:00:00	\N	\N	a8bd2c37-8177-4d71-be81-b5f826c370ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2652	1	11	1	[0]	2019-07-08 11:00:00	\N	\N	2ecbc842-baf6-4b47-923f-b038f06c069d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2653	1	10	1	[0]	2019-07-08 11:00:00	\N	\N	22a28524-31ad-4e3a-a390-19aa8184ea2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2654	1	9	1	[0]	2019-07-08 11:00:00	\N	\N	aee4cdd3-e0cc-4915-91f1-52f4d60ef107	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2655	1	8	1	[0]	2019-07-08 11:00:00	\N	\N	28b3ef36-edcd-40a7-a6f2-25cdb0eaf46e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2656	1	12	1	[0]	2019-07-08 12:00:00	\N	\N	eeabcf94-b5b3-498f-8c5e-0f562eabccd5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2657	1	11	1	[0]	2019-07-08 12:00:00	\N	\N	334326e4-5720-4ef3-97a3-88cbebd3d5ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2658	1	10	1	[0]	2019-07-08 12:00:00	\N	\N	a3a3836e-83ef-4f60-bd73-71e627008851	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2659	1	9	1	[0]	2019-07-08 12:00:00	\N	\N	9f8846b3-05c0-4a38-8a1f-80f89f212c7d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2660	1	8	1	[0]	2019-07-08 12:00:00	\N	\N	057bcd70-bcb2-4db4-bf88-9ae79f6e64e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2661	1	12	1	[0]	2019-07-08 13:00:00	\N	\N	3842e4d7-54d6-4832-83c7-ba9d3af80180	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2662	1	11	1	[0]	2019-07-08 13:00:00	\N	\N	f9ae920f-2f34-45b1-9fb7-04c927d85422	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2663	1	10	1	[0]	2019-07-08 13:00:00	\N	\N	c855366e-80a2-4cc1-b095-33e6e1a959e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2664	1	9	1	[0]	2019-07-08 13:00:00	\N	\N	f79736c2-51ff-4543-a633-a8cd653802da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2665	1	8	1	[0]	2019-07-08 13:00:00	\N	\N	93ae9306-913e-44a0-bfa6-95bd53c30ccf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2666	1	12	1	[0]	2019-07-08 14:00:00	\N	\N	16ee4c73-da80-4433-8e2c-b7c42c895daf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2667	1	11	1	[0]	2019-07-08 14:00:00	\N	\N	6abc7d4e-abe6-4663-b492-d07a44ce4e2e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2668	1	10	1	[0]	2019-07-08 14:00:00	\N	\N	b17531cb-d6b6-45f2-960b-a809b2d7b5d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2669	1	9	1	[0]	2019-07-08 14:00:00	\N	\N	49d3e52a-a3de-49ec-87dd-3d004960c6b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2670	1	8	1	[0]	2019-07-08 14:00:00	\N	\N	457990e9-1178-43e8-8a13-9d4af4a00121	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2671	1	12	1	[0]	2019-07-08 15:00:00	\N	\N	4e24c74f-797a-4765-9e59-e9aa010475a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2672	1	11	1	[0]	2019-07-08 15:00:00	\N	\N	528b9346-6600-4d6b-89c5-307fc422c840	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2673	1	10	1	[0]	2019-07-08 15:00:00	\N	\N	32c8c96a-44a2-49fc-b5ab-3a54ac3265dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2674	1	9	1	[0]	2019-07-08 15:00:00	\N	\N	38ad18f9-c10a-461b-ae00-bb7b862a6477	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2675	1	8	1	[0]	2019-07-08 15:00:00	\N	\N	6a6e2a3e-49df-4911-9314-8b7e40bf4d23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2676	1	12	1	[0]	2019-07-08 16:00:00	\N	\N	1b3e262c-0c16-443c-8c27-8a0b295416ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2677	1	11	1	[0]	2019-07-08 16:00:00	\N	\N	05cc2357-0472-4987-b35d-37b43be6d49b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2678	1	10	1	[0]	2019-07-08 16:00:00	\N	\N	e75f4c3a-a40c-463d-8e45-4a61abbe283d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2679	1	9	1	[0]	2019-07-08 16:00:00	\N	\N	df7851a0-1c0b-4e12-89e3-87abfbb0add2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2680	1	8	1	[0]	2019-07-08 16:00:00	\N	\N	106b9824-0d73-4208-920d-6c18ac153506	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2681	1	12	1	[0]	2019-07-08 17:00:00	\N	\N	07f94641-fe47-49d4-8589-3abe5098e945	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2682	1	11	1	[0]	2019-07-08 17:00:00	\N	\N	487fadae-f52a-4952-8bb2-e4d771a6ae13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2683	1	10	1	[0]	2019-07-08 17:00:00	\N	\N	171b5005-2ef3-41b0-9316-ae9102f2bb7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2684	1	9	1	[0]	2019-07-08 17:00:00	\N	\N	8a2610ee-f982-499d-aeec-53c45020428d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2685	1	8	1	[0]	2019-07-08 17:00:00	\N	\N	099627d6-7023-47be-bd2e-d5202b80f2a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2686	1	12	1	[0]	2019-07-08 18:00:00	\N	\N	8df9c44c-14e1-4aac-be93-17e40f7427c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2687	1	11	1	[0]	2019-07-08 18:00:00	\N	\N	f8d4ad5c-fb49-4ead-835d-519a7d35943a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2688	1	10	1	[0]	2019-07-08 18:00:00	\N	\N	87239e9e-dd34-4079-8871-202ff291f984	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2689	1	9	1	[0]	2019-07-08 18:00:00	\N	\N	ca7247c5-3bd4-4a3e-9375-429cb4a280c0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2690	1	8	1	[0]	2019-07-08 18:00:00	\N	\N	e5514107-1078-47e0-89f7-a80d9932f61d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2691	1	12	1	[0]	2019-07-08 19:00:00	\N	\N	2e77caa5-17e4-4beb-afb9-fa11f8853299	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2692	1	11	1	[0]	2019-07-08 19:00:00	\N	\N	9cf5d1c5-8503-4803-a005-b30f46ca158c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2693	1	10	1	[0]	2019-07-08 19:00:00	\N	\N	1e1d32df-22ff-4d57-8a01-c19a0acdd92e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2694	1	9	1	[0]	2019-07-08 19:00:00	\N	\N	6acf7280-b0dc-409d-8f86-28bc6d10e0de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2695	1	8	1	[0]	2019-07-08 19:00:00	\N	\N	7ea98f2b-1ffd-4b1d-ab12-aa137b87413a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2696	1	12	1	[0]	2019-07-08 20:00:00	\N	\N	a3ce3a6f-ec88-4f3d-9b9a-e251a941187e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2697	1	11	1	[0]	2019-07-08 20:00:00	\N	\N	c3348069-8c85-4670-a364-01feef594304	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2698	1	10	1	[0]	2019-07-08 20:00:00	\N	\N	0b8e2f2a-3c0b-4c30-a071-d4d6944f0c7f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2699	1	9	1	[0]	2019-07-08 20:00:00	\N	\N	16b4656f-94d4-497e-a3d8-c7382f951ee3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2700	1	8	1	[0]	2019-07-08 20:00:00	\N	\N	25791b7a-2431-449c-a076-67672141a5e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2701	1	12	1	[0]	2019-07-08 21:00:00	\N	\N	414b01d2-325b-478d-a687-753e14229a2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2702	1	11	1	[0]	2019-07-08 21:00:00	\N	\N	e5470d2c-6840-46fa-a54e-fb740f1f0f4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2703	1	10	1	[0]	2019-07-08 21:00:00	\N	\N	dd8e1784-9904-48e0-aedb-de5ed839dbc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2704	1	9	1	[0]	2019-07-08 21:00:00	\N	\N	743bf7fc-70f1-46c0-a33e-35669a7844fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2705	1	8	1	[0]	2019-07-08 21:00:00	\N	\N	019c5e99-1f65-490f-998d-4d5129d64785	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2706	1	12	1	[0]	2019-07-08 22:00:00	\N	\N	a7fb0087-f543-4260-9893-8fcb6c872865	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2707	1	11	1	[0]	2019-07-08 22:00:00	\N	\N	c5f7ad95-b67a-4e3f-af27-23e03c5a05c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2708	1	10	1	[0]	2019-07-08 22:00:00	\N	\N	34930337-7cb3-4a06-b678-aebaf88baf88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2709	1	9	1	[0]	2019-07-08 22:00:00	\N	\N	c8e29e3d-1fa9-4750-bc2e-5bcdabaf4b6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2710	1	8	1	[0]	2019-07-08 22:00:00	\N	\N	28c0130b-61fb-4d4f-8379-912a84e7f835	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2711	1	12	1	[0]	2019-07-08 23:00:00	\N	\N	8d0558b0-51ca-4c6b-9eb7-439bbab3726b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2712	1	11	1	[0]	2019-07-08 23:00:00	\N	\N	d7f82a86-a161-42f8-b62d-4f03232fd96b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2713	1	10	1	[0]	2019-07-08 23:00:00	\N	\N	b260fa86-1223-4ada-b724-9c0923643a8b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2714	1	9	1	[0]	2019-07-08 23:00:00	\N	\N	0f64fa5d-e95b-49fc-b897-e6c298cf2d37	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2715	1	8	1	[0]	2019-07-08 23:00:00	\N	\N	5c0a8d96-0b54-4aac-80f9-455bce869261	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2716	1	12	1	[0]	2019-07-09 00:00:00	\N	\N	170d8c3c-5aa4-406f-a922-0dfebe64b587	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2717	1	11	1	[0]	2019-07-09 00:00:00	\N	\N	c352451b-feda-470d-9c32-72b285b54978	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2718	1	10	1	[0]	2019-07-09 00:00:00	\N	\N	c73ac64c-92f8-4929-84c7-7bd74a16e687	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2719	1	9	1	[0]	2019-07-09 00:00:00	\N	\N	92ebfe94-3ac3-4ed2-bdf5-985792720c48	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2720	1	8	1	[0]	2019-07-09 00:00:00	\N	\N	8d63608d-9c97-4de7-b4b2-157c7a439415	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2721	1	12	1	[0]	2019-07-09 01:00:00	\N	\N	95f412b8-6754-419a-b47c-efba5e626edd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2722	1	11	1	[0]	2019-07-09 01:00:00	\N	\N	e63c5f04-faea-4288-97bf-221f3b679c54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2723	1	10	1	[0]	2019-07-09 01:00:00	\N	\N	a34077ae-4d2c-4ccc-829e-f796bd8f969c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2724	1	9	1	[0]	2019-07-09 01:00:00	\N	\N	5dfb5e31-e8d4-492e-a768-b5a177f0af67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2725	1	8	1	[0]	2019-07-09 01:00:00	\N	\N	03a21fea-4c56-4947-8089-a1c6ae22ef5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2726	1	12	1	[0]	2019-07-09 02:00:00	\N	\N	d21d0799-3159-4ef4-8454-4c0825a75d94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2727	1	11	1	[0]	2019-07-09 02:00:00	\N	\N	1e0c9a70-bcc6-406c-af9a-2548d089ff42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2728	1	10	1	[0]	2019-07-09 02:00:00	\N	\N	acd3f39a-b873-4c38-a555-da4009273de0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2729	1	9	1	[0]	2019-07-09 02:00:00	\N	\N	d0fc6560-f950-4e9f-9d65-5fadfb727f58	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2730	1	8	1	[0]	2019-07-09 02:00:00	\N	\N	530b071d-05c8-476a-955f-7aecdf5ac0b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2731	1	12	1	[0]	2019-07-09 03:00:00	\N	\N	92bfc3d9-a126-4c71-894d-be6214799a04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2732	1	11	1	[0]	2019-07-09 03:00:00	\N	\N	17909943-46be-4c52-9186-dc7e4bc6167b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2733	1	10	1	[0]	2019-07-09 03:00:00	\N	\N	2913189e-e0cd-4286-8e86-be3dbe2af184	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2734	1	9	1	[0]	2019-07-09 03:00:00	\N	\N	e1879a2f-32c7-4b68-be9f-4028985a92e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2735	1	8	1	[0]	2019-07-09 03:00:00	\N	\N	ba630efd-8d8c-45f2-b4ba-b7cc1201ca32	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2736	1	12	1	[0]	2019-07-09 04:00:00	\N	\N	1f265830-418f-45ff-8bc2-168cd4c638f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2737	1	11	1	[0]	2019-07-09 04:00:00	\N	\N	64c977ce-89ba-4ef0-b724-bdb57a82cdec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2738	1	10	1	[0]	2019-07-09 04:00:00	\N	\N	27863f5f-d839-4b17-b941-f714068c7bbc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2739	1	9	1	[0]	2019-07-09 04:00:00	\N	\N	0cdf9d7c-d1df-4115-a1c3-7f0167425005	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2740	1	8	1	[0]	2019-07-09 04:00:00	\N	\N	b98f0923-7856-436f-8ff9-73d8fc48edb0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2741	1	12	1	[0]	2019-07-09 05:00:00	\N	\N	f08b7aa9-a13f-46b3-b5d2-def0a89eba88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2742	1	11	1	[0]	2019-07-09 05:00:00	\N	\N	e28ef05b-d147-4bf4-ad9c-493bef222774	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2743	1	10	1	[0]	2019-07-09 05:00:00	\N	\N	2fb2c29f-0767-4bf0-b6ff-4bd4f44a53f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2744	1	9	1	[0]	2019-07-09 05:00:00	\N	\N	34be027a-d117-4924-9b26-b62c4b176847	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2745	1	8	1	[0]	2019-07-09 05:00:00	\N	\N	6ea1e577-191c-4439-a270-439be0a9be32	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2746	1	12	1	[0]	2019-07-09 06:00:00	\N	\N	bf3aecb2-59e2-4b4f-8918-2ff25ed7e297	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2747	1	11	1	[0]	2019-07-09 06:00:00	\N	\N	4f145512-f524-40b8-8e0b-a562fbd88dca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2748	1	10	1	[0]	2019-07-09 06:00:00	\N	\N	ec2572ec-91d1-43d5-b5a8-495c656ad067	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2749	1	9	1	[0]	2019-07-09 06:00:00	\N	\N	65837c88-37a0-4be4-b3f2-400def75d952	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2750	1	8	1	[0]	2019-07-09 06:00:00	\N	\N	4ff7089c-5490-440b-9cae-b7255c76c67d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2751	1	12	1	[0]	2019-07-09 07:00:00	\N	\N	ae15ff6c-4416-43e2-82af-f05a9c93b38c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2752	1	11	1	[0]	2019-07-09 07:00:00	\N	\N	021a1972-f91f-41df-b31d-25308c848080	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2753	1	10	1	[0]	2019-07-09 07:00:00	\N	\N	b16b08cc-3839-4635-8015-9ba30fe79971	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2754	1	9	1	[0]	2019-07-09 07:00:00	\N	\N	680d1f7a-84c0-4b61-83da-e76e73cb8d3b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2755	1	8	1	[0]	2019-07-09 07:00:00	\N	\N	d1ef856a-8e78-4231-833b-e70d8603f436	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2756	1	12	1	[0]	2019-07-09 08:00:00	\N	\N	5881723f-0b4c-4e8b-9e2b-20b11fb8d2a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2757	1	11	1	[0]	2019-07-09 08:00:00	\N	\N	127f5542-a61a-4e0f-85be-18cb82514c71	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2758	1	10	1	[0]	2019-07-09 08:00:00	\N	\N	89b3d32e-dac2-408d-ac68-b479ceb417c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2759	1	9	1	[0]	2019-07-09 08:00:00	\N	\N	7a026353-5344-41e4-8959-817402064e94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2760	1	8	1	[0]	2019-07-09 08:00:00	\N	\N	8772afe0-eaed-49dd-a311-4e361baaa630	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2761	1	12	1	[0]	2019-07-09 09:00:00	\N	\N	ea81afb4-37c4-49b0-9600-69d4195631c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2762	1	11	1	[0]	2019-07-09 09:00:00	\N	\N	b6ad3c63-7224-4e4b-9d0d-7c0e48025033	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2763	1	10	1	[0]	2019-07-09 09:00:00	\N	\N	7bd97a3d-c41f-4081-985a-64fa2b345be0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2764	1	9	1	[0]	2019-07-09 09:00:00	\N	\N	77ab8971-0414-4bd0-a2cb-9f52a29a6967	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2765	1	8	1	[0]	2019-07-09 09:00:00	\N	\N	04d05698-3f80-4b44-9afc-c0ec8e5749ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2766	1	12	1	[0]	2019-07-09 10:00:00	\N	\N	34fcae78-3881-4f76-b49d-a5cbffe49e84	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2767	1	11	1	[0]	2019-07-09 10:00:00	\N	\N	dc04af13-1136-4c4f-a082-247bd903a8a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2768	1	10	1	[0]	2019-07-09 10:00:00	\N	\N	3eed7599-843a-4e98-a903-24d2da021eca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2769	1	9	1	[0]	2019-07-09 10:00:00	\N	\N	76989228-3d41-4dc7-bf08-8b862ae4fb4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2770	1	8	1	[0]	2019-07-09 10:00:00	\N	\N	6c371a7c-04ac-4d10-b217-7d92a93f0713	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2771	1	12	1	[0]	2019-07-09 11:00:00	\N	\N	c5ce139a-eb07-4792-a6d6-d92d836563e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2772	1	11	1	[0]	2019-07-09 11:00:00	\N	\N	b08e057e-b1a2-4eb6-b8e8-3ad4fce70b75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2773	1	10	1	[0]	2019-07-09 11:00:00	\N	\N	1f813266-f3a0-45e3-a5a5-4f80fe5bd357	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2774	1	9	1	[0]	2019-07-09 11:00:00	\N	\N	0a7513b7-6579-4247-a6db-27c50b134371	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2775	1	8	1	[0]	2019-07-09 11:00:00	\N	\N	0e22cda6-c682-48fb-9488-a1e4b5f53208	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2776	1	12	1	[0]	2019-07-09 12:00:00	\N	\N	46f6d8a6-50a6-4e51-9c5d-66b1a31f9a14	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2777	1	11	1	[0]	2019-07-09 12:00:00	\N	\N	c2fca35e-e5bc-40eb-bff7-fa809f3c0f32	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2778	1	10	1	[0]	2019-07-09 12:00:00	\N	\N	29613a3c-3938-4aee-9c3e-bb82571a2b8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2779	1	9	1	[0]	2019-07-09 12:00:00	\N	\N	07ee2978-ea89-436a-bd9f-053f67de704e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2780	1	8	1	[0]	2019-07-09 12:00:00	\N	\N	3f9fd66c-70fb-4539-81b7-b1c6000c744a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2781	1	12	1	[0]	2019-07-09 13:00:00	\N	\N	ed1c29ad-7db0-4bcf-bf3d-d7cb7183ea37	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2782	1	11	1	[0]	2019-07-09 13:00:00	\N	\N	bf1d058e-f06b-46b9-97f7-404399ffde75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2783	1	10	1	[0]	2019-07-09 13:00:00	\N	\N	128fc6d9-3975-4d07-8251-24cfb3751911	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2784	1	9	1	[0]	2019-07-09 13:00:00	\N	\N	675dcc87-7e6f-4f2b-ad4c-5de30cb218b8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2785	1	8	1	[0]	2019-07-09 13:00:00	\N	\N	d2a93a66-8638-489d-aa2a-446828fb3594	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2786	1	12	1	[0]	2019-07-09 14:00:00	\N	\N	e930811d-87d3-4f18-9e97-4081494162bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2787	1	11	1	[0]	2019-07-09 14:00:00	\N	\N	3b42901d-71a8-4cda-a345-308ac8b8c086	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2788	1	10	1	[0]	2019-07-09 14:00:00	\N	\N	48a4d1ca-c873-42e4-a2c5-bf6121865dc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2789	1	9	1	[0]	2019-07-09 14:00:00	\N	\N	173ea37b-8806-40cb-912b-e1172c5d6a1c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2790	1	8	1	[0]	2019-07-09 14:00:00	\N	\N	c1e1ac79-f842-4459-9df5-de44e6b00309	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2791	1	12	1	[0]	2019-07-09 15:00:00	\N	\N	df72b7fe-ce3e-478c-b339-cd5c856b10fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2792	1	11	1	[0]	2019-07-09 15:00:00	\N	\N	5b855b84-c1fe-4d2a-8840-f4adb0a032de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2793	1	10	1	[0]	2019-07-09 15:00:00	\N	\N	7f7c04d6-10b4-489e-b211-30cc8fa7ad52	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2794	1	9	1	[0]	2019-07-09 15:00:00	\N	\N	11f56fb2-357b-4042-835b-8094965d76af	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2795	1	8	1	[0]	2019-07-09 15:00:00	\N	\N	123ecdc2-5f80-4100-b46a-94056a0b7e11	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2796	1	12	1	[0]	2019-07-09 16:00:00	\N	\N	08ed4f33-0441-453a-9596-8b2a6fbab1f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2797	1	11	1	[0]	2019-07-09 16:00:00	\N	\N	4bdff2ac-d7e6-4a40-8cd4-043c79935d64	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2798	1	10	1	[0]	2019-07-09 16:00:00	\N	\N	ac081e81-06fa-48f0-b3bd-33f6f60e9cb4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2799	1	9	1	[0]	2019-07-09 16:00:00	\N	\N	9d6a21dd-267d-4452-83b9-4234bb946804	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2800	1	8	1	[0]	2019-07-09 16:00:00	\N	\N	6f7e42fc-67a9-4351-8354-689cc053b59b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2801	1	12	1	[0]	2019-07-09 17:00:00	\N	\N	6e3b81c1-81c2-4229-8345-da84289a99c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2802	1	11	1	[0]	2019-07-09 17:00:00	\N	\N	ab2f5e29-b4db-49d1-b8f8-073d4325ac2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2803	1	10	1	[0]	2019-07-09 17:00:00	\N	\N	884deaa3-9bb3-46a4-beec-dd250c0e4841	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2804	1	9	1	[0]	2019-07-09 17:00:00	\N	\N	55c3c414-18c9-4d69-bb70-e6c64760f69b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2805	1	8	1	[0]	2019-07-09 17:00:00	\N	\N	8d6696a3-8640-4f07-b461-165cea7469ce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2806	1	12	1	[0]	2019-07-09 18:00:00	\N	\N	c578cbce-1e38-401d-a572-1214b1f162da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2807	1	11	1	[0]	2019-07-09 18:00:00	\N	\N	2b7bc2b5-82c8-4f65-ae5f-f941e36234ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2808	1	10	1	[0]	2019-07-09 18:00:00	\N	\N	17230c9c-0fc3-4497-bbf7-147c0a1a7df4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2809	1	9	1	[0]	2019-07-09 18:00:00	\N	\N	3719df84-2203-4fec-93e1-06ac13728cb7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2810	1	8	1	[0]	2019-07-09 18:00:00	\N	\N	f7cdba0b-04ae-4749-bf16-e0ed80e20439	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2811	1	12	1	[0]	2019-07-09 19:00:00	\N	\N	14fcb3a6-114d-41a1-b871-00991a8951a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2812	1	11	1	[0]	2019-07-09 19:00:00	\N	\N	2f61f82e-529b-46c9-a0ca-66327bccebee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2813	1	10	1	[0]	2019-07-09 19:00:00	\N	\N	dc090a64-cf9a-45f5-bda3-4acd16548b38	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2814	1	9	1	[0]	2019-07-09 19:00:00	\N	\N	2be68c14-67fa-4895-bf09-65e4afcc583a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2815	1	8	1	[0]	2019-07-09 19:00:00	\N	\N	0e5ba6ea-5487-4bfe-a5dd-d58af3d06b97	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2816	1	12	1	[0]	2019-07-09 20:00:00	\N	\N	f610f004-dce8-4b4b-89d6-93caddbe3704	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2817	1	11	1	[0]	2019-07-09 20:00:00	\N	\N	c94d326f-af7a-4a06-97a3-b5ca69ac8246	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2818	1	10	1	[0]	2019-07-09 20:00:00	\N	\N	77a795fc-b88b-4b8a-97b6-70fdc4751ef8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2819	1	9	1	[0]	2019-07-09 20:00:00	\N	\N	645ca16c-0fd9-4406-9ec9-fd1054babac5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2820	1	8	1	[0]	2019-07-09 20:00:00	\N	\N	97f8c388-3cc6-4414-8e66-d08f45e98881	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2821	1	12	1	[0]	2019-07-09 21:00:00	\N	\N	3c2616c5-b2b7-4e54-9534-739c94c22788	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2822	1	11	1	[0]	2019-07-09 21:00:00	\N	\N	989f24b4-c948-43dc-9a9d-a3d2ddd9ccfb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2823	1	10	1	[0]	2019-07-09 21:00:00	\N	\N	dca1a906-66b2-4037-89a3-d5597994848f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2824	1	9	1	[0]	2019-07-09 21:00:00	\N	\N	1bd7cbca-7820-4325-a297-c6dcaded3216	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2825	1	8	1	[0]	2019-07-09 21:00:00	\N	\N	e81d099a-bae9-444a-813e-6ddb7367706f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2826	1	12	1	[0]	2019-07-09 22:00:00	\N	\N	8205a44f-dce9-49ba-afe8-80c966dbd46c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2827	1	11	1	[0]	2019-07-09 22:00:00	\N	\N	22168a65-6b06-49d2-aabb-e81b7183af35	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2828	1	10	1	[0]	2019-07-09 22:00:00	\N	\N	b6842c2c-e119-4907-8c29-eed38c058c55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2829	1	9	1	[0]	2019-07-09 22:00:00	\N	\N	b2288a62-b7f1-4091-befc-c4708ea6fb98	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2830	1	8	1	[0]	2019-07-09 22:00:00	\N	\N	5e669766-de25-494a-b6b9-2c50f3727f81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2831	1	12	1	[0]	2019-07-09 23:00:00	\N	\N	895bfd3c-2ae9-44ce-81a3-df63df82767b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2832	1	11	1	[0]	2019-07-09 23:00:00	\N	\N	b611efd9-6210-40bb-92cb-2e3c5b9090ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2833	1	10	1	[0]	2019-07-09 23:00:00	\N	\N	ee4ca31f-977c-4638-99e4-70004665c8eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2834	1	9	1	[0]	2019-07-09 23:00:00	\N	\N	a4059977-22b5-4831-9e8d-57c7825e4a04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2835	1	8	1	[0]	2019-07-09 23:00:00	\N	\N	73980d9a-4b63-4e5f-98e8-98c3904f5be9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2836	1	12	1	[0]	2019-07-10 00:00:00	\N	\N	9e63a73e-4055-4561-aa10-83dc2f08f7e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2837	1	11	1	[0]	2019-07-10 00:00:00	\N	\N	db83cac9-d94c-46aa-a738-92d8ca740abd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2838	1	10	1	[0]	2019-07-10 00:00:00	\N	\N	9943ee88-4124-4e37-ad83-faed82563048	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2839	1	9	1	[0]	2019-07-10 00:00:00	\N	\N	1da7a60c-a312-4674-9de0-3d7491b70a5c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2840	1	8	1	[0]	2019-07-10 00:00:00	\N	\N	2f9e79ec-5a38-4583-a37b-290b6ab71332	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2841	1	12	1	[0]	2019-07-10 01:00:00	\N	\N	b28f9976-3eb3-49d9-9d77-a076daef535b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2842	1	11	1	[0]	2019-07-10 01:00:00	\N	\N	c23fd9f8-c22a-43bf-99bf-2e6697d19615	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2843	1	10	1	[0]	2019-07-10 01:00:00	\N	\N	eb95c81e-4a42-4d5e-81f3-b30c4c5c8b74	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2844	1	9	1	[0]	2019-07-10 01:00:00	\N	\N	1d1974b5-a4fe-4cbe-92d5-43ff4ae83f12	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2845	1	8	1	[0]	2019-07-10 01:00:00	\N	\N	16f4730b-e66f-48db-a665-ea432d4cc041	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2846	1	12	1	[0]	2019-07-10 02:00:00	\N	\N	78b73a72-9409-4576-a52c-c768897db642	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2847	1	11	1	[0]	2019-07-10 02:00:00	\N	\N	743bede2-6d9a-48c8-9029-30618affe1a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2848	1	10	1	[0]	2019-07-10 02:00:00	\N	\N	7bf65903-8eae-485e-9f44-24d2d4aa387c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2849	1	9	1	[0]	2019-07-10 02:00:00	\N	\N	bd5421a1-ca21-4aee-9b40-0b756b78200a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2850	1	8	1	[0]	2019-07-10 02:00:00	\N	\N	83621cdd-ea9a-4344-99cf-9e8607cdce69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2851	1	12	1	[0]	2019-07-10 03:00:00	\N	\N	c4e5e108-378f-4432-8398-7218fc16174c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2852	1	11	1	[0]	2019-07-10 03:00:00	\N	\N	80eeb655-3f29-4223-95ec-c360455694bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2853	1	10	1	[0]	2019-07-10 03:00:00	\N	\N	3dd6e949-4fc1-4a5a-af4c-ab24446e5e1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2854	1	9	1	[0]	2019-07-10 03:00:00	\N	\N	1c7f7e5f-2fdb-4969-a1b1-14e61b18363c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2855	1	8	1	[0]	2019-07-10 03:00:00	\N	\N	553566b6-82ad-40d3-b43e-f5c0fa33e09e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2856	1	12	1	[0]	2019-07-10 04:00:00	\N	\N	6c5d9213-1c25-4519-ae96-fffa3e680361	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2857	1	11	1	[0]	2019-07-10 04:00:00	\N	\N	d55f2104-ce0e-4015-a327-701bc6273a06	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2858	1	10	1	[0]	2019-07-10 04:00:00	\N	\N	f374cea4-aaaa-4f3c-a517-0104b5c3a2f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2859	1	9	1	[0]	2019-07-10 04:00:00	\N	\N	67c57480-4712-4463-a646-8471115aaf72	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2860	1	8	1	[0]	2019-07-10 04:00:00	\N	\N	032ad3b0-564d-4058-b6a9-5f07887f0a0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2861	1	12	1	[0]	2019-07-10 05:00:00	\N	\N	561563a4-4ef7-4b93-b3bb-1fadf82e83d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2862	1	11	1	[0]	2019-07-10 05:00:00	\N	\N	adf4d05a-3522-4492-9ad6-020664e9f67e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2863	1	10	1	[0]	2019-07-10 05:00:00	\N	\N	088694af-365c-4d36-aeb8-8c2f3df78448	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2864	1	9	1	[0]	2019-07-10 05:00:00	\N	\N	d6eba5f4-7064-41e3-9cd8-c8f6aaff4c6c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2865	1	8	1	[0]	2019-07-10 05:00:00	\N	\N	5076f9da-7e30-4844-8579-d6dd29822f24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2866	1	12	1	[0]	2019-07-10 06:00:00	\N	\N	3314e377-2e6f-4067-ab03-9bf4f5c1a664	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2867	1	11	1	[0]	2019-07-10 06:00:00	\N	\N	f7028bb8-ef74-4171-be00-ba2c216000c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2868	1	10	1	[0]	2019-07-10 06:00:00	\N	\N	b5095d05-7775-4407-bfb7-df1629e77fd5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2869	1	9	1	[0]	2019-07-10 06:00:00	\N	\N	d08844f3-4a1e-4e1c-9b04-adf403dcf1c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2870	1	8	1	[0]	2019-07-10 06:00:00	\N	\N	c6c24cfe-5b80-4c7d-b2fa-1612381b46ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2871	1	12	1	[0]	2019-07-10 07:00:00	\N	\N	5e2e8260-5f27-44ab-970a-641f681808ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2872	1	11	1	[0]	2019-07-10 07:00:00	\N	\N	9d7a19cf-2092-454d-af9d-3f0148f2591a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2873	1	10	1	[0]	2019-07-10 07:00:00	\N	\N	4ba0e5ec-ae87-4c06-828e-eba3b2ad8964	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2874	1	9	1	[0]	2019-07-10 07:00:00	\N	\N	ceee1097-7b29-4757-adcc-850472a14a9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2875	1	8	1	[0]	2019-07-10 07:00:00	\N	\N	d9a63685-b8eb-420d-a479-0c796074f846	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2876	1	12	1	[0]	2019-07-10 08:00:00	\N	\N	cbe07fdf-8b19-4912-9622-ef60fcb25441	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2877	1	11	1	[0]	2019-07-10 08:00:00	\N	\N	d61e3c40-84a4-4058-8b1c-2a1140993ed5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2878	1	10	1	[0]	2019-07-10 08:00:00	\N	\N	c2e19301-31a1-41da-99ed-15f81535d7ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2879	1	9	1	[0]	2019-07-10 08:00:00	\N	\N	13e98acf-26dc-40d3-80b4-e282387e6cf4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2880	1	8	1	[0]	2019-07-10 08:00:00	\N	\N	1388a919-b271-489e-82c0-595f08ec3dc2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2881	1	12	1	[0]	2019-07-10 09:00:00	\N	\N	7eee52df-82eb-47d8-ac59-a91d836a4c83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2882	1	11	1	[0]	2019-07-10 09:00:00	\N	\N	a217b04b-3a3b-4c2a-93b5-9cb70e06c955	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2883	1	10	1	[0]	2019-07-10 09:00:00	\N	\N	35b85ef8-90fd-4edd-b76b-a5d2f889f6aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2884	1	9	1	[0]	2019-07-10 09:00:00	\N	\N	88eaaa8d-c131-4185-a0e7-027f774470b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2885	1	8	1	[0]	2019-07-10 09:00:00	\N	\N	44ee225d-6999-4390-a37b-b04b7fbc27b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2886	1	12	1	[0]	2019-07-10 10:00:00	\N	\N	a4d28841-9a87-45d0-aa5c-f765108e3f1b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2887	1	11	1	[0]	2019-07-10 10:00:00	\N	\N	0e69848f-e7ea-44b8-820b-ccb5a73b74ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2888	1	10	1	[0]	2019-07-10 10:00:00	\N	\N	0d7f1880-bfce-4278-929a-348540eed711	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2889	1	9	1	[0]	2019-07-10 10:00:00	\N	\N	c5fbcecb-574d-4398-b1a3-c87dab4857fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2890	1	8	1	[0]	2019-07-10 10:00:00	\N	\N	6ce349f7-2d0b-4fd8-939d-a965611726a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2891	1	12	1	[0]	2019-07-10 11:00:00	\N	\N	ea7ea34e-6976-4fe9-8a1d-99b017ef40b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2892	1	11	1	[0]	2019-07-10 11:00:00	\N	\N	e120afea-2d91-4c3b-b0ac-72b4772522b8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2893	1	10	1	[0]	2019-07-10 11:00:00	\N	\N	db1a0354-627a-4c12-aa07-079108698ce2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2894	1	9	1	[0]	2019-07-10 11:00:00	\N	\N	2ced192d-eed3-46a5-832a-3d37e1abdd98	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2895	1	8	1	[0]	2019-07-10 11:00:00	\N	\N	d55921ca-c3dc-4a61-8890-e9694ac0e4fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2896	1	12	1	[0]	2019-07-10 12:00:00	\N	\N	02f93823-13c2-451c-8db4-4ee74c3ebde0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2897	1	11	1	[0]	2019-07-10 12:00:00	\N	\N	aea54651-f279-44ed-b779-a0e4d993e0b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2898	1	10	1	[0]	2019-07-10 12:00:00	\N	\N	3a04ecea-cc3e-4074-b381-0e563976627a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2899	1	9	1	[0]	2019-07-10 12:00:00	\N	\N	5d705a47-75a6-4981-9eb8-2d5d6aa3f42f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2900	1	8	1	[0]	2019-07-10 12:00:00	\N	\N	b849dcc1-f2d1-4e4a-a1e6-05cd5b66a593	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2901	1	12	1	[0]	2019-07-10 13:00:00	\N	\N	95e7f270-be10-47ef-8662-9ab048a1a9f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2902	1	11	1	[0]	2019-07-10 13:00:00	\N	\N	25dd624a-4457-481a-b809-836e2227629d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2903	1	10	1	[0]	2019-07-10 13:00:00	\N	\N	18115383-e8ed-4702-9975-321875ee8870	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2904	1	9	1	[0]	2019-07-10 13:00:00	\N	\N	4a6b3d1a-56d7-497c-9652-2a5777e274d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2905	1	8	1	[0]	2019-07-10 13:00:00	\N	\N	96e7e74c-6ea5-4ea6-abac-c8e34ac83a1d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2906	1	12	1	[0]	2019-07-10 14:00:00	\N	\N	19aeb815-24e6-4612-b473-2f34abed6307	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2907	1	11	1	[0]	2019-07-10 14:00:00	\N	\N	a08d8d97-ddc9-47c9-b056-9c1695ea183b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2908	1	10	1	[0]	2019-07-10 14:00:00	\N	\N	ed175486-79af-48d9-a294-dae3acfed79b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2909	1	9	1	[0]	2019-07-10 14:00:00	\N	\N	56b48279-234c-46f4-a677-fd4187d5f350	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2910	1	8	1	[0]	2019-07-10 14:00:00	\N	\N	b83e4ee0-92af-4a93-a21d-0cb9dff02577	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2911	1	12	1	[0]	2019-07-10 15:00:00	\N	\N	7d770964-a000-4028-97fd-94abe311def8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2912	1	11	1	[0]	2019-07-10 15:00:00	\N	\N	3c5dbb65-3a61-4987-ac3b-e95c8de7f3dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2913	1	10	1	[0]	2019-07-10 15:00:00	\N	\N	a2edf716-d7ee-4c0f-b32f-17ae9a4bbd33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2914	1	9	1	[0]	2019-07-10 15:00:00	\N	\N	5599f044-b580-454a-9211-6475047f8901	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2915	1	8	1	[0]	2019-07-10 15:00:00	\N	\N	97ee9b78-11ac-4e5f-a47f-424fb2f52371	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2916	1	12	1	[0]	2019-07-10 16:00:00	\N	\N	a1a8d9d2-3682-426d-9015-d7d23aa844e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2917	1	11	1	[0]	2019-07-10 16:00:00	\N	\N	430f68cc-4e55-4b06-8bcc-879131f5b6ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2918	1	10	1	[0]	2019-07-10 16:00:00	\N	\N	bdbc4be9-1deb-4049-9a19-5c18a3b637d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2919	1	9	1	[0]	2019-07-10 16:00:00	\N	\N	3642148f-74e3-45cd-b3d9-1a3a7ca81ed8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2920	1	8	1	[0]	2019-07-10 16:00:00	\N	\N	314fc965-3d19-445e-82cd-9464c0a0a792	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2921	1	12	1	[0]	2019-07-10 17:00:00	\N	\N	9dff9651-ffa0-4aea-8102-c18966adc87e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2922	1	11	1	[0]	2019-07-10 17:00:00	\N	\N	2e673763-adca-4dfa-8b87-9f51bed0854d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2923	1	10	1	[0]	2019-07-10 17:00:00	\N	\N	7932fe5a-8bdb-4fbe-98bb-1d5b0a9bbf1f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2924	1	9	1	[0]	2019-07-10 17:00:00	\N	\N	fced8122-32c9-4a20-addb-29e35ff32cde	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2925	1	8	1	[0]	2019-07-10 17:00:00	\N	\N	b9c682d1-b9d6-4702-8779-6e3063e10c7e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2926	1	12	1	[0]	2019-07-10 18:00:00	\N	\N	9bcab6d1-be0a-46f3-bcdc-de1dc596f2ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2927	1	11	1	[0]	2019-07-10 18:00:00	\N	\N	d7b08b0b-038b-4aa7-9808-6b03efdabc7a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2928	1	10	1	[0]	2019-07-10 18:00:00	\N	\N	a3b6ad2b-0bcb-411b-b18f-1aa95c1d2a28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2929	1	9	1	[0]	2019-07-10 18:00:00	\N	\N	648074a5-9ad8-47b7-bdb5-78a5e68ce74d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2930	1	8	1	[0]	2019-07-10 18:00:00	\N	\N	e4c4563e-0a89-47f3-9610-c11b63a898c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2931	1	12	1	[0]	2019-07-10 19:00:00	\N	\N	07c506e2-4f9e-431a-b2ac-600d77e788ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2932	1	11	1	[0]	2019-07-10 19:00:00	\N	\N	3a424108-7349-4fe5-a4ba-916ad9e8af41	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2933	1	10	1	[0]	2019-07-10 19:00:00	\N	\N	d595049a-14ec-4ef5-8bf2-2dde75528c99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2934	1	9	1	[0]	2019-07-10 19:00:00	\N	\N	bbd5635b-ca48-4bf1-ab4c-08da90b4eba0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2935	1	8	1	[0]	2019-07-10 19:00:00	\N	\N	7bbf9890-de7e-433d-b05f-a15167bf87cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2936	1	12	1	[0]	2019-07-10 20:00:00	\N	\N	83ba80b0-69ca-4041-a632-050b4434555b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2937	1	11	1	[0]	2019-07-10 20:00:00	\N	\N	b56f6171-9ec9-4030-bb98-b57849dcaa14	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2938	1	10	1	[0]	2019-07-10 20:00:00	\N	\N	317b6d30-0f23-4cf3-81e1-0dd8c5a970bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2939	1	9	1	[0]	2019-07-10 20:00:00	\N	\N	9da70a30-dc72-4403-97a9-caa5030b6087	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2940	1	8	1	[0]	2019-07-10 20:00:00	\N	\N	9377b12e-4333-488c-909b-18bd6ef35867	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2941	1	12	1	[0]	2019-07-10 21:00:00	\N	\N	5b362eb6-3407-46d4-b361-f175e1620706	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2942	1	11	1	[0]	2019-07-10 21:00:00	\N	\N	073ae699-a2ad-453f-9027-6038d258d660	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2943	1	10	1	[0]	2019-07-10 21:00:00	\N	\N	b8ac16f1-3458-4858-abcc-30b9a516b5d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2944	1	9	1	[0]	2019-07-10 21:00:00	\N	\N	f31e0779-8b10-45bc-b85b-1c2656ab5be5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2945	1	8	1	[0]	2019-07-10 21:00:00	\N	\N	8311b1aa-3710-448d-aabc-3796820129fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2946	1	12	1	[0]	2019-07-10 22:00:00	\N	\N	6c9fb259-b9ff-4603-86ea-a7d5ee3f9d90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2947	1	11	1	[0]	2019-07-10 22:00:00	\N	\N	1a9432b1-c4a8-4b8e-9b95-d5eb4dba0c3d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2948	1	10	1	[0]	2019-07-10 22:00:00	\N	\N	3850c1f2-aebb-4ad9-93d9-4a34a420409a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2949	1	9	1	[0]	2019-07-10 22:00:00	\N	\N	f8c4ff62-4f32-4c01-81f4-3d501fa00693	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2950	1	8	1	[0]	2019-07-10 22:00:00	\N	\N	949696f1-0b16-4e86-9f17-e4660974e005	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2951	1	12	1	[0]	2019-07-10 23:00:00	\N	\N	103e78d0-07a7-4bfa-ab6c-8de69c25b281	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2952	1	11	1	[0]	2019-07-10 23:00:00	\N	\N	86516c6d-8a8d-46d3-8ea4-2f48cd11b051	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2953	1	10	1	[0]	2019-07-10 23:00:00	\N	\N	7bd2e797-6100-4e89-b42f-19931395e6d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2954	1	9	1	[0]	2019-07-10 23:00:00	\N	\N	a6460715-ca88-4e14-8824-84adeb512422	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2955	1	8	1	[0]	2019-07-10 23:00:00	\N	\N	3b73e2ae-31ea-446a-a23c-be639951bafa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2956	1	12	1	[0]	2019-07-11 00:00:00	\N	\N	03da0c96-190a-44a5-87e5-06bb1b109fc0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2957	1	11	1	[0]	2019-07-11 00:00:00	\N	\N	961d13e7-ba0f-45bb-81fb-8e29efbd2780	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2958	1	10	1	[0]	2019-07-11 00:00:00	\N	\N	2a235890-9876-4bfe-8d1c-61cd1b4ec254	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2959	1	9	1	[0]	2019-07-11 00:00:00	\N	\N	455fcd9b-3116-4a0d-b661-ca9869e3ea17	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2960	1	8	1	[0]	2019-07-11 00:00:00	\N	\N	ede97f35-7250-442d-a34e-a756da199530	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2961	1	12	1	[0]	2019-07-11 01:00:00	\N	\N	4637d234-049e-4a43-ac99-462238fe9d84	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2962	1	11	1	[0]	2019-07-11 01:00:00	\N	\N	2bb10486-f2cb-4821-ad7f-5c286af14293	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2963	1	10	1	[0]	2019-07-11 01:00:00	\N	\N	d47a6cd0-aa44-4d41-b45a-334dc9bb36dd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2964	1	9	1	[0]	2019-07-11 01:00:00	\N	\N	20cd3c72-aa73-4ccb-86f2-579d1777e808	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2965	1	8	1	[0]	2019-07-11 01:00:00	\N	\N	56aaafca-bb4c-4516-b526-2d1020dd264e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2966	1	12	1	[0]	2019-07-11 02:00:00	\N	\N	8f1a0a49-a03f-4e52-8434-43c3c831c7e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2967	1	11	1	[0]	2019-07-11 02:00:00	\N	\N	062b339a-021f-43b6-8265-5533a90f2a77	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2968	1	10	1	[0]	2019-07-11 02:00:00	\N	\N	32baa31c-801b-468f-b2fc-a8946254f040	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2969	1	9	1	[0]	2019-07-11 02:00:00	\N	\N	24882282-f864-45a6-bff8-b0820af615f8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2970	1	8	1	[0]	2019-07-11 02:00:00	\N	\N	f956a31c-73f2-4f29-8ca8-130942a4e114	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2971	1	12	1	[0]	2019-07-11 03:00:00	\N	\N	ffddf309-11e3-4f13-a6dd-bd565f69efdd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2972	1	11	1	[0]	2019-07-11 03:00:00	\N	\N	5ca2b0ed-c5d5-4f39-9e9d-caea3823f7fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2973	1	10	1	[0]	2019-07-11 03:00:00	\N	\N	ef4e80c7-f73a-4546-ac57-ab2200ef80a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2974	1	9	1	[0]	2019-07-11 03:00:00	\N	\N	e5ed4911-5a4f-4845-a35f-f6906be510b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2975	1	8	1	[0]	2019-07-11 03:00:00	\N	\N	b397acd4-75ba-419b-b209-17d74cbaee77	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2976	1	12	1	[0]	2019-07-11 04:00:00	\N	\N	ab600963-75fa-4b2f-9d7c-8e4ee0f79f59	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2977	1	11	1	[0]	2019-07-11 04:00:00	\N	\N	e1cba9dd-9286-4159-8021-c2c352c8b152	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2978	1	10	1	[0]	2019-07-11 04:00:00	\N	\N	d08fa254-3133-4989-8953-314ac832031a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2979	1	9	1	[0]	2019-07-11 04:00:00	\N	\N	9f2ed848-6561-48b9-ab81-18f11d7014e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2980	1	8	1	[0]	2019-07-11 04:00:00	\N	\N	1cb15a12-2776-4a92-9caf-3b32801994aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2981	1	12	1	[0]	2019-07-11 05:00:00	\N	\N	00719e81-47c1-4855-b6f1-1263f74db34f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2982	1	11	1	[0]	2019-07-11 05:00:00	\N	\N	35c68a33-739d-4711-b4f9-5454e1b6416f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2983	1	10	1	[0]	2019-07-11 05:00:00	\N	\N	c3ec20cd-bfe8-4370-ba8a-826e3e5b642b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2984	1	9	1	[0]	2019-07-11 05:00:00	\N	\N	27f52725-a1b5-44bf-8aaf-e617c90a2abf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2985	1	8	1	[0]	2019-07-11 05:00:00	\N	\N	f74e9f6b-2bec-426a-b2e3-fcd7be119b77	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2986	1	12	1	[0]	2019-07-11 06:00:00	\N	\N	876ad8f1-7fb9-4cdf-baa7-e4dc68b3040f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2987	1	11	1	[0]	2019-07-11 06:00:00	\N	\N	fd582448-cd36-4356-b75f-8c22e81fbfbc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2988	1	10	1	[0]	2019-07-11 06:00:00	\N	\N	20306ec3-657f-4caf-8542-683299b704f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2989	1	9	1	[0]	2019-07-11 06:00:00	\N	\N	11b595f7-21cf-4b2f-b975-8a5acc6844a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2990	1	8	1	[0]	2019-07-11 06:00:00	\N	\N	3c8c34c2-70bc-4efb-9845-3bff4bd54021	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2991	1	12	1	[0]	2019-07-11 07:00:00	\N	\N	62a02cf6-be03-4a57-bbfe-dc4b0cb62f5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2992	1	11	1	[0]	2019-07-11 07:00:00	\N	\N	d3b059d6-51d7-4510-aa5b-e968d53cdf6c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2993	1	10	1	[0]	2019-07-11 07:00:00	\N	\N	f673c25f-97b4-4139-8537-55ab6be0c7f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2994	1	9	1	[0]	2019-07-11 07:00:00	\N	\N	e053710d-a15c-49d5-bac8-b4cb5eb63ce0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2995	1	8	1	[0]	2019-07-11 07:00:00	\N	\N	6aad93cf-a44f-4e8b-9864-21cca04eb169	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2996	1	12	1	[0]	2019-07-11 08:00:00	\N	\N	3c7a4b67-c2ef-4a77-8723-fa212d4dc6f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2997	1	11	1	[0]	2019-07-11 08:00:00	\N	\N	6a34ace6-5be9-40b2-9996-8e4dec0386fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2998	1	10	1	[0]	2019-07-11 08:00:00	\N	\N	8bc75f04-6892-406f-94ec-ef7b7fe953e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
2999	1	9	1	[0]	2019-07-11 08:00:00	\N	\N	fb64c412-5e67-4c62-b0f5-8e7824b605fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3000	1	8	1	[0]	2019-07-11 08:00:00	\N	\N	3158ca5f-8d28-46b6-af79-0cb9e4991d70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3001	1	12	1	[0]	2019-07-11 09:00:00	\N	\N	2bae2917-e5be-4a10-bb30-bcaf2176389d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3002	1	11	1	[0]	2019-07-11 09:00:00	\N	\N	5708fe07-d917-4a73-9593-8b8e241ae23c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3003	1	10	1	[0]	2019-07-11 09:00:00	\N	\N	cf2953f7-7980-4e93-9abd-5c957bc9d23d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3004	1	9	1	[0]	2019-07-11 09:00:00	\N	\N	196209d5-335c-4c23-8bdd-72d41e23cfb1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3005	1	8	1	[0]	2019-07-11 09:00:00	\N	\N	d3c3c52e-f389-492a-b39e-0c7f26246447	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3006	1	12	1	[0]	2019-07-11 10:00:00	\N	\N	e5793910-518b-48f3-a026-91e15f629165	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3007	1	11	1	[0]	2019-07-11 10:00:00	\N	\N	259d27f3-0509-49fe-aa5a-d04664c7df15	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3008	1	10	1	[0]	2019-07-11 10:00:00	\N	\N	3e538b39-a5ea-45d9-8486-96f47b2be999	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3009	1	9	1	[0]	2019-07-11 10:00:00	\N	\N	253507d1-d40d-4cfe-ae2e-c4abfca1957a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3010	1	8	1	[0]	2019-07-11 10:00:00	\N	\N	84ee0b20-3afb-4a2b-b9c0-2769df80595b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3011	1	12	1	[0]	2019-07-11 11:00:00	\N	\N	b47e4765-ac49-4e2d-886d-baa04682bf04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3012	1	11	1	[0]	2019-07-11 11:00:00	\N	\N	59a9499f-3212-445a-a745-974b276dac3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3013	1	10	1	[0]	2019-07-11 11:00:00	\N	\N	2ed6d8cd-31e5-4f12-9821-d02ba23cd577	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3014	1	9	1	[0]	2019-07-11 11:00:00	\N	\N	e8559d3e-dc32-4e7e-9faf-7ef1bf15b035	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3015	1	8	1	[0]	2019-07-11 11:00:00	\N	\N	f4a68bfc-38a6-478e-9fe9-251d87b1cf0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3016	1	12	1	[0]	2019-07-11 12:00:00	\N	\N	c2e044a1-9c7c-4ada-9ba0-7461a466468a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3017	1	11	1	[0]	2019-07-11 12:00:00	\N	\N	c6665fa4-7e71-4b16-bbf6-e4896737acb0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3018	1	10	1	[0]	2019-07-11 12:00:00	\N	\N	a7d587aa-dc0b-4ece-9607-932c9a777694	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3019	1	9	1	[0]	2019-07-11 12:00:00	\N	\N	8e674a17-3380-4cd7-bbfc-9180ea365dae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3020	1	8	1	[0]	2019-07-11 12:00:00	\N	\N	ab9edc17-097e-4830-97c8-f8804a04a01f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3021	1	12	1	[0]	2019-07-11 13:00:00	\N	\N	09cb3e46-cda4-490a-87ef-ae62f333b8d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3022	1	11	1	[0]	2019-07-11 13:00:00	\N	\N	5ccd9ee1-907c-4252-9bfb-967295e83364	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3023	1	10	1	[0]	2019-07-11 13:00:00	\N	\N	39bd766a-3250-4382-be02-5d206ac21acb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3024	1	9	1	[0]	2019-07-11 13:00:00	\N	\N	376ae4f3-81e5-4be0-b834-983ada169551	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3025	1	8	1	[0]	2019-07-11 13:00:00	\N	\N	f0c061a6-e15d-42a3-a893-2da23b6d32ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3026	1	12	1	[0]	2019-07-11 14:00:00	\N	\N	a3a4348b-4525-4c4a-b00b-8d64a57c7cf5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3027	1	11	1	[0]	2019-07-11 14:00:00	\N	\N	e6df755e-cdea-4694-8d10-0c6890232d40	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3028	1	10	1	[0]	2019-07-11 14:00:00	\N	\N	8f7b805a-0962-47e7-9e5a-34e35adaf274	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3029	1	9	1	[0]	2019-07-11 14:00:00	\N	\N	ae92d48b-f33e-4106-a083-94c1d70250a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3030	1	8	1	[0]	2019-07-11 14:00:00	\N	\N	3e4d0474-6ffb-48ac-8fa3-96e19959f8c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3031	1	12	1	[0]	2019-07-11 15:00:00	\N	\N	6311a774-4a4f-4cbb-9899-2d640a2cdda6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3032	1	11	1	[0]	2019-07-11 15:00:00	\N	\N	6dc6e565-38ad-495d-905c-0ed5ecdd12eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3033	1	10	1	[0]	2019-07-11 15:00:00	\N	\N	16e79976-51c2-4c8c-9619-3671c3be501c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3034	1	9	1	[0]	2019-07-11 15:00:00	\N	\N	83ac039f-950f-45f8-bb91-032af4fcfc60	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3035	1	8	1	[0]	2019-07-11 15:00:00	\N	\N	4a5ebfcf-eb28-4b7e-a354-e4fa0a3a2418	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3036	1	12	1	[0]	2019-07-11 16:00:00	\N	\N	094f5c7d-ef08-4804-bbba-09d136945816	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3037	1	11	1	[0]	2019-07-11 16:00:00	\N	\N	6ab08cc5-7794-4573-8716-5a5478154d92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3038	1	10	1	[0]	2019-07-11 16:00:00	\N	\N	454c0cb8-6b36-4a91-a886-addeefed6031	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3039	1	9	1	[0]	2019-07-11 16:00:00	\N	\N	b859cafd-778f-4113-beeb-25a448441d9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3040	1	8	1	[0]	2019-07-11 16:00:00	\N	\N	ffd8c34b-278c-469a-956c-b7f499f8adda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3041	1	12	1	[0]	2019-07-11 17:00:00	\N	\N	3df1c2e7-e6b7-4bb9-b084-ce232dc00cd2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3042	1	11	1	[0]	2019-07-11 17:00:00	\N	\N	bfcd3064-e56f-4d5b-b751-dd3467ad06c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3043	1	10	1	[0]	2019-07-11 17:00:00	\N	\N	2c9112a7-af12-4454-8ffa-ffe69563b9f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3044	1	9	1	[0]	2019-07-11 17:00:00	\N	\N	e53c4263-5d8e-4716-80bc-4386ed66eb94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3045	1	8	1	[0]	2019-07-11 17:00:00	\N	\N	2dcf2d01-541b-4bb2-9e74-f401349746ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3046	1	12	1	[0]	2019-07-11 18:00:00	\N	\N	4c7e270d-99ad-4608-805b-afaea08d6739	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3047	1	11	1	[0]	2019-07-11 18:00:00	\N	\N	8d57df09-b188-4de0-aec1-5315431451aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3048	1	10	1	[0]	2019-07-11 18:00:00	\N	\N	a543d3d7-d638-4102-aeee-f1074499abea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3049	1	9	1	[0]	2019-07-11 18:00:00	\N	\N	09e117ff-f004-406d-8a28-801423d7ccd2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3050	1	8	1	[0]	2019-07-11 18:00:00	\N	\N	d36ad103-20b2-4109-99da-95f4ccb187bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3051	1	12	1	[0]	2019-07-11 19:00:00	\N	\N	cc7bd335-60f8-4501-b0c7-10072a0dcb5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3052	1	11	1	[0]	2019-07-11 19:00:00	\N	\N	e7463d74-cfff-4d14-86f0-5667cd16c582	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3053	1	10	1	[0]	2019-07-11 19:00:00	\N	\N	9ef5b405-c80c-47b1-9ec6-24c3b039fed6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3054	1	9	1	[0]	2019-07-11 19:00:00	\N	\N	022e7f92-b365-41ae-9aa6-68318c1c2c91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3055	1	8	1	[0]	2019-07-11 19:00:00	\N	\N	13dc051b-d1f2-4572-b655-3e642b8b35b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3056	1	12	1	[0]	2019-07-11 20:00:00	\N	\N	6d2d88a0-d7ad-4543-897b-62f36b204a1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3057	1	11	1	[0]	2019-07-11 20:00:00	\N	\N	597bd273-f0be-4e1d-8324-7c7e99ced5b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3058	1	10	1	[0]	2019-07-11 20:00:00	\N	\N	ed3d19f4-0c44-457f-866a-ffa0092733b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3059	1	9	1	[0]	2019-07-11 20:00:00	\N	\N	8eadc5fc-7c2f-40e5-ac56-1d85be406c0f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3060	1	8	1	[0]	2019-07-11 20:00:00	\N	\N	14b09f55-c789-4890-b6f9-0520c2ef8813	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3061	1	12	1	[0]	2019-07-11 21:00:00	\N	\N	b286841c-5610-4692-abc1-408988554b81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3062	1	11	1	[0]	2019-07-11 21:00:00	\N	\N	8f479289-f2b5-4b73-8f5d-c6a28c76f7fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3063	1	10	1	[0]	2019-07-11 21:00:00	\N	\N	8f2cb8de-cda2-411d-8b4b-44cfe571fc65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3064	1	9	1	[0]	2019-07-11 21:00:00	\N	\N	eacc5fe4-1594-4d31-a672-fa2cbd1a556f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3065	1	8	1	[0]	2019-07-11 21:00:00	\N	\N	cd96d9ee-279a-4be4-b979-6e4dce862c5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3066	1	12	1	[0]	2019-07-11 22:00:00	\N	\N	de54e8ae-8987-438d-820b-67d5f90baa94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3067	1	11	1	[0]	2019-07-11 22:00:00	\N	\N	3f8d3097-4281-4fcb-8d41-d2d23c859c91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3068	1	10	1	[0]	2019-07-11 22:00:00	\N	\N	a1e69181-6afb-4031-80f1-4c08647210ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3069	1	9	1	[0]	2019-07-11 22:00:00	\N	\N	9f488143-8f8e-4e95-b38b-ed2bf940ab17	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3070	1	8	1	[0]	2019-07-11 22:00:00	\N	\N	b11a5678-2bec-4f4c-82fe-ad73f6d91a62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3071	1	12	1	[0]	2019-07-11 23:00:00	\N	\N	aad21fc0-5b75-4b68-8479-fea16415b45f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3072	1	11	1	[0]	2019-07-11 23:00:00	\N	\N	46df2a35-3ae6-4746-ba67-0982f6e0a2e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3073	1	10	1	[0]	2019-07-11 23:00:00	\N	\N	da2155b2-2481-4564-9b02-7b9e1aff3def	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3074	1	9	1	[0]	2019-07-11 23:00:00	\N	\N	77584730-5a15-40df-abb0-217387de3a51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3075	1	8	1	[0]	2019-07-11 23:00:00	\N	\N	fd990643-7a9e-48e1-b9c5-e9b1c14883d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3076	1	12	1	[0]	2019-07-12 00:00:00	\N	\N	9b4ff5df-82eb-4e59-b88f-270fdfc7a8cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3077	1	11	1	[0]	2019-07-12 00:00:00	\N	\N	2fbafaa4-c0e5-412b-b7cc-e1548fed69a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3078	1	10	1	[0]	2019-07-12 00:00:00	\N	\N	9d051a31-b834-4e98-8a1a-dd8860955101	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3079	1	9	1	[0]	2019-07-12 00:00:00	\N	\N	aafb6281-ccbd-4bc7-89f3-fa28fb4d22b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3080	1	8	1	[0]	2019-07-12 00:00:00	\N	\N	d7ba0d15-c3f7-4984-b995-a5acef9ad05c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3081	1	12	1	[0.200000003]	2019-07-12 01:00:00	\N	\N	71227281-2f38-492f-9cb2-670d208f3149	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3082	1	11	1	[0]	2019-07-12 01:00:00	\N	\N	8d59b071-04d4-4e88-bdf1-40d4f8c7f452	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3083	1	10	1	[0]	2019-07-12 01:00:00	\N	\N	b6d22f86-9c00-4914-bac4-9bc04d9048cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3084	1	9	1	[0]	2019-07-12 01:00:00	\N	\N	267cae18-88fa-4674-84ed-33700742c5aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3085	1	8	1	[0]	2019-07-12 01:00:00	\N	\N	fc985033-c060-43fc-a7a5-2edfc647f921	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3086	1	12	1	[0.400000006]	2019-07-12 02:00:00	\N	\N	f976a977-8fcc-4f12-be12-7bb1403ae962	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3087	1	11	1	[0]	2019-07-12 02:00:00	\N	\N	450d2a86-8cca-4808-a91c-7e91c106910b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3088	1	10	1	[0]	2019-07-12 02:00:00	\N	\N	2bd1e8c4-0d0f-40b0-8b24-7bd8902a847b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3089	1	9	1	[0]	2019-07-12 02:00:00	\N	\N	46d0abad-7e15-42e3-a264-92b8e3725da8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3090	1	8	1	[0.200000003]	2019-07-12 02:00:00	\N	\N	d03f12c1-9568-4700-80f1-b101a880f389	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3091	1	12	1	[0]	2019-07-12 03:00:00	\N	\N	ed950d4e-836e-47b7-8ada-b7f56df5ad70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3092	1	11	1	[0]	2019-07-12 03:00:00	\N	\N	aefffa97-303b-4eff-bf9c-974a4a94310a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3093	1	10	1	[0]	2019-07-12 03:00:00	\N	\N	0251b916-935e-4763-bf39-c7261dcaf915	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3094	1	9	1	[0]	2019-07-12 03:00:00	\N	\N	b9870d6f-2c44-4707-9395-43cb97b1f794	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3095	1	8	1	[0.400000006]	2019-07-12 03:00:00	\N	\N	81fe49d3-e0e9-44cd-92c9-3254c4650680	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3096	1	12	1	[0]	2019-07-12 04:00:00	\N	\N	bc4ee75d-6916-4511-aec5-078bd5588bed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3097	1	11	1	[0]	2019-07-12 04:00:00	\N	\N	52b17af3-7ecc-40e5-9c52-f7c8c8f167a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3098	1	10	1	[0]	2019-07-12 04:00:00	\N	\N	fed82512-c653-413a-8bc8-3d92bea93757	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3099	1	9	1	[0]	2019-07-12 04:00:00	\N	\N	003ee6d6-0d1d-41e4-85a4-412e14c7eafc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3100	1	8	1	[0]	2019-07-12 04:00:00	\N	\N	59d47e28-cbdf-401a-af20-0158527a9090	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3101	1	12	1	[0.200000003]	2019-07-12 05:00:00	\N	\N	0ff58578-10b8-4761-a442-23d73859a6f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3102	1	11	1	[0]	2019-07-12 05:00:00	\N	\N	52bd6aeb-762c-49d9-9c97-8465df1f72f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3103	1	10	1	[0]	2019-07-12 05:00:00	\N	\N	b24181ae-1995-4a61-b50f-359789265964	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3104	1	9	1	[0]	2019-07-12 05:00:00	\N	\N	c2e722d1-8cdf-4d95-8163-9e28ff5ac044	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3105	1	8	1	[0.200000003]	2019-07-12 05:00:00	\N	\N	4441993c-2244-41c7-bda0-9fd6eb428570	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3106	1	12	1	[0]	2019-07-12 06:00:00	\N	\N	5db81705-7614-4fb0-83c0-d331ee8c76b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3107	1	11	1	[0.200000003]	2019-07-12 06:00:00	\N	\N	96cf30d4-5d7c-47f2-af6f-421a9770730a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3108	1	10	1	[0.200000003]	2019-07-12 06:00:00	\N	\N	8cc70278-427a-48cc-adaf-ad1c9b905fab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3109	1	9	1	[0]	2019-07-12 06:00:00	\N	\N	979fcb97-d422-43eb-9ef7-25719f1e580a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3110	1	8	1	[0.200000003]	2019-07-12 06:00:00	\N	\N	bc78b62f-c468-4c3b-a4ad-b863d90b512f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3111	1	12	1	[0]	2019-07-12 07:00:00	\N	\N	124ed2e0-6622-481d-9dd7-fe9b05f0b7ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3112	1	11	1	[0]	2019-07-12 07:00:00	\N	\N	78d2df37-c493-4405-8ccd-bd9c68f71fb9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3113	1	10	1	[0.200000003]	2019-07-12 07:00:00	\N	\N	5630b277-9638-474f-b54c-809d2dbf0915	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3114	1	9	1	[0.200000003]	2019-07-12 07:00:00	\N	\N	00c7b964-26b7-4057-be6c-3fe7e878fa0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3115	1	8	1	[0.200000003]	2019-07-12 07:00:00	\N	\N	6c90f6e9-6f58-4b62-8205-630fa2b5df80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3116	1	12	1	[0]	2019-07-12 08:00:00	\N	\N	e9a51180-36cb-45ca-81a6-be28628d68d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3117	1	11	1	[0]	2019-07-12 08:00:00	\N	\N	88026d66-c79e-49f6-9415-1428f81d6f23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3118	1	10	1	[0]	2019-07-12 08:00:00	\N	\N	be48cf47-d64a-44af-8a47-944bc6ad296c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3119	1	9	1	[0]	2019-07-12 08:00:00	\N	\N	4729ab1f-0846-44f2-b084-ca8087b3be11	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3120	1	8	1	[0]	2019-07-12 08:00:00	\N	\N	2345766f-754e-41b6-8c03-2b9c64cc7fdf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3121	1	12	1	[0]	2019-07-12 09:00:00	\N	\N	1a6516a4-1525-4453-8c07-f33c90d37c4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3122	1	11	1	[0]	2019-07-12 09:00:00	\N	\N	8642532a-070a-4426-9b02-5f152d923225	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3123	1	10	1	[0]	2019-07-12 09:00:00	\N	\N	7ac1915c-5982-46b9-872b-1425d5abdc8f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3124	1	9	1	[0]	2019-07-12 09:00:00	\N	\N	f449a412-9f38-45ae-9f68-43d95f938ed9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3125	1	8	1	[0]	2019-07-12 09:00:00	\N	\N	0ca59cad-8c9a-47bd-a71a-a8ebad84a23c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3126	1	12	1	[0]	2019-07-12 10:00:00	\N	\N	6a1fd77f-1e40-4075-92fd-73fb8581cb30	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3127	1	11	1	[0]	2019-07-12 10:00:00	\N	\N	951e1913-6c3a-4e98-8fa9-33bb5de49c69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3128	1	10	1	[0]	2019-07-12 10:00:00	\N	\N	9438c016-3335-467e-a89a-07d5ae2678e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3129	1	9	1	[0]	2019-07-12 10:00:00	\N	\N	f3b795d1-adab-4658-9004-0fa3fe50b469	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3130	1	8	1	[0]	2019-07-12 10:00:00	\N	\N	f3c6f080-b797-41f9-a8e4-34722dfb7f42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3131	1	12	1	[0]	2019-07-12 11:00:00	\N	\N	f3f87df1-2a5f-4b00-a41f-4a8bbb6942dd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3132	1	11	1	[0]	2019-07-12 11:00:00	\N	\N	e0f10893-46ae-412e-81ea-08dd76b1049a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3133	1	10	1	[0]	2019-07-12 11:00:00	\N	\N	3806cc91-0385-4730-8445-483716dde8bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3134	1	9	1	[0]	2019-07-12 11:00:00	\N	\N	96a078ca-578e-4780-98d1-838da7881b98	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3135	1	8	1	[0]	2019-07-12 11:00:00	\N	\N	14a80343-ac0c-4aa4-a20a-143b8f9cc76e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3136	1	12	1	[0]	2019-07-12 12:00:00	\N	\N	6e8b68be-e46e-4c49-9191-4696bd4b11dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3137	1	11	1	[0]	2019-07-12 12:00:00	\N	\N	0454e6f4-2169-417a-bdff-0092b6b57e4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3138	1	10	1	[0]	2019-07-12 12:00:00	\N	\N	18039c13-7c92-473e-831c-1fdee4f86ff5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3139	1	9	1	[0]	2019-07-12 12:00:00	\N	\N	2055fcfa-1474-48d4-819a-5cb96201c6a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3140	1	8	1	[0]	2019-07-12 12:00:00	\N	\N	b7563018-b66f-48a0-bc02-8ce2f99999c9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3141	1	12	1	[0]	2019-07-12 13:00:00	\N	\N	d17a07b6-cc73-484d-8292-7427ce680ce6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3142	1	11	1	[0]	2019-07-12 13:00:00	\N	\N	fdc93eb7-bbbe-4afd-9548-dbc6085a4faa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3143	1	10	1	[0]	2019-07-12 13:00:00	\N	\N	025a34bb-0b31-4490-b817-dacab0b1b5fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3144	1	9	1	[0]	2019-07-12 13:00:00	\N	\N	680bb0e7-0126-44d8-bbd5-d605407484d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3145	1	8	1	[0]	2019-07-12 13:00:00	\N	\N	f5d6f738-fdc3-49d0-a0d2-5d8f4d2fdb33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3146	1	12	1	[0]	2019-07-12 14:00:00	\N	\N	56cd1b74-1953-4b08-88ec-1e714ccb5a6f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3147	1	11	1	[0]	2019-07-12 14:00:00	\N	\N	f4f2ce2e-c7cb-4178-9795-e703a9dfcf8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3148	1	10	1	[0]	2019-07-12 14:00:00	\N	\N	37c10972-d668-4339-af3f-76a799d7df46	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3149	1	9	1	[0]	2019-07-12 14:00:00	\N	\N	58ccffac-aefd-437b-98f5-400ddfda2c09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3150	1	8	1	[0]	2019-07-12 14:00:00	\N	\N	78e3b9e2-0c80-414e-a70f-374435d7bdab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3151	1	12	1	[0]	2019-07-12 15:00:00	\N	\N	0ef09c06-33f2-4b4c-a3e0-cb01a19cef26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3152	1	11	1	[0]	2019-07-12 15:00:00	\N	\N	5c9389f5-a983-4570-b8cf-c63d1ccbb7ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3153	1	10	1	[0]	2019-07-12 15:00:00	\N	\N	fa17acb7-f5e3-47de-ba6c-0c2967f36c4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3154	1	9	1	[0]	2019-07-12 15:00:00	\N	\N	644637e3-55ed-41ae-aa64-01e97ee47317	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3155	1	8	1	[0]	2019-07-12 15:00:00	\N	\N	fdb2b41b-ac6c-437d-bf99-d41f790f8794	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3156	1	12	1	[0]	2019-07-12 16:00:00	\N	\N	c3aef488-205a-475d-ae56-8d22c3ed6eb5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3157	1	11	1	[0]	2019-07-12 16:00:00	\N	\N	eeca72ea-4770-408b-acd8-c0dd5b6a10d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3158	1	10	1	[0]	2019-07-12 16:00:00	\N	\N	2cdb39d9-90cb-4630-bd42-3ab5847d8cbe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3159	1	9	1	[0]	2019-07-12 16:00:00	\N	\N	811337d6-652d-442f-b4b3-a09662f5da71	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3160	1	8	1	[0]	2019-07-12 16:00:00	\N	\N	ff9e7323-8f8a-4265-9c6e-586a24bbfe78	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3161	1	12	1	[0]	2019-07-12 17:00:00	\N	\N	65b48691-1898-40d1-ac42-6805f5bfec6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3162	1	11	1	[0]	2019-07-12 17:00:00	\N	\N	fed7e736-3165-498c-8a24-d3d89f028e16	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3163	1	10	1	[0]	2019-07-12 17:00:00	\N	\N	2e6345aa-9b8b-4917-a209-23deb2e55417	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3164	1	9	1	[0]	2019-07-12 17:00:00	\N	\N	ce7b021a-1fe7-44b9-9498-2a2604e32a78	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3165	1	8	1	[0]	2019-07-12 17:00:00	\N	\N	3389d712-94e6-4dba-ad96-0d12c0609681	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3166	1	12	1	[0]	2019-07-12 18:00:00	\N	\N	e0a24797-1694-4685-b9fa-ec4f5621c786	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3167	1	11	1	[0]	2019-07-12 18:00:00	\N	\N	45258882-09cd-48a1-a9c5-3e85fc612819	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3168	1	10	1	[0]	2019-07-12 18:00:00	\N	\N	add92e67-c339-4c28-a351-ed782125dc3f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3169	1	9	1	[0]	2019-07-12 18:00:00	\N	\N	80ce1648-dfd0-424d-b687-3f24d88d8e44	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3170	1	8	1	[0]	2019-07-12 18:00:00	\N	\N	fcfe387d-91b1-4ce7-b7c0-add25b003e55	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3171	1	12	1	[0]	2019-07-12 19:00:00	\N	\N	35b6fd49-8fd4-432d-a845-d578e7c94cde	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3172	1	11	1	[0]	2019-07-12 19:00:00	\N	\N	b44e8356-bb9e-4dd6-8a11-bb7bc81b9056	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3173	1	10	1	[0]	2019-07-12 19:00:00	\N	\N	2fd994c1-9d91-497b-96e9-0fd4bd2ff667	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3174	1	9	1	[0]	2019-07-12 19:00:00	\N	\N	d1f9d1c5-56fb-4cdb-bfb4-6b3da83f1848	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3175	1	8	1	[0]	2019-07-12 19:00:00	\N	\N	f7135d8d-0264-4ae8-8057-9b514797c868	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3176	1	12	1	[0]	2019-07-12 20:00:00	\N	\N	be1b3ce6-804d-4bf1-a8f8-b42d3e06fd0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3177	1	11	1	[0]	2019-07-12 20:00:00	\N	\N	ef2adc5f-56c9-45bf-a208-7b0fe8454f4e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3178	1	10	1	[0]	2019-07-12 20:00:00	\N	\N	49acfe7a-b929-49cc-971b-ceea68c3f413	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3179	1	9	1	[0]	2019-07-12 20:00:00	\N	\N	501def4e-ddb1-4ca2-8160-2f013fd167bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3180	1	8	1	[0]	2019-07-12 20:00:00	\N	\N	685067fc-e10e-4205-864c-bada17a2f971	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3181	1	12	1	[0]	2019-07-12 21:00:00	\N	\N	1bbb07b2-5af7-45a4-9393-bff915ae4ab9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3182	1	11	1	[0]	2019-07-12 21:00:00	\N	\N	e197bb4e-e2db-4688-b5ef-0b3279dca0dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3183	1	10	1	[0]	2019-07-12 21:00:00	\N	\N	93c1178e-97af-4dd8-b5c5-bb85fe4ba5bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3184	1	9	1	[0]	2019-07-12 21:00:00	\N	\N	f7a18ac3-ff46-4137-a6b2-b6e30925cf5d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3185	1	8	1	[0]	2019-07-12 21:00:00	\N	\N	3edfc70c-5469-46f9-99bf-f91aeaba2e59	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3186	1	12	1	[0]	2019-07-12 22:00:00	\N	\N	19e2db58-4fc2-4770-98ee-b0f1f3259e13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3187	1	11	1	[0]	2019-07-12 22:00:00	\N	\N	5811e6a4-ac0f-4050-83a9-096f33584ed4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3188	1	10	1	[0]	2019-07-12 22:00:00	\N	\N	0079a25c-f238-414c-a7e6-d5918093b7f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3189	1	9	1	[0]	2019-07-12 22:00:00	\N	\N	ec571556-d4e8-49cb-b974-a235eef5956c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3190	1	8	1	[0]	2019-07-12 22:00:00	\N	\N	62da88b2-ce8d-435a-8996-1fcf1962fd9f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3191	1	12	1	[0]	2019-07-12 23:00:00	\N	\N	8b23e6ef-c17e-4325-90c5-44a149a17437	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3192	1	11	1	[0]	2019-07-12 23:00:00	\N	\N	6ecadd05-7f89-49e5-b0a8-db746bf04efb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3193	1	10	1	[0]	2019-07-12 23:00:00	\N	\N	076b7cb6-6ec4-49e4-a8da-65645fdb67b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3194	1	9	1	[0]	2019-07-12 23:00:00	\N	\N	55fd2b54-15e9-47b0-a726-3633a3493b63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3195	1	8	1	[0]	2019-07-12 23:00:00	\N	\N	c52c4e09-21b1-4e9d-aa98-d01117b5b2c0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3196	1	12	1	[0]	2019-07-13 00:00:00	\N	\N	6920c19f-4869-4659-98a4-1dd6a5eae785	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3197	1	11	1	[0]	2019-07-13 00:00:00	\N	\N	fb913774-e8d7-4645-8157-c1d603f42839	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3198	1	10	1	[0]	2019-07-13 00:00:00	\N	\N	4b2e5086-f865-49e2-950a-a384809f17bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3199	1	9	1	[0]	2019-07-13 00:00:00	\N	\N	5fa37380-b644-44ab-8a06-e216a93878b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3200	1	8	1	[0]	2019-07-13 00:00:00	\N	\N	15a26e8d-c099-4016-a128-8f1948edbe05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3201	1	12	1	[0]	2019-07-13 01:00:00	\N	\N	eb0c1a94-b3d4-40c6-94ad-cb787f58c2e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3202	1	11	1	[0]	2019-07-13 01:00:00	\N	\N	917b11a6-6dd4-47fe-9a56-6119902f25c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3203	1	10	1	[0]	2019-07-13 01:00:00	\N	\N	7c564a14-2252-4081-9d61-b495b52425d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3204	1	9	1	[0]	2019-07-13 01:00:00	\N	\N	6e8898bf-c6ac-4390-b13d-d90ddb0b9cbe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3205	1	8	1	[0]	2019-07-13 01:00:00	\N	\N	2a01d3df-a97b-4978-8739-7d8fe90e4747	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3206	1	12	1	[0]	2019-07-13 02:00:00	\N	\N	1ca266ca-aff3-4f04-a26a-6ababb4446e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3207	1	11	1	[0]	2019-07-13 02:00:00	\N	\N	6169dc8f-7f20-45b7-8a26-fca2bc7985cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3208	1	10	1	[0]	2019-07-13 02:00:00	\N	\N	f4212a40-aa45-4be5-8761-ebf0679f6169	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3209	1	9	1	[0]	2019-07-13 02:00:00	\N	\N	c1093c53-a805-4cff-82a7-1e7ab946351a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3210	1	8	1	[0]	2019-07-13 02:00:00	\N	\N	fc46fbd7-37c0-4dc1-8cd2-aa34e20963a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3211	1	12	1	[0]	2019-07-13 03:00:00	\N	\N	94a49b75-1253-49b1-92d0-c96dfcdea756	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3212	1	11	1	[0]	2019-07-13 03:00:00	\N	\N	912295f9-9afd-4ada-8e73-539fe56ad4e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3213	1	10	1	[0]	2019-07-13 03:00:00	\N	\N	2979e021-8583-4d63-9ed8-fd7a2cd701f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3214	1	9	1	[0]	2019-07-13 03:00:00	\N	\N	0ba12202-0313-4177-b6e6-c8806a89e6dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3215	1	8	1	[0]	2019-07-13 03:00:00	\N	\N	da2320a3-6599-400b-8289-9cb7a2b52804	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3216	1	12	1	[0]	2019-07-13 04:00:00	\N	\N	ef1fa7a9-82df-4f2c-b46c-175609bf808d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3217	1	11	1	[0]	2019-07-13 04:00:00	\N	\N	662df115-c6d4-4c5a-80a0-d59d5d65307c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3218	1	10	1	[0]	2019-07-13 04:00:00	\N	\N	e9c70334-d24e-4862-aa41-a2bea486340a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3219	1	9	1	[0]	2019-07-13 04:00:00	\N	\N	47e417ce-a2a1-40a2-9bf3-1921c01a296d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3220	1	8	1	[0]	2019-07-13 04:00:00	\N	\N	514b5fa7-1859-4974-b27f-06868fe3f0a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3221	1	12	1	[0.200000003]	2019-07-13 05:00:00	\N	\N	c9a0c599-3839-4ae7-bc05-230ad309ad3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3222	1	11	1	[0]	2019-07-13 05:00:00	\N	\N	0a0a0c9f-7c27-4b95-9bf4-963f7b854fce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3223	1	10	1	[0]	2019-07-13 05:00:00	\N	\N	1ee53ad0-e403-4643-9cf2-d50f724433be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3224	1	9	1	[0]	2019-07-13 05:00:00	\N	\N	e8a8497e-3a85-400d-9624-fdf19f77d619	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3225	1	8	1	[0]	2019-07-13 05:00:00	\N	\N	fb8d320a-289e-4faf-afef-ea0386c2ae33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3226	1	12	1	[0]	2019-07-13 06:00:00	\N	\N	a5d4c586-6ab8-493a-9f53-ee5b0a3e0c06	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3227	1	11	1	[0]	2019-07-13 06:00:00	\N	\N	05a85b2a-4e4f-4793-923b-73a7cd42844c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3228	1	10	1	[0]	2019-07-13 06:00:00	\N	\N	c2f6dca1-564e-48d8-a398-972ef66d4383	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3229	1	9	1	[0]	2019-07-13 06:00:00	\N	\N	394106b0-5af6-4d11-9172-c92b11aa1900	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3230	1	8	1	[0]	2019-07-13 06:00:00	\N	\N	c2c86461-b0b9-445d-b4f1-191df4db066a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3231	1	12	1	[0]	2019-07-13 07:00:00	\N	\N	5da16bde-a6ca-44c4-b67e-fdf284fdb602	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3232	1	11	1	[0]	2019-07-13 07:00:00	\N	\N	89891607-0b43-4ff8-8888-86422d0cece6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3233	1	10	1	[0]	2019-07-13 07:00:00	\N	\N	d8f79c7a-e560-41db-a2ca-3ad1f7dd7869	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3234	1	9	1	[0]	2019-07-13 07:00:00	\N	\N	6426c75f-b858-4714-b5da-ada3d4af421c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3235	1	8	1	[0]	2019-07-13 07:00:00	\N	\N	4bef2378-cf74-4339-aa1d-f80e8026c31e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3236	1	12	1	[0]	2019-07-13 08:00:00	\N	\N	47e6a808-6fb2-4a78-86a0-cbf9b0613f69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3237	1	11	1	[0]	2019-07-13 08:00:00	\N	\N	2ba29103-b981-4996-a079-342f32d9e791	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3238	1	10	1	[0]	2019-07-13 08:00:00	\N	\N	2b1a8689-6a73-4292-8669-59403984cb16	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3239	1	9	1	[0]	2019-07-13 08:00:00	\N	\N	078f0801-dc60-42b4-b7db-895891ccfece	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3240	1	8	1	[0]	2019-07-13 08:00:00	\N	\N	ffe53996-72bf-4718-a3b5-dd4d9e6a203e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3241	1	12	1	[0]	2019-07-13 09:00:00	\N	\N	e079540e-2362-4958-b5e5-08f2169232ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3242	1	11	1	[0]	2019-07-13 09:00:00	\N	\N	7657c833-70ea-4f8c-b2e6-27deb5a493ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3243	1	10	1	[0]	2019-07-13 09:00:00	\N	\N	c65ca5a0-0f4c-4ea8-a583-0d44ed22917e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3244	1	9	1	[0]	2019-07-13 09:00:00	\N	\N	b38d97ab-1bae-40e1-aafe-95f92a7cd648	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3245	1	8	1	[0]	2019-07-13 09:00:00	\N	\N	8b08d88d-73fa-4996-8ec3-e7d87f9ece02	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3246	1	12	1	[0]	2019-07-13 10:00:00	\N	\N	0130c000-d9c4-4f5e-98a1-757e774182b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3247	1	11	1	[0]	2019-07-13 10:00:00	\N	\N	ced7cb60-3e1d-425c-a6d9-3fbedbc734a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3248	1	10	1	[0]	2019-07-13 10:00:00	\N	\N	54ece732-8ccc-44ef-b26b-5f0c9f012cf1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3249	1	9	1	[0]	2019-07-13 10:00:00	\N	\N	fcbfc656-3be7-4e28-a345-e25ab6103d18	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3250	1	8	1	[0]	2019-07-13 10:00:00	\N	\N	89c8be47-07c5-4dbe-8fb4-0497220773bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3251	1	12	1	[0]	2019-07-13 11:00:00	\N	\N	8f37a555-982e-47b1-b5fa-efb25e272a28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3252	1	11	1	[0]	2019-07-13 11:00:00	\N	\N	1c711c57-87c0-4da9-8916-1023747edb1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3253	1	10	1	[0]	2019-07-13 11:00:00	\N	\N	8f49d578-3b33-4691-ab93-1161d033ce29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3254	1	9	1	[0]	2019-07-13 11:00:00	\N	\N	23ddf7f0-6d4c-4b7e-b3e2-b83119b247ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3255	1	8	1	[0]	2019-07-13 11:00:00	\N	\N	6f1ff4a6-4590-4af8-9c26-e4974f30c8b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3256	1	12	1	[0]	2019-07-13 12:00:00	\N	\N	7a97acf4-1a11-4dc7-ad32-6a9a002fb5ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3257	1	11	1	[0]	2019-07-13 12:00:00	\N	\N	3ca4645d-72bf-4ea5-ba48-a893b0a1ce01	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3258	1	10	1	[0]	2019-07-13 12:00:00	\N	\N	f5f7e0a4-b6f2-4de1-ba9c-31b62e739b8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3259	1	9	1	[0]	2019-07-13 12:00:00	\N	\N	16a527d1-4d6b-4575-9f17-0b1d572a51ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3260	1	8	1	[0]	2019-07-13 12:00:00	\N	\N	b60d03fc-8fae-4e5c-97dd-12b6b0b6bf66	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3261	1	12	1	[0]	2019-07-13 13:00:00	\N	\N	ee2c8027-2d0b-4048-ba3c-10c8fae234f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3262	1	11	1	[0]	2019-07-13 13:00:00	\N	\N	a9e2a7b8-2783-490e-b8b9-4abf4c1f83f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3263	1	10	1	[0]	2019-07-13 13:00:00	\N	\N	30f81f7d-f7a2-4de7-8ada-8347be0654c9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3264	1	9	1	[0]	2019-07-13 13:00:00	\N	\N	ed70af15-6633-4d63-8d3a-df34aefe6673	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3265	1	8	1	[0]	2019-07-13 13:00:00	\N	\N	0d2bc041-8b71-4669-9fee-d0c2d11b6803	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3266	1	12	1	[0]	2019-07-13 14:00:00	\N	\N	18301d32-c3c2-4098-a892-24d1fa276c4a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3267	1	11	1	[0]	2019-07-13 14:00:00	\N	\N	0ff38ca2-ce17-402c-bb6c-dc59622816f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3268	1	10	1	[0]	2019-07-13 14:00:00	\N	\N	5dc602bc-e9ce-4a3c-ab0e-26230ad22e26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3269	1	9	1	[0]	2019-07-13 14:00:00	\N	\N	20ca1afb-95eb-4308-a231-3ec4e7afd523	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3270	1	8	1	[0]	2019-07-13 14:00:00	\N	\N	c7dfd196-7aa0-457f-9de3-45baf3f628fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3271	1	12	1	[0]	2019-07-13 15:00:00	\N	\N	e657c613-df80-419b-89b4-bee2af870c3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3272	1	11	1	[0]	2019-07-13 15:00:00	\N	\N	b42843a7-9abe-49fe-a7fd-a19527883f2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3273	1	10	1	[0]	2019-07-13 15:00:00	\N	\N	32f54a17-96a9-4e20-a7bc-550e11de8994	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3274	1	9	1	[0]	2019-07-13 15:00:00	\N	\N	f52976ad-947c-4bcb-854c-9784456a8ea3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3275	1	8	1	[0]	2019-07-13 15:00:00	\N	\N	fff3dbda-99ea-47b7-be17-02231ae33ba0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3276	1	12	1	[0]	2019-07-13 16:00:00	\N	\N	713fbe69-396a-4db3-bb78-0be8ad65b6f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3277	1	11	1	[0]	2019-07-13 16:00:00	\N	\N	5fce8085-b36e-4df1-97a9-addcc2ff91ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3278	1	10	1	[0]	2019-07-13 16:00:00	\N	\N	fbdee9cb-ac73-4e32-8cc4-258912148f63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3279	1	9	1	[0]	2019-07-13 16:00:00	\N	\N	e3795afb-eb96-4984-ad50-4e1f28a4e468	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3280	1	8	1	[0]	2019-07-13 16:00:00	\N	\N	a01095ea-eebd-4835-be6d-feef7b95855d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3281	1	12	1	[0]	2019-07-13 17:00:00	\N	\N	76e7c792-22a8-4166-be27-c823a62d9d62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3282	1	11	1	[0]	2019-07-13 17:00:00	\N	\N	219e39ce-21a2-46c3-97cd-c15433b8a738	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3283	1	10	1	[0]	2019-07-13 17:00:00	\N	\N	e3eefd52-b418-44c0-a007-a3627301775d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3284	1	9	1	[0]	2019-07-13 17:00:00	\N	\N	b2a5b063-0ba9-464e-a892-3988579a2c5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3285	1	8	1	[0]	2019-07-13 17:00:00	\N	\N	14347ad7-ed8f-4ba2-aa24-a9d045b2e745	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3286	1	12	1	[0]	2019-07-13 18:00:00	\N	\N	0461e91b-7e72-44bd-9cdb-4a2fa756c04c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3287	1	11	1	[0]	2019-07-13 18:00:00	\N	\N	f77ae3ab-0492-496f-ab4a-dcf9c35432a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3288	1	10	1	[0]	2019-07-13 18:00:00	\N	\N	eb84894e-654b-45cd-b214-e9d99a984806	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3289	1	9	1	[0]	2019-07-13 18:00:00	\N	\N	4e32d270-14fe-4e48-a59a-63e5853ae31c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3290	1	8	1	[0]	2019-07-13 18:00:00	\N	\N	20b4aabb-62cc-4ae1-ac53-8f80379409b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3291	1	12	1	[0]	2019-07-13 19:00:00	\N	\N	02c2ae76-504a-4ba2-b3dd-134569021f6c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3292	1	11	1	[0]	2019-07-13 19:00:00	\N	\N	81d93aab-0172-4dab-8c6f-cb66d8d1ac69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3293	1	10	1	[0]	2019-07-13 19:00:00	\N	\N	bc82b723-74b5-4ff1-9ee9-b3d086d790ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3294	1	9	1	[0]	2019-07-13 19:00:00	\N	\N	1b23aab7-cf5c-45b9-828d-a627bcc079fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3295	1	8	1	[0]	2019-07-13 19:00:00	\N	\N	0fabdf28-a834-483d-8ff8-f97797180213	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3296	1	12	1	[0]	2019-07-13 20:00:00	\N	\N	6705dbf7-32b8-4bc7-a4e4-598bf366b604	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3297	1	11	1	[0]	2019-07-13 20:00:00	\N	\N	e2f369ed-8842-4181-97b1-d84e5bb7d59c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3298	1	10	1	[0]	2019-07-13 20:00:00	\N	\N	4f745b35-9951-4b3c-a93b-9ccbb1686126	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3299	1	9	1	[0]	2019-07-13 20:00:00	\N	\N	8a2fe870-f79d-4b4f-b37a-2a1ed05400fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3300	1	8	1	[0]	2019-07-13 20:00:00	\N	\N	fc678ca0-b06c-4d5d-82c8-5815f6473682	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3301	1	12	1	[0]	2019-07-13 21:00:00	\N	\N	c6622395-82cf-426a-9856-948cce692af0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3302	1	11	1	[0]	2019-07-13 21:00:00	\N	\N	e01a1c79-c092-4574-b7e1-d595dd08d232	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3303	1	10	1	[0]	2019-07-13 21:00:00	\N	\N	08062ee9-ebbf-44bd-a48b-02f2102372ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3304	1	9	1	[0]	2019-07-13 21:00:00	\N	\N	42ef1c77-38bf-47a4-b58c-6bcd76bf3328	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3305	1	8	1	[0]	2019-07-13 21:00:00	\N	\N	3f832e0d-8834-405e-bf60-c90886ca92bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3306	1	12	1	[0]	2019-07-13 22:00:00	\N	\N	d1596362-9984-4698-a75b-a98f134be9a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3307	1	11	1	[0]	2019-07-13 22:00:00	\N	\N	dda2b52a-00c6-445b-9e80-24f024c1bd19	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3308	1	10	1	[0]	2019-07-13 22:00:00	\N	\N	0eed08b0-8bd7-4339-93fd-4d0787ccb87b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3309	1	9	1	[0]	2019-07-13 22:00:00	\N	\N	43dbba69-1216-4a1f-b538-a98e0387568b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3310	1	8	1	[0]	2019-07-13 22:00:00	\N	\N	6a936ad0-6f53-43e4-b470-f6053ce1f8bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3311	1	12	1	[0]	2019-07-13 23:00:00	\N	\N	bd41fceb-0dbf-44d2-8b92-b9713ef35b91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3312	1	11	1	[0]	2019-07-13 23:00:00	\N	\N	b757c20f-55d2-4bc5-8792-a003a3564d2e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3313	1	10	1	[0]	2019-07-13 23:00:00	\N	\N	79052861-2218-4d4b-a624-f523524bf2d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3314	1	9	1	[0]	2019-07-13 23:00:00	\N	\N	9bdd6424-0918-42bb-95f0-456ce97f9603	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3315	1	8	1	[0]	2019-07-13 23:00:00	\N	\N	f9f7ee29-e32a-443a-b07d-a3b29a130694	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3316	1	12	1	[0]	2019-07-14 00:00:00	\N	\N	a2b96f3e-f218-4a31-a6c1-9f8da52401ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3317	1	11	1	[0]	2019-07-14 00:00:00	\N	\N	ad62f424-ec0f-4264-9e56-833866fcd953	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3318	1	10	1	[0]	2019-07-14 00:00:00	\N	\N	f648fa58-a255-49ba-b8ea-86f5a32e4a67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3319	1	9	1	[0]	2019-07-14 00:00:00	\N	\N	9328fcd7-7d88-4f02-b022-5912f4e78d2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3320	1	8	1	[0]	2019-07-14 00:00:00	\N	\N	4330a0c3-96ea-4113-bda0-4d502794bcf8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3321	1	12	1	[0]	2019-07-14 01:00:00	\N	\N	41878f55-3a87-48e4-b3c2-08a91f1d4a34	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3322	1	11	1	[0]	2019-07-14 01:00:00	\N	\N	d3d5b325-3ed6-4fff-bd94-4c4a10f24423	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3323	1	10	1	[0]	2019-07-14 01:00:00	\N	\N	e258e207-9bed-4f6b-9129-f711a5813604	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3324	1	9	1	[0]	2019-07-14 01:00:00	\N	\N	a7729e45-eec5-4922-90be-5a2ae629e7cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3325	1	8	1	[0]	2019-07-14 01:00:00	\N	\N	bd7036fe-741e-4b04-8816-b150acbba0e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3326	1	12	1	[0]	2019-07-14 02:00:00	\N	\N	dd4b9111-039c-4317-89cd-04cf4bd4096a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3327	1	11	1	[0]	2019-07-14 02:00:00	\N	\N	94a54a9c-bc4f-4b22-9481-9b0d6e7a98fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3328	1	10	1	[0]	2019-07-14 02:00:00	\N	\N	515fd2c7-27f0-4f89-b1b4-6da1831982bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3329	1	9	1	[0]	2019-07-14 02:00:00	\N	\N	0b7f50aa-e4b0-43ea-aa0f-4fda666aedef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3330	1	8	1	[0]	2019-07-14 02:00:00	\N	\N	93889782-5e4f-4e3d-a8e5-70c909f16363	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3331	1	12	1	[0]	2019-07-14 03:00:00	\N	\N	774f04d6-053e-4c6f-98e3-27de66aa552e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3332	1	11	1	[0]	2019-07-14 03:00:00	\N	\N	f81171ca-bf21-42c9-9fb4-46fc74734ac0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3333	1	10	1	[0]	2019-07-14 03:00:00	\N	\N	5cec09d0-e982-4d3b-af37-8908a2cd3cf9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3334	1	9	1	[0]	2019-07-14 03:00:00	\N	\N	fa018a7b-80a7-4414-a4b1-8318ad8e601b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3335	1	8	1	[0]	2019-07-14 03:00:00	\N	\N	d2c1412b-fc84-4b8e-8d10-e1c6d8ddae29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3336	1	12	1	[0]	2019-07-14 04:00:00	\N	\N	fb886478-d597-45d2-aff6-54ca417bd712	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3337	1	11	1	[0]	2019-07-14 04:00:00	\N	\N	de64ead4-abe5-47a7-bc3f-c8f581ae9f81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3338	1	10	1	[0]	2019-07-14 04:00:00	\N	\N	b7438008-c1f3-4c82-b3e3-e1ae4d494de4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3339	1	9	1	[0]	2019-07-14 04:00:00	\N	\N	9d885b39-e718-4ac7-aecf-dcd6830894fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3340	1	8	1	[0]	2019-07-14 04:00:00	\N	\N	533ac1f2-a21a-4375-84c8-b3c0ec21c82a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3341	1	12	1	[0]	2019-07-14 05:00:00	\N	\N	1980b325-b039-4584-9a5d-7639ad79f06d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3342	1	11	1	[0]	2019-07-14 05:00:00	\N	\N	e01eec0f-ff4d-4466-838a-d42feb8d3129	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3343	1	10	1	[0]	2019-07-14 05:00:00	\N	\N	3c36c80f-70f0-4f49-ad98-2537ffc3701c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3344	1	9	1	[0]	2019-07-14 05:00:00	\N	\N	837fe54d-8bd5-476d-a076-fe2ed81cbc28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3345	1	8	1	[0]	2019-07-14 05:00:00	\N	\N	8bce1737-61aa-44ea-bbe0-54c4ffe79e90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3346	1	12	1	[0]	2019-07-14 06:00:00	\N	\N	f1b45801-e9a2-44ab-a4b6-f424c11d9ce3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3347	1	11	1	[0]	2019-07-14 06:00:00	\N	\N	af271c57-7fa0-4a37-a051-3233a2544b83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3348	1	10	1	[0]	2019-07-14 06:00:00	\N	\N	a596165f-eb1c-413f-90fb-d191aba4b3aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3349	1	9	1	[0]	2019-07-14 06:00:00	\N	\N	c27785aa-67da-4e72-b914-5fccf4e5ced2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3350	1	8	1	[0]	2019-07-14 06:00:00	\N	\N	073d656b-2d25-4f7a-9b04-3daaf8439ae6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3351	1	12	1	[0]	2019-07-14 07:00:00	\N	\N	016ae602-2fa0-40ef-8773-14e4773070ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3352	1	11	1	[0]	2019-07-14 07:00:00	\N	\N	efc9a85f-1aeb-4815-9aa9-78b10a25e7ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3353	1	10	1	[0.200000003]	2019-07-14 07:00:00	\N	\N	b42665e7-5c48-4089-a576-096e27411303	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3354	1	9	1	[0]	2019-07-14 07:00:00	\N	\N	8e58247e-9038-4c2d-b2b2-792b7d49e137	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3355	1	8	1	[0]	2019-07-14 07:00:00	\N	\N	9cd1c2ac-5da9-4909-8baa-1826d313847b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3356	1	12	1	[0.200000003]	2019-07-14 08:00:00	\N	\N	557c51c4-0773-4b03-b379-2739ff2c90d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3357	1	11	1	[0]	2019-07-14 08:00:00	\N	\N	f814aa28-10f1-489f-9f52-c0c4c740b18c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3358	1	10	1	[0]	2019-07-14 08:00:00	\N	\N	111d843a-3aaa-4e62-836b-9bb4e2c7665a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3359	1	9	1	[0]	2019-07-14 08:00:00	\N	\N	c50378d1-5296-4835-b406-ddbadf7bc710	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3360	1	8	1	[0.200000003]	2019-07-14 08:00:00	\N	\N	7bd7872d-3485-4a8b-b761-ffea9c13e441	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3361	1	12	1	[0]	2019-07-14 09:00:00	\N	\N	6a70b3a4-dcc7-4a14-bd76-37c1660a4e0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3362	1	11	1	[0]	2019-07-14 09:00:00	\N	\N	8a2c7173-36ec-4a8b-8820-f614882882bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3363	1	10	1	[0]	2019-07-14 09:00:00	\N	\N	3ddf781e-9643-4668-9163-541ad2cfd567	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3364	1	9	1	[0]	2019-07-14 09:00:00	\N	\N	6e0729c9-33e3-413f-bd2b-685b35c9fe94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3365	1	8	1	[0]	2019-07-14 09:00:00	\N	\N	9d0dcb5a-b722-465d-9d93-1c9654b40266	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3366	1	12	1	[0]	2019-07-14 10:00:00	\N	\N	15364230-cc30-4abf-a52b-c19851e34839	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3367	1	11	1	[0]	2019-07-14 10:00:00	\N	\N	1676dcd4-a308-4eb1-b480-16d395916a8a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3368	1	10	1	[0]	2019-07-14 10:00:00	\N	\N	642771fc-8ee6-473f-ba62-288b678fe23e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3369	1	9	1	[0]	2019-07-14 10:00:00	\N	\N	fbd9565a-40d6-4209-9b33-6a90ddd048d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3370	1	8	1	[0]	2019-07-14 10:00:00	\N	\N	7424a741-8053-4264-8b2f-d389f134fe3d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3371	1	12	1	[0]	2019-07-14 11:00:00	\N	\N	6cd2c732-7639-4128-943c-faef77169c61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3372	1	11	1	[0]	2019-07-14 11:00:00	\N	\N	ba0e0217-23a1-4bd1-9242-de81745fb934	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3373	1	10	1	[0]	2019-07-14 11:00:00	\N	\N	5b787f48-7090-4625-a757-f30884ca6305	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3374	1	9	1	[0]	2019-07-14 11:00:00	\N	\N	54a057b3-11de-4842-b70b-7849009abdf8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3375	1	8	1	[0]	2019-07-14 11:00:00	\N	\N	26ab4a70-9c9a-476a-89b5-76420cb9ecf9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3376	1	12	1	[0]	2019-07-14 12:00:00	\N	\N	1fdf89f3-a001-44fc-803a-2c4a385a2a12	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3377	1	11	1	[0]	2019-07-14 12:00:00	\N	\N	1a2a788b-ac0e-4957-b23a-0587a926b819	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3378	1	10	1	[0]	2019-07-14 12:00:00	\N	\N	8e2581f2-2c32-4c4d-8b64-074fa9034d76	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3379	1	9	1	[0]	2019-07-14 12:00:00	\N	\N	2fafc775-5f46-4df1-9924-a389ead81ccc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3380	1	8	1	[0]	2019-07-14 12:00:00	\N	\N	30dccfd6-11f5-456e-bd02-18173cbf190c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3381	1	12	1	[0]	2019-07-14 13:00:00	\N	\N	606bac7e-beca-44b4-bc07-21938498e2f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3382	1	11	1	[0]	2019-07-14 13:00:00	\N	\N	22b8b8fc-9cb3-4461-9ef6-cc7ec241b446	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3383	1	10	1	[0]	2019-07-14 13:00:00	\N	\N	2593a704-0859-4c1b-9f91-03c12c06c41a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3384	1	9	1	[0]	2019-07-14 13:00:00	\N	\N	bbfe26a0-7417-4832-a79f-9e1c8b7868d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3385	1	8	1	[0]	2019-07-14 13:00:00	\N	\N	a8ea5557-387a-4347-b0a2-4e0f20a48e1d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3386	1	12	1	[0]	2019-07-14 14:00:00	\N	\N	2cccf720-0a30-4f02-9520-e10a6fa73b34	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3387	1	11	1	[0]	2019-07-14 14:00:00	\N	\N	96dd75e1-fed5-494a-8178-d28f716b6abf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3388	1	10	1	[0]	2019-07-14 14:00:00	\N	\N	307dfcf8-c15f-4110-ab2f-b128b87187da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3389	1	9	1	[0]	2019-07-14 14:00:00	\N	\N	be570ec7-ca14-4312-a4e8-660e8adcf073	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3390	1	8	1	[0]	2019-07-14 14:00:00	\N	\N	30480f27-cc62-4e94-9158-f83093b27090	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3391	1	12	1	[0]	2019-07-14 15:00:00	\N	\N	32f9a03b-b7dc-496a-9674-5254de8a8ecd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3392	1	11	1	[0]	2019-07-14 15:00:00	\N	\N	9e4adbb2-59be-4fb5-8211-907f6081c304	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3393	1	10	1	[0]	2019-07-14 15:00:00	\N	\N	1228ede7-2d7f-4179-a386-3feee9f73ea7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3394	1	9	1	[0]	2019-07-14 15:00:00	\N	\N	a1480fb7-9a1e-4e81-8940-d25a8c16279d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3395	1	8	1	[0]	2019-07-14 15:00:00	\N	\N	e670b406-85cc-41a3-b5fc-e1c7d05ac222	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3396	1	12	1	[0]	2019-07-14 16:00:00	\N	\N	f70975ab-2829-4ce9-bbea-650214d96203	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3397	1	11	1	[0]	2019-07-14 16:00:00	\N	\N	e32984f3-bfec-4f8f-acfb-e21160b42130	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3398	1	10	1	[0]	2019-07-14 16:00:00	\N	\N	85e06905-6c8b-4188-900c-313d6a5387a3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3399	1	9	1	[0]	2019-07-14 16:00:00	\N	\N	74152d90-effd-4338-93bc-dc1d12770cff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3400	1	8	1	[0]	2019-07-14 16:00:00	\N	\N	25bb03ca-c7b5-4632-94ae-79c358d23fa6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3401	1	12	1	[0]	2019-07-14 17:00:00	\N	\N	7be22a4b-1d87-4b64-845a-a2db7730006f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3402	1	11	1	[0]	2019-07-14 17:00:00	\N	\N	6d81e537-efe9-4b98-89ae-41f33b4abb1b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3403	1	10	1	[0]	2019-07-14 17:00:00	\N	\N	5aaaf47c-5b04-4b67-b1ef-1449546984a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3404	1	9	1	[0]	2019-07-14 17:00:00	\N	\N	a9ef29c9-6fcb-48ed-a75e-e8ef10c16256	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3405	1	8	1	[0]	2019-07-14 17:00:00	\N	\N	a1457643-6db1-45f0-b761-2d6154ca0c4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3406	1	12	1	[0]	2019-07-14 18:00:00	\N	\N	e612f52a-9241-4890-92ad-71c0caefa3f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3407	1	11	1	[0]	2019-07-14 18:00:00	\N	\N	1012ec39-438e-4ee4-86be-1d065f7b9ee0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3408	1	10	1	[0]	2019-07-14 18:00:00	\N	\N	556ba099-799e-44c2-aa86-48880725716b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3409	1	9	1	[0]	2019-07-14 18:00:00	\N	\N	215bd3bc-e708-4c77-a4b2-71720583919c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3410	1	8	1	[0]	2019-07-14 18:00:00	\N	\N	daa73a49-f196-4289-836d-12a6257ea8b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3411	1	12	1	[0]	2019-07-14 19:00:00	\N	\N	f897bded-5ea4-4c8a-8daf-65d7a5e3a769	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3412	1	11	1	[0]	2019-07-14 19:00:00	\N	\N	80631983-de9a-44b3-b23b-59976948c5be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3413	1	10	1	[0]	2019-07-14 19:00:00	\N	\N	8d7c8ee1-440b-4245-8a0c-0f01501f42b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3414	1	9	1	[0]	2019-07-14 19:00:00	\N	\N	3ecf0b8e-d1cc-4188-96bf-3597918c41ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3415	1	8	1	[0]	2019-07-14 19:00:00	\N	\N	afa025f1-45b9-4762-8724-a38febf0f2cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3416	1	12	1	[0]	2019-07-14 20:00:00	\N	\N	fb836c8c-791a-487e-8b91-2a194fb6fa49	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3417	1	11	1	[0]	2019-07-14 20:00:00	\N	\N	c4362e66-0a6a-4aa1-b461-b84f10a9b571	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3418	1	10	1	[0]	2019-07-14 20:00:00	\N	\N	e83c20d7-5e8c-4d2d-8fc0-1527b9bf5de7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3419	1	9	1	[0]	2019-07-14 20:00:00	\N	\N	f1d1bde9-3cf0-4f2d-85f4-344f4221ab75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3420	1	8	1	[0]	2019-07-14 20:00:00	\N	\N	94cdde6d-0f68-4d5e-bba5-4a06f6030635	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3421	1	12	1	[0]	2019-07-14 21:00:00	\N	\N	2778059e-cc48-420c-a15d-3fb34ca26b63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3422	1	11	1	[0]	2019-07-14 21:00:00	\N	\N	e0dbedd1-3392-4199-b8ab-68a4f28abbba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3423	1	10	1	[0]	2019-07-14 21:00:00	\N	\N	cc022abc-4a5f-4dc7-82bb-c1e14d582732	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3424	1	9	1	[0]	2019-07-14 21:00:00	\N	\N	16ee7bc3-28bc-4241-bd34-08cf95e19e61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3425	1	8	1	[0]	2019-07-14 21:00:00	\N	\N	9fe937a0-9947-47d1-8998-25f08e580364	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3426	1	12	1	[0]	2019-07-14 22:00:00	\N	\N	2cd656d0-79aa-44f4-a02a-c22957f34613	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3427	1	11	1	[0]	2019-07-14 22:00:00	\N	\N	f9a78d25-5aa0-4e29-9d16-f57a93798fda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3428	1	10	1	[0]	2019-07-14 22:00:00	\N	\N	666ea6b0-f8b2-410b-b0dd-75f53e68dea4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3429	1	9	1	[0]	2019-07-14 22:00:00	\N	\N	2cba9f8d-5f9d-4ef2-8094-c547e1169e75	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3430	1	8	1	[0]	2019-07-14 22:00:00	\N	\N	184cb50b-028b-4f6f-8bf2-308449a8cc27	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3431	1	12	1	[0]	2019-07-14 23:00:00	\N	\N	b3289c9a-6708-4ffb-94ff-942450125e73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3432	1	11	1	[0]	2019-07-14 23:00:00	\N	\N	487e83ab-5653-4597-952d-68c3022aeac7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3433	1	10	1	[0]	2019-07-14 23:00:00	\N	\N	39436ebb-290e-4067-a33f-1798a8426c66	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3434	1	9	1	[0]	2019-07-14 23:00:00	\N	\N	b0a3b89d-4641-4204-bd01-9b7227a20cd1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3435	1	8	1	[0]	2019-07-14 23:00:00	\N	\N	6521ba64-1520-4e6e-bfdf-b9e8272a310c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3436	1	12	1	[0]	2019-07-15 00:00:00	\N	\N	7f52195f-66b7-4c26-be27-813474795aab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3437	1	11	1	[0]	2019-07-15 00:00:00	\N	\N	5137bdba-e7b4-42df-8564-e3a1b33bc4dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3438	1	10	1	[0]	2019-07-15 00:00:00	\N	\N	b640002f-d71e-4086-8197-483b9cdd132b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3439	1	9	1	[0]	2019-07-15 00:00:00	\N	\N	e63d270a-34e2-4d0b-b9f8-499efbff0395	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3440	1	8	1	[0]	2019-07-15 00:00:00	\N	\N	59081841-1ea5-49d7-be52-87c584a75318	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3441	1	12	1	[0]	2019-07-15 01:00:00	\N	\N	1219a113-1121-4768-8650-087615f7f83e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3442	1	11	1	[0]	2019-07-15 01:00:00	\N	\N	d16b7950-060d-4f07-84d9-35b8c6fcaf45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3443	1	10	1	[0]	2019-07-15 01:00:00	\N	\N	6af4f210-7d92-4ba1-b691-70fed082ee33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3444	1	9	1	[0]	2019-07-15 01:00:00	\N	\N	26150391-3cc8-45ad-a0cb-b93078153b23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3445	1	8	1	[0]	2019-07-15 01:00:00	\N	\N	b648dfcd-48aa-4543-bde3-c47ef9cc2a70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3446	1	12	1	[0]	2019-07-15 02:00:00	\N	\N	3d524ef7-ab9f-42e0-8367-227825b9cdf5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3447	1	11	1	[0]	2019-07-15 02:00:00	\N	\N	ceb4cdeb-0b0c-4f8b-802e-e6233b2c5baf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3448	1	10	1	[0]	2019-07-15 02:00:00	\N	\N	5a5d7b8b-2dae-4919-97e1-5247443b1ec7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3449	1	9	1	[0]	2019-07-15 02:00:00	\N	\N	ff83f6e5-d219-4c1f-beed-5f821a82f6fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3450	1	8	1	[0]	2019-07-15 02:00:00	\N	\N	e1e8c459-ccf1-4921-8682-9425b4d3dbdb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3451	1	12	1	[0]	2019-07-15 03:00:00	\N	\N	53a35420-103e-4510-89dd-a5f6573afa88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3452	1	11	1	[0]	2019-07-15 03:00:00	\N	\N	9784791c-3858-44a0-bfef-3c4d2553096c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3453	1	10	1	[0]	2019-07-15 03:00:00	\N	\N	b1abccb3-3853-4658-9fcf-cc36154034f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3454	1	9	1	[0]	2019-07-15 03:00:00	\N	\N	bea433d5-e224-4121-b687-81cd22bdaca8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3455	1	8	1	[0]	2019-07-15 03:00:00	\N	\N	1bec6502-8c53-4ac3-8218-16e5b2408baf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3456	1	12	1	[0]	2019-07-15 04:00:00	\N	\N	264ae7fc-971b-4aaf-84c3-38e90f07fcda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3457	1	11	1	[0]	2019-07-15 04:00:00	\N	\N	4ad2fe85-cb28-46b9-acaf-e7f619ebd1da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3458	1	10	1	[0]	2019-07-15 04:00:00	\N	\N	32d95abd-a7ee-49e1-b4f6-7c4cd63f3eef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3459	1	9	1	[0]	2019-07-15 04:00:00	\N	\N	c9416106-1df9-4949-85e4-2a9aa13bf929	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3460	1	8	1	[0]	2019-07-15 04:00:00	\N	\N	a50c86bd-c34c-40ef-bdce-5fae2cfc638e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3461	1	12	1	[0]	2019-07-15 05:00:00	\N	\N	6a590bc1-8e1d-4903-acf8-cfd6a2f070ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3462	1	11	1	[0]	2019-07-15 05:00:00	\N	\N	85592c7a-886b-4a66-bcaa-da877364fc24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3463	1	10	1	[0]	2019-07-15 05:00:00	\N	\N	2d1982c2-c953-41ee-930e-6bea95475986	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3464	1	9	1	[0]	2019-07-15 05:00:00	\N	\N	1ec0d573-372e-46c9-90a7-4ddf7af6e175	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3465	1	8	1	[0]	2019-07-15 05:00:00	\N	\N	86aa7f51-f1a4-407d-ab37-6484dc912ccd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3466	1	12	1	[0]	2019-07-15 06:00:00	\N	\N	afad56d9-e9e7-4bb8-a174-ed95fb35e0e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3467	1	11	1	[0]	2019-07-15 06:00:00	\N	\N	ac022835-b7e9-42f5-a8eb-ba3c53b2c1ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3468	1	10	1	[0]	2019-07-15 06:00:00	\N	\N	cb7cdb47-32e5-44b1-bfd7-615187ffb444	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3469	1	9	1	[0]	2019-07-15 06:00:00	\N	\N	3d78317c-5fe7-4999-b210-7647003bb1ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3470	1	8	1	[0]	2019-07-15 06:00:00	\N	\N	607cc01b-9e5d-4723-88ae-5213761233e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3471	1	12	1	[0]	2019-07-15 07:00:00	\N	\N	7a9bf950-c181-49a6-b2b5-c20a8247f759	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3472	1	11	1	[0]	2019-07-15 07:00:00	\N	\N	ef488be7-a872-46a3-b486-aa9d8375464b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3473	1	10	1	[0]	2019-07-15 07:00:00	\N	\N	724fdd16-6e15-4140-91e4-b66bc4f96759	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3474	1	9	1	[0]	2019-07-15 07:00:00	\N	\N	f44ac841-a04a-4a9b-ba5c-9a80f40d070e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3475	1	8	1	[0]	2019-07-15 07:00:00	\N	\N	d37edb9d-581e-4cc2-af60-e3f3db20742f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3476	1	12	1	[0]	2019-07-15 08:00:00	\N	\N	25ef8dc2-76f2-4874-9862-3685c76cedc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3477	1	11	1	[0]	2019-07-15 08:00:00	\N	\N	d7e33a3d-5577-49fe-8832-cb94c1cbb25d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3478	1	10	1	[0]	2019-07-15 08:00:00	\N	\N	7d887a16-b15e-4dc2-a7db-ce2f4afec35d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3479	1	9	1	[0]	2019-07-15 08:00:00	\N	\N	8def5c1b-deff-41dd-8f97-ae6835085fe9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3480	1	8	1	[0]	2019-07-15 08:00:00	\N	\N	cfcaa02a-dc0a-4449-b378-6cc49cd25a50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3481	1	12	1	[0]	2019-07-15 09:00:00	\N	\N	82c87b7b-5c98-4db2-8ec0-847e93e344c9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3482	1	11	1	[0]	2019-07-15 09:00:00	\N	\N	d981c006-5765-4f9f-a62b-ba04e4df5a92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3483	1	10	1	[0]	2019-07-15 09:00:00	\N	\N	40f01a53-5477-4bd6-86c5-8bc894e620fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3484	1	9	1	[0]	2019-07-15 09:00:00	\N	\N	552c025d-a3cc-489f-9c55-e5ef31233099	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3485	1	8	1	[0]	2019-07-15 09:00:00	\N	\N	bd1f6bd6-3df4-4725-8cbe-32ea6f8310bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3486	1	12	1	[0]	2019-07-15 10:00:00	\N	\N	b834ab71-b42c-4d12-ae36-a8b2a48be346	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3487	1	11	1	[0]	2019-07-15 10:00:00	\N	\N	91ae137a-e426-4eda-8756-32005f62b817	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3488	1	10	1	[0]	2019-07-15 10:00:00	\N	\N	38f8b9f7-cb64-40ca-9c6d-bd86076986c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3489	1	9	1	[0]	2019-07-15 10:00:00	\N	\N	144172c7-e0b0-4ffa-90d6-dcd0a384626a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3490	1	8	1	[0]	2019-07-15 10:00:00	\N	\N	c6fda8ef-f561-47f8-b9af-3c261535c436	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3491	1	12	1	[0]	2019-07-15 11:00:00	\N	\N	4ee06ec4-1b1d-4a09-afa6-2169f71d1cea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3492	1	11	1	[0]	2019-07-15 11:00:00	\N	\N	4de31bf7-558b-4247-b975-74ab655eb42f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3493	1	10	1	[0]	2019-07-15 11:00:00	\N	\N	83e35961-b76f-49d4-a24f-0fcebfd822a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3494	1	9	1	[0]	2019-07-15 11:00:00	\N	\N	7b02e06c-213e-44a4-94c2-999f817d99bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3495	1	8	1	[0]	2019-07-15 11:00:00	\N	\N	6cc376fe-128b-4a7c-ba00-3d47fc1f4a2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3496	1	12	1	[0]	2019-07-15 12:00:00	\N	\N	2142e815-8aaa-4305-a040-3840d63bb825	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3497	1	11	1	[0]	2019-07-15 12:00:00	\N	\N	38b0ee82-5821-4e44-a6e9-b0918c8779a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3498	1	10	1	[0]	2019-07-15 12:00:00	\N	\N	cd360221-29ed-4456-bab6-55c48c5109c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3499	1	9	1	[0]	2019-07-15 12:00:00	\N	\N	e94ae712-70c4-4d7e-83d8-85f7df78d1d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3500	1	8	1	[0]	2019-07-15 12:00:00	\N	\N	10309dea-6f54-4fcd-a100-6f161b3ee788	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3501	1	12	1	[0]	2019-07-15 13:00:00	\N	\N	59c65446-8ef0-49f3-ad3f-881ef5e07991	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3502	1	11	1	[0]	2019-07-15 13:00:00	\N	\N	63ecbdd3-2579-4eed-ac9a-c5472c276dee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3503	1	10	1	[0]	2019-07-15 13:00:00	\N	\N	cf087613-2f56-4496-aa64-e7cc0298efb9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3504	1	9	1	[0]	2019-07-15 13:00:00	\N	\N	2bd1e5fe-ddac-434a-b077-089f42dc2bf6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3505	1	8	1	[0]	2019-07-15 13:00:00	\N	\N	1e55b47c-adbf-44be-b40e-7609f4d00836	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3506	1	12	1	[0]	2019-07-15 14:00:00	\N	\N	2b116d08-8298-443e-b8b4-a8a9fd20d55d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3507	1	11	1	[0]	2019-07-15 14:00:00	\N	\N	fcfe86ad-d7d6-4283-8722-5872d9046a1c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3508	1	10	1	[0]	2019-07-15 14:00:00	\N	\N	206e1651-4d63-467e-a8dd-942c49abe560	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3509	1	9	1	[0]	2019-07-15 14:00:00	\N	\N	957e227e-1522-4039-94d2-f5465013767a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3510	1	8	1	[0]	2019-07-15 14:00:00	\N	\N	7349abe7-b416-4e96-8ecf-010153f1ef37	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3511	1	12	1	[0]	2019-07-15 15:00:00	\N	\N	53ff7159-3e08-464f-a807-4443bfb4626e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3512	1	11	1	[0]	2019-07-15 15:00:00	\N	\N	2d317bdb-0f1e-4a1c-9493-b0abc0381c36	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3513	1	10	1	[0]	2019-07-15 15:00:00	\N	\N	922319eb-6871-4cb6-a07f-ccd21c34c0e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3514	1	9	1	[0]	2019-07-15 15:00:00	\N	\N	bb50830c-c0a9-4a47-9490-4f6a8c28de33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3515	1	8	1	[0]	2019-07-15 15:00:00	\N	\N	9593a816-53a4-41c7-9faa-ce93e402db2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3516	1	12	1	[0]	2019-07-15 16:00:00	\N	\N	44fcdefe-e4a7-40e4-84dc-b983973a516e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3517	1	11	1	[0]	2019-07-15 16:00:00	\N	\N	46c4d74c-737a-44e4-a0b7-7c45231dcdab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3518	1	10	1	[0]	2019-07-15 16:00:00	\N	\N	9d934005-9fc9-4b91-b296-63b7a6fe471d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3519	1	9	1	[0]	2019-07-15 16:00:00	\N	\N	427973e1-edbf-4262-b208-26c5c43a95bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3520	1	8	1	[0]	2019-07-15 16:00:00	\N	\N	ea86603c-2a37-46fa-8923-ebd6a472b51a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3521	1	12	1	[0]	2019-07-15 17:00:00	\N	\N	ab42a8b3-83ff-4b77-beed-0bc9d0203079	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3522	1	11	1	[0]	2019-07-15 17:00:00	\N	\N	aaf796d6-65ee-44f6-bdcb-e1694f142ef6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3523	1	10	1	[0]	2019-07-15 17:00:00	\N	\N	80718b2c-6359-4de7-a7d0-805a488f71ae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3524	1	9	1	[0]	2019-07-15 17:00:00	\N	\N	a79d6b5f-ee6c-4603-b3b9-dc350688970d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3525	1	8	1	[0]	2019-07-15 17:00:00	\N	\N	8af57247-2402-4d60-a81a-dca542bc79be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3526	1	12	1	[0]	2019-07-15 18:00:00	\N	\N	bf4f8c1a-6f79-495f-bd32-ec66525a6ec9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3527	1	11	1	[0]	2019-07-15 18:00:00	\N	\N	4041ae12-4e5a-4f21-9830-359162767ea6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3528	1	10	1	[0]	2019-07-15 18:00:00	\N	\N	138e8882-dba0-4631-89ed-61c6946d8eae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3529	1	9	1	[0]	2019-07-15 18:00:00	\N	\N	1b352b80-d3a2-45b1-a004-3c10a1591e9e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3530	1	8	1	[0]	2019-07-15 18:00:00	\N	\N	b90277dc-679d-48ed-82e4-f3d3b225fd2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3531	1	12	1	[0]	2019-07-15 19:00:00	\N	\N	03fd228d-fc48-45c4-9378-eb8dbc6cc719	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3532	1	11	1	[0]	2019-07-15 19:00:00	\N	\N	64409aa6-278e-4194-a617-db323d0d81fb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3533	1	10	1	[0]	2019-07-15 19:00:00	\N	\N	2fe184e3-2d87-4329-b1e1-231fe65dbb87	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3534	1	9	1	[0]	2019-07-15 19:00:00	\N	\N	c473dd18-b1e1-4f04-a185-92837832e382	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3535	1	8	1	[0]	2019-07-15 19:00:00	\N	\N	69aae83b-dd41-41be-b87d-a18859db499a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3536	1	12	1	[0]	2019-07-15 20:00:00	\N	\N	e0acc34c-7dae-45cf-b5a4-e4b6c42c3e09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3537	1	11	1	[0]	2019-07-15 20:00:00	\N	\N	eefcad3e-1163-43be-8638-94272a175093	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3538	1	10	1	[0]	2019-07-15 20:00:00	\N	\N	4ed4ac9e-2223-46fa-bbd5-123463822ede	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3539	1	9	1	[0]	2019-07-15 20:00:00	\N	\N	b45a1cd4-86c5-4699-9a7d-90dc21bba9f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3540	1	8	1	[0]	2019-07-15 20:00:00	\N	\N	c31f242e-d156-4c8e-852f-bc06456cd8f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3541	1	12	1	[0]	2019-07-15 21:00:00	\N	\N	29422306-d5ac-4a36-a2c8-eb8dcd22ea3f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3542	1	11	1	[0]	2019-07-15 21:00:00	\N	\N	9f476aab-5422-47a1-a1b0-b53437f47331	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3543	1	10	1	[0]	2019-07-15 21:00:00	\N	\N	eddabb41-ed21-461e-a028-0d649ee4980e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3544	1	9	1	[0]	2019-07-15 21:00:00	\N	\N	72e7c427-8510-4f8e-b6cb-b8063d404b9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3545	1	8	1	[0]	2019-07-15 21:00:00	\N	\N	c551bbb9-3808-4878-bf9e-fdf649b33e05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3546	1	12	1	[0]	2019-07-15 22:00:00	\N	\N	deda1d7e-23d3-4cac-82ff-f734988b5118	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3547	1	11	1	[0]	2019-07-15 22:00:00	\N	\N	4ab63042-d1e3-435c-83b9-64f9c1851a6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3548	1	10	1	[0]	2019-07-15 22:00:00	\N	\N	e861554c-6b7a-4dba-84d8-35a623e40cdb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3549	1	9	1	[0]	2019-07-15 22:00:00	\N	\N	118dc897-dc25-4db5-a8b2-00397b2023ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3550	1	8	1	[0]	2019-07-15 22:00:00	\N	\N	22016d1a-bdf5-464f-ad6a-dade617e7392	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3551	1	12	1	[0]	2019-07-15 23:00:00	\N	\N	18ba50ae-773d-42a3-b916-0303a8fd7cd9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3552	1	11	1	[0]	2019-07-15 23:00:00	\N	\N	aa85513f-8f61-4917-b9ce-59f61099d04c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3553	1	10	1	[0]	2019-07-15 23:00:00	\N	\N	5ae60d7e-f4c7-4091-80bf-f6caecbfe27d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3554	1	9	1	[0]	2019-07-15 23:00:00	\N	\N	1f847373-1904-4339-aade-189737303b24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3555	1	8	1	[0]	2019-07-15 23:00:00	\N	\N	1c45eebf-7775-47a1-9a12-70654f440c3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3556	1	12	1	[0]	2019-07-16 00:00:00	\N	\N	cf737cc0-8eb8-4b74-8c12-d90f07ff0de1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3557	1	11	1	[0]	2019-07-16 00:00:00	\N	\N	f40f25a4-122d-495e-b8ec-e61b61ae9d79	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3558	1	10	1	[0]	2019-07-16 00:00:00	\N	\N	dd6b7d05-66f0-4e81-872e-32df38ef0819	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3559	1	9	1	[0]	2019-07-16 00:00:00	\N	\N	7cb657a4-930e-454b-a1fb-6c76b197ef43	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3560	1	8	1	[0]	2019-07-16 00:00:00	\N	\N	3f1d67b1-4629-415b-b0a1-11827a224ca0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3561	1	12	1	[0]	2019-07-16 01:00:00	\N	\N	85df02a6-477f-4310-90ad-c18dcfe56f54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3562	1	11	1	[0]	2019-07-16 01:00:00	\N	\N	5ba89a51-7120-4a20-a910-3ad60002df0e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3563	1	10	1	[0]	2019-07-16 01:00:00	\N	\N	d887717a-1027-45b3-8c7d-d5afc7e02245	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3564	1	9	1	[0]	2019-07-16 01:00:00	\N	\N	b06164d3-95a9-4ef7-a876-46d4211703b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3565	1	8	1	[0]	2019-07-16 01:00:00	\N	\N	eba3fce4-2af7-4450-8adf-ff822a588cec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3566	1	12	1	[0]	2019-07-16 02:00:00	\N	\N	16f8b497-be3e-41f0-9cc1-70de8c3c1a49	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3567	1	11	1	[0]	2019-07-16 02:00:00	\N	\N	1a90be0a-5a25-43f6-b211-4842e02f9140	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3568	1	10	1	[0]	2019-07-16 02:00:00	\N	\N	f01a0dee-9a9a-4ba9-b96a-c19a6a6b8992	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3569	1	9	1	[0]	2019-07-16 02:00:00	\N	\N	c3cfd28d-71f2-428c-8f1f-c98306ab96b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3570	1	8	1	[0]	2019-07-16 02:00:00	\N	\N	31bc18ac-9b0d-458e-926b-d5a111137ffc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3571	1	12	1	[0]	2019-07-16 03:00:00	\N	\N	bf5052e4-a2da-4570-bdd5-0676c9921d11	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3572	1	11	1	[0]	2019-07-16 03:00:00	\N	\N	a59f9d74-58f1-46b2-93c5-18d92836e14b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3573	1	10	1	[0]	2019-07-16 03:00:00	\N	\N	7b375c50-1fd1-4302-a43c-f20ea59d0fc1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3574	1	9	1	[0]	2019-07-16 03:00:00	\N	\N	8c96b163-df64-4597-8d57-19c4c6e95050	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3575	1	8	1	[0]	2019-07-16 03:00:00	\N	\N	119ca806-12d1-415e-b55f-6273aeada36d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3576	1	12	1	[0]	2019-07-16 04:00:00	\N	\N	db7b4576-b732-4f50-b30c-504e9d1bd4b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3577	1	11	1	[0]	2019-07-16 04:00:00	\N	\N	b45216f1-4288-407a-b72d-319394cfe846	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3578	1	10	1	[0]	2019-07-16 04:00:00	\N	\N	a09ec97d-8cd9-480e-9729-377e7b2c10a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3579	1	9	1	[0]	2019-07-16 04:00:00	\N	\N	14b3c862-e962-49c8-8e2a-3dd5fff0a94d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3580	1	8	1	[0]	2019-07-16 04:00:00	\N	\N	2edf544a-e576-4e09-8fe8-c940a5503c54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3581	1	12	1	[0]	2019-07-16 05:00:00	\N	\N	72922c6b-9d0c-44d6-8dea-9d663cf55f47	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3582	1	12	1	[0]	2019-07-16 06:00:00	\N	\N	d2b63a89-1fe2-4735-bcaf-c18cbdca5b95	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3583	2	49	4	[960]	2010-01-01 00:00:00	\N	\N	416129bd-5a0d-4903-832e-7eb5d35dd47c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3584	2	50	4	[448]	2010-01-01 00:00:00	\N	\N	aacb8ecb-e85f-405e-a619-611707224ec9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3585	2	51	4	[1638]	2010-01-01 00:00:00	\N	\N	90309cf2-1e6a-4261-b375-2054e0d7805d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3586	2	52	4	[654]	2010-01-01 00:00:00	\N	\N	8a2c5de7-2919-4ffc-b448-7e90ea0cc217	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3587	2	53	4	[360]	2010-01-01 00:00:00	\N	\N	82d5f93a-70a5-48ba-a2f9-2cd7f44d9a6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3588	2	54	4	[635]	2010-01-01 00:00:00	\N	\N	2f5a1bc8-7596-4ce7-9a14-ba19f3520587	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3589	2	55	4	[3070]	2010-01-01 00:00:00	\N	\N	2df0c9e1-bfa9-4af0-a00e-5d22cbd0ac7b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3590	2	56	4	[3293]	2010-01-01 00:00:00	\N	\N	dec85320-1ba9-4d17-b636-c8467d6ffb83	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3591	2	57	4	[1265]	2010-01-01 00:00:00	\N	\N	4bfabc47-c580-4d70-950c-b40d87168c2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3592	2	58	4	[4448]	2010-01-01 00:00:00	\N	\N	441bf093-2ceb-4cdc-8d00-cfc9099f5ef5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3593	2	59	4	[802]	2010-01-01 00:00:00	\N	\N	37bdd9ea-0a43-4aba-b900-9bf10d5af76d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3594	2	49	5	[956]	2013-01-01 00:00:00	\N	\N	4ff3a8de-7a6f-4005-8bfb-8adab112ea8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3595	2	50	5	[450]	2013-01-01 00:00:00	\N	\N	084963a0-ac8c-4b22-8a57-f60256ba867b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3596	2	51	5	[1604]	2013-01-01 00:00:00	\N	\N	5a8ce869-8d98-4664-8824-2637fa2a160f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3597	2	52	5	[659]	2013-01-01 00:00:00	\N	\N	1d8eed65-55ef-4ad1-a238-b39609091de1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3598	2	53	5	[361]	2013-01-01 00:00:00	\N	\N	a8995056-e2c0-4a80-96f2-ce7db8971dc9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3599	2	54	5	[617]	2013-01-01 00:00:00	\N	\N	144fdc6b-83e6-4354-861c-297d2150b8bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3600	2	55	5	[3044]	2013-01-01 00:00:00	\N	\N	fdac5bd8-20a7-47ee-8dcd-ee250600109e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3601	2	56	5	[3264]	2013-01-01 00:00:00	\N	\N	6dd20c7b-a324-4b97-a774-8e9c91ca45f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3602	2	57	5	[1239]	2013-01-01 00:00:00	\N	\N	ddc8f371-b84d-43a3-b788-b08e53fa1f77	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3603	2	58	5	[4581]	2013-01-01 00:00:00	\N	\N	a013e5d7-9346-4202-8b3c-e5e7c490cc6d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3604	2	59	5	[805]	2013-01-01 00:00:00	\N	\N	c410deeb-a843-49e8-a09a-0b7011227295	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3605	2	49	6	[982]	2014-01-01 00:00:00	\N	\N	8298f55f-2a3e-4cc9-bde6-58dcc961d447	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3606	2	50	6	[460]	2014-01-01 00:00:00	\N	\N	d6875e7e-f0a0-4e54-b8bc-df7909a49f80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3607	2	51	6	[1541]	2014-01-01 00:00:00	\N	\N	e34ab50a-cdc5-41a8-bae2-b5596aa1d164	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3608	2	52	6	[635]	2014-01-01 00:00:00	\N	\N	ccc436d1-d08a-40cf-9257-ee69c2f8af54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3609	2	53	6	[379]	2014-01-01 00:00:00	\N	\N	40ccd83e-ec24-4e22-b26c-e29ff4494015	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3610	2	54	6	[669]	2014-01-01 00:00:00	\N	\N	3d5ddde1-0f22-4264-a97e-4b207a2cbc40	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3611	2	55	6	[3082]	2014-01-01 00:00:00	\N	\N	0bc4a06e-7a22-4b76-88d9-ee21ed6174ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3612	2	56	6	[3405]	2014-01-01 00:00:00	\N	\N	08ab1813-7e8c-4039-b091-f0e2ff59e494	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3613	2	57	6	[1267]	2014-01-01 00:00:00	\N	\N	84a260ba-06c8-4881-a0a4-507a80e2bcb9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3614	2	58	6	[4343]	2014-01-01 00:00:00	\N	\N	a961ea53-15bb-47c8-9761-846052285a70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3615	2	59	6	[799]	2014-01-01 00:00:00	\N	\N	ac292103-dd37-482a-a81a-5c84bed57244	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3616	2	49	7	[963]	2015-01-01 00:00:00	\N	\N	f1744a2e-0120-4322-a682-cab160db27bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3617	2	50	7	[458]	2015-01-01 00:00:00	\N	\N	08ab1a85-e99d-4c1d-b901-a3ae1744bb65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3618	2	51	7	[1530]	2015-01-01 00:00:00	\N	\N	4064bc6d-b96b-4ad2-b490-b00fce5d42d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3619	2	52	7	[638]	2015-01-01 00:00:00	\N	\N	f40e75b1-c6d8-49de-a090-94c14fe03ce8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3620	2	53	7	[381]	2015-01-01 00:00:00	\N	\N	ec0193ce-66e2-444e-bf2d-8d0b94c25ec4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3621	2	54	7	[663]	2015-01-01 00:00:00	\N	\N	f1e16933-9842-458d-b7e0-c87009241c1d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3622	2	55	7	[3076]	2015-01-01 00:00:00	\N	\N	2837b031-94f9-4a02-b954-656f7b18f7ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3623	2	56	7	[3439]	2015-01-01 00:00:00	\N	\N	355febd2-39ea-4906-a783-3f38c5292d77	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3624	2	57	7	[1251]	2015-01-01 00:00:00	\N	\N	bc1a3bbf-0f2b-4b5f-8d1b-f69c474eb4eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3625	2	58	7	[4368]	2015-01-01 00:00:00	\N	\N	65ce00be-d73d-4d21-a24b-81fa02a23f0b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3626	2	59	7	[801]	2015-01-01 00:00:00	\N	\N	31629129-324f-4f12-8562-ee5fd8e036cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3627	3	332	8	[777]	2017-10-31 13:53:36	\N	\N	1adae0cf-0f3b-4af5-bf26-e72c7fde24f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3628	3	331	8	[779]	2017-10-31 13:53:25	\N	\N	3896325c-c002-4ad1-8a4f-d98364761b13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3629	3	330	8	[780]	2017-10-31 13:53:14	\N	\N	2c9ea2a2-a188-47f4-9891-93e74df84b92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3630	3	329	8	[782]	2017-10-31 13:52:59	\N	\N	e2fd020c-49c2-4780-bb11-511893c6b545	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3631	3	328	8	[784]	2017-10-31 13:52:55	\N	\N	2fc62873-28f1-4150-b297-c145deb4b1c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3632	3	327	8	[784]	2017-10-31 13:52:40	\N	\N	275ee8a7-8735-406e-bb2a-f762a41e7cc5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3633	3	326	8	[782]	2017-10-31 13:52:28	\N	\N	9f7848bb-e642-41b7-8d10-6f67389f3368	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3634	3	325	8	[781]	2017-10-31 13:52:25	\N	\N	6bc64c0a-b508-41e3-a1b9-c3f6cf3dacaa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3635	3	324	8	[783]	2017-10-31 13:52:08	\N	\N	4dd1ef48-301a-4e9c-a72d-0b52a11bc4e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3636	3	323	8	[783]	2017-10-31 13:52:03	\N	\N	4abe12c2-6bc2-4ea5-a8b9-92f5c3d88f7a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3637	3	322	8	[784]	2017-10-31 13:51:54	\N	\N	c8bb3242-408b-4ce1-b722-2fdd3ed9cadb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3638	3	321	8	[783]	2017-10-31 13:51:40	\N	\N	3d668054-88a1-40cd-82f5-c4e54ad226e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3639	3	320	8	[782]	2017-10-31 13:51:35	\N	\N	77978d07-d157-4343-83dc-ba339b647bcd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3640	3	319	8	[782]	2017-10-31 13:51:29	\N	\N	65e71385-6cbf-47fd-800c-dbeb407ffb79	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3641	3	318	8	[782]	2017-10-31 13:51:22	\N	\N	8c8d7c90-22fc-448e-b5f7-62f642959f23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3642	3	317	8	[784]	2017-10-31 13:51:04	\N	\N	3460dd50-1c4b-4348-a8bd-4409a382a9ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3643	3	316	8	[783]	2017-10-31 13:50:58	\N	\N	1b4428e4-8654-4458-9385-37fa7c444ded	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3644	3	315	8	[782]	2017-10-31 13:50:52	\N	\N	fd88d100-da8d-41b7-adc5-6f8dc1297f44	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3645	3	314	8	[783]	2017-10-31 13:50:46	\N	\N	419dcf2d-fc47-4b8e-bb2e-1aae33d14668	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3646	3	313	8	[784]	2017-10-31 13:50:43	\N	\N	a620fe80-6119-453e-9202-54e6abb55379	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3647	3	312	8	[785]	2017-10-31 13:50:36	\N	\N	39ad0061-40fa-4111-b965-1756184fdf91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3648	3	311	8	[785]	2017-10-31 13:50:33	\N	\N	de32957b-ec77-4d1f-961f-7b30df03559e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3649	3	310	8	[786]	2017-10-31 13:50:24	\N	\N	f508f664-cbdb-4644-a60e-deac5db1301b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3650	3	309	8	[788]	2017-10-31 13:50:20	\N	\N	42d21c04-ac66-4c48-acf6-bb4b75a3c431	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3651	3	308	8	[790]	2017-10-31 13:50:16	\N	\N	65144189-9547-4d48-9b6d-c85d6831cbf3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3652	3	307	8	[792]	2017-10-31 13:50:07	\N	\N	ad1f1897-19af-4f78-8926-df238a0cd714	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3653	3	306	8	[794]	2017-10-31 13:49:51	\N	\N	aba379f4-883a-4f78-8fdd-c2ede0f3dea5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3654	3	305	8	[794]	2017-10-31 13:49:46	\N	\N	61f1edb4-4173-4831-b2c5-35157922c1f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3655	3	304	8	[794]	2017-10-31 13:49:41	\N	\N	631c0740-6a0c-4209-b2ab-91bf1d73310c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3656	3	303	8	[794]	2017-10-31 13:49:37	\N	\N	31a17991-6c89-461a-8a4c-cdd8e344308f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3657	3	302	8	[795]	2017-10-31 13:49:21	\N	\N	1e1d4c82-7cee-4034-8a9b-88cd9021b226	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3658	3	301	8	[795]	2017-10-31 13:49:16	\N	\N	a626da3f-c2b1-4d31-ac08-f6ecbd28d37b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3659	3	300	8	[795]	2017-10-31 13:49:10	\N	\N	b45dca9f-8b21-4e23-a1f2-f6463c2f5986	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3660	3	299	8	[795]	2017-10-31 13:49:00	\N	\N	f0b0d3af-81d6-45b7-af29-ce687baf1163	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3661	3	298	8	[795]	2017-10-31 13:48:55	\N	\N	3cd6bb8a-d6db-44de-bade-36f33ce5b74e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3662	3	297	8	[794]	2017-10-31 13:48:50	\N	\N	cd9434a8-4624-4012-a837-420d37b1149b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3663	3	296	8	[794]	2017-10-31 13:48:46	\N	\N	62a8ce09-714b-417e-9c66-b8ef2a8870f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3664	3	295	8	[793]	2017-10-31 13:48:42	\N	\N	fdd976ef-c08c-40aa-9ce9-60c2f87f07b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3665	3	294	8	[791]	2017-10-31 13:48:38	\N	\N	149c02a5-cfeb-4926-84d2-f8b064d4fa40	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3666	3	293	8	[791]	2017-10-31 13:48:31	\N	\N	a5d57ef9-6962-4dc6-960d-65b1dafd559c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3667	3	292	8	[791]	2017-10-31 13:48:22	\N	\N	8c442ec8-2dde-45fd-a97d-957139fde71a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3668	3	291	8	[791]	2017-10-31 13:48:16	\N	\N	232219a8-cb1f-4a58-90da-eaae210f671d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3669	3	290	8	[792]	2017-10-31 13:48:07	\N	\N	9c251a32-fc48-47f8-9be7-5db2bc31f222	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3670	3	289	8	[791]	2017-10-31 13:47:55	\N	\N	0fbe0f77-44b2-4d93-8b32-9d4738955ec1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3671	3	288	8	[789]	2017-10-31 13:47:50	\N	\N	a65cf873-b9d8-4575-9687-f22486bea078	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3672	3	287	8	[788]	2017-10-31 13:47:44	\N	\N	9474a537-23ac-455f-b4da-7ec10cb24d62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3673	3	286	8	[787]	2017-10-31 13:47:38	\N	\N	5a2db385-11ee-4942-adcb-1b763849001a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3674	3	285	8	[785]	2017-10-31 13:47:27	\N	\N	b4a847e7-3dd2-4755-824d-cbebe584c872	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3675	3	284	8	[784]	2017-10-31 13:47:16	\N	\N	7b4fbd37-5801-47c3-b0b1-d2f2e2f37f99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3676	3	283	8	[784]	2017-10-31 13:47:08	\N	\N	f387a5d7-68d3-4141-8412-648da83977de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3677	3	282	8	[786]	2017-10-31 13:47:00	\N	\N	68ba47da-e017-488e-9e2b-0da7cadaa450	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3678	3	281	8	[789]	2017-10-31 13:46:51	\N	\N	3a90c2d3-2af3-40f0-b948-55301ed7c5e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3679	3	280	8	[788]	2017-10-31 13:46:44	\N	\N	77192020-a080-4006-a2b7-f847d1ed1882	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3680	3	279	8	[784]	2017-10-31 13:46:25	\N	\N	b86f89db-88bc-4c51-996d-72438da5fb4c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3681	3	278	8	[785]	2017-10-31 13:44:29	\N	\N	6392db13-985f-4d1b-aa81-2ef6f8e705c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3682	3	277	8	[786]	2017-10-31 13:44:23	\N	\N	d5c11c09-19da-47dd-850e-c4746fe1b7f8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3683	3	276	8	[787]	2017-10-31 13:44:18	\N	\N	5d6f5a77-bd32-41a1-8e52-c2a4d646b785	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3684	3	275	8	[788]	2017-10-31 13:44:09	\N	\N	c2a46cbf-769a-4b9f-a270-75d460eed02f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3685	3	274	8	[785]	2017-10-31 13:43:47	\N	\N	30fd376d-16bd-48fe-ac37-f39b36a95a63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3686	3	273	8	[785]	2017-10-31 13:43:43	\N	\N	c1ae6ca9-436a-40ab-b1c7-0763a9b631f2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3687	3	272	8	[784]	2017-10-31 13:43:38	\N	\N	3c26092e-b0ac-4c23-804c-6f304129ea17	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3688	3	271	8	[782]	2017-10-31 13:43:29	\N	\N	6090db39-1a0e-4771-b2a8-4f592ab35f7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3689	3	270	8	[778]	2017-10-31 13:43:16	\N	\N	2526c74e-bd2f-4919-8a11-d298a9c6641d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3690	3	269	8	[778]	2017-10-31 13:43:07	\N	\N	5bfe0f23-ff59-4f55-8589-1764ee26f73f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3691	3	268	8	[778]	2017-10-31 13:42:47	\N	\N	80ed5d19-8d39-4029-b750-2c59cc839955	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3692	3	267	8	[773]	2017-10-31 13:42:00	\N	\N	e5002297-ff4f-412b-9c04-b4978bb94def	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3693	3	266	8	[773]	2017-10-31 13:41:55	\N	\N	c049778a-ad99-4a10-9e08-e854105eb904	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3694	3	265	8	[772]	2017-10-31 13:41:48	\N	\N	e71887c4-0466-4911-aede-ca80431d5f50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3695	3	264	8	[770]	2017-10-31 13:41:41	\N	\N	c12a0e5d-036d-4f99-8700-67dc98e9ff6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3696	3	263	8	[770]	2017-10-31 13:41:35	\N	\N	04f662b1-0417-489a-ac80-b37aba33019b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3697	3	262	8	[771]	2017-10-31 13:41:15	\N	\N	fa4ff156-6521-4810-9ad6-59d875c912f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3698	3	261	8	[770]	2017-10-31 13:40:54	\N	\N	e9375439-60c0-486f-bfad-4231afbb4d6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3699	3	260	8	[769]	2017-10-31 13:40:49	\N	\N	344d0b4c-7055-4690-ad06-0589ad9ef74b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3700	3	259	8	[767]	2017-10-31 13:40:43	\N	\N	21fa0152-e8a3-434a-adf0-7c2d7caa3e26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3701	3	258	8	[766]	2017-10-31 13:40:37	\N	\N	12269d90-d3e3-4570-bb69-867e6453306a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3702	3	257	8	[764]	2017-10-31 13:40:26	\N	\N	335db11b-e859-4361-a5f3-562bc0f1be2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3703	3	256	8	[763]	2017-10-31 13:40:21	\N	\N	0be50ece-6743-4f87-b0db-876851246d71	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3704	3	255	8	[763]	2017-10-31 13:40:17	\N	\N	38dbac06-71f1-4018-8911-11311eeda3dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3705	3	254	8	[762]	2017-10-31 13:39:55	\N	\N	d81756f4-d581-4acf-9d71-84ee2fa44e62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3706	3	253	8	[762]	2017-10-31 13:39:18	\N	\N	2129524c-06fc-499f-94fd-19f3644fb363	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3707	3	252	8	[762]	2017-10-31 13:39:11	\N	\N	231055ee-596b-4843-b086-58f330762fa8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3708	3	251	8	[761]	2017-10-31 13:39:00	\N	\N	b2813b57-4b0c-434a-b3b7-dacac58e8c09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3709	3	250	8	[761]	2017-10-31 13:38:56	\N	\N	0009b90f-b260-4c37-ad5f-83e2474b4c65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3710	3	249	8	[762]	2017-10-31 13:38:51	\N	\N	d742f1fe-3409-4697-9abf-3676a857540b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3711	3	248	8	[762]	2017-10-31 13:38:29	\N	\N	96a83c4c-84f5-4894-a861-b084940043fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3712	3	247	8	[762]	2017-10-31 13:38:20	\N	\N	d7400b52-c455-477e-9a72-cdc5e639115b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3713	3	246	8	[763]	2017-10-31 13:38:13	\N	\N	6a4b4c64-2b40-47ae-8e67-3692e2e2f139	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3714	3	245	8	[763]	2017-10-31 13:38:08	\N	\N	c5ef2fd5-2a90-46da-b4af-faa1bc030c85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3715	3	244	8	[763]	2017-10-31 13:38:04	\N	\N	d759f111-fc51-4353-b18b-1056acec0571	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3716	3	243	8	[762]	2017-10-31 13:37:58	\N	\N	c9f102be-0e89-4e02-985f-cd832937a770	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3717	3	242	8	[762]	2017-10-31 13:37:51	\N	\N	157e8f3f-6344-4c81-a7cc-e667d81eddca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3718	3	241	8	[760]	2017-10-31 13:37:45	\N	\N	82128d72-827a-4fcd-99fa-e9134102d188	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3719	3	240	8	[760]	2017-10-31 13:37:29	\N	\N	aeb3066d-2121-4b51-a235-683155273a67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3720	3	239	8	[758]	2017-10-31 13:36:57	\N	\N	a63515c4-b332-4ecc-b501-444b57e22d67	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3721	3	238	8	[758]	2017-10-31 13:36:52	\N	\N	6420d453-c559-4119-9a16-53de73a5d38a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3722	3	237	8	[758]	2017-10-31 13:36:46	\N	\N	348313b3-9688-4dbf-84eb-616a85aed7de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3723	3	236	8	[759]	2017-10-31 13:36:38	\N	\N	0cca4d7d-b52b-43ee-aff1-14288976d507	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3724	3	235	8	[759]	2017-10-31 13:36:32	\N	\N	3529f6b5-1ede-4034-831a-7e651bebd48a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3725	3	234	8	[759]	2017-10-31 13:36:20	\N	\N	66f97912-f66a-411b-a249-b48c095b6150	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3726	3	233	8	[759]	2017-10-31 13:36:15	\N	\N	6d1032d3-a98b-4b34-a61b-5894f83dc324	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3727	3	232	8	[759]	2017-10-31 13:36:10	\N	\N	528fa288-ead3-4210-bbb0-7cd94f6d8f62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3728	3	231	8	[760]	2017-10-31 13:35:56	\N	\N	00520bba-0777-4575-8572-f95af59509a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3729	3	230	8	[760]	2017-10-31 13:35:50	\N	\N	8edfa1a2-b8df-4edc-87a8-c0ba8422a610	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3730	3	229	8	[760]	2017-10-31 13:35:44	\N	\N	22bd770a-a4cb-4124-9584-c85c5986a7ec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3731	3	228	8	[760]	2017-10-31 13:35:37	\N	\N	afa4c903-831a-4480-9db2-7ca9a10073f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3732	3	227	8	[757]	2017-10-31 13:35:26	\N	\N	b1f52c03-237a-4a02-ac49-51c83e6f8668	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3733	3	226	8	[752]	2017-10-31 13:35:18	\N	\N	5a09dd7b-64e9-47f1-8ba4-0e6e062dcc8a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3734	3	225	8	[750]	2017-10-31 13:35:13	\N	\N	3aa312a6-e314-4f72-8686-0c54559a336d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3735	3	224	8	[743]	2017-10-31 13:35:04	\N	\N	9fb1e25e-af3f-4987-a18e-772706cb1c63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3736	3	223	8	[741]	2017-10-31 13:32:04	\N	\N	008f9a2e-0910-4f78-9594-bce58b7a5c35	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3737	3	222	8	[741]	2017-10-31 13:31:56	\N	\N	a518f1c8-e03d-4571-88ef-3b4d6e7ca5c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3738	3	221	8	[741]	2017-10-31 13:31:49	\N	\N	b76c2ee1-5ec2-4dc8-8082-0e1886f51817	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3739	3	220	8	[740]	2017-10-31 13:31:43	\N	\N	48c5e517-9dfc-4dfb-bd7d-868b43d87bda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3740	3	219	8	[737]	2017-10-31 13:31:29	\N	\N	71b80e19-40da-4d8c-a451-d92c771f5086	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3741	3	218	8	[737]	2017-10-31 13:31:24	\N	\N	927c0f6e-2966-4d9a-902b-c35b5ad5f99a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3742	3	217	8	[737]	2017-10-31 13:31:18	\N	\N	a45bf240-d73d-4579-b7fa-0584fd1bfe2e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3743	3	216	8	[736]	2017-10-31 13:31:13	\N	\N	d9319f40-c826-4afc-ab81-b08aba98e45f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3744	3	215	8	[735]	2017-10-31 13:31:08	\N	\N	5d789513-ae75-47da-9170-c210d201027a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3745	3	214	8	[735]	2017-10-31 13:30:51	\N	\N	7dc42f06-0870-4e67-a7a7-57cb3f4a9cf0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3746	3	213	8	[735]	2017-10-31 13:30:41	\N	\N	2f1a1ebb-a05e-4c56-a94a-cf9968c994b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3747	3	212	8	[735]	2017-10-31 13:30:35	\N	\N	b789000a-00bb-4c3c-ac72-c415a6bb6fcd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3748	3	211	8	[735]	2017-10-31 13:30:28	\N	\N	9cd9de0f-867f-4587-a410-091a2f5087f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3749	3	210	8	[735]	2017-10-31 13:30:20	\N	\N	7a58e798-9de2-4d5c-9fec-86c8e457815a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3750	3	209	8	[734]	2017-10-31 13:30:16	\N	\N	c3b8b82f-6b5f-41cd-a71d-575a29720502	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3751	3	208	8	[733]	2017-10-31 13:30:12	\N	\N	ec0282d7-e102-48d6-8d23-32a048aa94e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3752	3	207	8	[730]	2017-10-31 13:30:08	\N	\N	3b81e391-8b8f-4a9c-b6d0-0e446cce0f51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3753	3	206	8	[723]	2017-10-31 13:29:54	\N	\N	deeadec9-900e-4c16-81d3-0bde4d1fa859	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3754	3	205	8	[723]	2017-10-31 13:29:45	\N	\N	25840154-70d6-4418-b8ff-49d643b922d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3755	3	204	8	[723]	2017-10-31 13:29:34	\N	\N	eb4a15b4-bee2-43be-a73c-6e42f1cdc7d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3756	3	203	8	[724]	2017-10-31 13:29:28	\N	\N	270556a2-7bfe-470a-a5db-947865da6552	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3757	3	202	8	[726]	2017-10-31 13:29:08	\N	\N	6541e3b5-f2bf-4828-8c8f-288dc00fda22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3758	3	201	8	[723]	2017-10-31 13:29:00	\N	\N	8c870838-66fb-475e-949a-6978d1108314	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3759	3	200	8	[722]	2017-10-31 13:28:56	\N	\N	0d2fbac7-213c-4f99-a32f-3205c3085232	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3760	3	199	8	[721]	2017-10-31 13:28:50	\N	\N	a291a0b8-dff8-4322-bf2b-f5e7b28a84c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3761	3	198	8	[717]	2017-10-31 13:28:39	\N	\N	79d4920b-2e13-4b02-a768-1d2509194254	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3762	3	197	8	[712]	2017-10-31 13:28:31	\N	\N	145cdb56-6dd4-412d-aa15-c659dac5b8d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3763	3	196	8	[711]	2017-10-31 13:28:23	\N	\N	68ea1e70-b24f-4b3a-b4b2-776573bd7fc3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3764	3	195	8	[707]	2017-10-31 13:28:11	\N	\N	b820ac44-d193-42ab-b38b-490e9fc950d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3765	3	194	8	[707]	2017-10-31 13:27:52	\N	\N	2cb54d5b-3477-4e41-ae1a-f74fb66cb67b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3766	3	193	8	[707]	2017-10-31 13:27:47	\N	\N	c9b36cd9-4adf-45b4-9d84-5e635449660e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3767	3	192	8	[707]	2017-10-31 13:27:42	\N	\N	7f5e0550-c1a8-4f5e-9dac-f923da27f65c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3768	3	191	8	[706]	2017-10-31 13:27:32	\N	\N	bc7ca54c-5972-4e21-8a30-12e243c96270	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3769	3	190	8	[703]	2017-10-31 13:27:28	\N	\N	74d971fa-1940-4c4b-a279-df8fbefbf08f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3770	3	189	8	[697]	2017-10-31 13:27:08	\N	\N	aac5fd3d-ed2f-4b5e-be12-a5d3c634ac45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3771	3	188	8	[696]	2017-10-31 13:27:03	\N	\N	132c803c-3229-4772-9a18-70fb1b8298d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3772	3	187	8	[692]	2017-10-31 13:26:49	\N	\N	30a3f8f0-017f-47c8-b47d-9303810a576e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3773	3	186	8	[692]	2017-10-31 13:26:46	\N	\N	c42395f1-bac0-451c-b8c3-c2fb322837d8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3774	3	185	8	[691]	2017-10-31 13:26:31	\N	\N	f1205eac-b533-43fe-ac69-54ecbfe40415	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3775	3	184	8	[689]	2017-10-31 13:26:19	\N	\N	e9b6a4a4-b7c2-4005-bfc4-0d1e695d243e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3776	3	183	8	[689]	2017-10-31 13:26:01	\N	\N	891bee1b-e82e-4c0b-819f-63e6c582a10d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3777	3	182	8	[689]	2017-10-31 13:25:55	\N	\N	32e86798-775e-427f-9f75-f184cbd3a915	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3778	3	181	8	[689]	2017-10-31 13:25:51	\N	\N	23140bea-28ae-4e7b-9c67-75d3cfd107a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3779	3	180	8	[687]	2017-10-31 13:25:41	\N	\N	7d826365-fbab-4b61-a180-f26e3dfd0925	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3780	3	179	8	[685]	2017-10-31 13:25:34	\N	\N	393de344-c7fb-4994-923c-5b6449db94aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3781	3	178	8	[683]	2017-10-31 13:25:28	\N	\N	c2cd9bff-c1ea-493b-94d2-c0560f025ba0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3782	3	177	8	[683]	2017-10-31 13:25:24	\N	\N	f8f3ba05-ac46-4270-b911-3146de0b5b8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3783	3	176	8	[681]	2017-10-31 13:24:54	\N	\N	c3b12432-138a-4e28-99f7-c0feb79d3046	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3784	3	175	8	[677]	2017-10-31 13:24:41	\N	\N	9c213951-496a-4618-995d-2f630008493b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3785	3	174	8	[676]	2017-10-31 13:24:29	\N	\N	32a604dd-b8e5-44bd-a205-d1930d7751f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3786	3	173	8	[675]	2017-10-31 13:24:22	\N	\N	7507d3d9-ed1c-49ca-9e60-9110925d799d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3787	3	172	8	[675]	2017-10-31 13:24:18	\N	\N	1cfe5d63-a46e-4118-8778-9d9883075d21	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3788	3	171	8	[676]	2017-10-31 13:23:57	\N	\N	cc5a4a4b-96ca-42f0-8dd8-3b98f10a5c4c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3789	3	170	8	[677]	2017-10-31 13:23:54	\N	\N	f31fd226-61d4-4c23-8a2d-d2b90fc8452a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3790	3	169	8	[672]	2017-10-31 13:23:36	\N	\N	e7ccd5f4-0766-43b4-ae18-041c95080666	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3791	3	168	8	[672]	2017-10-31 13:23:23	\N	\N	7333df05-d23b-464d-addb-36ce0918c158	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3792	3	167	8	[670]	2017-10-31 13:23:17	\N	\N	ca53f17f-ba75-4356-8eda-fde142ff7487	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3793	3	166	8	[669]	2017-10-31 13:23:11	\N	\N	4d7ec323-a0be-43b7-80de-dd051c9a8b96	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3794	3	165	8	[667]	2017-10-31 13:23:06	\N	\N	37ec8731-a8e7-43eb-8722-bea6b48bfdc8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3795	3	164	8	[669]	2017-10-31 13:22:48	\N	\N	5167864a-103b-4af5-8441-603038499c04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3796	3	163	8	[668]	2017-10-31 13:22:35	\N	\N	b79f38a4-c5d6-4686-a02c-854e0e3e4b08	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3797	3	162	8	[671]	2017-10-31 13:22:17	\N	\N	a16193f9-a10b-4aef-acc9-67a9c9964d6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3798	3	161	8	[672]	2017-10-31 13:22:10	\N	\N	15968631-b538-4642-a78e-681a89c1f372	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3799	3	160	8	[674]	2017-10-31 13:21:56	\N	\N	53bf71e8-e90a-4361-81fc-60e431eb5108	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3800	3	159	8	[673]	2017-10-31 13:21:48	\N	\N	f40c4cac-8c3f-4e51-a287-622581efe880	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3801	3	158	8	[669]	2017-10-31 13:21:39	\N	\N	4b51118b-b4d3-4958-93df-22e3434a3e22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3802	3	157	8	[669]	2017-10-31 13:21:31	\N	\N	bb81c8f1-b1e9-4da6-8ba3-710384e5c5d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3803	3	156	8	[667]	2017-10-31 13:21:21	\N	\N	4f58ad10-4762-48c6-b4c1-4109a5e2a1f9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3804	3	155	8	[667]	2017-10-31 13:21:16	\N	\N	d5e09d6a-05f1-4d14-bbf7-bd6dc6ff2f45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3805	3	154	8	[661]	2017-10-31 13:20:51	\N	\N	9091eb66-6522-4da9-b8fa-ce96a6ee2bd4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3806	3	153	8	[659]	2017-10-31 13:20:44	\N	\N	a2f7e44e-3d53-4e91-a5f2-ebcc1080dfb5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3807	3	152	8	[659]	2017-10-31 13:20:37	\N	\N	3d2818ff-4b48-46de-897a-ab9221c3fcc5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3808	3	151	8	[660]	2017-10-31 13:20:25	\N	\N	a89ada59-b4a7-4b1b-8dee-ef8d782faf0a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3809	3	150	8	[659]	2017-10-31 13:20:19	\N	\N	5a582ec8-42ae-48be-bf5b-e13d58032cff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3810	3	149	8	[659]	2017-10-31 13:20:10	\N	\N	836efea6-94ce-454a-a7e2-a5cdfeb06809	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3811	3	148	8	[660]	2017-10-31 13:20:05	\N	\N	5fa3bd18-07e3-463a-8285-75c4bcf5b855	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3812	3	147	8	[660]	2017-10-31 13:19:59	\N	\N	1a2755b5-f433-4c9a-97d8-2b6a51bb76ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3813	3	146	8	[664]	2017-10-31 13:19:49	\N	\N	d9c55367-da17-4104-acb4-71da52a215a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
3814	3	145	8	[667]	2017-10-31 13:19:43	\N	\N	bad751ed-5ab8-445f-bfe6-5a77db8713a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
\.


--
-- Data for Name: project; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.project (id, pt_code, pt_lizmap_project_key, pt_label, pt_description, pt_indicator_codes, pt_groups, pt_xmin, pt_ymin, pt_xmax, pt_ymax) FROM stdin;
\.


--
-- Data for Name: project_view; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.project_view (id, pv_label, fk_id_project, pv_groups, fk_id_spatial_layer, fk_so_unique_id) FROM stdin;
\.


--
-- Data for Name: protocol; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.protocol (id, pr_code, pr_label, pr_description) FROM stdin;
1	pluviometry	Pluviometry	Measure of rainfall in mm
2	population	Population	Number of inhabitants obtained from census.
3	gps-tracking	GPS tracking	GPS position recorded by a smartphone containing timestamp at second resolution, position and altitude in meters.
4	field_observations	Field observations on species	Go to the field, recognize the observed species and give the number of individuals.
\.


--
-- Data for Name: r_graph_edge; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.r_graph_edge (ge_parent_node, ge_child_node) FROM stdin;
1	2
2	3
3	4
4	3
1	7
7	8
8	9
1	11
11	12
2	15
15	16
\.


--
-- Data for Name: r_indicator_node; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.r_indicator_node (fk_id_indicator, fk_id_node) FROM stdin;
1	3
2	9
3	12
4	16
\.


--
-- Data for Name: series; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.series (id, fk_id_protocol, fk_id_actor, fk_id_indicator, fk_id_spatial_layer) FROM stdin;
1	1	2	1	1
2	2	2	2	2
3	3	4	3	3
4	3	5	3	3
5	3	6	3	3
6	3	7	3	3
7	3	8	3	3
8	4	4	4	4
\.


--
-- Data for Name: spatial_layer; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.spatial_layer (id, sl_code, sl_label, sl_description, sl_creation_date, fk_id_actor, sl_geometry_type) FROM stdin;
1	pluviometers	Pluviometers	Sites equiped with pluviometers to measure rainfalls	2019-06-26	3	point
2	brittany-cities	Cities of Brittany , France	Cities of Brittany, France	2019-07-05	1	multipolygon
3	gpsposition	GPS position	Position of GPS trackers	2020-09-10	2	point
4	faunal_observation	Position of faunal observations	Observations on species (lions, girafes, etc.)	2022-09-10	4	point
\.


--
-- Data for Name: spatial_object; Type: TABLE DATA; Schema: gobs; Owner: -
--

COPY gobs.spatial_object (id, so_unique_id, so_unique_label, geom, fk_id_spatial_layer, so_valid_from, so_valid_to, so_uid, created_at, updated_at) FROM stdin;
111	51	John	0101000020E6100000D44DCAF2216C0DC000F8330E5C394840	3	2017-10-31	\N	6de00710-5862-4b2f-9384-c62b995d2df5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
112	52	John	0101000020E61000003B241D33FC6B0DC03BF63F125D394840	3	2017-10-31	\N	a3cad278-aed5-4bea-8bed-5ba8553d8d24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
8	29275003	(Aulne) Scrignac [Poulpry]	0101000020E610000077378A16C7360DC010212512F3394840	1	2019-06-01	\N	8a4365a2-0d8d-4e0b-aa16-a2e33bfca330	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
9	29202002	(Morlaix) Queffleuth [Le Plessis]	0101000020E610000075D1EF85C48A0EC0C5128B903B3B4840	1	2019-06-01	\N	000d23b8-efbb-4f8f-abae-6e1895b63a2c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
10	29191003	(Morlaix) Plougonven [Toulivinen]	0101000020E61000007ED9C0572C7F0DC097208A533E3F4840	1	2019-06-01	\N	047f3706-1796-4332-9a87-6096e807d05d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
11	29163004	(Morlaix) Pleyber-Christ [Gendarmerie]	0101000020E6100000AE279B9911FC0EC02711999C8E404840	1	2019-06-01	\N	76e4a057-9733-4a76-8cf6-33dd8b1c931a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
12	29018003	Ellez Brennilis	0101000020E6100000DABD4DD0B9FA0EC067BB8FB3562D4840	1	2019-06-01	\N	0ffa3369-2865-4b06-af0d-7c4b7d67b74b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
113	53	John	0101000020E6100000E019D537DC6B0DC0229ACCCA5D394840	3	2017-10-31	\N	9de33bbc-d12a-4cd3-a7fe-cb9f4d8d8404	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
114	54	John	0101000020E61000004CAD5FFEB66B0DC0F31530D35D394840	3	2017-10-31	\N	2ba835cb-7d47-4cab-8e76-76174e0dba2e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
115	55	John	0101000020E6100000C4BA59D1926B0DC016EC12275E394840	3	2017-10-31	\N	05fc1bc8-fba1-4d3b-86a6-cfe32e9b415d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
116	56	John	0101000020E61000003CC853A46E6B0DC0875F3D405E394840	3	2017-10-31	\N	867b2f63-f6b4-402f-aa05-9ca1d4ee288e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
117	57	John	0101000020E6100000AE1816F1496B0DC082A205BA5D394840	3	2017-10-31	\N	4c4d41f2-ea36-497e-9088-fef1a412cb5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
118	58	John	0101000020E6100000365DB756276B0DC01DDD94445D394840	3	2017-10-31	\N	7dfe0c85-e545-4c8c-aa0b-162c25e6df86	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
119	59	John	0101000020E61000008CFC6204006B0DC0930DF7E35D394840	3	2017-10-31	\N	17aac9ba-bff3-4e7b-af58-e552481fa954	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
120	60	John	0101000020E6100000FE86F1E8F26A0DC0C25D49445F394840	3	2017-10-31	\N	24c6f4a7-e08c-4ebc-a5f4-eb5ebc5bd9c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
121	61	John	0101000020E6100000E29B0EB2D86A0DC06221C6BD60394840	3	2017-10-31	\N	a856b2ef-3e75-49fa-8fbb-ce6b886fa0e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
122	62	John	0101000020E610000081D48E30B86A0DC0FD270BB161394840	3	2017-10-31	\N	97aa635e-f028-4090-900d-28a0d8ca38b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
123	63	John	0101000020E6100000F9E18803946A0DC0DF0E60E361394840	3	2017-10-31	\N	eab45bf0-9f18-442e-97d2-72e9d168c4a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
124	64	John	0101000020E61000000ADF63FE7D6A0DC0FCF3C01963394840	3	2017-10-31	\N	f1d2f435-8ee3-44ae-9d21-7734ff16f8e0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
125	65	John	0101000020E610000087A995575A6A0DC09B83F3FB65394840	3	2017-10-31	\N	2b5f97d6-994b-40a9-8800-06a0812206ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
126	66	John	0101000020E6100000996CA4BA2C6A0DC0582CD1AB68394840	3	2017-10-31	\N	9c23f8be-65cc-4928-bd1f-009ad2719ac9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
127	67	John	0101000020E6100000C15D5ECE186A0DC0468D95EA69394840	3	2017-10-31	\N	78ca3cad-f7ae-4260-b53b-9e42cf1d5f71	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
128	68	John	0101000020E6100000E94E18E2046A0DC033EE59296B394840	3	2017-10-31	\N	230f780f-143b-425c-888e-f18491f5005a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
129	69	John	0101000020E610000022777988F2690DC00336739A6C394840	3	2017-10-31	\N	b165e990-4ca4-473a-a8b5-1664c14c6aa4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
130	70	John	0101000020E6100000AAF5E685E7690DC0A3F9EF136E394840	3	2017-10-31	\N	488a8179-f063-4fea-86c2-e5e35d8360bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
131	71	John	0101000020E61000009984735BCE690DC04F6B26316F394840	3	2017-10-31	\N	7da20f1f-bf32-483d-968f-af5906647b8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
132	72	John	0101000020E610000011CC39C6C1690DC0A2915BE570394840	3	2017-10-31	\N	b13ad2b0-a57c-46eb-b11d-b0176b689f03	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
133	73	John	0101000020E610000066A5B10BB2690DC012D13B6772394840	3	2017-10-31	\N	d57f1976-e47b-47e6-a89c-f983e70f5d1b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
134	74	John	0101000020E610000089D933999D690DC0A029C7B673394840	3	2017-10-31	\N	51ae6851-8be2-4674-a91e-9465ad101127	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
135	75	John	0101000020E6100000CD7B044C8C690DC021A04ECB76394840	3	2017-10-31	\N	28fcfb7f-f492-4b60-8e5d-b3976381771e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
136	76	John	0101000020E61000001D98440B7C690DC0F1E7673C78394840	3	2017-10-31	\N	5a4ced47-67c6-4fe5-82dd-d1108bba25cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
137	77	John	0101000020E610000067BD80AC53690DC090779A1E7B394840	3	2017-10-31	\N	4d7bc917-bb68-4abd-aaa4-fa6936de8bec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
138	78	John	0101000020E61000008FAE3AC03F690DC060BFB38F7C394840	3	2017-10-31	\N	290567c6-96da-4e12-93c1-aeb58bf3b687	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
139	79	John	0101000020E6100000AC2585C72A690DC04E2078CE7D394840	3	2017-10-31	\N	f3f6d55a-f21f-4366-b1a1-3e0c727e52b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
77	17	John	0101000020E61000001652E634B7660DC09EC29D5D25394840	3	2017-10-31	\N	8266506f-11d1-40d7-b13a-d6c6549f2ebd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
78	18	John	0101000020E610000016C67E64E6660DC02CE7DE1528394840	3	2017-10-31	\N	1c05a2e0-34e5-4982-8cea-d57b8cb1db22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
79	19	John	0101000020E6100000DD9D1DBEF8660DC09C26BF9729394840	3	2017-10-31	\N	ef59b709-bfc7-493f-a87c-b99bc6edacd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
80	20	John	0101000020E6100000CCA042C30E670DC05A03E7DE2A394840	3	2017-10-31	\N	36040675-610f-4cb5-94c3-77225424837b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
81	21	John	0101000020E6100000F30595062A670DC006751DFC2B394840	3	2017-10-31	\N	fb5b5be8-d451-40b9-95db-d5e0b422cb23	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
82	22	John	0101000020E6100000E24286A357670DC07680B3E62E394840	3	2017-10-31	\N	7ccee1fb-55c6-4320-9386-d1e7c39ff5bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
83	23	John	0101000020E61000000F4D41CCD1670DC0AF162BBC32394840	3	2017-10-31	\N	deb04a4c-f4a6-49b4-b8fc-1dc16a7242e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
84	24	John	0101000020E61000008608A066F4670DC068361B7D33394840	3	2017-10-31	\N	d253025a-68b2-49e2-ba7b-5fa48b473c0a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
85	25	John	0101000020E610000086426CFE0B680DC0432CEE9134394840	3	2017-10-31	\N	d6d843a0-6bf9-48ff-a9b7-c8bb809fdcfa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
86	26	John	0101000020E6100000BEDE65D428680DC0318DB2D035394840	3	2017-10-31	\N	7a84fea8-056a-483d-bcce-e963c818c0cc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
87	27	John	0101000020E6100000B8B7C374CD680DC01EEE760F37394840	3	2017-10-31	\N	569e0bee-78b2-4a9a-b942-50a40b82f7bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
88	28	John	0101000020E6100000621818C7F4680DC0A1CC925237394840	3	2017-10-31	\N	ec254fd9-236f-4c45-a1ab-a8995320a569	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
89	29	John	0101000020E610000018F3DB251D690DC089701F0B38394840	3	2017-10-31	\N	d933b076-0d77-45de-9452-f4eff1d8ebb2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
90	30	John	0101000020E6100000B7D9C06B43690DC0A09848BB38394840	3	2017-10-31	\N	3a95c409-a8f1-41d4-a51e-cfe2b63d4222	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
91	31	John	0101000020E610000050036E2B69690DC0C46E2B0F39394840	3	2017-10-31	\N	8350a3b0-c8ba-4f9e-92b1-cdb9e499ef9f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
54	29034	Le Cloître-Saint-Thégonnec	0106000020E610000001000000010300000001000000610000005A265E31B7960EC06F957F31153748401CF306FF83980EC000F4E7AACD374840E97A4BDE0B9D0EC04221B4CDE9374840F2B02F19F79C0EC023CCCB6008384840800575A68EA50EC03A5B1051723848403E36174E28A70EC0431A653204394840D1A0BCA7B8AB0EC0F780B79A4E394840C0DFC7AEC89D0EC06B7058B2B639484001EEE437FB9D0EC09124CBF0FA394840DBF5C7A243990EC0CC6B2394243A48406B46E00B77960EC0D3C1AFE6DD3A48408065B6FF5D8E0EC0A6FB3724F93A484007B0276D5E8A0EC0E8ACE9D22F3B4840A28268093A910EC05AF78CE58A3B4840A1E8BE0559950EC0247EA6F3983B484051B93E362A910EC0DCD7A379E73B48408230EF1476950EC0DF468FFC2E3C4840DC8197C1C0940EC00C35D2EB5A3C48402FC7B55FB39A0EC04094D5097D3C4840911F211D21990EC0C27877B6B93C48400FD5E32358A00EC0E62B0E73033D48408547A7A80F9E0EC04AF8A59E093D48403D9F42BAB79D0EC06FEE62D9263D48402ACF7BCF93A20EC036F5DA01383D4840DCFF3E0C2D9E0EC07FC0681C7E3D4840BEC8BD31069C0EC053621B903A3E4840308F43DDEC930EC09888DD3D1E3E484017AC17DABE910EC0A3E8410DDD3D484097D54E0A1B800EC0A60ABC4DD93D4840EDDC28A31F7B0EC0C4D380A6F63D4840DED9350905730EC039BF8DA1E13D48401178402EC96C0EC07A46024A373E48401D85CB90DE6A0EC0A25DAA0CBF3E484044AEE8C62E670EC07A2CE0FBBA3E48406EFA899E6D590EC0538733FC6D3E4840398D45336F560EC05EE62FE71E3E4840456C086E864C0EC0F6E365C0D63D4840F16360A73D3F0EC05B9396DABE3D48408A61A50DAE3E0EC0ACA4F0AB6B3D4840D8E3260A373C0EC0D2D1DF5B8C3D4840E191F2BA0E360EC0F93E2E17853D4840671A771711300EC0BC1E97034C3D4840D1C46372C82C0EC0D39FFC53653D48401E60CDF6472C0EC0B3DB43B1A43D4840D1EC454D82250EC0B8071795DF3D4840B253A0515C240EC08C48E6EE3E3E48409D275F53A0260EC01BA390E4633E484085FB5142A71C0EC093DF09B68F3E484026662CD33C160EC0F4FB809D8A3E48402FA3C2BD7E130EC0186EBB80513E4840F25B7F94190F0EC06FAF0DA68D3D4840A3D3ADE3CE080EC0747FAAFB763D4840C933558A87040EC058217C18443D48405E38922C8A080EC0E413A998163D484072CD3692F2030EC0B63CA9B1EA3C484095EBCC4CF20E0EC0EF81FB4DB73C484045C97671F00B0EC09228182A053C4840EB56D7B62E040EC00A86660D713B4840EEB62412120C0EC0C1CF40BF5F3B4840EECB2EC2BC060EC010FD6B514F3B48400D8B6D0504030EC038D0FDA3183B48407F39968CA9000EC001E0686D293B48400401162D9EFF0DC03BA47AB1183B4840E8EA8CA233050EC0CE6F239DE83A484029040C0F79030EC0E7C73534BA3A4840B8DCC665F9050EC0F26D77B5B43A4840DEC36C91C5040EC0272AA960863A484015EDE7E61B010EC0DA92D6427D3A4840604B0A5C77070EC0DC72E143613A48409D29CAD339060EC06E592F50B8394840D37F247274010EC099470CB650394840B0FFC2FF09070EC05E169A7F3D3948409786B91FED0A0EC0D216398F35394840CC801D73CD0B0EC052932F1C003948403137751D61150EC0B4EBBCDAF0384840AD04EA514C160EC067D2505605394840E2158656BD260EC068129A62B338484074A8C45C89290EC0F66CA96DD338484082540064A7260EC0AB4535B796384840E211C13C47290EC0F20A15117C384840644667725A2F0EC09A8554298138484057F901E1802F0EC0F3CDA0F64338484064F23DB27D490EC09F6690E8FF3748407F8B9014434C0EC0CE66AD390C384840A4073C17624F0EC0E110DCB4CF37484068E304E2C1530EC0CA174EEFD137484076E7E6D2B3540EC0B73135E3A4374840FE92B953076C0EC0AB7F0187B0374840C6266C5E79710EC0CE01880557374840AA0D2C19D0720EC02CF5CB49FA3648401E5F6C08C16C0EC00909DD878E36484060468ACEB6720EC081422F914936484062D8DD4EA07B0EC082DC17C197364840B76110DF4C7E0EC06D485C32D7364840E4BD38D4718C0EC02E2A859118374840C412A568888F0EC0C4525E5F023748405A265E31B7960EC06F957F3115374840	2	2010-01-01	\N	29afee59-0b89-4b9f-a2da-234b19461eb9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
153	93	Al	0101000020E6100000AB314982AEE00DC0B3EF943C963B4840	3	2017-10-31	\N	aea86e4d-0165-4a8f-bfa0-f1476533214b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
49	29007	Berrien	0106000020E6100000010000000103000000010000007D000000E7CACAA599610EC008F29506B62F48404110604DA3610EC03A63114D0730484002C8D0C130650EC0D309327B223048408C385ABC79640EC053BCD48D4E30484089392530BC660EC09F05DD7F6A304840DB73A8F304690EC09360DDB3F6304840DA5E94CFE4650EC0F8B559656831484002C3D4EE9A6A0EC0BFCEA814BD314840EFE89E24FB740EC03928F7E6A2314840ADF252C054870EC091C513B82B324840AC005219CC850EC00A31024294324840EF6C97F090890EC094641364973248405387C25AEC8B0EC0D9E3C384BF32484033678E2B95910EC08BC922B8D532484034BF6B25C2930EC0487C4D3D0F33484078E3D9B9B9A00EC01531A6FF7E334840D20C33EC5A9C0EC0BB73B7700F3448401E3891D40A9F0EC006407FEA47344840524B4490A3A30EC01F2C9E606C344840A0291898DFB50EC052203E1D8E3448408FCD683676B60EC0CC961F1AAA3448406EE9267409C00EC0AD8E7AF2C1344840B6827E699DBF0EC05802A4873B354840D08D4032E6C40EC06F25B920F9354840E9B5ABEE9AAF0EC01BF7CC3FD33648405A265E31B7960EC06F957F3115374840C412A568888F0EC0C4525E5F02374840E4BD38D4718C0EC02E2A859118374840B76110DF4C7E0EC06D485C32D736484062D8DD4EA07B0EC082DC17C19736484060468ACEB6720EC081422F91493648401E5F6C08C16C0EC00909DD878E364840AA0D2C19D0720EC02CF5CB49FA364840C6266C5E79710EC0CE01880557374840FE92B953076C0EC0AB7F0187B037484076E7E6D2B3540EC0B73135E3A437484068E304E2C1530EC0CA174EEFD1374840A4073C17624F0EC0E110DCB4CF3748407F8B9014434C0EC0CE66AD390C38484064F23DB27D490EC09F6690E8FF37484057F901E1802F0EC0F3CDA0F643384840E082CA90ED260EC064C01C9DAA374840DFE3979B7B2B0EC00A3F589972374840E02381FD14230EC017C694CF2A3748402B136DA145180EC0A5F819F73937484064040143EF0F0EC00EBA8F2123374840B615EBB44A0B0EC08449A1E0EA364840070C2EB7B90B0EC076A0FD0670364840CF5EB19A67080EC0B819A8A856364840BD178342B5F90DC098F04A223F36484041FE8871EAEF0DC049A3E5C5CC354840633750B70DDD0DC00B40B183C03548400CA8520FD5DA0DC033C1DF32FC35484034223A2514DC0DC0EAEC2D2C18364840B2C31E5D97D80DC099476BF14F364840397B40D1A4D10DC0214EE7C75D364840F77EA7FEC8CB0DC08BCBA13199364840E77496B3A3C30DC047DF1AE163364840798EE19AE6C20DC0D8B6A700233648406D1CC8A0D1BD0DC029EDAD870236484025496855F9BB0DC088DD2F28493548409012C81EB7B50DC00E2D570519354840DC13D0443AB10DC0E147C51A1835484075EA4817ECAC0DC030A611A7E2344840AEC8EA75DF9D0DC0BB994396BA344840482A1AA0CA980DC0ACBB91025A344840B5EE97AA03930DC0CB7E77042A34484015EC7FB7558D0DC06B2C05452634484061F3DDE89A870DC0D5C435A2F733484085D1F30ED5800DC05963E5DF0C34484086EF2150AF7D0DC013D9A122F33348400AFAD9091A7C0DC08C394ADFA93348401C32068E477F0DC08037D6224B3348407DD0BCFB477B0DC09F28045AFE32484052C1B9E223780DC02704718A6B3248404E605872AE780DC0934C402C343248409C76FAB78C7E0DC05EC35431CE314840F248C9870D7F0DC04F0BE0E36C3148403CB68CC1B6920DC0F2F31AACDD3148404B85602866A00DC0936FF6DC73314840E6FD349FDAA80DC09645E055A931484013906DEE6FB60DC0F2B3D6E7CB314840507815BCF3B50DC07F31B802753148407B0926AEF2B00DC0076085B12431484065B531171DB20DC075AEDF831531484016F2BA3CD1B40DC0EE5162332631484088E4FB4204BA0DC0CCF63F33F43048400F19DF708ABC0DC04188A598DD2F48406BEFEE122CC30DC0BFA88FB0FC2F4840A5AAD0079FCB0DC0861074E5C42F48407BB0546D47CD0DC030E17A1E9E2F48402E4B57FA92C70DC0FBACC1352D2F484021EFC07413CC0DC0A1702ED0F42E484055907F01D3DF0DC0FEB4B181E52E48408CC283F302E00DC031B550EB232F48400B415AB821E90DC0D3E92CF7B22F4840B5575E926DE80DC0ADD10E09DF2F48401D7B8C0950EC0DC06E4C7B4B0C3048409D4191B349ED0DC0FB7B6068523048405BB3D9D2DAF60DC0A2EAEE7954304840F9CC97E4E0FC0DC0AD57CC5F7730484030A2733FB8FC0DC0605A6F73613048407F312C602F020EC0F3388B6B5A304840BD19EA3BF3FF0DC07420558F2F304840DCA33E07C7040EC0A25EA786293048404DF33D97C5050EC01A7B09544430484004060BA26F090EC0C7555A0A2C304840AA3BA7C7BE0A0EC057403DBB48304840614AABF7180F0EC0E9AE93D72C3048408F9983D6F6150EC0E1E38FE749304840056BB15A6C250EC0D58C1DDFEE2F4840FC899F9D5F240EC04D7272A5BA2F4840CB9A4801062B0EC0DCC3B3CE732F4840EDDFC90A76330EC0E7DF5D17572F4840A0E215F849290EC0FBAB6E43922E4840142659EDD22B0EC0D12A45BC572E4840E976D257792F0EC07A1E66D18A2E4840410B040F2E2E0EC0685ABC55A92E48404F3FE21C83320EC098492212D32E4840A6A6E5BD49380EC02A81EA2DE62E4840079FA653F43A0EC0707E2915CA2E484041887E58D74A0EC0FB96D1FA2E2F4840FD323B411D520EC0DEA60E140A2F4840D3F136204B540EC0FBBC77805F2F4840E7CACAA599610EC008F29506B62F4840	2	2010-01-01	\N	dabab797-b900-4834-a8a0-da7523470efa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
50	29018	Brennilis	0106000020E6100000010000000103000000010000004E000000FCBCD9718F330FC0006E713DAA2D4840AD84596996370FC0D0F5BA07F42D484054D5DF3DAC360FC04A6BA47F4A2E48407A0157E9E62D0FC0AABF9AC4922E4840A757F22C57270FC0982946EB8B2E4840C35A67E1EC220FC0D8AE5AB1012F4840F07143D1E9240FC0EF622CD36E2F48401DEE75636E2D0FC0B4580202EB2F48405C721ED3712F0FC0C33B1D3D7E304840AD3D024724300FC0AE244A3C1731484031B7917B5D2B0FC023FC719E7C314840901B55ECB0240FC0434082D1A031484024E57B79B31C0FC09BC8F7178A31484076CB38FDF8070FC08F2074FA193148404FA4A606EB060FC0D43C9AB2F9304840EBB537C192F90EC0C6EC6EB4A5304840FA4D33D592F20EC0DDFF19F396304840C760CB2DE3F40EC076EE7CBA2A3048403C89B7F3EAF20EC070AF83D22130484056E646F068F30EC0FA1AF7D2812F484086FAC6F1A2EE0EC0ACD9828C922F48409A0B95083DE60EC0C4A1097E7B2F4840DB6B4A6156DE0EC0ED0E5B65A42F4840115C5F6B33D50EC0897C7617A32F4840B48410485ACF0EC0AD4ECE1AC62F4840463F0AE7B8B60EC04C44410DDE2E4840C89B306AADB20EC08E8343DF5E2E48409EC7567E79980EC0C021AF781D2E4840B2FCCEC4DC870EC0CB1DFEC54F2E484034FDFEF19A750EC0975EB6D9472E484000F59D17F86A0EC08C7A01E6702E4840A313C40C8D490EC036775174292D4840B058809D934E0EC03313ED66232D48406A45B3EA444C0EC016FA1C87FF2C48401EFA3E6DBE4E0EC0AC6575EDD32C484055833E6802540EC0737F47B4D42C4840BBC80D67445F0EC0A837B8629A2C48400DB0706B8E5C0EC0B2D2082B212C4840987C93FF25620EC06EB993C32C2C4840F8A02D68ED640EC07D94AD58082C4840689A457A906A0EC0166BF78F1D2C484053413128B1700EC0B5391CA3032C4840B299D75BAF780EC09ACDD9BE202C48405D7D87A5D3790EC0AFB2CED5382C484026ADE910D47D0EC0CBEAFEC41E2C48408DE9E6462E830EC07FE2C485BF2B484034E3102CF28A0EC0864CD3AB942B4840384678A7588D0EC0897BCD956E2B48402649213BA49B0EC0997DC8C08A2B4840EC1ACDFED29F0EC058B89C47C02B484085F3D852CCA60EC08FA011F6A82B4840FDF7848E8DAF0EC0DF7FACB4AE2B48409DC1A6681DB70EC04927B309FD2B4840A9F96E1252C60EC01514CFAE372C4840C743195D4ED10EC0E61B586C162C4840178DC5F48CD10EC082582A80292C48402BBE21CDA2D90EC07E7A095C2A2C4840B7FC8DED0FD80EC07458C65E442C4840027C2B7C5EDA0EC0353D307D542C4840B83AAE8185D90EC0C867273C6E2C4840A06C6E072FDF0EC06088DB69862C484046C9B55517E30EC0C54221F5EC2C4840446C3FCE3FEC0EC0F8D0AF7DF92C4840F4289362FEED0EC0F49A85CE152D4840797F4CF610F10EC0DED8C25F112D48407EFD1C8744F70EC037E086C13B2D4840F3BE0EBFBB000FC0870DFB7E1E2D484083BBD1A21F050FC059EE8AE5402D484072E29FCECA0A0FC04579A9532A2D484095DA12C96F0F0FC06188C0AC4B2D4840A639808861140FC0B6C2A9A83E2D48400BFBCC609A160FC094DABB7C4F2D48403C61846A061B0FC0C1551D68262D484033770BF52A210FC0D518DE894E2D4840B796E0FFC9270FC08FAB91344B2D484056373B11062D0FC0CFE60C5A7C2D4840A3084483CE2F0FC032DB0FD8752D4840FCBCD9718F330FC0006E713DAA2D4840	2	2010-01-01	\N	b05675f1-ba2c-46fb-b8a4-22198098f5b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
51	29081	Huelgoat	0106000020E6100000010000000103000000010000003F00000000F59D17F86A0EC08C7A01E6702E4840CD0EC395ED6E0EC0C61BD50BBA2E48404BF4235FB47B0EC0528D1B46232F4840BCE440669C7B0EC027709EDE372F4840AF9499ED79770EC073444634812F4840E7CACAA599610EC008F29506B62F4840D3F136204B540EC0FBBC77805F2F4840FD323B411D520EC0DEA60E140A2F484041887E58D74A0EC0FB96D1FA2E2F4840079FA653F43A0EC0707E2915CA2E4840A6A6E5BD49380EC02A81EA2DE62E48404F3FE21C83320EC098492212D32E4840410B040F2E2E0EC0685ABC55A92E4840E976D257792F0EC07A1E66D18A2E4840142659EDD22B0EC0D12A45BC572E4840A0E215F849290EC0FBAB6E43922E4840EDDFC90A76330EC0E7DF5D17572F4840CB9A4801062B0EC0DCC3B3CE732F4840FC899F9D5F240EC04D7272A5BA2F4840056BB15A6C250EC0D58C1DDFEE2F48408F9983D6F6150EC0E1E38FE749304840614AABF7180F0EC0E9AE93D72C304840AA3BA7C7BE0A0EC057403DBB4830484004060BA26F090EC0C7555A0A2C3048404DF33D97C5050EC01A7B095444304840DCA33E07C7040EC0A25EA78629304840BD19EA3BF3FF0DC07420558F2F3048407F312C602F020EC0F3388B6B5A30484030A2733FB8FC0DC0605A6F7361304840F9CC97E4E0FC0DC0AD57CC5F773048405BB3D9D2DAF60DC0A2EAEE79543048409D4191B349ED0DC0FB7B6068523048401D7B8C0950EC0DC06E4C7B4B0C304840B5575E926DE80DC0ADD10E09DF2F48400B415AB821E90DC0D3E92CF7B22F48408CC283F302E00DC031B550EB232F484055907F01D3DF0DC0FEB4B181E52E484021EFC07413CC0DC0A1702ED0F42E48402E4B57FA92C70DC0FBACC1352D2F48407BB0546D47CD0DC030E17A1E9E2F4840A5AAD0079FCB0DC0861074E5C42F48406BEFEE122CC30DC0BFA88FB0FC2F48400F19DF708ABC0DC04188A598DD2F4840202444A6E9BB0DC0027EB9BB7D2F4840E89B732F25B80DC04951BE39402F4840B14B6FAA9FB50DC091E34C4C702E4840EB38E78BDFBC0DC08DC21CD84B2E4840F9EFAAB505C60DC00BEF70567C2E4840DAB6157FFAC90DC0224104BB5C2E48406FF57611E9CB0DC0AAC9F0022F2E48404C7306AB7FC70DC0DE808398022E4840AB90F41D14CA0DC05BFB208E912D484002DAF5FFB8D00DC03003297B212D48404AF3489D62D80DC07AB59AA0DB2C4840ADB0762D82E70DC0201416E19E2C48409BE8CF8146E50DC05A55261A3D2C48404E06859DB4EB0DC0F91B43DB402C4840EE006E566DFD0DC05B85095AA22C484014FCC708850E0EC0212A01F7742C4840FB242381462C0EC0177E941C612C4840C1E48A8885370EC07858CFD58F2C4840A313C40C8D490EC036775174292D484000F59D17F86A0EC08C7A01E6702E4840	2	2010-01-01	\N	d98bb9a6-79a8-4def-a249-b3ca751ac134	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
52	29054	La Feuillée	0106000020E6100000010000000103000000010000004200000031B7917B5D2B0FC023FC719E7C314840CF596CE12B330FC09183CA2ADC3148407CDF20474C390FC03E30BEB4E0314840E6C33776A23D0FC055EAD86B53324840ACB78AA26D440FC0DC2141D577324840A8C5FF8AB14A0FC00985281E623248403C47F110014C0FC0D1165B438B32484072454E4BB9470FC0009BAEC1A532484030AD19365B4C0FC0FCDD5A830C33484067B8BD3D2E5B0FC0365C62566C3348403405D8A5CD560FC0C63290A28F334840D758129363490FC0AC898EC8AB334840C0F6087383250FC092310A679F344840A8BC4B4ED4180FC0FDBF6669DB344840B6C81D83EDF90EC00D863F8450354840A99173C662D60EC0CE7D4E55993548403268C11F9ED00EC09FE92E26DB354840D08D4032E6C40EC06F25B920F9354840B6827E699DBF0EC05802A4873B3548406EE9267409C00EC0AD8E7AF2C13448408FCD683676B60EC0CC961F1AAA344840A0291898DFB50EC052203E1D8E344840524B4490A3A30EC01F2C9E606C3448401E3891D40A9F0EC006407FEA47344840D20C33EC5A9C0EC0BB73B7700F34484078E3D9B9B9A00EC01531A6FF7E33484034BF6B25C2930EC0487C4D3D0F33484033678E2B95910EC08BC922B8D53248405387C25AEC8B0EC0D9E3C384BF324840EF6C97F090890EC09464136497324840AC005219CC850EC00A31024294324840ADF252C054870EC091C513B82B324840EFE89E24FB740EC03928F7E6A231484002C3D4EE9A6A0EC0BFCEA814BD314840DA5E94CFE4650EC0F8B5596568314840DB73A8F304690EC09360DDB3F630484089392530BC660EC09F05DD7F6A3048408C385ABC79640EC053BCD48D4E30484002C8D0C130650EC0D309327B223048404110604DA3610EC03A63114D07304840E7CACAA599610EC008F29506B62F4840AF9499ED79770EC073444634812F4840BCE440669C7B0EC027709EDE372F48404BF4235FB47B0EC0528D1B46232F4840CD0EC395ED6E0EC0C61BD50BBA2E484000F59D17F86A0EC08C7A01E6702E484034FDFEF19A750EC0975EB6D9472E4840B2FCCEC4DC870EC0CB1DFEC54F2E48409EC7567E79980EC0C021AF781D2E4840C89B306AADB20EC08E8343DF5E2E4840463F0AE7B8B60EC04C44410DDE2E4840B48410485ACF0EC0AD4ECE1AC62F4840115C5F6B33D50EC0897C7617A32F4840DB6B4A6156DE0EC0ED0E5B65A42F48409A0B95083DE60EC0C4A1097E7B2F484086FAC6F1A2EE0EC0ACD9828C922F484056E646F068F30EC0FA1AF7D2812F48403C89B7F3EAF20EC070AF83D221304840C760CB2DE3F40EC076EE7CBA2A304840FA4D33D592F20EC0DDFF19F396304840EBB537C192F90EC0C6EC6EB4A53048404FA4A606EB060FC0D43C9AB2F930484076CB38FDF8070FC08F2074FA1931484024E57B79B31C0FC09BC8F7178A314840901B55ECB0240FC0434082D1A031484031B7917B5D2B0FC023FC719E7C314840	2	2010-01-01	\N	99458569-9541-4fc7-853e-14eb30071165	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
53	29114	Lannéanou	0106000020E6100000010000000103000000010000004A0000003E844F471C620DC076B6C9EC9D3B484047F383B4AE620DC0CECCDAACD83B4840A56CD6E7805F0DC0BC9371B9223C48406C8AE5ED73600DC0255996165C3C4840E3E74410595D0DC00B0A2386CD3C4840A0BCA2387B680DC0F49F8B88333E4840DB12C94004680DC032C863556D3E48407B17B379526E0DC06CE45CC99F3E4840CAA7E5C1CF6C0DC0F087D992D23E4840080D129D37670DC0B049B42EB83E48402B4CB931C7640DC0AB301FA7D63E4840E09248421B690DC0C455FD61353F48404325C372C06E0DC0BEB1A744463F4840876AFED369760DC0416B114F923F48408AD8D8AAFD760DC00ADAA790E23F4840A2A317E7E97D0DC07463135C684048406F6C84ECCB7E0DC0C751B15A04414840C2583053D5790DC0ABAA740F98414840C02EC4DEF77A0DC0646AAA01C84148402565BA54E17D0DC08F7F73E5BE4148401EFC754E7C7D0DC03F114EB9F34148409B6EA1BE0E890DC038F07FDF3D4248400CA60D98F98C0DC00E42B96D77424840889FFE69BC8C0DC05B4558771A43484062720564D4880DC0ED4D2254764348407CAA53D427840DC0CBF5AA2259434840A35F621E05840DC0AA9BF02884434840425F9CFAF6760DC09991AB459A434840D9904DF61A770DC06C73DF6FB94348409130C1FEEB690DC0870194B6A643484053AD6DCFB3670DC08934D8F6774348403388A3305C620DC02E988C5B93434840C72297DC2E5F0DC02E29B1A08343484079D9E6881F5C0DC011BB4736A14348406C632C20045A0DC0D55B15E418434840040E29998F4A0DC0A04C2CAB2843484002A4BD60694B0DC0F5B085266B43484016CD82FD74480DC0C92EAFB968434840A5D99E8164480DC07C7222C0834348409382B28760450DC088568D1F8B434840DBE489D5A3430DC0032213276E434840CD3E8078CD410DC016D1ECF53643484051238000E73D0DC06482CF4F27434840E4188FA8D43C0DC063BEF73CEF42484084AA55E31E390DC00C066C2BD4424840B644F226613B0DC084EDB5309A424840F257C8A61D450DC0BC351B6C9A42484096546F481C470DC0198ABC87784248400EDDB3F813460DC08ECD8E09404248408360E51E76480DC0FEF1130E004248404B1F46685A450DC0035B0EA9A7414840B80B99FF89460DC029A1F1FF814148400A5A7C989F430DC09D039A7F76414840CD84901F503E0DC07B0F9AA916414840CC505F7306330DC02705480EFB40484002B786249D300DC0331F17D3784048401BEB3D41752C0DC0CBB76380674048407F77E42AA2270DC00DD0CC171940484078AC3B6B08260DC05F9DE8C08F3F48402D936D5810180DC0419A4169ED3E4840D3B290A7EB190DC08E606975B73E48409AD81E771A1E0DC076F873B9BA3E48400A689795CC220DC06BCF9C7E553E484059AC8A5DFF2F0DC0E0282381F03D4840F808A61B6F2D0DC050BF9F44A13D48401C988A4ACD220DC09FE72D92493D4840392F6C2F67200DC0ED3A5653CA3C4840F1A8B94C87260DC0DE3A88D98C3C4840C256E69C17380DC0B0CC705E413C48403E9F377C4E340DC0629DA992C33B4840CFF1CC69743D0DC09BA8ACC8983B48402776D4F04F4F0DC063ED3B04A43B4840E06078144B590DC0294C287A7E3B48403E844F471C620DC076B6C9EC9D3B4840	2	2010-01-01	\N	4e3365a8-96ac-49a6-979e-c03ed2c440c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
92	32	John	0101000020E6100000D3383CD28C690DC017C9AA5A39394840	3	2017-10-31	\N	43d94fa2-09af-4728-9ac3-4e0ff10859ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
93	33	John	0101000020E61000005B2B42FFB0690DC0DB9654BF39394840	3	2017-10-31	\N	5a790152-457e-46e5-9583-e5da762c8910	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
94	34	John	0101000020E61000008E7E9C7EFC690DC0769D99B23A394840	3	2017-10-31	\N	1cee5254-4181-4f54-8a31-103131db5662	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
95	35	John	0101000020E61000006BBEB220406A0DC0C30697E03B394840	3	2017-10-31	\N	9231dca1-80bc-426d-9311-d531e9d839c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
96	36	John	0101000020E6100000BB4E8B0F5F6A0DC0DA2EC0903C394840	3	2017-10-31	\N	9e7ab2dc-6330-4e67-82e7-6a6e3157813e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
97	37	John	0101000020E6100000CB339769A76A0DC063CA135A3D394840	3	2017-10-31	\N	6a2acef9-19e8-4582-a8f5-0a718d373c5b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
98	38	John	0101000020E6100000377586F7C86A0DC01BEA031B3E394840	3	2017-10-31	\N	86cf90ea-4d02-44cf-bbfe-af3b0ac9e6d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
55	29163	Pleyber-Christ	0106000020E610000001000000010300000001000000960000002FC7B55FB39A0EC04094D5097D3C48405C6BA1441DA00EC02B5187E3593C484057B73E8380AD0EC0CA13CC095B3C48400B17221D3DAF0EC0EE764E52E33C48400B7060B77EB30EC05CFAB001CB3C48406FE92FBE84B50EC07B06E5FA833C48401C63C26015B80EC01F145895863C4840BD22F01266BD0EC032EE0F95EF3C48402194978138BE0EC0E8795198403D4840AC61C2AF18C30EC019FB45FB313D484068D5029F6BC70EC0E87B77365F3D48403D61B80062D10EC0B41BFE584A3D4840FF79960F44DC0EC0E78EE582DC3D484003544D0AA6E30EC05227DB90DE3D4840D6A8B454C0F00EC0CA73EE087E3D4840CC58D5CE39FC0EC0BB56ABDAB03D4840B1B3C64B1F0F0FC07E72DADF653D484077D3988474100FC0103855F5353D484065E5B11A8E1B0FC000ADBA29453D4840108754784C1E0FC0F6F6C6A63E3D4840AC9CE0CE631D0FC07E5B2C071D3D4840ED39ED2B94230FC0EE5866A3243D48406AD72839BB320FC01FE93974563C484024DD8F0BE03A0FC0252646B9443C4840E99797B7393D0FC0D2186883253C4840F9E7D38BF2420FC0642013DA1C3C484058725ED280490FC06B23695FD83B4840D4B251ADA4520FC0B53029CAC03B484012C2C73A97530FC028837E59853B4840F18EF1E5035D0FC08542DE2A653B4840834371C4C1620FC073AE8047153B48400315311F65660FC0593A538F333B4840506CDD24F5680FC0023C038ADA3B4840025099F7D65C0FC01C2997E2FF3B48403CA3E4E11C5E0FC0C483ED695A3C4840053AF71EEB600FC0EBAF7D925C3C4840731896DF9C5B0FC0E59961348B3C48408BF379698E5D0FC027DC7E2BCE3C4840094D0E85645C0FC012903FBBEE3C48408E82660F5A600FC0F9780372393D4840106C2C2ED75B0FC04952B4CE743D48403F31AFEDBC560FC0927422459D3D4840390C9E1AC14F0FC061BF70FFA13D4840A5FFFA3B914A0FC0A806C7E3C53D48400242CBF0AB480FC0C16F089BA53D4840AC28FD4488430FC0692B4FBFC53D4840B2F19D5DE73D0FC04FE81A016B3D484015F8353A06320FC023819473E33D4840E030943124260FC09EB1D9711C3E4840A2A4F35F56270FC0CDC46750443E484061736F749E2A0FC016FAA3BB2D3E484093DA37A1942F0FC09025FFD15E3E48405309667F0E2D0FC092620003953E484073174DE0682F0FC02A5A0D514B3F48409F7AC3E6EE3D0FC082D8C597553F48408562F2FD833B0FC0133B80A9A43F48402B9C88B639410FC06D2E8032FD3F48402C32A6E1CA4A0FC06A4934F9C13F4840B9E2025530490FC0E672B444E83F48409EA49A03C34C0FC06F672344FE3F4840B929B9C4DF4B0FC08B76510C19404840015A32345A470FC0CCBFCFC41E4048405053D79983490FC054347DB261404840EE5F346DFC4C0FC06D89B61F5A40484014E284C5F24C0FC01AED30EB79404840846617EE9A500FC05C87CA067B40484090A695182B510FC0F0CB4D20C94048408F63B1EF41530FC065D4B469C1404840F328AF932E550FC0EC2B297DE640484030ED819B3A580FC0DC3AD243DA40484010D730C8FA5F0FC0FA92B93011414840BC520E55015C0FC0F5BAA9DB46414840658B0EBB285B0FC0E930004794414840AADF11E6EC550FC0E187EF02AE414840CE1C5A83B9570FC0D19FF2CB7542484077D0E357E14E0FC0E1AB969B1443484035F638BA304E0FC014B08263F64348402E249B266E460FC03E8AE81C484448404DEE97AF0E440FC0DAEF72E27E444840F56F769893440FC03A43EFC0B6444840478A692D773F0FC0711A7F5DC9444840C08EFEDB9C3B0FC002064324044548400C46F9E3DE3B0FC00112A7BF4645484055ED457EFB2D0FC03294A1C97945484082ED603FA5200FC03AC8CB01F945484039AD134B28240FC0C9F8D0E46D454840C7CE263F4F200FC0091A678131454840D49128FFDC170FC0BCE54623644548400FAC0EF8FD130FC029A260BAFF454840DC2FB35F38100FC028BCDBD4164648401BAAA68345100FC08CE5A286EB454840C0D62AE9100C0FC03F32923CF445484019100A250D0A0FC018D833DCCE4548405152D26FBB030FC05BC7BFE9CD45484056C5F58294020FC04DC00BD2254648401A7A565003FE0EC0D62E05604E464840664305E830FC0EC00502566F454648408431E2A806FC0EC033EEE6EB3146484027B46B2771F60EC01854614F1F4648405D966D4DC0F50EC039A00D7EE645484032402B58C1EF0EC03A2B329BB5454840A11521DD27E50EC07D7395CA0846484032C5D346CDDF0EC0F2437F830B46484043807308EADC0EC0B30185E940464840B066B41596D90EC0168A6DA338464840DA149E0E25D30EC0B61B87427C46484022276631F0CF0EC0E332FC173046484057BC6CA901D40EC048B45F6F684548409B8604C550CD0EC041FD594882454840EFF5DCA8EDC50EC0B4E98F5A7E454840BDC23BD8C7C10EC029D41DD990454840B3831BC2FEC30EC05A2EFC1AB545484026D2D7D0A5C20EC01CB12E46E64548409155AF9F7FBE0EC03B207ED4D14548405AB1A9E965BA0EC0D583C706224648407722FF48C5BA0EC03A7B32DF49464840B7A2B21109B10EC0B565491EEF46484008B9B78FA0AE0EC073DBFC7CD24648400055976C6CAE0EC0CF6685F5904648401B9D864E93AB0EC06CE1A2736B46484033D5452C27A90EC0A7D4D9E875464840811324C823A90EC052EA63FE20464840D08718054BA30EC0A70C154E3346484085683949C19F0EC09A31B7541B464840A3B0FE30749B0EC0EF2B5A2CA1454840AA4B869076A00EC0D8263692E8444840AC27330CDFA30EC0F28DB250C44448403481BEC22CA20EC02B6CC8B15B44484047022D5747A90EC064E0806CF34348405DA568A117A90EC0B7AE6EE6A04348405D7BC912F7B40EC09A1CE149094348407BAAA3F51AB70EC0F7D2FC2EB44248401B70AFA132B20EC09B29CAB869424840CFD41E0935B00EC04EC7124F164248402A08A88232B50EC0FBF085CEAD41484077A2C84B8BAF0EC0D9F6A5A409414840EE5BDB3754AC0EC02D18E7920B4148409C86BBC2DCA60EC0E1267CACB8404840EAAD052869A90EC0EBE5B5C0354048402E7485A26DA50EC0F6406637D03F484094F06A1133A60EC04A8042D39A3F4840DE588D9FD69D0EC019AF8946D03E4840BEC8BD31069C0EC053621B903A3E4840DCFF3E0C2D9E0EC07FC0681C7E3D48402ACF7BCF93A20EC036F5DA01383D48403D9F42BAB79D0EC06FEE62D9263D48408547A7A80F9E0EC04AF8A59E093D48400FD5E32358A00EC0E62B0E73033D4840911F211D21990EC0C27877B6B93C48402FC7B55FB39A0EC04094D5097D3C4840	2	2010-01-01	\N	d30d93d0-c3cc-4028-a542-1dca0d20fc73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
56	29191	Plougonven	0106000020E6100000010000000103000000010000008A000000133B143DA6680EC01186F799A748484077290CE5C8590EC0FFF1575578484840E055B149AC540EC0489EF7CD86484840FCB3B8E7634E0EC01F375768594848401972419E89430EC076027EC0A14848408317991C533A0EC04CC8200988484840C7CA92786F340EC0D4AC6BE23A4848404618F5B3542D0EC0B3D4848A324848405D5A0E9ECA280EC08FAA9B64FF474840AA62766DA4220EC040C74B04F34748404A07A8778B200EC0159919790E4848402692FECA631B0EC06FB47C240D4848407F4C7250E1150EC06030CB1D35484840D044C842180F0EC03E06DEEF3D48484060E87488F90B0EC0B0C8C0792B4848404DD8F6206BF90DC04F4C899049484840B69AFC69E9E90DC0D51EF4F3164848401EEB863D02E40DC0CD1475B22348484078957D39C8DB0DC0DA0BD7A8CA474840B741347C35CB0DC0A4E475CDAB4748405BA78E8EF5C30DC0294D03F329474840C0FC8031AFC30DC042AE49ADCA464840DF742E77BBC00DC0B9ADAB37B34648400A0E2C3665BB0DC0C24AF4ECBA4648403D09FB675CB90DC0423B448D5F46484070A9F38BA8B20DC0370FEA1F2B464840A667493539B20DC026D79818E2454840C5322048E3AE0DC047EDC4D3D44548400BA309D097A90DC0ADD9EF06F14548409DF76D6E9EA80DC08A74563CB645484072A91BE323A40DC0FCEC2E987A454840480E2325EEA70DC02CFEDF70454548400316044A46A70DC0ED07BB5818454840E08A300380A20DC01F3F4519ED4448400A588C56C2960DC01B144632DF444840EF74BED595920DC0AFF5A87EA34448405429E9DF9A920DC03E576BA06F444840D159CD52508E0DC09478C25E4944484040D5A29D2B890DC0B6CE27F8C143484062720564D4880DC0ED4D225476434840889FFE69BC8C0DC05B4558771A4348400CA60D98F98C0DC00E42B96D774248409B6EA1BE0E890DC038F07FDF3D4248401EFC754E7C7D0DC03F114EB9F34148402565BA54E17D0DC08F7F73E5BE414840C02EC4DEF77A0DC0646AAA01C8414840C2583053D5790DC0ABAA740F984148406F6C84ECCB7E0DC0C751B15A04414840A2A317E7E97D0DC07463135C684048408AD8D8AAFD760DC00ADAA790E23F4840876AFED369760DC0416B114F923F48404325C372C06E0DC0BEB1A744463F4840E09248421B690DC0C455FD61353F48402B4CB931C7640DC0AB301FA7D63E4840080D129D37670DC0B049B42EB83E4840CAA7E5C1CF6C0DC0F087D992D23E48407B17B379526E0DC06CE45CC99F3E4840DB12C94004680DC032C863556D3E4840A0BCA2387B680DC0F49F8B88333E4840E3E74410595D0DC00B0A2386CD3C48406C8AE5ED73600DC0255996165C3C4840A56CD6E7805F0DC0BC9371B9223C484047F383B4AE620DC0CECCDAACD83B48403E844F471C620DC076B6C9EC9D3B4840F09EC0CEE7650DC0183EEAC35E3B48405F937EBFFF6E0DC07B1E241F2B3B48404A34F1665D6E0DC0D09A2749143B4840DAA669CDC37B0DC0F95D7FC8833A4840A735D771E87B0DC06C592683463A4840CE9819EEE8840DC08DAFD0C0D93948403CC48CAA158B0DC092142B1FDB394840919FF48F739B0DC0CC16DE311E3A484062807F57D4A10DC06557D396D9394840F5CA40FD4FA90DC0D151A97FD1394840724F918F13AB0DC079E23B705A3948404C08A6BC21C20DC0E89989CC503948406FB6B3195ACE0DC0CF7425B5003948404485370C3CD20DC0084B546676394840B43EC8F8A9D40DC0EE80796E7A3948401C5D16EBF9D50DC022BAD73A59394840350D3303EFD80DC0E91C6CE569394840F393FB121CE30DC064582A384F394840A5AB0B7480EC0DC0FD8E20B06139484081069ABAB2040EC0CA56D4F319394840B0FFC2FF09070EC05E169A7F3D394840D37F247274010EC099470CB6503948409D29CAD339060EC06E592F50B8394840604B0A5C77070EC0DC72E143613A484015EDE7E61B010EC0DA92D6427D3A4840DEC36C91C5040EC0272AA960863A4840B8DCC665F9050EC0F26D77B5B43A484029040C0F79030EC0E7C73534BA3A4840E8EA8CA233050EC0CE6F239DE83A48400401162D9EFF0DC03BA47AB1183B48407F39968CA9000EC001E0686D293B48400D8B6D0504030EC038D0FDA3183B4840EECB2EC2BC060EC010FD6B514F3B4840EEB62412120C0EC0C1CF40BF5F3B4840EB56D7B62E040EC00A86660D713B484045C97671F00B0EC09228182A053C484095EBCC4CF20E0EC0EF81FB4DB73C484072CD3692F2030EC0B63CA9B1EA3C48405E38922C8A080EC0E413A998163D4840C933558A87040EC058217C18443D4840A3D3ADE3CE080EC0747FAAFB763D4840F25B7F94190F0EC06FAF0DA68D3D48402FA3C2BD7E130EC0186EBB80513E4840FBC0308B070D0EC00A3238A1AF3E4840E9B91341CB100EC08160AB0E203F48403C5D6BFF5E130EC0005BCC3EFF3F4840832349CC79110EC08C2636F955404840263210688E0E0EC09410155A734048402267D853050F0EC0BC3FB6AEE74048400A425694DD0C0EC0BC2EC7DC264148404908240E920F0EC060A52BA36D4148401BC23D05B5140EC0EE3C94A591414840BBF158B94B1D0EC000F88618144248409FFB53B679200EC002C60AE3BC424840DC08835CB0270EC030897791F34248408B61680E7C2A0EC0131D870F69434840DF9D174793280EC0DE575088B74348409FBCA5616E230EC03C07E3AEDF43484081AE945C99200EC0CA080FDB1C44484095DE5E67BC1E0EC081BAA2169A444840E08EA57BAC200EC0CB4F81BAF74448406279E7914F2D0EC0DC5C1DFD3B454840B7DADED6252F0EC01FAEC6F1BF4548404682EA04D0360EC044CE45C0DB454840237077EB6E3D0EC0BA35D3E63246484044DA22D18F3E0EC05264276B66464840FFEE6798CB490EC0F22CF7949C464840CA114092184F0EC0787C7A6FCE464840A9D29404C34F0EC006B8A6C0F1464840E3FBD58A0D570EC04C04B21924474840846D5E91315B0EC091686C838E474840EBE554D7A3640EC00A916295ED474840E88A1B585A650EC0F24390DA56484840133B143DA6680EC01186F799A7484840	2	2010-01-01	\N	cd29d316-899b-4218-949c-6ee012eff1b0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
99	39	John	0101000020E610000081482760E76A0DC014F981FD3E394840	3	2017-10-31	\N	87ed267a-386b-411c-86b6-10a6c50b895a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
100	40	John	0101000020E610000058CB057C2A6B0DC019826FEC40394840	3	2017-10-31	\N	90f0b5cf-7c66-4546-a227-fae778dcd729	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
101	41	John	0101000020E61000009167FF51476B0DC0E30C51D741394840	3	2017-10-31	\N	f42cf8a6-0f66-4baf-a309-782ee4054d0b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
102	42	John	0101000020E610000030141800566B0DC0E3D8064043394840	3	2017-10-31	\N	228f78e0-6ccf-4de3-b691-187754ea590e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
103	43	John	0101000020E61000003645E8B5856B0DC0F3DB633B46394840	3	2017-10-31	\N	618ec323-5047-4dfb-a2ad-c32c0898289e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
104	44	John	0101000020E61000004C7393669F6B0DC0B1B88B8247394840	3	2017-10-31	\N	2b87e71e-fea4-4cb2-b2c1-621108189e72	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
105	45	John	0101000020E6100000BEAB8612D96B0DC031FBC8FF4B394840	3	2017-10-31	\N	e87e3a69-99bb-432c-abce-08be8d49c2b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
106	46	John	0101000020E610000051DE2FB4E66B0DC0968CEFDD4D394840	3	2017-10-31	\N	819346e6-01b4-4ea7-9302-220d7b2030be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
107	47	John	0101000020E6100000EB41A90B246C0DC0E61646CC53394840	3	2017-10-31	\N	e510e105-088c-45ac-ba83-dbc561c52f93	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
108	48	John	0101000020E6100000846B56CB496C0DC044B7EA8C56394840	3	2017-10-31	\N	f77d5d7e-e416-4e09-9623-5f5553fa2746	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
109	49	John	0101000020E61000004B43F5245C6C0DC0A28BD9E457394840	3	2017-10-31	\N	b57bee78-8a60-4597-a1d1-b6dd97cae702	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
110	50	John	0101000020E6100000076758DA556C0DC0843EE47F59394840	3	2017-10-31	\N	2a786232-6383-4ac7-8653-eacfbd3d2363	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
57	29202	Plounéour-Ménez	0106000020E610000001000000010300000001000000580000003405D8A5CD560FC0C63290A28F334840EB175BBEB75A0FC0CB5441108A334840EC05C75EEF560FC0C944FE0A263448404FDC3A32E05E0FC0F949ACA6A534484092F7F9ACB4600FC0DAC48B089D354840F9CCB90E44680FC099F8F7E6F3354840FCCA6BFCCA6E0FC019060BEA82364840BE6DAEAE696E0FC0E465D4F3D43648403308F03800760FC07CED97582F374840064A70CFC6750FC05A2E815D5C374840563F31A1827C0FC001591B13893748409C76CA9D2F7F0FC0B3F9A9968437484019A15F6DE3870FC0FDF7C36318384840F15E5A27AE8D0FC047338AE01E3848405D358EBB7B900FC0E75749314C3848402C7E5FEC7A980FC0B6AD8F907C3848408FD50DCCF28E0FC0108D140086384840C58744549A890FC0AB0ED003A7384840CE1763E010880FC0017DF764ED3848402EF785653F7D0FC0228248B047394840F54F79467C780FC0E0D50271A53948407FAB06EDD66D0FC083DF00BE253A4840CED988E2E2710FC0D9CC3C31523A4840C132334808700FC0C2C6FED9B03A4840DE11432591720FC0CBB8576E463B48409F9AFF3504840FC0D56707DBF23B4840C9FE0377917C0FC0ED306BF33E3C4840005EF4F429700FC0E99917F3C33B4840506CDD24F5680FC0023C038ADA3B48400315311F65660FC0593A538F333B4840834371C4C1620FC073AE8047153B4840F18EF1E5035D0FC08542DE2A653B484012C2C73A97530FC028837E59853B4840D4B251ADA4520FC0B53029CAC03B484058725ED280490FC06B23695FD83B4840F9E7D38BF2420FC0642013DA1C3C4840E99797B7393D0FC0D2186883253C484024DD8F0BE03A0FC0252646B9443C48406AD72839BB320FC01FE93974563C4840ED39ED2B94230FC0EE5866A3243D4840AC9CE0CE631D0FC07E5B2C071D3D4840108754784C1E0FC0F6F6C6A63E3D484065E5B11A8E1B0FC000ADBA29453D484077D3988474100FC0103855F5353D4840B1B3C64B1F0F0FC07E72DADF653D4840CC58D5CE39FC0EC0BB56ABDAB03D4840D6A8B454C0F00EC0CA73EE087E3D484003544D0AA6E30EC05227DB90DE3D4840FF79960F44DC0EC0E78EE582DC3D48403D61B80062D10EC0B41BFE584A3D484068D5029F6BC70EC0E87B77365F3D4840AC61C2AF18C30EC019FB45FB313D48402194978138BE0EC0E8795198403D4840BD22F01266BD0EC032EE0F95EF3C48401C63C26015B80EC01F145895863C48406FE92FBE84B50EC07B06E5FA833C48400B7060B77EB30EC05CFAB001CB3C48400B17221D3DAF0EC0EE764E52E33C484057B73E8380AD0EC0CA13CC095B3C48405C6BA1441DA00EC02B5187E3593C48402FC7B55FB39A0EC04094D5097D3C4840DC8197C1C0940EC00C35D2EB5A3C48408230EF1476950EC0DF468FFC2E3C484051B93E362A910EC0DCD7A379E73B4840A1E8BE0559950EC0247EA6F3983B4840A28268093A910EC05AF78CE58A3B484007B0276D5E8A0EC0E8ACE9D22F3B48408065B6FF5D8E0EC0A6FB3724F93A48406B46E00B77960EC0D3C1AFE6DD3A4840DBF5C7A243990EC0CC6B2394243A484001EEE437FB9D0EC09124CBF0FA394840C0DFC7AEC89D0EC06B7058B2B6394840D1A0BCA7B8AB0EC0F780B79A4E3948403E36174E28A70EC0431A653204394840800575A68EA50EC03A5B105172384840F2B02F19F79C0EC023CCCB6008384840E97A4BDE0B9D0EC04221B4CDE93748401CF306FF83980EC000F4E7AACD3748405A265E31B7960EC06F957F3115374840E9B5ABEE9AAF0EC01BF7CC3FD3364840D08D4032E6C40EC06F25B920F93548403268C11F9ED00EC09FE92E26DB354840A99173C662D60EC0CE7D4E5599354840B6C81D83EDF90EC00D863F8450354840A8BC4B4ED4180FC0FDBF6669DB344840C0F6087383250FC092310A679F344840D758129363490FC0AC898EC8AB3348403405D8A5CD560FC0C63290A28F334840	2	2010-01-01	\N	04ac03b7-8335-4a77-aba1-87c86f4456a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
152	92	Al	0101000020E610000039E18635D3E00DC09A9321F5963B4840	3	2017-10-31	\N	95c9f15c-fa09-4d4d-9906-ebd59b07ad82	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
58	29207	Plourin-lès-Morlaix	0106000020E61000000100000001030000000100000062000000BEC8BD31069C0EC053621B903A3E4840DE588D9FD69D0EC019AF8946D03E484094F06A1133A60EC04A8042D39A3F48402E7485A26DA50EC0F6406637D03F4840EAAD052869A90EC0EBE5B5C0354048409C86BBC2DCA60EC0E1267CACB8404840EE5BDB3754AC0EC02D18E7920B41484077A2C84B8BAF0EC0D9F6A5A4094148402A08A88232B50EC0FBF085CEAD414840CFD41E0935B00EC04EC7124F164248401B70AFA132B20EC09B29CAB8694248407BAAA3F51AB70EC0F7D2FC2EB44248405D7BC912F7B40EC09A1CE149094348405DA568A117A90EC0B7AE6EE6A043484047022D5747A90EC064E0806CF34348403481BEC22CA20EC02B6CC8B15B444840AC27330CDFA30EC0F28DB250C4444840AA4B869076A00EC0D8263692E8444840A3B0FE30749B0EC0EF2B5A2CA145484085683949C19F0EC09A31B7541B464840D08718054BA30EC0A70C154E33464840811324C823A90EC052EA63FE2046484033D5452C27A90EC0A7D4D9E8754648401B9D864E93AB0EC06CE1A2736B4648400055976C6CAE0EC0CF6685F59046484008B9B78FA0AE0EC073DBFC7CD2464840B7A2B21109B10EC0B565491EEF46484007A75B55BBB10EC09D2D6DBD78474840F550411DF1B50EC07E673FC31848484045C9D49BDCB00EC0D44D225F79484840A523750176B10EC0BA164D5EAE484840DB24B6FA13AA0EC0E8ED69FFB3484840AD7DAA1CD8980EC0B67A0EC078484840871029327F940EC0562599F6BA4848406532BE4FA6930EC0D17C9349014948408D8C80E79F950EC0E02B8A5C494948403CABDDC6A9900EC037FC74966949484093BB623348860EC06F26151F044948409860CA8D9D7A0EC074635C48314848406C171127EB750EC0E58681965D4848409C9AA338FB6D0EC0570BA5BA42484840296CDCC2BF6C0EC08E7711422A484840D666A5FC82670EC035E11A7529484840E88A1B585A650EC0F24390DA56484840EBE554D7A3640EC00A916295ED474840846D5E91315B0EC091686C838E474840E3FBD58A0D570EC04C04B21924474840A9D29404C34F0EC006B8A6C0F1464840CA114092184F0EC0787C7A6FCE464840FFEE6798CB490EC0F22CF7949C46484044DA22D18F3E0EC05264276B66464840237077EB6E3D0EC0BA35D3E6324648404682EA04D0360EC044CE45C0DB454840B7DADED6252F0EC01FAEC6F1BF4548406279E7914F2D0EC0DC5C1DFD3B454840E08EA57BAC200EC0CB4F81BAF744484095DE5E67BC1E0EC081BAA2169A44484081AE945C99200EC0CA080FDB1C4448409FBCA5616E230EC03C07E3AEDF434840DF9D174793280EC0DE575088B74348408B61680E7C2A0EC0131D870F69434840DC08835CB0270EC030897791F34248409FFB53B679200EC002C60AE3BC424840BBF158B94B1D0EC000F88618144248401BC23D05B5140EC0EE3C94A5914148404908240E920F0EC060A52BA36D4148400A425694DD0C0EC0BC2EC7DC264148402267D853050F0EC0BC3FB6AEE7404840263210688E0E0EC09410155A73404840832349CC79110EC08C2636F9554048403C5D6BFF5E130EC0005BCC3EFF3F4840E9B91341CB100EC08160AB0E203F4840FBC0308B070D0EC00A3238A1AF3E48402FA3C2BD7E130EC0186EBB80513E484026662CD33C160EC0F4FB809D8A3E484085FB5142A71C0EC093DF09B68F3E48409D275F53A0260EC01BA390E4633E4840B253A0515C240EC08C48E6EE3E3E4840D1EC454D82250EC0B8071795DF3D48401E60CDF6472C0EC0B3DB43B1A43D4840D1C46372C82C0EC0D39FFC53653D4840671A771711300EC0BC1E97034C3D4840E191F2BA0E360EC0F93E2E17853D4840D8E3260A373C0EC0D2D1DF5B8C3D48408A61A50DAE3E0EC0ACA4F0AB6B3D4840F16360A73D3F0EC05B9396DABE3D4840456C086E864C0EC0F6E365C0D63D4840398D45336F560EC05EE62FE71E3E48406EFA899E6D590EC0538733FC6D3E484044AEE8C62E670EC07A2CE0FBBA3E48401D85CB90DE6A0EC0A25DAA0CBF3E48401178402EC96C0EC07A46024A373E4840DED9350905730EC039BF8DA1E13D4840EDDC28A31F7B0EC0C4D380A6F63D484097D54E0A1B800EC0A60ABC4DD93D484017AC17DABE910EC0A3E8410DDD3D4840308F43DDEC930EC09888DD3D1E3E4840BEC8BD31069C0EC053621B903A3E4840	2	2010-01-01	\N	2517bcfb-ef01-4e47-83ea-96a7d0aee7f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
59	29275	Scrignac	0106000020E610000001000000010300000001000000A1000000F248C9870D7F0DC04F0BE0E36C3148409C76FAB78C7E0DC05EC35431CE3148404E605872AE780DC0934C402C3432484052C1B9E223780DC02704718A6B3248407DD0BCFB477B0DC09F28045AFE3248401C32068E477F0DC08037D6224B3348400AFAD9091A7C0DC08C394ADFA933484086EF2150AF7D0DC013D9A122F333484085D1F30ED5800DC05963E5DF0C34484061F3DDE89A870DC0D5C435A2F733484015EC7FB7558D0DC06B2C054526344840B5EE97AA03930DC0CB7E77042A344840482A1AA0CA980DC0ACBB91025A344840AEC8EA75DF9D0DC0BB994396BA34484075EA4817ECAC0DC030A611A7E2344840DC13D0443AB10DC0E147C51A183548409012C81EB7B50DC00E2D57051935484025496855F9BB0DC088DD2F28493548406D1CC8A0D1BD0DC029EDAD8702364840798EE19AE6C20DC0D8B6A70023364840E77496B3A3C30DC047DF1AE163364840F77EA7FEC8CB0DC08BCBA13199364840397B40D1A4D10DC0214EE7C75D364840B2C31E5D97D80DC099476BF14F36484034223A2514DC0DC0EAEC2D2C183648400CA8520FD5DA0DC033C1DF32FC354840633750B70DDD0DC00B40B183C035484041FE8871EAEF0DC049A3E5C5CC354840BD178342B5F90DC098F04A223F364840CF5EB19A67080EC0B819A8A856364840070C2EB7B90B0EC076A0FD0670364840B615EBB44A0B0EC08449A1E0EA36484064040143EF0F0EC00EBA8F21233748402B136DA145180EC0A5F819F739374840E02381FD14230EC017C694CF2A374840DFE3979B7B2B0EC00A3F589972374840E082CA90ED260EC064C01C9DAA37484057F901E1802F0EC0F3CDA0F643384840644667725A2F0EC09A85542981384840E211C13C47290EC0F20A15117C38484082540064A7260EC0AB4535B79638484074A8C45C89290EC0F66CA96DD3384840E2158656BD260EC068129A62B3384840AD04EA514C160EC067D25056053948403137751D61150EC0B4EBBCDAF0384840CC801D73CD0B0EC052932F1C003948409786B91FED0A0EC0D216398F35394840B0FFC2FF09070EC05E169A7F3D39484081069ABAB2040EC0CA56D4F319394840A5AB0B7480EC0DC0FD8E20B061394840F393FB121CE30DC064582A384F394840350D3303EFD80DC0E91C6CE5693948401C5D16EBF9D50DC022BAD73A59394840B43EC8F8A9D40DC0EE80796E7A3948404485370C3CD20DC0084B5466763948406FB6B3195ACE0DC0CF7425B5003948404C08A6BC21C20DC0E89989CC50394840724F918F13AB0DC079E23B705A394840F5CA40FD4FA90DC0D151A97FD139484062807F57D4A10DC06557D396D9394840919FF48F739B0DC0CC16DE311E3A48403CC48CAA158B0DC092142B1FDB394840CE9819EEE8840DC08DAFD0C0D9394840A735D771E87B0DC06C592683463A4840DAA669CDC37B0DC0F95D7FC8833A48404A34F1665D6E0DC0D09A2749143B48405F937EBFFF6E0DC07B1E241F2B3B4840F09EC0CEE7650DC0183EEAC35E3B48403E844F471C620DC076B6C9EC9D3B4840E06078144B590DC0294C287A7E3B48402776D4F04F4F0DC063ED3B04A43B4840CFF1CC69743D0DC09BA8ACC8983B48403E9F377C4E340DC0629DA992C33B4840C256E69C17380DC0B0CC705E413C4840F1A8B94C87260DC0DE3A88D98C3C4840392F6C2F67200DC0ED3A5653CA3C4840230AA2586E1E0DC07EA265818D3C484069E9C8273B1A0DC0CCDC528D6E3C4840B48ED90FDE070DC0711008AB683C4840756694D9C8020DC0887464C07C3C4840C93919293D000DC08B45B8A4D63B484026E18EFAE8FA0CC0DC7B9B71573B4840206A1D9869EC0CC0FA9790F7213B4840A3494B8507E50CC0756B6869293B48400AFFB39BF9DF0CC0ED6863F0B83A4840FDF7AE260BE10CC08855304D823A48405138A3CBCADD0CC0566E16F0313A48404DA017895AE00CC051F0002D143A48404D588B135DE20CC0912F7A459B394840A0686011C8F00CC0A0552E783C394840C36E21070EF40CC059E54CF8C0384840D86C585344FA0CC02B4B878C5D3848404934C547C5F80CC0A332FEF92D384840875DA615E1FF0CC086D06DBEB437484022DAF55418FE0CC0EFA618313C374840B32451EA86000DC05DCE1718AD364840DADE81B73EFE0CC0A99A023994364840F118DE1B4FFC0CC09068F2A3A6364840CEA85AD4D6F30CC0AEDEC7898B364840A83B408F5DED0CC09B5715DE463648401AC9A697D9EC0CC0EE1C96070B364840A9A51240F9E40CC0323FDA8BF13548403BEFAD6218E10CC063F8FA53B43548403C39E27386E10CC055B049716C354840C17B049D12E40CC053DE020F54354840830F38F943E20CC0972746E8E4344840A12022261DDB0CC000569CDD703448409DCF15E201D70CC0FBC33DE59E334840B6B6C00600D40CC0040D8F298C3348405E82F0C4C7D20CC081DC35453A3348407FCBA8B6F5D10CC0CE864B0FF43248400A6CF915F4D40CC0EEE409E6993248400485FD26EAD00CC08F55E5ED9032484096B1470419CF0CC07C3A0B1257324840CDD1B24600DD0CC09B17041CBA31484008806A52AEE00CC00DADC78761314840FF8C8A4FE0E50CC03A88F2C74E314840444B30ACC7EB0CC04127DF8CE830484037BAB55537F20CC05E390F56CF304840394E881F77F70CC0E3B29B7AE33048405F5E960562F90CC094C94533CC3048408AE7F073B9FE0CC0EE67ABB8D730484020A54E1A5AFF0CC0D7B11CC9BD304840D3521BF77F030DC079C8B605C8304840AE50A2CDDB050DC0EA63C3D6AA304840CE708054EA080DC0BC3E2DD7C93048407B4D578A55100DC05F62196CD9304840B2143DB806130DC0723AC6E4AA3048409EEC9F3CA6150DC0330FA1BAC3304840D60F2EADAF180DC0DF6D345DB43048407E3ACE4E221D0DC083F7C62CE63048401DB1EBA38F220DC076261991F3304840BB8AD79A22260DC067EA8261603148406183F405DA290DC03E81503968314840EDC067114E2E0DC0D0F5017646314840F087914BE32F0DC08989C0EE72314840F4AF686140330DC07DA76CEA6A314840D6C7237EBF370DC06BCFA214963148406ED27DB0CB390DC0BCEE9AAF7631484046927CEF5A3B0DC085B5165A913148406A4323E73A410DC0170F5EDE77314840047C09291F430DC052CD3A949F31484043178000BB470DC03CCC23299F3148402BF7E5440D540DC0C30DFE0FF53148406BDC4A20405C0DC094B455808931484026723CE2B65B0DC03E762991673148406AE09C00DD620DC01663B4D8D73048409CA6520B356A0DC05E63303CB6304840C975E362296B0DC0031B30807E30484068292D6B58660DC0B2EC955C3B304840493D3CCA99660DC02007BB3A1D30484018FDE04D126F0DC006C681F1A92F4840B3CFF63038720DC0F7DB3B54BD2F4840DFEAEA8F3D700DC076017C3BE22F48408E20D8415D720DC03E59FBD60F304840BC1203284C760DC0C7959BBE253048405626EF64CD740DC01DFF0FEE613048400E539A946E7A0DC088C58319E53048408693BC1A6C7D0DC07EBE63D5F8304840089F81A2F97B0DC0EB4E815644314840F248C9870D7F0DC04F0BE0E36C314840	2	2010-01-01	\N	e9c55228-476a-4016-b317-464d804ba424	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
60	0	John	0101000020E6100000899BBBABCA620DC0EC25198B0D394840	3	2017-10-31	\N	7748ca52-658a-441f-8d42-e26021530804	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
61	1	John	0101000020E6100000899BBBABCA620DC0EC25198B0D394840	3	2017-10-31	\N	dd97f25d-1a33-4a52-948d-9fc8949f12e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
62	2	John	0101000020E61000004533B790F3620DC00A3FC4580D394840	3	2017-10-31	\N	2d46e396-889f-4946-9797-cbf8b599f8be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
63	3	John	0101000020E6100000C868853717630DC0B7E4440D0D394840	3	2017-10-31	\N	01b0fde1-4bd7-4610-a93c-05737f46b15c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
64	4	John	0101000020E61000005518C3EA3B630DC0F2E250110E394840	3	2017-10-31	\N	cc3b829e-1520-4f1e-b901-1fb05bfc99ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
65	5	John	0101000020E610000082D0E2DAFC630DC055402D5811394840	3	2017-10-31	\N	127e0b84-236d-41b5-b829-471c4e556f4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
66	6	John	0101000020E6100000918550F301650DC0D6826AD515394840	3	2017-10-31	\N	afe1c71e-d531-4238-a6af-12fafbff3d61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
67	7	John	0101000020E610000063112BF12C650DC012B5C07015394840	3	2017-10-31	\N	78a25638-c0e6-4568-8d10-b7b6a004f227	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
68	8	John	0101000020E6100000521450F642650DC02F9A21A716394840	3	2017-10-31	\N	636d3b28-d0fa-4d8a-81bd-f367fc0714d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
69	9	John	0101000020E6100000DA06562367650DC046C24A5717394840	3	2017-10-31	\N	7d033548-4fe9-42ed-bdd7-71df8f4a1e9c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
70	10	John	0101000020E6100000901BE619A7650DC0FEADF08019394840	3	2017-10-31	\N	062ce5fd-7170-45ea-8792-7bd9fc48fbd6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
71	11	John	0101000020E6100000294593D9CC650DC0637361F619394840	3	2017-10-31	\N	9ca47c1a-4633-4ee3-84e7-1681fb00c64c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
72	12	John	0101000020E61000002F3C97F7E4650DC0DF60FB1B1B394840	3	2017-10-31	\N	f48ebb6e-6792-405e-a11b-8f78b5be65ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
73	13	John	0101000020E6100000EA0D5F7425660DC067C8044E1D394840	3	2017-10-31	\N	15643acc-ea71-4509-9ef1-218c4542b51f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
74	14	John	0101000020E61000000CB6793140660DC0C69CF3A51E394840	3	2017-10-31	\N	4a3e35b2-571c-4102-b9e6-80b82c86b659	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
75	15	John	0101000020E610000011AD7D4F58660DC01206F1D31F394840	3	2017-10-31	\N	f1c08323-c50e-488b-a02c-bae0a3b3a7ac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
76	16	John	0101000020E6100000229289A9A0660DC0BD0F93C223394840	3	2017-10-31	\N	7de1ac91-252a-4467-9c36-346a56b84e72	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
140	80	John	0101000020E61000009531A6AE28690DC0A046AD827F394840	3	2017-10-31	\N	a6007419-8bcd-4e95-a5ef-3ab765793983	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
141	81	John	0101000020E610000001FFFC0C1B690DC010868D0481394840	3	2017-10-31	\N	ceb1667a-53ee-4063-908b-1acccae24433	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
142	82	John	0101000020E6100000FC07F9EE02690DC0809123EF83394840	3	2017-10-31	\N	dd544dc3-396e-41d5-813c-e71281cd29c7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
143	83	John	0101000020E61000008A439E72F8680DC0A333BCAB85394840	3	2017-10-31	\N	17854d44-24bf-4b24-b226-4489eee4d02a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
144	84	John	0101000020E61000007315F3C1DE680DC0120B08FF89394840	3	2017-10-31	\N	6fbc7b05-4574-4512-ad04-5d18754397ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
145	85	Al	0101000020E6100000A3A03C49F8E10DC0739CE5E0913B4840	3	2017-10-31	\N	b3a703ba-d9da-4f38-bedb-c36f450dd7c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
146	86	Al	0101000020E6100000E14B09DECEE10DC0739CE5E0913B4840	3	2017-10-31	\N	ac33d104-043e-41e0-9edc-90d722b09438	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
147	87	Al	0101000020E610000059E56A817BE10DC0DDB6F9AD953B4840	3	2017-10-31	\N	8a87f9c3-16a9-4761-b142-23185e9eb8d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
148	88	Al	0101000020E6100000D7AF9CDA57E10DC0FACFA47B953B4840	3	2017-10-31	\N	8e5b071b-b6b0-4306-b959-29c23ed44d70	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
149	89	Al	0101000020E61000003E86EF1A32E10DC0427C6A23963B4840	3	2017-10-31	\N	770209a1-2f09-4f0b-872b-ba2df839ad85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
150	90	Al	0101000020E6100000B593E9ED0DE10DC05F9515F1953B4840	3	2017-10-31	\N	017f4cae-145c-48cc-9220-acba9fabb5a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
151	91	Al	0101000020E6100000B5591D56F6E00DC0DC82AF16973B4840	3	2017-10-31	\N	7c22251e-7647-4e2b-9acf-c041527fe2d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
154	94	Al	0101000020E6100000E9DC151785E00DC0F4DE225E963B4840	3	2017-10-31	\N	e9cd60fa-fe29-4a80-8709-00e0f17f60a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
155	95	Al	0101000020E61000009AD8A4F836E00DC0BE690449973B4840	3	2017-10-31	\N	03c7cba8-b436-44fa-9a55-442b8461542f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
156	96	Al	0101000020E61000005105049018E00DC0B878822B983B4840	3	2017-10-31	\N	a9f74417-70df-45a4-9fe2-318046f6e8ae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
157	97	Al	0101000020E61000002F5DE9D2FDDF0DC0936E5540993B4840	3	2017-10-31	\N	61e7a3b7-4a26-4237-b9c5-9e4c17986bb0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
158	98	Al	0101000020E61000009076048DD7DF0DC0AB967EF0993B4840	3	2017-10-31	\N	3de01d32-ae5e-42e0-a7f1-18dd03f5f39a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
159	99	Al	0101000020E61000006811B249BCDF0DC0B610EEFC9A3B4840	3	2017-10-31	\N	8c498dc2-ed9f-4efe-9b8b-89cfb2ef43bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
160	100	Al	0101000020E6100000E01EAC1C98DF0DC0CE3817AD9B3B4840	3	2017-10-31	\N	db503d8b-4517-49db-afa7-10aa80550d44	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
161	101	Al	0101000020E6100000CA429CA437DF0DC0FC541F769E3B4840	3	2017-10-31	\N	710ae0d8-9e02-40a1-9e48-17cf345da315	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
162	102	Al	0101000020E61000004DCA058414DF0DC0C022C9DA9E3B4840	3	2017-10-31	\N	1be892d9-109b-49f4-9f34-f5f72a324e73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
163	103	Al	0101000020E61000008BAF9EB002DF0DC04E7B542AA03B4840	3	2017-10-31	\N	d81633bc-d87f-4341-8d2d-58cc72bbc80a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
164	104	Al	0101000020E6100000A826E9B7EDDE0DC04E470A93A13B4840	3	2017-10-31	\N	06c3e67c-79d1-4681-9491-3f47229a50d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
165	105	Al	0101000020E6100000A87884F0A6DE0DC0ABB364BCA53B4840	3	2017-10-31	\N	ed5061f6-d63f-4d19-a699-43d75e9769ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
166	106	Al	0101000020E6100000BA755FEB90DE0DC01BF3443EA73B4840	3	2017-10-31	\N	876988ef-c716-415a-a366-1a67645b9b4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
167	107	Al	0101000020E61000005F6B17F070DE0DC0E57D2629A83B4840	3	2017-10-31	\N	e17bfdc7-8917-46f3-82de-5831153dabee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
168	108	Al	0101000020E610000032498D2655DE0DC07F846B1CA93B4840	3	2017-10-31	\N	565b0dc1-d874-4bcb-8e82-723601ef65df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
169	109	Al	0101000020E6100000155EAAEF3ADE0DC0BA827720AA3B4840	3	2017-10-31	\N	09147b58-a975-45cb-a287-7f941924c6a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
170	110	Al	0101000020E610000054CFAAECF9DD0DC0BF0B650FAC3B4840	3	2017-10-31	\N	8314ab95-5e35-4569-930c-c68cc4d05532	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
171	111	Al	0101000020E6100000D299DC45D6DD0DC09B013824AD3B4840	3	2017-10-31	\N	97cf47ec-c28a-48a1-83cb-ded118aecdf2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
172	112	Al	0101000020E61000007D649B7158DD0DC0B77E042CB13B4840	3	2017-10-31	\N	026db06a-f628-4eda-b3eb-25aeb9496c09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
173	113	Al	0101000020E61000004A85D9213CDD0DC0F27C1030B23B4840	3	2017-10-31	\N	64c3b28c-bee7-4c77-91c0-afed4c707694	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
174	114	Al	0101000020E6100000B15B2C6216DD0DC05CFFB82BB33B4840	3	2017-10-31	\N	dee9f089-a6fe-4b1d-9daf-4a55383a299d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
175	115	Al	0101000020E6100000123B7B84D8DC0DC002806D2BB53B4840	3	2017-10-31	\N	425fc4d1-9e05-4420-83b6-5ea98f9f11c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
176	116	Al	0101000020E610000018841ADBA9DC0DC04EB520C2B73B4840	3	2017-10-31	\N	9354cacd-5c3f-4dd1-81c8-3c21b7b5310c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
177	117	Al	0101000020E6100000DA42B81F2EDC0DC00B2AB4DABB3B4840	3	2017-10-31	\N	743c5a2f-ccaa-4379-89ec-026e2b101a53	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
178	118	Al	0101000020E6100000E0C5230E17DC0DC0C806DC21BD3B4840	3	2017-10-31	\N	87706ac4-7903-44f9-b077-636c577f2455	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
179	119	Al	0101000020E61000002A252C4706DC0DC0F7562E82BE3B4840	3	2017-10-31	\N	eca29775-003a-4ab3-b7e1-ced1fa6bed1a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
180	120	Al	0101000020E61000000E3A4910ECDB0DC0143C8FB8BF3B4840	3	2017-10-31	\N	fa9779f9-61f0-4f5d-a83b-2e60d6d988e5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
181	121	Al	0101000020E61000001A7AEC84D5DB0DC0D218B7FFC03B4840	3	2017-10-31	\N	0f7aa73f-ef9a-4671-9d63-6e7b1f3d7d9b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
182	122	Al	0101000020E61000000909795ABCDB0DC0DE92260CC23B4840	3	2017-10-31	\N	17cd1fb9-58e2-4e02-b901-b61919d99b7b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
183	123	Al	0101000020E61000008CCAAED1B0DB0DC08FC194AFC33B4840	3	2017-10-31	\N	97aa6a86-5c9a-459c-9950-4ec31dc5e7bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
184	124	Al	0101000020E6100000AE8A982F6DDB0DC08F8D4A18C53B4840	3	2017-10-31	\N	634ec8d9-d97c-4b5f-a657-7e6a2743d0b2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
185	125	Al	0101000020E61000003112020F4ADB0DC0944A829EC53B4840	3	2017-10-31	\N	9ee1f488-27b4-4e75-baaf-72f934487fc3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
186	126	Al	0101000020E61000004E15B4E605DB0DC07CBAC4BFC73B4840	3	2017-10-31	\N	72a4c84b-af7d-4688-baf5-20ffd3940c13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
187	127	Al	0101000020E610000027B061A3EADA0DC0999F25F6C83B4840	3	2017-10-31	\N	de14865f-014d-49b7-a1cc-abb0dd02f056	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
188	128	Al	0101000020E61000009E838FDEAEDA0DC09E2813E5CA3B4840	3	2017-10-31	\N	44ca435e-de3d-4cc6-97c9-e1e44aa19982	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
189	129	Al	0101000020E6100000E32560919DDA0DC06D702C56CC3B4840	3	2017-10-31	\N	fd6f38a1-8c8d-49c1-bd0c-5a6564ece706	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
190	130	Al	0101000020E61000009FD52A1768DA0DC01E6B5062CF3B4840	3	2017-10-31	\N	a840ee1b-b513-465f-a63f-8d423458aba8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
191	131	Al	0101000020E61000002DD7030346DA0DC0F4A3EBF0CF3B4840	3	2017-10-31	\N	8d42fa0d-8a7d-45b4-96d2-8d635adc7b61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
192	132	Al	0101000020E61000002E9D376B2EDA0DC012894C27D13B4840	3	2017-10-31	\N	20309bb9-f0dd-4aaf-9d15-04aebac073e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
193	133	Al	0101000020E6100000EA86CE8810DA0DC04D87582BD23B4840	3	2017-10-31	\N	dbf949fe-163c-40b7-9342-6a034eff2cf2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
194	134	Al	0101000020E6100000FB83A983FAD90DC06A6CB961D33B4840	3	2017-10-31	\N	d7d07cbd-6927-47e9-ae42-eb4d8ad07d92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
195	135	Al	0101000020E61000001D7E5F79CED90DC0C80C5E22D63B4840	3	2017-10-31	\N	9f94fa8a-24b7-4cb8-ad5a-8d896cac5f41	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
196	136	Al	0101000020E6100000D3AABE10B0D90DC0D94305B5D73B4840	3	2017-10-31	\N	21db755c-4932-49c0-910e-be5d94b0bc7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
197	137	Al	0101000020E6100000A688344794D90DC0D80FBB1DD93B4840	3	2017-10-31	\N	51542e03-5ff9-4618-9e65-716114fe3506	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
198	138	Al	0101000020E61000005101583A5DD90DC0A1665271DB3B4840	3	2017-10-31	\N	a6c30e94-476f-4c3d-a602-9c3d2081498f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
199	139	Al	0101000020E61000005253F37216D90DC0779FEDFFDB3B4840	3	2017-10-31	\N	9ad9b8b2-f5ee-4186-8031-ed61a1ec17e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
200	140	Al	0101000020E61000003568103CFCD80DC05395C014DD3B4840	3	2017-10-31	\N	8b8696cc-8200-4529-97bd-6c8bd7716bee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
201	141	Al	0101000020E61000002AB4D497E3D80DC022DDD985DE3B4840	3	2017-10-31	\N	702c73eb-177f-45db-a334-25f8cd598b9a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
202	142	Al	0101000020E610000086D6EB33A5D80DC069555596E03B4840	3	2017-10-31	\N	a91cadd5-1cb2-4a28-b81b-3b8cdf179545	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
203	143	Al	0101000020E61000000F6D28D23BD80DC050C597B7E23B4840	3	2017-10-31	\N	16245d9a-5de2-41a3-9101-96a828df08c9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
204	144	Al	0101000020E61000009D6E01BE19D80DC0F679964EE33B4840	3	2017-10-31	\N	0b2a75ef-4d1a-4560-9672-f6af5bff6da9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
205	145	Al	0101000020E6100000CBA85A28D7D70DC0EA979213E53B4840	3	2017-10-31	\N	9b5861b2-87f9-43e2-be82-722c5d3bc486	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
206	146	Al	0101000020E6100000AFBD77F1BCD70DC0F5110220E63B4840	3	2017-10-31	\N	5973fa73-2b68-41d6-b6bb-93061f6dfcb4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
207	147	Al	0101000020E6100000B5CC4AB076D70DC024625480E73B4840	3	2017-10-31	\N	158b3a84-78e8-466e-bd64-e359ef2d742e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
208	148	Al	0101000020E61000003854B48F53D70DC0CA165317E83B4840	3	2017-10-31	\N	68f0ea02-8ce0-40ac-b991-19ad9c35544f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
209	149	Al	0101000020E6100000CC12C50132D70DC0823643D8E83B4840	3	2017-10-31	\N	1f1a2634-ff32-40c5-a7cf-b09c0a28ec8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
210	150	Al	0101000020E61000006C4B458011D70DC0BD344FDCE93B4840	3	2017-10-31	\N	d232acaf-5a1e-4686-909e-36ebe5a59635	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
211	151	Al	0101000020E6100000F58FE6E5EED60DC005E11484EA3B4840	3	2017-10-31	\N	d023750e-c88a-4c18-8fd3-d0033494d7f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
212	152	Al	0101000020E6100000B636B589D1D60DC040DF2088EB3B4840	3	2017-10-31	\N	f932db25-d893-4997-b059-f8467448071e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
213	153	Al	0101000020E61000005C2C6D8EB1D60DC0878BE62FEC3B4840	3	2017-10-31	\N	325f5b28-c81f-4775-b90c-22e0c22faa05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
214	154	Al	0101000020E6100000792F1F666DD60DC0C7462ABAED3B4840	3	2017-10-31	\N	d7e7fc9c-dff9-45c4-a620-cdf08fff61ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
215	155	Al	0101000020E61000008A7E959910D60DC03195881EF03B4840	3	2017-10-31	\N	036b2527-bfc7-4da9-86f6-4dedf76aae45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
216	156	Al	0101000020E610000019806E85EED50DC00D8B5B33F13B4840	3	2017-10-31	\N	aca43a4a-3da5-4627-aae8-2b8bc01a1ee5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
217	157	Al	0101000020E6100000FC948B4ED4D50DC048896737F23B4840	3	2017-10-31	\N	1b9b6f0e-1441-432e-aa10-5ba6b3eeab65	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
218	158	Al	0101000020E610000085D92CB4B1D50DC0D124BB00F33B4840	3	2017-10-31	\N	db072780-4cb4-4cc1-bbef-47dfbe5e196e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
219	159	Al	0101000020E6100000F26CB77A8CD50DC0A75D568FF33B4840	3	2017-10-31	\N	662caf6a-cad0-4617-80b1-544aef23d57d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
220	160	Al	0101000020E6100000BF195DFB40D50DC0DC9E2A0DF43B4840	3	2017-10-31	\N	7d4cbfe2-1693-4535-bebf-5d028d0e17a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
221	161	Al	0101000020E6100000316A1F481CD50DC0AC1A8E15F43B4840	3	2017-10-31	\N	059a5e48-af31-41c0-a6c8-32f6d1547404	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
222	162	Al	0101000020E61000000448957E00D50DC09A7B5254F53B4840	3	2017-10-31	\N	3fe17bfd-994a-4499-b0a8-b08aafaae508	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
223	163	Al	0101000020E61000008112C7D7DCD40DC08ECD98B0F53B4840	3	2017-10-31	\N	2043dd9b-ddf9-40c6-b971-938a15e2253d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
224	164	Al	0101000020E6100000D1F43AFFB4D40DC09A7B5254F53B4840	3	2017-10-31	\N	e1dc8f3d-ab7d-4de5-9eca-efed1962cba4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
225	165	Al	0101000020E6100000490235D290D40DC070B4EDE2F53B4840	3	2017-10-31	\N	c064f951-bca5-4537-baf1-0f192dbbb250	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
226	166	Al	0101000020E61000007C33925A66D40DC011ACB4F3F53B4840	3	2017-10-31	\N	e4ba9ead-f9fe-4652-a276-ac602be6172c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
227	167	Al	0101000020E61000006C4E86001ED40DC063D2E9A7F73B4840	3	2017-10-31	\N	5d11fa3b-fcbf-477e-acc6-0e324c60cfbd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
228	168	Al	0101000020E610000039FB2B81D2D30DC05DE1678AF83B4840	3	2017-10-31	\N	f5d5230c-556c-41fe-a9a3-1d5dd5d497a1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
229	169	Al	0101000020E610000094570FB5ABD30DC021AF11EFF83B4840	3	2017-10-31	\N	a58e55b7-759b-4e39-83a1-9f69eed9e3bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
230	170	Al	0101000020E610000006A8D10187D30DC07409913AF93B4840	3	2017-10-31	\N	7536926d-43d0-48a7-9b90-44edb87da2b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
231	171	Al	0101000020E6100000733B5CC861D30DC0D9CE01B0F93B4840	3	2017-10-31	\N	9cddebb1-4159-4b09-93da-8ca252560767	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
232	172	Al	0101000020E610000029F4223014D30DC0A94A65B8F93B4840	3	2017-10-31	\N	5692e8a1-3140-41c9-bc7a-dc56c993dfc2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
233	173	Al	0101000020E6100000A1011D03F0D20DC0276C4975F93B4840	3	2017-10-31	\N	6aab720e-eae9-46ef-8665-2a82831f283b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
234	174	Al	0101000020E6100000E569211EC7D20DC0276C4975F93B4840	3	2017-10-31	\N	d313e288-eeac-4edf-a7ea-0bb1512fa028	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
235	175	Al	0101000020E61000005D771BF1A2D20DC003966621F93B4840	3	2017-10-31	\N	9c8c20b1-6ac1-4def-aabe-95a2f2a0f4fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
236	176	Al	0101000020E6100000CFC7DD3D7ED20DC0EC6D3D71F83B4840	3	2017-10-31	\N	06d378ec-42f8-4911-913d-dbf63dbef0c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
237	177	Al	0101000020E61000004118A08A59D20DC05DE1678AF83B4840	3	2017-10-31	\N	6faf9b25-9aee-45f5-aae0-6a7c105e8c90	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
238	178	Al	0101000020E6100000AEAB2A5134D20DC0390B8536F83B4840	3	2017-10-31	\N	0589c63b-94df-4d82-b0ca-cedc3eb7e41d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
239	179	Al	0101000020E6100000B32E963F1DD20DC01C262400F73B4840	3	2017-10-31	\N	295b2889-328e-4627-a770-ede5bb831512	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
240	180	Al	0101000020E61000004EFC7970B5D10DC00BEF7C6DF53B4840	3	2017-10-31	\N	37a4457c-476d-4da5-9d16-086e35f81fce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
241	181	Al	0101000020E61000001BA91FF169D10DC035B6E1DEF43B4840	3	2017-10-31	\N	597f8bbb-332f-4a2c-8c2e-08ef51ea0b72	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
242	182	Al	0101000020E61000006011240C41D10DC0E25B6293F43B4840	3	2017-10-31	\N	a47bb45a-3120-426b-86a4-cd6e8a8132bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
243	183	Al	0101000020E6100000C6E7764C1BD10DC0A6290CF8F43B4840	3	2017-10-31	\N	8d2c5971-f1b6-4e3f-9e0e-1cfe789dbd13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
244	184	Al	0101000020E6100000496FE02BF8D00DC0ACE6437EF53B4840	3	2017-10-31	\N	a50aeece-1ce2-4bbb-99ae-d69e2230963a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
245	185	Al	0101000020E6100000C17CDAFED3D00DC03B731965F53B4840	3	2017-10-31	\N	e21eadb0-f924-46b4-903e-a1bb008f4f0a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
246	186	Al	0101000020E6100000398AD4D1AFD00DC04CDE0A8FF53B4840	3	2017-10-31	\N	3cf1ece8-8d47-4f3d-abc1-cb9ef537a3fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
247	187	Al	0101000020E6100000B097CEA48BD00DC0938AD036F63B4840	3	2017-10-31	\N	c5f021ef-4b82-4dfc-8810-119a80fb3bfa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
248	188	Al	0101000020E610000023E890F166D00DC0C9CBA4B4F63B4840	3	2017-10-31	\N	f863215a-c699-4d38-9a4c-6476a560cc3e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
249	189	Al	0101000020E6100000A66FFAD043D00DC02217A61DF63B4840	3	2017-10-31	\N	12ce469c-ad71-44ce-ba7a-d67515bcecc6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
250	190	Al	0101000020E6100000FB0EA67E1CD00DC0C9FFEE4BF53B4840	3	2017-10-31	\N	e73ccf15-5e06-4ab1-ad5b-9b7e4109adc3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
251	191	Al	0101000020E6100000731CA051F8CF0DC02FF9A958F43B4840	3	2017-10-31	\N	ef304c7a-92ac-4290-b2f9-95bd0ba9685a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
252	192	Al	0101000020E6100000BD41DCF2CFCF0DC000750D61F43B4840	3	2017-10-31	\N	1e7063e1-3552-477e-b3d4-200f7b2c9b9a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
253	193	Al	0101000020E610000040C945D2ACCF0DC011E0FE8AF43B4840	3	2017-10-31	\N	c588afa5-9c0c-4012-9b93-7f9fd5bfc103	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
254	194	Al	0101000020E61000003BD241B494CF0DC0656EC86DF33B4840	3	2017-10-31	\N	4deea6e9-d670-4922-a93e-e971b7f74726	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
255	195	Al	0101000020E61000006E3D6BD481CF0DC0780D042FF23B4840	3	2017-10-31	\N	c4115ef2-31fe-4640-b999-6b7b56f3e77f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
256	196	Al	0101000020E6100000C9994E085BCF0DC0A791A026F23B4840	3	2017-10-31	\N	3340d7e3-5251-4302-9e58-989da9fe3019	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
257	197	Al	0101000020E610000080C6AD9F3CCF0DC06C939422F13B4840	3	2017-10-31	\N	736d70f1-2918-460a-982d-a26be95ab764	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
258	198	Al	0101000020E610000003144BE701CF0DC0261B1912EF3B4840	3	2017-10-31	\N	fb0b0be6-1149-4d0e-954d-c14d22ec22a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
259	199	Al	0101000020E610000042F9E313F0CE0DC0683EF1CAED3B4840	3	2017-10-31	\N	e00ea06c-0ea0-41b8-b594-2e68f7e14198	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
260	200	Al	0101000020E6100000ECABD39ED0CE0DC02D40E5C6EC3B4840	3	2017-10-31	\N	4763e1f7-ca7c-47b4-9d85-fbb28ab0c65e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
261	201	Al	0101000020E610000009231EA6BBCE0DC0CE6BF66EEB3B4840	3	2017-10-31	\N	368ac914-0277-41f6-aef2-b7d4a75c1770	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
262	202	Al	0101000020E610000098EA2AFA81CE0DC0F966A577E93B4840	3	2017-10-31	\N	536d85f7-a80b-435e-bdc5-a40ec3b1cc9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
263	203	Al	0101000020E61000007CC57B2B50CE0DC02B872035E53B4840	3	2017-10-31	\N	3a346bd7-5c2f-49e2-8e29-deca0ac1ad93	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
264	204	Al	0101000020E6100000546029E834CE0DC0F0881431E43B4840	3	2017-10-31	\N	ac059ddf-2c00-4686-9d0c-9cc0e34b8459	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
265	205	Al	0101000020E6100000387546B11ACE0DC0E50EA524E33B4840	3	2017-10-31	\N	51fd263d-fbf4-489d-b7da-296677b5bfc1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
266	206	Al	0101000020E61000006523384B07CE0DC074CFC4A2E13B4840	3	2017-10-31	\N	56a7ed20-ca87-4222-bfa0-3ba83581b7f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
267	207	Al	0101000020E6100000AF824084F6CD0DC0457F7242E03B4840	3	2017-10-31	\N	2edbf996-6451-4f7f-af83-efa75b99577d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
268	208	Al	0101000020E6100000604403CE90CD0DC0BF7FFD3EDB3B4840	3	2017-10-31	\N	c2068805-8929-4fef-bcb4-c17d336ae18f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
269	209	Al	0101000020E6100000CD63F5643CCD0DC01A3393D6D73B4840	3	2017-10-31	\N	e3f9687f-c448-4d7d-8ffa-4737d049d212	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
270	210	Al	0101000020E6100000612206D71ACD0DC06EC15CB9D63B4840	3	2017-10-31	\N	d8e97318-c9e6-46d1-8002-937157b3860d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
271	211	Al	0101000020E610000084A8239DBFCC0DC0FEB5C6CED33B4840	3	2017-10-31	\N	70d8d0ab-3e55-4c66-9197-5ea45661beae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
272	212	Al	0101000020E6100000956B320092CC0DC0E204B02FD13B4840	3	2017-10-31	\N	700c8197-9605-4eaa-895a-5fd00e40320b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
273	213	Al	0101000020E61000006849A83676CC0DC0A706A42BD03B4840	3	2017-10-31	\N	76e8c9c7-3991-43f8-bc11-66540351305b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
274	214	Al	0101000020E61000003B271E6D5ACC0DC0E9297CE4CE3B4840	3	2017-10-31	\N	62a774ac-5b9e-4b8e-a139-c2dc31efe55b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
275	215	Al	0101000020E61000007AEAB9A2D2CB0DC0DF17A106CB3B4840	3	2017-10-31	\N	71e912a9-36f3-4b93-ac2d-e506f18466f8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
276	216	Al	0101000020E61000000F6FFE7C99CB0DC0F8A75EE5C83B4840	3	2017-10-31	\N	fb0ed3c7-794d-4f2d-a7f2-146c0ae28b64	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
277	217	Al	0101000020E6100000BA21EE077ACB0DC0BDA952E1C73B4840	3	2017-10-31	\N	bb50e63b-b072-4465-9fdc-65dfe295eef8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
278	218	Al	0101000020E6100000093E2EC769CB0DC05ED56389C63B4840	3	2017-10-31	\N	86ad432a-f450-4493-937d-b7a0fc85c042	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
279	219	Al	0101000020E610000004472AA951CB0DC0DBC2FDAEC73B4840	3	2017-10-31	\N	82e81c14-7d36-4933-8530-1202ad230055	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
280	220	Al	0101000020E61000007B54247C2DCB0DC052F35F4EC83B4840	3	2017-10-31	\N	055dbd3f-0b58-4cb5-88a0-26c8f11faa13	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
281	221	Al	0101000020E61000004E329AB211CB0DC076FD8C39C73B4840	3	2017-10-31	\N	095b525c-65dc-4d0b-86ae-2498bcd8beb2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
282	222	Al	0101000020E6100000E2F0AA24F0CA0DC0BDA952E1C73B4840	3	2017-10-31	\N	c3e33098-40cd-4701-88b8-abc404d9438a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
283	223	Al	0101000020E6100000C0489067D5CA0DC0AA0A1720C93B4840	3	2017-10-31	\N	71af72b8-5c83-4d39-b5fa-55a63e022193	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
284	224	Al	0101000020E6100000D2456B62BFCA0DC068E73E67CA3B4840	3	2017-10-31	\N	f205636f-3826-46f8-80bb-790e36dd5d1a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
285	225	Al	0101000020E61000001C6BA70397CA0DC0E4A08EF5CC3B4840	3	2017-10-31	\N	cd8259a9-ac44-4225-86e0-8c46c49d421a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
286	226	Al	0101000020E6100000B029B87575CA0DC012BD96BECF3B4840	3	2017-10-31	\N	b32613f7-2a32-4007-9f0a-4289e31ee742	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
287	227	Al	0101000020E61000000BC0674166CA0DC071918516D13B4840	3	2017-10-31	\N	0d988286-7602-4766-8081-02f4765677a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
288	228	Al	0101000020E61000006C4D1B2B6FCA0DC082C82CA9D23B4840	3	2017-10-31	\N	019875d4-7dcb-413c-a634-b68aaedb294c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
289	229	Al	0101000020E610000099FB0CC55BCA0DC0B1187F09D43B4840	3	2017-10-31	\N	b271c1e1-26d2-45dc-b702-09d350027ba3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
290	230	Al	0101000020E61000002EBA1D373ACA0DC07BD7AA8BD33B4840	3	2017-10-31	\N	48c510f7-342a-460f-bca4-4be4c38921e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
291	231	Al	0101000020E6100000C2782EA918CA0DC0342BE5E3D23B4840	3	2017-10-31	\N	c623ab2d-8224-47c6-a776-f399fc54b8ae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
292	232	Al	0101000020E6100000A0D013ECFDC90DC0CAA83CE8D13B4840	3	2017-10-31	\N	0c7198d2-3264-4a49-8749-c0e980842746	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
293	233	Al	0101000020E61000000C649EB2D8C90DC005DB9283D13B4840	3	2017-10-31	\N	a9268dd4-fd9a-4443-bf8f-04055c67de29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
294	234	Al	0101000020E61000008FEB0792B5C90DC0BEFA8244D23B4840	3	2017-10-31	\N	b357bb4f-2888-40f0-b5a6-00fb39575c84	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
295	235	Al	0101000020E610000034E1BF9695C90DC0D522ACF4D23B4840	3	2017-10-31	\N	b6f49239-384a-4aba-85d2-18a9c12c2a5f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
296	236	Al	0101000020E610000035A7F3FE7DC90DC093FFD33BD43B4840	3	2017-10-31	\N	b704759a-b1e6-47bd-8e2e-64db1a10819a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
297	237	Al	0101000020E6100000B2ABF1EF71C90DC092CB89A4D53B4840	3	2017-10-31	\N	5735bdcf-d9b0-421a-a255-b8e2c6f940bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
298	238	Al	0101000020E610000013C50CAA4BC90DC09888C12AD63B4840	3	2017-10-31	\N	de7ed94f-84ce-467f-8688-ebfdf7539d30	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
299	239	Al	0101000020E61000008AD2067D27C90DC00FB923CAD63B4840	3	2017-10-31	\N	6301aa67-cef9-49d3-8b18-09e54383e4df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
300	240	Al	0101000020E61000009C5B4948E2C80DC0A9BF68BDD73B4840	3	2017-10-31	\N	a2629ae7-1b3f-4d5e-a607-65f3283c182b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
301	241	Al	0101000020E6100000FD746402BCC80DC06D8D1222D83B4840	3	2017-10-31	\N	1b9d6bab-697e-4b19-9fea-38147abf489c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
302	242	Al	0101000020E61000006FC5264F97C80DC07FF8034CD83B4840	3	2017-10-31	\N	c3ec1734-1084-45fd-83d0-2a1c2a31d4ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
303	243	Al	0101000020E61000002B3B253D4AC80DC0679C9004D93B4840	3	2017-10-31	\N	2d6179fe-89d6-4099-b437-55413395eac9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
304	244	Al	0101000020E6100000AEC28E1C27C80DC025AD02E3D83B4840	3	2017-10-31	\N	44181d4e-212a-4f90-b8ca-b38e656a52f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
305	245	Al	0101000020E610000004623ACAFFC70DC019FF483FD93B4840	3	2017-10-31	\N	96e5cba1-9527-403e-b994-c72bc3f9ebe7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
306	246	Al	0101000020E6100000BA8E9961E1C70DC08481F13ADA3B4840	3	2017-10-31	\N	f172707b-02ad-43b1-b2ae-e5345b39d47a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
307	247	Al	0101000020E6100000AAA98D0799C70DC00BB5B0D5DD3B4840	3	2017-10-31	\N	1b57f4bd-6c72-4e1d-b582-585e5c64b94f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
308	248	Al	0101000020E6100000491CDA1D90C70DC0CF4E10A3DF3B4840	3	2017-10-31	\N	b385221c-0705-411f-8a36-718214c93655	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
309	249	Al	0101000020E6100000F9C5CDC688C70DC0807D7E46E13B4840	3	2017-10-31	\N	b3195ee5-a752-469d-bfd5-e394e5e1eebf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
310	250	Al	0101000020E61000008DBEAAD07EC70DC032ACECE9E23B4840	3	2017-10-31	\N	3984cc63-5e87-4bdb-9340-37b7addb5065	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
311	251	Al	0101000020E6100000E35D567E57C70DC01A5079A2E33B4840	3	2017-10-31	\N	fcb76524-80a9-4892-8d8f-6c637b5f9c94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
312	252	Al	0101000020E6100000C1EF075954C70DC0CC7EE745E53B4840	3	2017-10-31	\N	14f77740-499a-4799-8cab-69b97726b682	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
313	253	Al	0101000020E6100000888DDA1A4FC70DC01EA51CFAE63B4840	3	2017-10-31	\N	23d443ed-b417-4fed-9d99-8f609a1856e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
314	254	Al	0101000020E61000008E10460938C70DC0DC814441E83B4840	3	2017-10-31	\N	f4246036-896d-4a33-b4e7-155636eaaadf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
315	255	Al	0101000020E61000000BDB776214C70DC0BE689973E83B4840	3	2017-10-31	\N	c7a526dd-8eab-4c62-b4d6-d618f93bc383	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
316	256	Al	0101000020E6100000AB4DC4780BC70DC0FF23DDFDE93B4840	3	2017-10-31	\N	fbf90345-5256-4e57-b9d7-4bbebe9ad778	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
317	257	Al	0101000020E61000009F0D210422C70DC0BD000545EB3B4840	3	2017-10-31	\N	4dd5a536-54c4-4630-aeb8-1093d493eeef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
318	258	Al	0101000020E6100000D83582AA0FC70DC09D7FC548EE3B4840	3	2017-10-31	\N	4bb3c8d7-be3d-4dab-9958-b031992d333a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
319	259	Al	0101000020E61000007D9FD2DE1EC70DC0DE3A09D3EF3B4840	3	2017-10-31	\N	1cdaa03c-92e8-4c0b-9ad5-02a45de43917	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
320	260	Al	0101000020E6100000F5E6984912C70DC0C0ED136EF13B4840	3	2017-10-31	\N	8fe4d4b1-c49b-444b-b812-ab59b8b1b11a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
321	261	Al	0101000020E6100000941F19C8F1C60DC0D7153D1EF23B4840	3	2017-10-31	\N	139069a6-a49a-40ab-b1aa-417231df0172	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
322	262	Al	0101000020E610000017A782A7CEC60DC0E3C3F6C1F13B4840	3	2017-10-31	\N	32147a24-be41-4b03-8e96-ddf1f9666714	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
323	263	Al	0101000020E6100000720366DBA7C60DC0361E760DF23B4840	3	2017-10-31	\N	77c6c5cf-fe3f-4aed-a03b-e9bd587fc2f3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
324	264	Al	0101000020E6100000BD626E1497C60DC0656EC86DF33B4840	3	2017-10-31	\N	54557292-ca0b-49f7-9978-8a5b35e26b7d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
325	265	Al	0101000020E610000012021AC26FC60DC08E01E347F43B4840	3	2017-10-31	\N	8c0e4202-e401-41fe-a030-3cd274d3b9ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
326	266	Al	0101000020E61000005C27566347C60DC08E01E347F43B4840	3	2017-10-31	\N	c470ca26-dd7f-4131-9c1e-a7d2593939ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
327	267	Al	0101000020E61000007F210C591BC60DC0B760B38AF63B4840	3	2017-10-31	\N	3189d218-fd81-44ac-ae5d-107f917edd8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
328	268	Al	0101000020E6100000A11BC24EEFC50DC080B74ADEF83B4840	3	2017-10-31	\N	96d87119-d98a-4b4c-9f9f-9db343e1aede	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
329	269	Al	0101000020E6100000B2189D49D9C50DC06E180F1DFA3B4840	3	2017-10-31	\N	445c281a-ab4c-403f-a586-f646551f493a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
330	270	Al	0101000020E6100000479DE123A0C50DC0CCB8B3DDFC3B4840	3	2017-10-31	\N	f6b2cca4-2b96-4eff-8f17-36a05bf53b4c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
331	271	Al	0101000020E6100000E761C97250C50DC0882D47F6003C4840	3	2017-10-31	\N	897e46a3-82bf-4379-80a4-6190392bc54d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
332	272	Al	0101000020E6100000D6B689B01FC50DC0545407A7FD3B4840	3	2017-10-31	\N	83d1e57d-ef99-4dd7-9ce4-96c1ee724a33	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
333	273	Phil	0101000020E61000006849FA207A8F0DC04E7C709AF33C4840	3	2017-10-31	\N	f15fd756-e0a9-4977-9b1c-4c62e3e171c0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
334	274	Phil	0101000020E610000029B6FC2C458F0DC0CD05E985F03C4840	3	2017-10-31	\N	66731f41-ff5a-4fef-9d8f-500428bc6918	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
335	275	Phil	0101000020E6100000F79C6E45118F0DC080D035EFED3C4840	3	2017-10-31	\N	dacb7c8a-1ae4-4dde-971d-125d5c75a194	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
336	276	Phil	0101000020E6100000C4BDACF5F48E0DC0936F71B0EC3C4840	3	2017-10-31	\N	3d198fd1-cfd1-4f73-b17a-c7a52a266965	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
337	277	Phil	0101000020E61000008B21B31FD88E0DC02330912EEB3C4840	3	2017-10-31	\N	53cff482-42f5-416a-b558-ca9f6c4ba724	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
338	278	Phil	0101000020E610000042A0ADEF728E0DC09BC887FCE83C4840	3	2017-10-31	\N	c79d4d9a-b6e3-44da-a0d9-384b7db3b1dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
339	279	Phil	0101000020E61000000904B419568E0DC0EF5651DFE73C4840	3	2017-10-31	\N	71b4970f-e62f-43bb-9c60-26f727d23cad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
340	280	Phil	0101000020E6100000D067BA43398E0DC0A2ED53B1E63C4840	3	2017-10-31	\N	bb5096fc-56b2-408b-b711-f61800ac08ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
341	281	Phil	0101000020E61000006426CBB5178E0DC0C6F7809CE53C4840	3	2017-10-31	\N	1aa1366a-5a4d-4003-945c-15c7e5ec60d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
342	282	Phil	0101000020E6100000DC33C588F38D0DC08508F37AE53C4840	3	2017-10-31	\N	44dd4681-3daa-483b-ac26-1e9c505e87bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
343	283	Phil	0101000020E61000002659012ACB8D0DC02CF13BA9E43C4840	3	2017-10-31	\N	e00597a3-ba00-4321-a848-8e1fca8ed4be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
344	284	Phil	0101000020E610000082B5E45DA48D0DC04A0AE776E43C4840	3	2017-10-31	\N	3c50b7f5-5a63-4b2b-bcb3-e8d9a56e27d6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
345	285	Phil	0101000020E6100000073D4E3D818D0DC0798E836EE43C4840	3	2017-10-31	\N	375f80f9-5b8b-469f-948c-42bd9d58c2b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
346	286	Phil	0101000020E6100000F45742E3388D0DC06DE0C9CAE43C4840	3	2017-10-31	\N	187ba293-33bb-4bb9-ae99-be5e33f2b6df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
347	287	Phil	0101000020E61000003E7D7E84108D0DC0BB7D1190E43C4840	3	2017-10-31	\N	a800fce7-e80d-489b-bed6-da9adc98c09f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
348	288	Phil	0101000020E6100000BE47B0DDEC8C0DC020438205E53C4840	3	2017-10-31	\N	16af4a58-4bfd-4d52-90f1-419ab9cf5dbc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
349	289	Phil	0101000020E61000003FCF19BDC98C0DC0376BABB5E53C4840	3	2017-10-31	\N	dd36d5d6-a9b2-4b4f-a777-19554a806945	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
350	290	Phil	0101000020E61000009A2BFDF0A28C0DC008E70EBEE53C4840	3	2017-10-31	\N	26b330c4-7584-4ffd-be22-0e4aed18d465	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
351	291	Phil	0101000020E6100000A6F707365D8C0DC04A0AE776E43C4840	3	2017-10-31	\N	93681c99-6c50-43a7-9be1-53bca0973695	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
352	292	Phil	0101000020E610000040FFB7FE0C8C0DC064023984DF3C4840	3	2017-10-31	\N	027bf2e5-d676-4984-bd35-9bf8d48938db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
353	293	Phil	0101000020E610000038297F637E8B0DC0556770B7D93C4840	3	2017-10-31	\N	c4418621-ed29-460b-8c07-210df48d946b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
354	294	Phil	0101000020E6100000257E3FA14D8B0DC0BC94755BD73C4840	3	2017-10-31	\N	89277d5c-5770-4cae-8224-0202cd796042	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
355	295	Phil	0101000020E6100000A2823D92418B0DC07BD931D1D53C4840	3	2017-10-31	\N	caa2f685-c195-4b3e-84e3-4b50c37a9da1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
356	296	Phil	0101000020E61000009F8B3974298B0DC03B5238DED23C4840	3	2017-10-31	\N	b2a5f52c-d9ca-4f3d-a48c-a557de0fad08	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
357	297	Phil	0101000020E6100000E7EA41AD188B0DC0BADBB0C9CF3C4840	3	2017-10-31	\N	715f7935-2d01-41ef-a32b-65c38340b5fd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
358	298	Phil	0101000020E610000080DA22D5268B0DC0158F4661CC3C4840	3	2017-10-31	\N	2a9317af-404e-46ed-8c34-619f1ac522a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
359	299	Phil	0101000020E6100000483E29FF098B0DC0AA0C9E65CB3C4840	3	2017-10-31	\N	f4252386-9a47-43c5-be88-f3fb7df6a80f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
360	300	Phil	0101000020E6100000C54227F0FD8A0DC069515ADBC93C4840	3	2017-10-31	\N	2a8a52a7-7532-4527-8723-67dd5a4cde05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
361	301	Phil	0101000020E6100000C54227F0FD8A0DC005C033FDC73C4840	3	2017-10-31	\N	f3db3aa8-2da0-4a65-b7a0-28044b0045fc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
362	302	Phil	0101000020E6100000C54227F0FD8A0DC061A7132CC33C4840	3	2017-10-31	\N	9cc8f57e-82d7-429a-8ea0-8f02f4b3406c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
363	303	Phil	0101000020E6100000155F67AFED8A0DC0BD8EF35ABE3C4840	3	2017-10-31	\N	e083aff8-1eee-46a1-be4b-391328b2252d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
364	304	Phil	0101000020E61000004E133026AC8A0DC073296921B63C4840	3	2017-10-31	\N	d4fafdb6-ca20-450d-a66a-8567afa2aa7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
365	305	Phil	0101000020E6100000CB172E17A08A0DC062F2C18EB43C4840	3	2017-10-31	\N	f304eb97-3406-4340-a6d8-426d440cb524	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
366	306	Phil	0101000020E610000010BAFEC98E8A0DC08273018BB13C4840	3	2017-10-31	\N	3dab226a-3247-4343-a49b-57d97be18255	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
367	307	Phil	0101000020E61000007CC121C0988A0DC04E9AC13BAE3C4840	3	2017-10-31	\N	a7fbe03c-cb04-495c-bf31-cc718c427da8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
368	308	Phil	0101000020E610000051F1322F368A0DC0D89DA933AC3C4840	3	2017-10-31	\N	842027b9-e095-4c1a-8ca3-a0a868a94eda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
369	309	Phil	0101000020E6100000830093C095890DC0A981A16AA93C4840	3	2017-10-31	\N	942353aa-0205-4916-bc33-f1f4606e771b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
370	310	Phil	0101000020E6100000F21F855741890DC069C65DE0A73C4840	3	2017-10-31	\N	d5afef71-c375-4b7d-bb0e-b015ec208bd0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
371	311	Phil	0101000020E6100000F189EF309C880DC087DF08AEA73C4840	3	2017-10-31	\N	44b06ba1-bd30-4a5d-85fd-746a243c4646	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
372	312	Phil	0101000020E610000047079EE7FE870DC04BADB212A83C4840	3	2017-10-31	\N	62a587be-c500-4758-9721-28bb44974018	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
373	313	Phil	0101000020E61000009DA64995D7870DC0F161B1A9A83C4840	3	2017-10-31	\N	1e69b5c5-7895-4ae7-989d-f8564e609e3b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
374	314	Phil	0101000020E6100000040904A682870DC0575B6CB6A73C4840	3	2017-10-31	\N	960f4885-8e08-4fe0-a409-5e6a1b83ba82	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
375	315	Phil	0101000020E6100000335B2CB1E1860DC07440CDECA83C4840	3	2017-10-31	\N	4fe09cca-3d1d-454f-9531-d51b066eddf6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
376	316	Phil	0101000020E610000045C2718526860DC080BA3CF9A93C4840	3	2017-10-31	\N	883a869f-9626-4e0f-b1a3-d2f6ab4d0be0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
377	317	Phil	0101000020E6100000738832C0B4850DC0E44B63D7AB3C4840	3	2017-10-31	\N	d682b519-e817-45e3-88de-01027a03b728	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
378	318	Phil	0101000020E6100000CA1DB017B9840DC090BD99F4AC3C4840	3	2017-10-31	\N	37d0a911-4465-403e-9afb-0ba7e9ffa362	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
379	319	Phil	0101000020E6100000DC325AB344840DC091F1E38BAB3C4840	3	2017-10-31	\N	bf19ce6a-043a-46f2-9fb6-04f0661476f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
380	320	Phil	0101000020E61000005AFD8B0C21840DC0207EB972AB3C4840	3	2017-10-31	\N	3096161c-773c-4cfe-a92e-2bd4fbd3da89	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
381	321	Phil	0101000020E6100000CC4D4E59FC830DC0253BF1F8AB3C4840	3	2017-10-31	\N	3a5a7dce-1be9-4dad-89e4-21d68404b726	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
382	322	Phil	0101000020E61000004F611F09AA830DC055BF8DF0AB3C4840	3	2017-10-31	\N	d567e9b2-d56a-42b0-9895-559e68f6e76a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
383	323	Phil	0101000020E61000004C304F537A830DC073D838BEAB3C4840	3	2017-10-31	\N	83dcdbc2-a4ec-4770-9267-493b79f48467	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
384	324	Phil	0101000020E610000069F934931E830DC04911D44CAC3C4840	3	2017-10-31	\N	5dac98fa-443d-4cf7-ab5e-0315fa83a385	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
385	325	Phil	0101000020E6100000C25518C7F7820DC072A4EE26AD3C4840	3	2017-10-31	\N	a4c6ade2-9c0f-419d-8d29-0c4d9ca1bb1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
386	326	Phil	0101000020E6100000ACB3D4E6AE820DC0A1F44087AE3C4840	3	2017-10-31	\N	644ef4a9-9405-41de-b0dc-d5cd6b9fb936	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
387	327	Phil	0101000020E6100000E52DD1C555820DC0FB3F42F0AD3C4840	3	2017-10-31	\N	a5c51f33-a4d9-41a7-b6f4-d9b94d744053	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
388	328	Phil	0101000020E6100000499987B8E8810DC04F02566AAB3C4840	3	2017-10-31	\N	c3f18cf0-18a5-4437-8268-48d291bdfe57	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
389	329	Phil	0101000020E61000004D6E8EDF8A810DC0672A7F1AAC3C4840	3	2017-10-31	\N	abe5ca6b-7923-4330-83ca-6d7c1dc8e779	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
390	330	Phil	0101000020E6100000C507F08237810DC0CCEFEF8FAC3C4840	3	2017-10-31	\N	a199947f-81ef-47f7-bfdb-d1bb97d5cf61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
391	331	Phil	0101000020E6100000CB508FD908810DC00DDF7DB1AC3C4840	3	2017-10-31	\N	f49cbec7-a1cc-4205-9e41-12c53da274ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
392	332	Phil	0101000020E6100000F3077D55DD800DC07E52A8CAAC3C4840	3	2017-10-31	\N	5c92f1d3-40f4-4281-853b-3c56446934ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
393	333	Phil	0101000020E610000007CB8BB8AF800DC03672988BAD3C4840	3	2017-10-31	\N	5d79393e-d34b-449c-961a-b5895fc6e390	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
394	334	Phil	0101000020E6100000A4C93F9F77800DC02407A761AD3C4840	3	2017-10-31	\N	74ca6efd-000e-41b5-b2de-d91e4ba31bfd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
395	335	Phil	0101000020E61000007ECE5735B77F0DC007EEFB93AD3C4840	3	2017-10-31	\N	b0d99127-733b-4b7d-a743-7651a58f1a00	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
396	336	Phil	0101000020E610000031CAE616697F0DC0B950B4CEAD3C4840	3	2017-10-31	\N	b16a536b-ee3d-4dec-9cb6-7f29639ec805	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
397	337	Phil	0101000020E61000004CE5678FC67E0DC0DD269722AE3C4840	3	2017-10-31	\N	62aca943-1b68-4ed8-86c7-ac4fc223a734	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
398	338	Phil	0101000020E610000075EEF043547E0DC089CC17D7AD3C4840	3	2017-10-31	\N	d74f6a03-9d80-4d62-a4d0-afae8896d759	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
399	339	Phil	0101000020E610000092F1A21B107E0DC00131C40DAD3C4840	3	2017-10-31	\N	f80a1975-9f86-4f58-b649-fbbc8cdc2517	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
400	340	Phil	0101000020E61000002E6DEB13EF7D0DC0FB738C87AC3C4840	3	2017-10-31	\N	4a98f6f2-1cf8-480f-8a6b-c74fd538551a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
401	341	Phil	0101000020E610000001D7C81AA47D0DC0EA3CE5F4AA3C4840	3	2017-10-31	\N	3d0375c1-b08b-42e6-8c82-40f08c00c692	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
402	342	Phil	0101000020E610000073278B677F7D0DC04488E65DAA3C4840	3	2017-10-31	\N	c684e0e1-9731-421a-a86c-4517511cb438	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
403	343	Phil	0101000020E6100000DDBA152E5A7D0DC04488E65DAA3C4840	3	2017-10-31	\N	8ed95602-2ac4-4bd0-9600-f417d793d58b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
404	344	Phil	0101000020E6100000DA8945782A7D0DC062A1912BAA3C4840	3	2017-10-31	\N	804805b1-19ac-447b-8b58-f39540bba81b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
405	345	Phil	0101000020E6100000AB7F8A4FB07C0DC00E4712E0A93C4840	3	2017-10-31	\N	598a144f-03f4-4e49-973c-c503810519e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
406	346	Phil	0101000020E6100000238D84228C7C0DC01BF5CB83A93C4840	3	2017-10-31	\N	408ce31e-fb15-41b6-af08-f8663633c7ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
407	347	Phil	0101000020E6100000BF08CD1A6B7C0DC020B2030AAA3C4840	3	2017-10-31	\N	4177dc69-b826-41b1-9d2d-6ce6e33935dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
408	348	Phil	0101000020E61000001865B04E447C0DC03ECBAED7A93C4840	3	2017-10-31	\N	aafd385c-ab16-4b1e-a480-a061260a3bd0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
409	349	Phil	0101000020E6100000E51156CFF87B0DC04A79687BA93C4840	3	2017-10-31	\N	af71bca4-17c0-41d6-8356-473c0739d151	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
410	350	Phil	0101000020E610000069B18E4F777B0DC0A4C469E4A83C4840	3	2017-10-31	\N	a0ea0712-373f-453e-a1bf-67c9e3c6952b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
411	351	Phil	0101000020E6100000259B256D597B0DC05036A001AA3C4840	3	2017-10-31	\N	4982d11d-abbc-4f45-bde2-cfafc8a879a4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
412	352	Phil	0101000020E61000003E8F04865B7B0DC073D838BEAB3C4840	3	2017-10-31	\N	aaec5d42-5bcd-47ca-99d4-e81fa71043ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
413	353	Phil	0101000020E6100000B39CFE58377B0DC096AE1B12AC3C4840	3	2017-10-31	\N	913ff1da-12ff-4f80-b7a2-b591db9ceef9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
414	354	Phil	0101000020E61000002EC2C7CCB47A0DC07B827F6DB23C4840	3	2017-10-31	\N	ce3da542-e089-4e90-a88c-0b97f81a5366	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
415	355	Phil	0101000020E6100000CBFA474B947A0DC0226BC89BB13C4840	3	2017-10-31	\N	bf3ec926-a42e-4b34-8f3a-b0304cfb0c2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
416	356	Phil	0101000020E6100000B7CC9C9A7A7A0DC0648EA054B03C4840	3	2017-10-31	\N	1aa9f1e1-cf4b-4a81-882b-b73f6938dcd2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
417	357	Phil	0101000020E6100000D7C652904E7A0DC0A0C0F6EFAF3C4840	3	2017-10-31	\N	3e8aa4b2-9431-4c98-85b9-6efbbaef99a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
418	358	Phil	0101000020E610000010B5E79E247A0DC01DE2DAACAF3C4840	3	2017-10-31	\N	a45b9f03-a17b-41e0-8065-acd95a1cc330	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
419	359	Phil	0101000020E6100000BB67D729057A0DC04775F586B03C4840	3	2017-10-31	\N	190a914d-f11d-41a3-b5a7-13d1595bce8b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
420	360	Phil	0101000020E610000039320983E1790DC09ACF74D2B03C4840	3	2017-10-31	\N	68c1d379-94a6-44d7-ad5e-9ea9e5001798	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
421	361	Phil	0101000020E61000008ED1B430BA790DC058E0E6B0B03C4840	3	2017-10-31	\N	a3fa255e-3921-4b1b-ac95-716e3ad2564c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
422	362	Phil	0101000020E6100000F23C6B234D790DC0226BC89BB13C4840	3	2017-10-31	\N	27980a79-d091-49a1-a93b-dae27d4fab28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
423	363	Phil	0101000020E6100000E1CBF7F833790DC0648EA054B03C4840	3	2017-10-31	\N	a63e5665-f53c-4f74-a564-37e46f87a490	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
424	364	Phil	0101000020E61000002FE837B823790DC004521DCEB13C4840	3	2017-10-31	\N	2fcd2491-7037-4a99-a552-98755085031e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
425	365	Phil	0101000020E610000092C786DAE5780DC057785282B33C4840	3	2017-10-31	\N	16edf951-39dc-4981-86ba-32c261451622	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
426	366	Phil	0101000020E6100000E62C66F0A6780DC01A12B24FB53C4840	3	2017-10-31	\N	f68a3599-5db1-4d2b-b8fc-9689c000053a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
427	367	Phil	0101000020E6100000F7B5A8BB61780DC0F6078564B63C4840	3	2017-10-31	\N	289befbd-670a-4b04-bfad-8bf1525ae439	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
428	368	Phil	0101000020E6100000608CFBFB3B780DC00873768EB63C4840	3	2017-10-31	\N	6738a019-e11d-445b-8c1d-69d4d8f8973a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
429	369	Phil	0101000020E6100000257C69F6EF770DC08B5192D1B63C4840	3	2017-10-31	\N	1a7f8fc6-b097-4ac7-ac37-f932a70d9198	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
430	370	Phil	0101000020E6100000A5469B4FCC770DC07FA3D82DB73C4840	3	2017-10-31	\N	3878b281-fec6-48ed-bb1a-a4920f111c80	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
431	371	Phil	0101000020E61000004E85F2AA7D770DC0E9258129B83C4840	3	2017-10-31	\N	10b30aee-4ed2-440c-8a34-c532100780c0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
432	372	Phil	0101000020E6100000C892EC7D59770DC013B99B03B93C4840	3	2017-10-31	\N	4b23129b-9bfb-4710-8cc7-2cba79a43599	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
433	373	Phil	0101000020E6100000AFF0A89D10770DC0D652FBD0BA3C4840	3	2017-10-31	\N	29f34b88-aa12-4b25-87b1-2e75fd6b40f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
434	374	Phil	0101000020E610000055E660A2F0760DC082C431EEBB3C4840	3	2017-10-31	\N	d742412f-bdd9-40fd-8a55-1a77b0876d8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
435	375	Phil	0101000020E6100000DD2A0208CE760DC0E789A263BC3C4840	3	2017-10-31	\N	5fa72f2d-ee4d-43ad-8407-c7d360966d1d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
436	376	Phil	0101000020E6100000A51A700282760DC09FA99224BD3C4840	3	2017-10-31	\N	e834ebe8-b31c-49aa-83ce-4ec10e96134c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
437	377	Phil	0101000020E610000050CD5F8D62760DC0B7D1BBD4BD3C4840	3	2017-10-31	\N	9243af40-1a57-4fa9-83dc-68922ede9176	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
438	378	Phil	0101000020E6100000FD7F4F1843760DC093C78EE9BE3C4840	3	2017-10-31	\N	3cd01134-297b-4a9d-96ba-6030418229ef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
439	379	Phil	0101000020E61000008F3E608A21760DC050A4B630C03C4840	3	2017-10-31	\N	1722c289-10f8-4910-9b51-a483c5d0faf1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
440	380	Phil	0101000020E61000002389D8CCD0750DC0438E685EC33C4840	3	2017-10-31	\N	a4b403ee-6e7a-4c21-8e1e-30423c5887f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
441	381	Phil	0101000020E61000005CB13973BE750DC013D681CFC43C4840	3	2017-10-31	\N	0af4327f-4674-4f57-a528-58ad93fa2958	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
442	382	Phil	0101000020E610000051C331378E750DC068E9C5ACCC3C4840	3	2017-10-31	\N	1d52058c-529b-46df-b46e-d2ecb3cbffb1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
443	383	Phil	0101000020E6100000578069BD8E750DC079206D3FCE3C4840	3	2017-10-31	\N	c2eec19e-88e8-452a-b9d4-f1f4fb156171	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
444	384	Phil	0101000020E610000035121B988B750DC00D363015D03C4840	3	2017-10-31	\N	0dc7c88e-7574-410a-ae16-6f5925c8eeca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
445	385	Phil	0101000020E6100000DA419F3483750DC04DF1739FD13C4840	3	2017-10-31	\N	db8bba21-3319-40f4-ad44-26842de59ddf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
446	386	Phil	0101000020E61000004CCC2D1976750DC0BE305421D33C4840	3	2017-10-31	\N	a2b70f6e-cf82-41c1-aa8e-a8fd29e1cc2e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
447	387	Phil	0101000020E61000007A7A1FB362750DC010233F3ED63C4840	3	2017-10-31	\N	90ceccb9-e1ef-4c3a-9c88-df9e1ab4a21e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
448	388	Phil	0101000020E6100000A762DDE466750DC0215AE6D0D73C4840	3	2017-10-31	\N	3c37e661-4aa5-4f43-91f9-4e3f844cd304	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
449	389	Phil	0101000020E61000003664B6D044750DC0AFB27120D93C4840	3	2017-10-31	\N	8608597d-77b8-436e-a3c3-809d6d61b66a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
450	390	Phil	0101000020E6100000ECE2B0A0DF740DC060AD952CDC3C4840	3	2017-10-31	\N	3feeb61e-59aa-4bdc-a8ca-ad36e51d06b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
451	391	Phil	0101000020E61000007DE4898CBD740DC059BC130FDD3C4840	3	2017-10-31	\N	f6f3be80-d77a-47e3-b66c-2df9695fd03e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
452	392	Phil	0101000020E61000006C731662A4740DC035B2E623DE3C4840	3	2017-10-31	\N	7c6a6510-5737-43f4-bd8f-1186737bb0ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
453	393	Phil	0101000020E61000003994541288740DC05297475ADF3C4840	3	2017-10-31	\N	8ef84555-12dc-497a-93c4-6eee34dd6def	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
454	394	Phil	0101000020E6100000B45E866B64740DC04CA6C53CE03C4840	3	2017-10-31	\N	7e0f6b59-517e-4f1b-a821-4e17d6cfa9e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
455	395	Phil	0101000020E6100000FBC68A863B740DC0CF84E17FE03C4840	3	2017-10-31	\N	fd3919f5-a9d2-4370-a0fb-1fe1e443ce0d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
456	396	Phil	0101000020E61000009EBC428B1B740DC08D6109C7E13C4840	3	2017-10-31	\N	9440d362-089a-4eb8-a843-36a67a333d73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
457	397	Phil	0101000020E61000002CBE1B77F9730DC015FD5C90E23C4840	3	2017-10-31	\N	a48eb8f2-56ea-43b3-9f47-e54920fe1b49	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
458	398	Phil	0101000020E6100000189070C6DF730DC0035E21CFE33C4840	3	2017-10-31	\N	700ff557-7d99-4c34-88e1-1e14db851b2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
459	399	Phil	0101000020E6100000935AA21FBC730DC08BF97498E43C4840	3	2017-10-31	\N	fc3b9db0-f673-4893-a520-4436f28df2a0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
460	400	Phil	0101000020E610000066381856A0730DC09773E4A4E53C4840	3	2017-10-31	\N	cd7e33f6-47fd-431f-9b76-0a1a62b8d2bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
461	401	Phil	0101000020E610000017A83F6781730DC0A2ED53B1E63C4840	3	2017-10-31	\N	bb31b48c-deca-4536-bf78-1f633e4edbfe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
462	402	Phil	0101000020E6100000853BCA2D5C730DC08A91E069E73C4840	3	2017-10-31	\N	24d08312-972e-4661-8e51-3b9bf736a55e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
463	403	Phil	0101000020E61000001DB712263B730DC0C58FEC6DE83C4840	3	2017-10-31	\N	c9e51191-f8be-46de-a950-6cf8d54c7f68	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
464	404	Phil	0101000020E6100000F551C0E21F730DC0D0095C7AE93C4840	3	2017-10-31	\N	1fb78270-1c86-4af7-8e8e-a02823800b84	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
465	405	Phil	0101000020E61000001812AA40DC720DC0768A107AEB3C4840	3	2017-10-31	\N	3898ab22-f960-43a4-aef3-222db67d38d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
466	406	Phil	0101000020E6100000B18DF238BB720DC05E2E9D32EC3C4840	3	2017-10-31	\N	c362ee3b-7a36-435f-a7ae-32e6689ec89b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
467	407	Phil	0101000020E61000005783AA3D9B720DC01B0BC579ED3C4840	3	2017-10-31	\N	28d2a213-d8a3-42be-8278-0cc307afb5fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
468	408	Phil	0101000020E6100000B23129AA2D720DC0C87CFB96EE3C4840	3	2017-10-31	\N	356e1876-1f61-4a04-8725-89ba7a3a87b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
469	409	Phil	0101000020E610000063A150BB0E720DC02094B268EF3C4840	3	2017-10-31	\N	8076b257-cf11-4e8c-97fa-4febf69697ea	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
470	410	Phil	0101000020E6100000F1A229A7EC710DC04A27CD42F03C4840	3	2017-10-31	\N	ff19db56-b8c2-47bb-853c-872fb1ad36e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
471	411	Phil	0101000020E6100000AACF883ECE710DC0B4A9753EF13C4840	3	2017-10-31	\N	940b1a56-a6cf-42b5-aef5-041704a2fab5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
472	412	Phil	0101000020E61000006F338F68B1710DC0137E6496F23C4840	3	2017-10-31	\N	023d4ad3-7ce3-4415-a2a3-b1c859df129f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
473	413	Phil	0101000020E610000047CE3C2596710DC0D15A8CDDF33C4840	3	2017-10-31	\N	68d728d9-92f6-4cd5-9d8d-cc77f957ab6a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
474	414	Mike	0101000020E61000004484028C178F0DC0DE1654EA0B374840	3	2017-10-31	\N	4382c548-574c-45ae-b324-2ec804fca29b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
475	415	Mike	0101000020E610000084F50289D68E0DC0722C17C00D374840	3	2017-10-31	\N	37606f00-4684-4c3e-b816-152300817f09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
476	416	Mike	0101000020E610000012F7DB74B48E0DC00776242D0E374840	3	2017-10-31	\N	ea5c3ff8-031b-4691-9f55-01bb17d13b38	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
477	417	Mike	0101000020E61000006D53BFA88D8E0DC0DDAEBFBB0E374840	3	2017-10-31	\N	1d4229a3-8a2f-49a8-a532-ec2a41c17858	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
478	418	Mike	0101000020E6100000F697600E6B8E0DC0D7BD3D9E0F374840	3	2017-10-31	\N	77401522-ca18-4b6a-aa87-4f90cd65c28d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
479	419	Mike	0101000020E610000051F44342448E0DC02FD5F46F10374840	3	2017-10-31	\N	9a3f52ab-6c34-449d-8e48-efada210f13b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
480	420	Mike	0101000020E6100000AF5027761D8E0DC0D689F30611374840	3	2017-10-31	\N	a0ccd02a-b887-4179-9b24-8c778e3e5a63	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
481	421	Mike	0101000020E6100000B890CAEA068E0DC0C3EAB74512374840	3	2017-10-31	\N	42d0a974-1da4-4734-8146-e9d5af4ca7f8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
482	422	Mike	0101000020E610000008733E12DF8D0DC0400C9C0212374840	3	2017-10-31	\N	da813f0c-d8af-4b9d-935e-ba0ab543f69d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
483	423	Mike	0101000020E61000007AC3005FBA8D0DC02FA1AAD811374840	3	2017-10-31	\N	4931e127-c340-40bd-8b32-90e92afadb68	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
484	424	Mike	0101000020E6100000868F0BA4748D0DC071C4829110374840	3	2017-10-31	\N	b19d42e6-fe2e-4731-abe1-6f92860548ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
485	425	Mike	0101000020E61000006F6160F35A8D0DC095CEAF7C0F374840	3	2017-10-31	\N	ccf66479-5cc4-4556-8f3b-64893c2577f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
486	426	Mike	0101000020E61000004DB94536408D0DC0258FCFFA0D374840	3	2017-10-31	\N	2dae0532-a86a-42b5-a1e3-acf8faf7c199	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
487	427	Mike	0101000020E61000004E7F799E288D0DC0A8A135D50C374840	3	2017-10-31	\N	de5ddea6-38d1-490e-b095-1e0ce8f2c87c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
488	428	Mike	0101000020E6100000A358F1E3188D0DC01A49AA850B374840	3	2017-10-31	\N	45bf58bb-addb-4d5e-abde-4daac3bb75c3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
489	429	Mike	0101000020E610000042CB3DFA0F8D0DC057AF4AB809374840	3	2017-10-31	\N	c343b2cb-deb9-48dc-9846-ac41a533b4eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
490	430	Mike	0101000020E61000004E0BE16EF98C0DC099D2227108374840	3	2017-10-31	\N	9c2f2048-b24a-4005-9ebb-59846296fbf1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
491	431	Mike	0101000020E61000007391FE349E8C0DC0B853626D05374840	3	2017-10-31	\N	29be62fd-a59a-4eb0-8dd8-0c46eae5376f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
492	432	Mike	0101000020E6100000EE5B308E7A8C0DC0412300CE04374840	3	2017-10-31	\N	e9c7d238-8040-4135-99ee-c96cc5c6c67f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
493	433	Mike	0101000020E610000071E3996D578C0DC03575462A05374840	3	2017-10-31	\N	9dffcfd4-4cb2-4191-820e-66ab0b6b1e97	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
494	434	Mike	0101000020E6100000358A68113A8C0DC041EFB53606374840	3	2017-10-31	\N	4d5a3daf-acc7-482c-8607-f2553fb21ae0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
495	435	Mike	0101000020E61000004C447B92248C0DC06F3F089707374840	3	2017-10-31	\N	592c120e-bea7-4467-b62c-f6764b31a374	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
496	436	Mike	0101000020E61000008EE64B45138C0DC09E8F5AF708374840	3	2017-10-31	\N	32b85e1f-37ea-4cd8-bd89-6e3a6b82f180	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
497	437	Mike	0101000020E6100000301FCCC3F28B0DC07A852D0C0A374840	3	2017-10-31	\N	74de7c7c-c5ce-4902-b842-3fdcb71af007	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
498	438	Mike	0101000020E6100000BC20A5AFD08B0DC0032181D50A374840	3	2017-10-31	\N	4d9c8646-828e-4883-9d7f-6d381ea678b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
499	439	Mike	0101000020E61000002E7167FCAB8B0DC0D39CE4DD0A374840	3	2017-10-31	\N	5e50245c-d06f-4f09-a125-b30b7c7f9fd6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
500	440	Mike	0101000020E6100000A87E61CF878B0DC0AFC6018A0A374840	3	2017-10-31	\N	e0ce8d78-9a11-4c8a-b1c0-cae8a7acecf1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
501	441	Mike	0101000020E610000070340332248B0DC04678A32508374840	3	2017-10-31	\N	bb4faa10-856e-4066-8fa7-f6ad7f1a2345	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
502	442	Mike	0101000020E6100000EBFE348B008B0DC02D1C30DE08374840	3	2017-10-31	\N	03d6b75a-da26-4e4c-b82b-181ff7e3cd64	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
503	443	Mike	0101000020E61000001BAD2625ED8A0DC09FC3A48E07374840	3	2017-10-31	\N	ae626397-3d4b-4f9f-998e-fadcc01f2509	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
504	444	Mike	0101000020E610000091805460B18A0DC029C78C8605374840	3	2017-10-31	\N	95db9354-7237-4ed3-9e1f-63c68e999567	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
505	445	Mike	0101000020E6100000EE16042CA28A0DC0C98A090007374840	3	2017-10-31	\N	8c7f1757-7525-4417-9c45-749c185b6bf9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
506	446	Mike	0101000020E61000008B895042998A0DC0BCA805C508374840	3	2017-10-31	\N	d4e189e3-4d79-4c6b-a529-9b0fcfab94d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
507	447	Mike	0101000020E6100000310B70174A8A0DC033D9676409374840	3	2017-10-31	\N	93bf7ac0-2a11-4a09-8013-6d1cb39b7132	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
508	448	Mike	0101000020E6100000AED5A170268A0DC0FE9793E608374840	3	2017-10-31	\N	f8ff8663-5c46-4334-99c2-d560f4cbaaf1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
509	449	Mike	0101000020E610000092028EDAAD890DC04678A32508374840	3	2017-10-31	\N	d9bceb36-36ac-4796-b198-17618a809a3d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
510	450	Mike	0101000020E6100000E2E4010286890DC0C856BF6808374840	3	2017-10-31	\N	cca43e53-739f-45b8-b8c7-2eeea9d7ede2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
511	451	Mike	0101000020E61000002D0A3EA35D890DC09FC3A48E07374840	3	2017-10-31	\N	3997e02e-1e32-4ccf-b52d-712565fd49ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
512	452	Mike	0101000020E6100000CC42BE213D890DC0889B7BDE06374840	3	2017-10-31	\N	ebb9df5f-5136-4432-9642-8f77ec72f3d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
513	453	Mike	0101000020E610000038D648E817890DC082DE435806374840	3	2017-10-31	\N	6d7c80f2-6c4d-497e-9fe2-aa614d8d10aa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
514	454	Mike	0101000020E6100000BB5DB2C7F4880DC041EFB53606374840	3	2017-10-31	\N	37e2627f-c030-453a-9bf6-b3de1fefc9b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
515	455	Mike	0101000020E610000022340508CF880DC0D66C0D3B05374840	3	2017-10-31	\N	9c1de5b5-f75a-4178-a0d2-7dbc9c922775	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
516	456	Mike	0101000020E6100000834D20C2A8880DC04DD1B97104374840	3	2017-10-31	\N	8cf6a640-914e-4fde-83fc-beade7190eb8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
517	457	Mike	0101000020E6100000F59DE20E84880DC00CE22B5004374840	3	2017-10-31	\N	bd61d2d1-17e2-4ce9-8fad-52cb50f73002	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
518	458	Mike	0101000020E61000003C06E7295B880DC0B3CA747E03374840	3	2017-10-31	\N	9140e0c9-0fd4-46e2-97a9-049ef1ed3dc4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
519	459	Mike	0101000020E610000046D2F16E15880DC02572E92E02374840	3	2017-10-31	\N	8cdcf679-e731-472f-b10a-aa26983408db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
520	460	Mike	0101000020E6100000A32ED5A2EE870DC0F03015B101374840	3	2017-10-31	\N	eda6b02c-015f-49db-9df8-3c79d2f5f877	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
521	461	Mike	0101000020E6100000EB531144C6870DC02B636B4C01374840	3	2017-10-31	\N	6b6c74de-ea43-4bd3-935d-76d8962d897a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
522	462	Mike	0101000020E6100000DB6E05EA7D870DC055F6852602374840	3	2017-10-31	\N	ff902693-7b3c-4b09-b7da-bdf99125c623	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
523	463	Mike	0101000020E6100000AED8E2F032870DC05BE7074401374840	3	2017-10-31	\N	98f45ed5-51a6-4f5e-9bbf-f28c0f889696	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
524	464	Mike	0101000020E610000003788E9E0B870DC07900B31101374840	3	2017-10-31	\N	b330f477-ebc7-4c67-9d72-f0a80686bd1c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
525	465	Mike	0101000020E61000007B858871E7860DC08B6BA43B01374840	3	2017-10-31	\N	c2c7dbf5-e51d-4fd1-9d33-3ee419a2da27	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
526	466	Mike	0101000020E6100000E7181338C2860DC073437B8B00374840	3	2017-10-31	\N	74512cf5-831d-4f8b-aaae-a56e524392e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
527	467	Mike	0101000020E61000002E81175399860DC0F0645F4800374840	3	2017-10-31	\N	ca2b9414-7d58-4b58-8318-1b62cebb67bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
528	468	Mike	0101000020E6100000DCF03E647A860DC068C90B7FFF364840	3	2017-10-31	\N	bf2dd647-a4bb-4406-af40-446f164c0bae	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
529	469	Mike	0101000020E61000004B84C92A55860DC0B5665344FF364840	3	2017-10-31	\N	c8906d05-4a46-468d-8186-6472c11e0c94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
530	470	Mike	0101000020E6100000A4E0AC5E2E860DC07934FDA8FF364840	3	2017-10-31	\N	eff2437b-1401-4a83-81db-e02cecdba577	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
531	471	Mike	0101000020E6100000DDCE416D04860DC0FC1219ECFF364840	3	2017-10-31	\N	4e8feefd-2ac2-4018-8755-f02e033965bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
532	472	Mike	0101000020E61000005B9973C6E0850DC0506D983700374840	3	2017-10-31	\N	d5282adb-64b1-4353-9ff4-cf8d38c2ef05	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
533	473	Mike	0101000020E6100000B0381F74B9850DC0915C265900374840	3	2017-10-31	\N	24d2b29e-62c6-417e-9e74-305a7ea1bf1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
534	474	Mike	0101000020E61000002846194795850DC0EBA727C2FF364840	3	2017-10-31	\N	35ae1de2-984d-4985-9e2f-f389661b14b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
535	475	Mike	0101000020E6100000B38ABAAC72850DC0C7D1446EFF364840	3	2017-10-31	\N	a3fa53be-bb8c-462e-b6f9-20f06e65b61e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
536	476	Mike	0101000020E61000001D1E45734D850DC050A1E2CEFE364840	3	2017-10-31	\N	9142c008-0aa6-47b6-b3ab-7090ff642bcc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
537	477	Mike	0101000020E6100000B9998D6B2C850DC0AAECE337FE364840	3	2017-10-31	\N	6c16bebc-567d-42ba-9fe5-6540a9d24869	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
538	478	Mike	0101000020E61000001AB3A82506850DC02DCBFF7AFE364840	3	2017-10-31	\N	631f2839-b895-4bdc-adfa-d95925eaf9c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
539	479	Mike	0101000020E61000005DE1E0A8C5840DC00A2967BEFC364840	3	2017-10-31	\N	288de0f5-6d5b-4b7c-9d2d-6ad939ebc35b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
540	480	Mike	0101000020E6100000CF31A3F5A0840DC06931A0ADFC364840	3	2017-10-31	\N	cf377fd2-d078-4e3e-97c9-b459842f7db8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
541	481	Mike	0101000020E61000000EA3A3F25F840DC0B702320AFB364840	3	2017-10-31	\N	09c8ef54-7292-4b6c-8f5e-1e963f697fda	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
542	482	Mike	0101000020E610000013260FE148840DC047C35188F9364840	3	2017-10-31	\N	fb07d36b-b4be-41e5-a64b-6b66871bf1b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
543	483	Mike	0101000020E6100000BB1BC7E528840DC0D092EFE8F8364840	3	2017-10-31	\N	1788d9c5-7e90-4648-b18f-8c7ef6ed8de4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
544	484	Mike	0101000020E610000009FE3A0D01840DC0309B28D8F8364840	3	2017-10-31	\N	e4c28111-12d2-421d-88b3-070bcc443237	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
545	485	Mike	0101000020E61000007B4EFD59DC830DC04DB4D3A5F8364840	3	2017-10-31	\N	dab7f07c-8322-46bd-9401-9d100bedec45	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
546	486	Mike	0101000020E6100000E7E18720B7830DC0368CAAF5F7364840	3	2017-10-31	\N	9e9b60c8-ee08-4239-8fca-affd91a0175e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
547	487	Mike	0101000020E6100000A06082F051830DC0B702320AFB364840	3	2017-10-31	\N	b71f68db-7b16-45f7-8399-c13814c70f1d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
548	488	Mike	0101000020E61000008D7B769609830DC0CAA16DCBF9364840	3	2017-10-31	\N	75fcfab7-33fc-47fd-8e2e-9c9718146169	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
549	489	Mike	0101000020E61000004FAEAC0ABD820DC0FA250AC3F9364840	3	2017-10-31	\N	1893de5f-ca0a-42dc-9098-73d44981f6d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
550	490	Mike	0101000020E6100000BB4137D197820DC029AAA6BAF9364840	3	2017-10-31	\N	50aa6a84-a4c1-4205-9cce-bd0f30208224	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
551	491	Mike	0101000020E6100000EF7294596D820DC0C4E43545F9364840	3	2017-10-31	\N	fe5463c1-1382-494b-875b-300472f39369	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
552	492	Mike	0101000020E610000061C356A648820DC01E3037AEF8364840	3	2017-10-31	\N	3a05e1a9-dea9-44ae-ac8b-1883e9062d81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
553	493	Mike	0101000020E610000095464F67D7810DC0073C5895F6364840	3	2017-10-31	\N	3c5383e9-c38f-4381-ac93-dbf70e1ab1d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
554	494	Mike	0101000020E6100000E2BD264168810DC0BF27FEBEF8364840	3	2017-10-31	\N	9f1a74f4-6043-41ba-bcf6-75fac174d455	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
555	495	Mike	0101000020E61000004694798142810DC0BF27FEBEF8364840	3	2017-10-31	\N	d9ad6ede-2565-4aab-b659-7e309aaa0a09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
556	496	Mike	0101000020E6100000B52704481D810DC0C4E43545F9364840	3	2017-10-31	\N	69c3104a-d78b-4824-ae8f-9b471674cd62	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
557	497	Mike	0101000020E610000016411F02F7800DC0DC0C5FF5F9364840	3	2017-10-31	\N	2dd31cc4-f69b-4b24-a87d-d2d329102c22	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
558	498	Mike	0101000020E6100000F4980445DC800DC0DBD8145EFB364840	3	2017-10-31	\N	9913ff0b-57de-47ac-985b-30db0820b028	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
559	499	Mike	0101000020E610000041B54404CC800DC00A2967BEFC364840	3	2017-10-31	\N	afbc7f1b-cd1c-4860-bae9-4a09719c5612	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
560	500	Mike	0101000020E610000025CA61CDB1800DC0E61E3AD3FD364840	3	2017-10-31	\N	1b595c99-bb90-4625-b283-9555a501b0da	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
561	501	Mike	0101000020E6100000B988723F90800DC0EC0FBCF0FC364840	3	2017-10-31	\N	f2141670-374e-4db4-bcaf-d4b162af44de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
562	502	Mike	0101000020E6100000205FC57F6A800DC0CEF61023FD364840	3	2017-10-31	\N	2bc66bb1-287f-4475-b50f-bbddef5b6616	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
563	503	Mike	0101000020E6100000D1CEEC904B800DC0F7892BFDFD364840	3	2017-10-31	\N	588b6e48-d6e9-44d9-bf40-466e9664fc69	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
564	504	Mike	0101000020E610000059138EF628800DC01B600E51FE364840	3	2017-10-31	\N	73eae6e3-3c2d-4963-a67b-fe21392f591f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
565	505	Mike	0101000020E6100000FB4B0E7508800DC0A3FB611AFF364840	3	2017-10-31	\N	0ca9c345-c8d6-44e2-b614-963a9428c66d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
566	506	Mike	0101000020E610000095C7566DE77F0DC07934FDA8FF364840	3	2017-10-31	\N	35b320af-10c6-4dd9-92e5-005056ad3906	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
567	507	Mike	0101000020E6100000CCB5EB7BBD7F0DC026DA7D5DFF364840	3	2017-10-31	\N	7aef56f4-ccbc-4bd6-9338-b4f88fe8ba7c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
568	508	Mike	0101000020E610000090E821F0707F0DC07900B31101374840	3	2017-10-31	\N	2cb34303-d767-4a5e-adba-bb76cd9ea122	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
569	509	Mike	0101000020E6100000BE227B5A2E7F0DC02B2F21B502374840	3	2017-10-31	\N	d730a492-e7ec-4f0b-b0ce-497e2dabf2bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
570	510	Mike	0101000020E610000011C22608077F0DC06070F53203374840	3	2017-10-31	\N	146eb6eb-9568-418b-b03a-a9d8b1330253	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
571	511	Mike	0101000020E610000078987948E17E0DC09CA24BCE02374840	3	2017-10-31	\N	9303ae28-7aa0-45f4-bd9b-9684948fb074	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
572	512	Mike	0101000020E61000000C1DBE22A87E0DC0AD0D3DF802374840	3	2017-10-31	\N	3b76d4d0-3caf-4504-bd00-7d3b3486505c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
573	513	Mike	0101000020E61000008FA42702857E0DC0B3CA747E03374840	3	2017-10-31	\N	bc93c731-7015-478f-be33-7fad266b7954	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
574	514	Mike	0101000020E6100000B29EDDF7587E0DC072DBE65C03374840	3	2017-10-31	\N	d6c88604-e1ca-4052-81d9-c57847f4f610	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
575	515	Mike	0101000020E61000009EFC9917107E0DC00625F4C903374840	3	2017-10-31	\N	ec529ea4-9c5b-429f-befa-5f8886915d1c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
576	516	Mike	0101000020E6100000E621D6B8E77D0DC02AFBD61D04374840	3	2017-10-31	\N	3a5745f5-b7c7-4ed6-836f-4a795e727d24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
577	517	Mike	0101000020E61000006FF2DEEE957D0DC042574A6503374840	3	2017-10-31	\N	6aed17ea-cf10-4df9-a730-13023e4760d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
578	518	Mike	0101000020E6100000E142A13B717D0DC03C9A12DF02374840	3	2017-10-31	\N	440979ff-0ea7-4a52-824d-0fb82932f333	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
579	519	Mike	0101000020E61000007501B2AD4F7D0DC007593E6102374840	3	2017-10-31	\N	f860b5b7-3fc8-41c7-a179-604076119ad1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
580	520	Mike	0101000020E6100000DED704EE297D0DC02572E92E02374840	3	2017-10-31	\N	d1a1da1b-d707-4cff-94a4-ba8a7251024e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
581	521	Mike	0101000020E6100000651CA653077D0DC0019C06DB01374840	3	2017-10-31	\N	a40c1392-680a-4605-9cec-bc17f1466307	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
582	522	Mike	0101000020E61000009290CB55DC7C0DC0FCDECE5401374840	3	2017-10-31	\N	56b35bf9-83fc-4fb9-8a44-d3d9ed0454df	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
583	523	Mike	0101000020E6100000F487E918407C0DC020E9FB3F00374840	3	2017-10-31	\N	14698757-802b-4c23-a1ba-80e962709af9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
584	524	Mike	0101000020E61000001F9172CDCD7B0DC038456F87FF364840	3	2017-10-31	\N	4527efb7-948d-4b8d-bbc5-e41f588b687f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
585	525	Mike	0101000020E6100000E07FAE53957A0DC07B9C91D7FC364840	3	2017-10-31	\N	3bc38b0e-1b89-493a-8382-305792c78bf9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
586	526	Mike	0101000020E6100000FDBC2CC3687A0DC0C839D99CFC364840	3	2017-10-31	\N	d4224a30-06ad-461b-91a0-41bc84228969	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
587	527	Mike	0101000020E6100000F320C0BFF1790DC09FA6BEC2FB364840	3	2017-10-31	\N	3de0d115-51cc-4ab2-9dc9-3c2427dcfe2b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
588	528	Mike	0101000020E610000098A2DF94A2790DC07CD0DB6EFB364840	3	2017-10-31	\N	f625a952-6c05-490f-ad4d-a12ef9ed622a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
589	529	Mike	0101000020E610000074A7F72AE2780DC0D05EA551FA364840	3	2017-10-31	\N	2c7db127-731b-48a3-ac75-131ffc4c7b42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
590	530	Mike	0101000020E6100000C746A3D8BA780DC05FEB7A38FA364840	3	2017-10-31	\N	f2de9df6-541a-4dcd-b013-1d55c8c33a92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
591	531	Mike	0101000020E61000007FBB6F5281770DC0E3312BAAF7364840	3	2017-10-31	\N	6527d83c-84cd-4a12-b814-10ebcba40b3e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
592	532	Mike	0101000020E6100000EF2CFD21E6760DC09CB9AF99F5364840	3	2017-10-31	\N	3caabc10-06dc-451c-9795-8acb42361bba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
593	533	Mike	0101000020E61000001AA12224BB760DC03DB176AAF5364840	3	2017-10-31	\N	1395d37f-356a-4a5f-8435-eb983dfcbedd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
594	534	Mike	0101000020E610000043AAABD848760DC00E61244AF4364840	3	2017-10-31	\N	ea1191cb-c2d3-42f3-9147-ce6645c7873d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
595	535	Mike	0101000020E6100000E89F63DD28760DC086C5D080F3364840	3	2017-10-31	\N	68075f69-534c-4242-ac86-4ca96e91f2c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
596	536	Mike	0101000020E6100000C152E03AAF750DC092738A24F3364840	3	2017-10-31	\N	99f183e0-3d86-4d46-9017-34e02632b4e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
597	537	Mike	0101000020E610000033A3A2878A750DC0DF10D2E9F2364840	3	2017-10-31	\N	cef46789-0af2-4115-8bf0-116e02181e43	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
598	538	Mike	0101000020E6100000A5F364D465750DC01B432885F2364840	3	2017-10-31	\N	3e34bd6b-8d91-49fd-9571-5c7dec02ec2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
599	539	Mike	0101000020E61000006DE3D2CE19750DC01C77721CF1364840	3	2017-10-31	\N	7c4ca3cd-cc80-4a27-ac2c-d9eb5889a6fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
600	540	Mike	0101000020E61000008AE684A6D5740DC02268F439F0364840	3	2017-10-31	\N	403ff35e-08d0-4117-b4dc-7eb6283ab23f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
601	541	Mike	0101000020E6100000FC3647F3B0740DC09F89D8F6EF364840	3	2017-10-31	\N	6d2b67f8-b855-4fc7-85be-47b9e1253e9d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
602	542	Mike	0101000020E6100000B8AC45E163740DC076F6BD1CEF364840	3	2017-10-31	\N	d17bd456-c141-4fff-b91d-d8a7c37e5e59	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
603	543	Mike	0101000020E6100000140929153D740DC0A0BD228EEE364840	3	2017-10-31	\N	a094acec-45c5-4fa5-b3c6-91a5dc6db697	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
604	544	Mike	0101000020E610000069A8D4C215740DC07CE73F3AEE364840	3	2017-10-31	\N	9dd01219-0fe9-4019-8796-5130102786b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
605	545	Mike	0101000020E6100000A853A157EC730DC0AC6BDC31EE364840	3	2017-10-31	\N	2c509e06-abf2-41ae-8afc-b1906d4ed5ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
606	546	Mike	0101000020E610000064C99F459F730DC0C4C74F79ED364840	3	2017-10-31	\N	58c8a449-fab4-43c4-aaac-3882605d644c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
607	547	Mike	0101000020E6100000B4AB136D77730DC0C4C74F79ED364840	3	2017-10-31	\N	67cffd27-779d-4ea8-9090-dfe81d2c7370	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
608	548	Mike	0101000020E61000001D8266AD51730DC0DCEF7829EE364840	3	2017-10-31	\N	a44d5237-6f72-4012-9db0-09e53e03f52b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
609	549	Mike	0101000020E61000008D5E90CAFD720DC0FA0824F7ED364840	3	2017-10-31	\N	8e666b9f-6008-49eb-9335-33ed6a11b179	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
610	550	Mike	0101000020E6100000CC095D5FD4720DC0FA0824F7ED364840	3	2017-10-31	\N	a7ce43bd-8fba-4cf4-bac1-a1f90139dc2d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
611	551	Mike	0101000020E61000002D237819AE720DC0E89D32CDED364840	3	2017-10-31	\N	39f60a4b-9336-458a-83c9-6ca5c10d8ccd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
612	552	Mike	0101000020E610000099B602E088720DC047A66BBCED364840	3	2017-10-31	\N	8f1a778e-9949-43a3-b268-a29a29108b09	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
613	553	Mike	0101000020E6100000CDE75F685E720DC0B81996D5ED364840	3	2017-10-31	\N	4ed256f1-d7cb-4ece-aea6-99c1e84f77a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
614	554	Mike	0101000020E61000003F3822B539720DC01722CFC4ED364840	3	2017-10-31	\N	8e26ffa6-eab2-493b-815f-fce28547e51a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
615	555	Mike	0101000020E61000009A9405E912720DC0C4C74F79ED364840	3	2017-10-31	\N	43860630-3aac-4f2c-87b2-891093223ddc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
616	556	Mike	0101000020E61000000CE5C735EE710DC0F44BEC70ED364840	3	2017-10-31	\N	edeacb17-6807-45e7-b996-d2ee4cfb4655	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
617	557	Mike	0101000020E61000006DFEE2EFC7710DC01722CFC4ED364840	3	2017-10-31	\N	b291ff62-c96d-40f0-af45-c211f9c2b88b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
618	558	Mike	0101000020E6100000A181DBB056710DC0B81996D5ED364840	3	2017-10-31	\N	75286037-6790-4ebd-bc7f-8a24e5205661	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
619	559	Mike	0101000020E61000004C34CB3B37710DC0DC23C3C0EC364840	3	2017-10-31	\N	3fe1ee4d-0fd1-4ef6-9715-c1fff70f8481	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
620	560	Mike	0101000020E61000007A1C896D3B710DC0BA812A04EB364840	3	2017-10-31	\N	b0a5ec25-4085-4548-ba74-c6621b778e46	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
621	561	Mike	0101000020E6100000F95A53F646710DC0A94A8371E9364840	3	2017-10-31	\N	d615eaa0-1c7c-441d-929c-13fc731754eb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
622	562	Mike	0101000020E6100000FC5157145F710DC0CD54B05CE8364840	3	2017-10-31	\N	383bd7d2-544b-4628-9868-d064e31cea56	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
623	563	Mike	0101000020E61000003BAB88707C710DC0FDD84C54E8364840	3	2017-10-31	\N	bed11a0f-ee91-451d-aee9-f80887f2039a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
624	564	Mike	0101000020E610000029AEAD7592710DC08B31D8A3E9364840	3	2017-10-31	\N	ad562fc8-2eff-48fa-992e-9da3d59cdbc8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
625	565	Mike	0101000020E610000092BECC4D84710DC0B4C4F27DEA364840	3	2017-10-31	\N	1409d8a4-8324-4093-a6f6-efbbcb09cf1d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
626	566	Mike	0101000020E61000005F19D7957F710DC0C62FE4A7EA364840	3	2017-10-31	\N	3a0a59ba-9ea0-419c-a4bc-5427eff9aeed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
627	567	Mike	0101000020E6100000BAAF866170710DC0266C672EE9364840	3	2017-10-31	\N	2e851abd-c96f-4ae6-a263-ec0d022641c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
628	568	Mike	0101000020E6100000AC3517556F710DC06D182DD6E9364840	3	2017-10-31	\N	9c1505a5-84c2-4882-875d-407c2b886eb1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
629	569	Mike	0101000020E6100000D9CB394EBA710DC06627ABB8EA364840	3	2017-10-31	\N	b4fa10cf-91a2-4e47-bf11-0a99208087f8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
630	570	Mike	0101000020E61000005C0108F5DD710DC0490E00EBEA364840	3	2017-10-31	\N	670dd90b-753c-49af-88ba-0776cd475421	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
631	571	Mike	0101000020E6100000B8A1E516A3720DC03C604647EB364840	3	2017-10-31	\N	ce86ed0d-62c5-42d9-8007-afbe84ae9ad1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
632	572	Mike	0101000020E61000007139E1FBCB720DC0DD570D58EB364840	3	2017-10-31	\N	4884b3f0-8da8-4ec5-9460-89062520e0ee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
633	573	Mike	0101000020E6100000FFE81EAFF0720DC06CE4E23EEB364840	3	2017-10-31	\N	a5dfc1c6-7665-47e1-adfa-05472df7ce26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
634	574	Mike	0101000020E6100000343C792E3C730DC0FB70B825EB364840	3	2017-10-31	\N	2ed3a691-b138-4a80-a5de-8b3a10e2be87	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
635	575	Mike	0101000020E6100000F94DE41F66730DC02BF5541DEB364840	3	2017-10-31	\N	c195ff09-2978-4fde-91e0-6c2a778fcaef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
636	576	Mike	0101000020E6100000C51C879790730DC0490E00EBEA364840	3	2017-10-31	\N	a0ed8468-bfda-4e6b-bb17-7180f5b4c16b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
637	577	Mike	0101000020E610000081B4827CB9730DC0198A63F3EA364840	3	2017-10-31	\N	b16d8c1d-21bc-4ae3-a62b-c429321d3fd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
638	578	Mike	0101000020E610000047C6ED6DE3730DC08AFD8D0CEB364840	3	2017-10-31	\N	e6fa6ba4-5f85-47a1-a41c-206b706d2203	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
639	579	Mike	0101000020E6100000F7E379460B740DC0FB70B825EB364840	3	2017-10-31	\N	34f2d5f5-0708-48dd-92fc-fd1401278b7d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
640	580	Mike	0101000020E61000009EFB2E4261740DC0D89AD5D1EA364840	3	2017-10-31	\N	6551afd2-645e-420d-a1e4-eeb34223d212	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
641	581	Mike	0101000020E6100000180A5B8929750DC00E10F4E6E9364840	3	2017-10-31	\N	dc9a631a-2fd7-4de3-9ffe-b4a406964cb9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
642	582	Mike	0101000020E610000056D7241576750DC02B299FB4E9364840	3	2017-10-31	\N	8a46b1a0-bb86-47dc-b389-d140c65839e9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
643	583	Mike	0101000020E61000003B9AA6A5A2750DC02B299FB4E9364840	3	2017-10-31	\N	68586a2e-6d02-4876-b2bb-ca5e7d2a80d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
644	584	Mike	0101000020E6100000E3FAFAF7C9750DC09C9CC9CDE9364840	3	2017-10-31	\N	add8f01d-865e-49c2-82bf-76eea5e97e3d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
645	585	Mike	0101000020E61000004079DB2219760DC0DE8B57EFE9364840	3	2017-10-31	\N	f0b015c3-d2e3-46ba-8482-af82a11800f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
646	586	Mike	0101000020E6100000F910D70742760DC0AE07BBF7E9364840	3	2017-10-31	\N	07abb79f-e4c0-482a-86da-7c09f25cfccc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
647	587	Mike	0101000020E610000070CC35A264760DC00E10F4E6E9364840	3	2017-10-31	\N	e1322815-6c81-4075-a914-0bd5c3dcd39e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
648	588	Mike	0101000020E61000006A31FB12DA760DC05BAD3BACE9364840	3	2017-10-31	\N	a6f2d773-64f9-419f-8b7d-da86b0610aaf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
649	589	Mike	0101000020E61000003CBDD51005770DC00E10F4E6E9364840	3	2017-10-31	\N	242d8239-3402-4392-a5dd-bc2f73bdde04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
650	590	Mike	0101000020E6100000E360F2DC2B770DC038D75858E9364840	3	2017-10-31	\N	4df1d337-44a2-4375-8095-9cd38390b422	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
651	591	Mike	0101000020E6100000DB511F1E72770DC038D75858E9364840	3	2017-10-31	\N	2fae3ba8-3704-4295-b76a-93504a27a4cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
652	592	Mike	0101000020E6100000C4D1D8349F770DC055F00326E9364840	3	2017-10-31	\N	caf06aba-fa07-49bb-a765-2e2476e4080a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
653	593	Mike	0101000020E6100000189381D9ED770DC055F00326E9364840	3	2017-10-31	\N	2d225ad4-39da-4a91-b36a-d6fb67c7f9ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
654	594	Mike	0101000020E6100000C2676E5B44780DC097DF9147E9364840	3	2017-10-31	\N	cde1367d-672a-4b2e-a342-6f9dbc359ff7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
655	595	Mike	0101000020E6100000C2896B52BA780DC0029684DAE8364840	3	2017-10-31	\N	45312d89-8ae7-4889-a315-c8aeb01844c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
656	596	Mike	0101000020E6100000BD62C9F25E790DC0A4C19582E7364840	3	2017-10-31	\N	f5a8c288-d87f-48aa-82e7-1755e6bd4e5f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
657	597	Mike	0101000020E6100000827434E488790DC0C1DA4050E7364840	3	2017-10-31	\N	df771147-931c-4bbf-9e2a-3db3e1dfee00	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
658	598	Mike	0101000020E610000045C9674FB2790DC0E5B023A4E7364840	3	2017-10-31	\N	9dba7fb2-ea34-4511-98cc-85f39a776ac8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
659	599	Mike	0101000020E6100000E4AF4C95D8790DC0E5B023A4E7364840	3	2017-10-31	\N	003dcb2b-a7e0-49db-b5fa-c4be1c6fb713	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
660	600	Mike	0101000020E6100000BAF85E19047A0DC0A97ECD08E8364840	3	2017-10-31	\N	b7d5a79c-1e38-45b8-9cb5-59e245ffc568	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
661	601	Mike	0101000020E61000005E9C7BE52A7A0DC0BBE9BE32E8364840	3	2017-10-31	\N	4cfbe981-1980-46c2-90dd-8f957239d335	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
662	602	Mike	0101000020E6100000312856E3557A0DC0098706F8E7364840	3	2017-10-31	\N	d765d0b3-e197-4f02-ac9d-2945e3080506	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
663	603	Mike	0101000020E6100000195674C1C97A0DC0098706F8E7364840	3	2017-10-31	\N	3dbc47b3-85a3-4baa-a47d-a03dc97a4358	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
664	604	Mike	0101000020E610000098CE0AE2EC7A0DC026A0B1C5E7364840	3	2017-10-31	\N	542dd2fd-88b1-41f4-a810-6818865e8f94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
665	605	Mike	0101000020E610000035B5EF27137B0DC0A97ECD08E8364840	3	2017-10-31	\N	9492f04b-ddce-45c1-b440-ed98ce6fb279	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
666	606	Mike	0101000020E6100000DA580CF4397B0DC021E3793FE7364840	3	2017-10-31	\N	a6cd3de7-3c52-43e8-be51-9d54712269f5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
667	607	Mike	0101000020E61000009DAD3F5F637B0DC01535C09BE7364840	3	2017-10-31	\N	ad8d97e2-504c-450e-a7f1-e48776e40c6c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
668	608	Mike	0101000020E61000002E1AB598887B0DC056244EBDE7364840	3	2017-10-31	\N	3a3e9a7b-1459-477c-b03d-8676dbb2e9f1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
669	609	Mike	0101000020E6100000F06EE803B27B0DC04A769419E8364840	3	2017-10-31	\N	7e0e0d5d-37d5-4c02-aff6-641859c57f91	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
670	610	Mike	0101000020E610000058F39F0BD37B0DC05033CC9FE8364840	3	2017-10-31	\N	4ee368e1-a660-451a-a034-5e50d377129b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
671	611	Mike	0101000020E61000008BD2615BEF7B0DC0A4C19582E7364840	3	2017-10-31	\N	6095dae4-68c1-497b-9ede-f60473d5a330	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
672	612	Mike	0101000020E61000004C2795C6187C0DC09256A458E7364840	3	2017-10-31	\N	7bc31625-9de9-4f88-afee-d5f28fc57988	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
673	613	Mike	0101000020E6100000DAD6D2793D7C0DC08C996CD2E6364840	3	2017-10-31	\N	6563d750-dc8a-4e3f-bb02-4886e28bfcd7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
674	614	Mike	0101000020E61000007C7AEF45647C0DC027D4FB5CE6364840	3	2017-10-31	\N	31563565-e89d-4e4f-9ad7-7f7ee0ce1746	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
675	615	Mike	0101000020E610000004E18DA2B77C0DC017D19E61E3364840	3	2017-10-31	\N	fe4f9914-c566-4114-af55-7c08499565ce	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
676	616	Mike	0101000020E61000005FEBD59DD77C0DC02970DA22E2364840	3	2017-10-31	\N	bf7a6891-d3ba-472e-807a-f2652d5ead04	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
677	617	Mike	0101000020E6100000506293D21C7D0DC048BDCF87E0364840	3	2017-10-31	\N	3d5ddcd5-b552-4d6b-9c24-d261c1beed17	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
678	618	Mike	0101000020E61000005FD306FD357D0DC0E9E8E02FDF364840	3	2017-10-31	\N	df40fcc4-a842-4721-8bf8-77be9faa3df8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
679	619	Mike	0101000020E6100000B6201772557D0DC03D77AA12DE364840	3	2017-10-31	\N	3585377a-df25-413d-92fb-987dc7ae74f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
680	620	Mike	0101000020E6100000FA368054737D0DC014E48F38DD364840	3	2017-10-31	\N	7f50fd8f-a4d9-4461-b15e-c6536078c588	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
681	621	Mike	0101000020E61000007AA61A93AE7D0DC06E63DB38DB364840	3	2017-10-31	\N	7d939e2d-4a68-4f27-b057-421316349a41	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
682	622	Mike	0101000020E6100000A40B6DD6C97D0DC075545D56DA364840	3	2017-10-31	\N	a92a0327-2f29-4374-b156-b00a8ffcf553	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
683	623	Mike	0101000020E610000002D3EC57EA7D0DC0995E8A41D9364840	3	2017-10-31	\N	4e008235-c027-45cf-9c16-312f5103acd1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
684	624	Mike	0101000020E61000004B8EBE1F677E0DC0D13B3D85D5364840	3	2017-10-31	\N	2510cc00-601c-476b-be42-7e71dc111468	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
685	625	Mike	0101000020E6100000DFFA33598C7E0DC02A873EEED4364840	3	2017-10-31	\N	b5b01222-89d5-4065-909d-0d008cebb0a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
686	626	Mike	0101000020E6100000ABB10730157F0DC03BBEE580D6364840	3	2017-10-31	\N	5b310c5f-101a-46fd-b59c-ba22fc886e32	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
687	627	Mike	0101000020E6100000396145E3397F0DC04D29D7AAD6364840	3	2017-10-31	\N	d8b3d2f8-b8eb-44f9-a144-04814624a48b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
688	628	Mike	0101000020E61000007DEB46F5867F0DC0E8636635D6364840	3	2017-10-31	\N	f221035d-9e38-4ee5-bc7c-c343148f4c9b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
689	629	Mike	0101000020E61000006B62042ACC7F0DC05F94C8D4D6364840	3	2017-10-31	\N	c8117b0b-fc91-4a88-aac5-cf1b65b0965e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
690	630	Mike	0101000020E61000002CB73795F57F0DC0B2EE4720D7364840	3	2017-10-31	\N	277b14cb-e5a6-4aa1-9868-97c60c58e502	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
691	631	Mike	0101000020E6100000BA6675481A800DC09A92D4D8D7364840	3	2017-10-31	\N	b6cee6be-2c84-4509-894c-4effc99025bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
692	632	Mike	0101000020E610000026A864D63B800DC0CFD3A856D8364840	3	2017-10-31	\N	e8989ba8-b1b6-4c89-8f64-b9e84877d2e4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
693	633	Mike	0101000020E6100000AE9A6A0360800DC07688A7EDD8364840	3	2017-10-31	\N	19bbdfbb-cf6e-4c18-9aac-98e865921483	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
694	634	Mike	0101000020E6100000971A241A8D800DC07688A7EDD8364840	3	2017-10-31	\N	569eb107-3e1b-41b3-88dc-855ca1ae6ac6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
695	635	Mike	0101000020E61000008B4E19D5D2800DC063E96B2CDA364840	3	2017-10-31	\N	00e3f14a-e566-4581-a374-e9903d3ec45a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
696	636	Mike	0101000020E61000002778C694F8800DC0CE9F5EBFD9364840	3	2017-10-31	\N	000d4f4d-7dda-43e4-9591-b9d25a79e9b5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
697	637	Mike	0101000020E61000009676EDA81A810DC028EB5F28D9364840	3	2017-10-31	\N	067030a2-ffa3-4c42-92ce-4f29c8fa9c2f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
698	638	Mike	0101000020E6100000BEDB3FEC35810DC05E607E3DD8364840	3	2017-10-31	\N	b050ff21-1f07-41ca-9818-198c264d4148	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
699	639	Mike	0101000020E6100000EBFDC9B551810DC0F3DDD541D7364840	3	2017-10-31	\N	0b7a5d45-eede-4811-89b5-ab8fbe2d7f15	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
700	640	Mike	0101000020E61000005C7089F9A2810DC0A774D813D6364840	3	2017-10-31	\N	f723665a-c444-473e-817c-cb2ef06b5f1d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
701	641	Mike	0101000020E6100000CE6EB00DC5810DC0EE54E852D5364840	3	2017-10-31	\N	090c2bd6-c86d-47df-b8e3-9410190ddef7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
702	642	Mike	0101000020E6100000B6D69A8350820DC007E5A531D3364840	3	2017-10-31	\N	c9b7ba37-220b-4a7a-9e0b-82ade9be1c85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
703	643	Mike	0101000020E61000003FC9A0B074820DC0A21F35BCD2364840	3	2017-10-31	\N	7759526e-f3fc-4b98-a7d1-884444275808	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
704	644	Mike	0101000020E6100000B884FF4A97820DC0A21F35BCD2364840	3	2017-10-31	\N	03fa79c8-d12b-4bf2-90cd-d54d31da1a0b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
705	645	Mike	0101000020E61000007913FF4DD8820DC0AF0139F7D0364840	3	2017-10-31	\N	933d6d35-6c77-4610-8b7b-2bde6c129aeb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
706	646	Mike	0101000020E6100000DD97B655F9820DC0D9C89D68D0364840	3	2017-10-31	\N	9f661701-1dae-4109-b4a0-737a6787932f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
707	647	Mike	0101000020E6100000E28EBA7311830DC0CE4E2E5CCF364840	3	2017-10-31	\N	a7e3ca85-8196-40c4-81e6-3bda236eca85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
708	648	Mike	0101000020E610000081759FB937830DC021A9ADA7CF364840	3	2017-10-31	\N	97177023-4e3b-41bc-a15e-d718b3a874f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
709	649	Mike	0101000020E610000015E214F35C830DC0BCE33C32CF364840	3	2017-10-31	\N	01d5d0c1-8d0f-4c91-a6ba-5262330ea4d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
710	650	Mike	0101000020E610000070EC5CEE7C830DC0162F3E9BCE364840	3	2017-10-31	\N	7fea8904-6285-4e35-9c02-bf0bf9c91186	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
711	651	Mike	0101000020E6100000EF64F30EA0830DC051619436CE364840	3	2017-10-31	\N	27353bb9-cdcd-4052-8fd9-76fa9afde68f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
712	652	Mike	0101000020E6100000FD49FF68E8830DC069BD077ECD364840	3	2017-10-31	\N	8544f6fa-fca0-4213-8860-b723bf384f8d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
713	653	Mike	0101000020E6100000BE4C979B58840DC0BE7F1BF8CA364840	3	2017-10-31	\N	e6e22987-c5dd-42be-9290-5732d0d87bb6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
714	654	Mike	0101000020E61000000A20380477840DC083810FF4C9364840	3	2017-10-31	\N	c9e2571d-b77d-4314-9fca-673293d8389f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
715	655	Mike	0101000020E61000000D173C228F840DC07807A0E7C8364840	3	2017-10-31	\N	014f15aa-39a3-45aa-9816-7c38d9cabe51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
716	656	Mike	0101000020E6100000C8D034FE2D850DC013767909C7364840	3	2017-10-31	\N	7120ea0e-2198-4167-b8cd-65157766c70f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
717	657	Mike	0101000020E61000004A0603A551850DC0CCC9B361C6364840	3	2017-10-31	\N	d24f10fe-1f36-4fde-b0cd-700f9db98824	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
718	658	Mike	0101000020E61000007DE5C4F46D850DC032C36E6EC5364840	3	2017-10-31	\N	ba4ce150-d8d8-4132-8fa2-f6bd1bd423ca	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
719	659	Mike	0101000020E6100000FA5D5B1591850DC08C0E70D7C4364840	3	2017-10-31	\N	1702207c-8944-4e3c-bcc7-eba1a579a7d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
720	660	Mike	0101000020E61000003EE85C27DE850DC0627B55FDC3364840	3	2017-10-31	\N	e5a59401-f7c5-4a99-8b44-7223ee4dc88b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
721	661	Mike	0101000020E6100000BDD48B7730860DC01BCF8F55C3364840	3	2017-10-31	\N	f745ca32-4356-4174-8744-fa2ab67d994a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
722	662	Mike	0101000020E61000003A4D229853860DC02D3A817FC3364840	3	2017-10-31	\N	1e6ebbc1-5cc8-4133-900f-aa3e4cc00191	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
723	663	Mike	0101000020E6100000A94B49AC75860DC0E68DBBD7C2364840	3	2017-10-31	\N	97a50592-b891-4bd6-9b3c-c18e2edae530	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
724	664	Mike	0101000020E6100000313E4FD999860DC0E68DBBD7C2364840	3	2017-10-31	\N	fec53473-e24c-4298-9795-5c7956ab52fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
725	665	Mike	0101000020E61000003FF28A7DB2860DC092FFF1F4C3364840	3	2017-10-31	\N	2d5a015c-d97a-4d54-ae55-2d81980004a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
726	666	Mike	0101000020E6100000DED86FC3D8860DC0C2838EECC3364840	3	2017-10-31	\N	62dbe880-93ce-426b-b1ee-b18d60136a82	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
727	667	Mike	0101000020E6100000807C8C8FFF860DC015DE0D38C4364840	3	2017-10-31	\N	9cfcc161-1ee9-4af6-a9f1-d046d0d0c7ba	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
728	668	Mike	0101000020E61000001F6371D525870DC0B0189DC2C3364840	3	2017-10-31	\N	0f0e236b-a711-4a1a-91fe-7e2046c835ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
729	669	Mike	0101000020E6100000D53D35344E870DC074E64627C4364840	3	2017-10-31	\N	a121ae1e-ea80-4163-9936-9b6d80e1c718	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
730	670	Mike	0101000020E6100000809E898675870DC033F7B805C4364840	3	2017-10-31	\N	4e66a389-a207-43c5-967c-47a9170cf309	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
731	671	Mike	0101000020E6100000FC1620A798870DC04562AA2FC4364840	3	2017-10-31	\N	995dd5a9-952b-4a7c-a0b7-5d1e2ca19dd8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
732	672	Mike	0101000020E61000009840CD66BE870DC04562AA2FC4364840	3	2017-10-31	\N	78e30062-f19f-442b-9670-ed1cce638b3f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
733	673	Mike	0101000020E6100000620F70DEE8870DC086513851C4364840	3	2017-10-31	\N	a052a6f2-d1d0-4e7d-8010-a9b1fb0c10c6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
734	674	Mike	0101000020E6100000359B4ADC13880DC0D4EE7F16C4364840	3	2017-10-31	\N	b9ef3c21-22ae-41b7-80bd-5f267200293f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
735	675	Mike	0101000020E6100000A69971F035880DC086513851C4364840	3	2017-10-31	\N	a44dbb33-1cb3-4e72-b73a-43a3b8cb1577	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
736	676	Mike	0101000020E610000012DB607E57880DC05C8AD3DFC4364840	3	2017-10-31	\N	08044187-0e7c-4fff-bdef-3c3b98e01899	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
737	677	Mike	0101000020E61000006FE5A87977880DC0023FD276C5364840	3	2017-10-31	\N	912ef144-44a8-41dd-84a6-5fe9fb21819d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
738	678	Mike	0101000020E6100000060F56399D880DC05B568948C6364840	3	2017-10-31	\N	ea5f0891-6ee1-499d-9cf3-a40733720122	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
739	679	Mike	0101000020E61000004A25BF1BBB880DC05565072BC7364840	3	2017-10-31	\N	c9203447-8b38-4562-9b2d-f9f7ff71c0b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
740	680	Mike	0101000020E61000009AB5970ADA880DC04F74850DC8364840	3	2017-10-31	\N	8a19fbea-350a-4864-b63a-918eb5b9d8e6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
741	681	Mike	0101000020E61000004AD323E301890DC0361812C6C8364840	3	2017-10-31	\N	16ca0263-0fbb-4767-88dd-9e42c1e46e4f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
742	682	Mike	0101000020E61000008A6621D736890DC07D908DD6CA364840	3	2017-10-31	\N	88bf9bc5-569c-4699-a072-f46bc665b621	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
743	683	Mike	0101000020E6100000F6A7106558890DC023458C6DCB364840	3	2017-10-31	\N	e4c4ec74-5d63-4e10-9698-71729e19aeac	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
744	684	Mike	0101000020E610000048DD5139D6890DC05DDB0343CF364840	3	2017-10-31	\N	8c3385f6-81c3-4344-8280-68b2f469660a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
745	685	Mike	0101000020E61000004E0E22EF058A0DC0D89453D1D1364840	3	2017-10-31	\N	9475dd47-c0fd-4f07-a73a-956106db2d00	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
746	686	Mike	0101000020E6100000EDF406352C8A0DC06130A79AD2364840	3	2017-10-31	\N	9e637856-30fa-4c15-bb0b-48d9cd6345a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
747	687	Mike	0101000020E610000077E70C62508A0DC02BBB8885D3364840	3	2017-10-31	\N	c2c7219e-82e5-4b1c-af18-9d4d7786e524	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
748	688	Mike	0101000020E6100000B9FD75446E8A0DC0782486B3D4364840	3	2017-10-31	\N	d6d96e0e-46b3-494f-a22b-35bf5cc0986c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
749	689	Mike	0101000020E61000004CA4B715AB8A0DC0826AAB28D7364840	3	2017-10-31	\N	e28e166d-a397-4808-a18a-3f9d9b4caa5c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
750	690	Mike	0101000020E610000019398EF5BD8A0DC0E13E9A80D8364840	3	2017-10-31	\N	258e2525-1ffe-4b71-bb0a-eaae63206a19	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
751	691	Mike	0101000020E61000002A1E9A4F068B0DC09DB32D99DC364840	3	2017-10-31	\N	5a8a8b2e-3d82-4729-acb1-10da063ad92c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
752	692	Mike	0101000020E61000005183EC92218B0DC02C0CB9E8DD364840	3	2017-10-31	\N	db852148-d44c-40b7-bb51-60c9701b484c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
753	693	Mike	0101000020E6100000A313C581408B0DC0F5969AD3DE364840	3	2017-10-31	\N	2b71a7f8-cadd-441e-b4c0-16c976bf1fc7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
754	694	Mike	0101000020E61000001212EC95628B0DC0AEB68A94DF364840	3	2017-10-31	\N	319fc801-4b99-4483-a79b-ac57de9d8e5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
755	695	Mike	0101000020E6100000C22F786E8A8B0DC078416C7FE0364840	3	2017-10-31	\N	3d430fe6-07b9-44d5-b38a-5bff77f079bb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
756	696	Mike	0101000020E610000061165DB4B08B0DC0B930FAA0E0364840	3	2017-10-31	\N	37f5180e-cb47-40b4-b5d7-a8d9d0f5d53e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
757	697	Mike	0101000020E6100000833210A1FA8B0DC06B93B2DBE0364840	3	2017-10-31	\N	192a1081-97f5-44ec-a83f-9cdedd7d9d53	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
758	698	Mike	0101000020E610000033509C79228C0DC06B93B2DBE0364840	3	2017-10-31	\N	49d7679d-0f6d-4c11-a32f-556f2c74fc51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
759	699	Mike	0101000020E6100000BB42A2A6468C0DC0D0582351E1364840	3	2017-10-31	\N	6543d620-f8d4-4c0c-ab48-7a7c05461bed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
760	700	Mike	0101000020E610000049F2DF596B8C0DC04D46BD76E2364840	3	2017-10-31	\N	3e2f49a4-8321-4af2-8449-0fe990885fa1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
761	701	Mike	0101000020E6100000BDF0066E8D8C0DC0E28FCAE3E2364840	3	2017-10-31	\N	be63721f-0009-45e2-8647-775302e7bffb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
762	702	Mike	0101000020E61000000A81DF5CAC8C0DC0C933579CE3364840	3	2017-10-31	\N	4aca4141-177d-4847-b10d-9961ead8e930	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
763	703	Mike	0101000020E6100000BA9E6B35D48C0DC0828791F4E2364840	3	2017-10-31	\N	39c9dff4-0ed2-4040-96f8-49d13b40674a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
764	704	Mike	0101000020E61000006ADEF404728D0DC01DC2207FE2364840	3	2017-10-31	\N	ba6d98b9-4682-48ae-8733-871df29e385a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
765	705	Mike	0101000020E6100000977417FEBC8D0DC03BDBCB4CE2364840	3	2017-10-31	\N	6995536b-1e03-476c-a619-f4a2ddea6549	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
766	706	Mike	0101000020E6100000A1D6B7691C8E0DC0B373C21AE0364840	3	2017-10-31	\N	49525284-77ee-4b21-a849-324eb601e160	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
767	707	Mike	0101000020E6100000F36690583B8E0DC007028CFDDE364840	3	2017-10-31	\N	ce4db0d0-fabf-42a6-bdc1-694a59eb53b1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
768	708	Mike	0101000020E61000006265B76C5D8E0DC0CC0380F9DD364840	3	2017-10-31	\N	ebdc3940-5008-4d96-ad23-4c3318705879	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
769	709	Mike	0101000020E6100000754AC3C6A58E0DC0D9E58334DC364840	3	2017-10-31	\N	82ee087e-9f94-4e96-ae4c-a798174140ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
770	710	Mike	0101000020E61000000C747086CB8E0DC03331859DDB364840	3	2017-10-31	\N	e8a3975e-ee02-4571-b0f0-453e42f0ec0c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
771	711	Bob	0101000020E6100000F361A200E6260DC00F23062378364840	3	2017-10-31	\N	0e031a6b-d2be-4a53-acbc-835b2f26c0de	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
772	712	Bob	0101000020E610000020F8C4F930270DC0F23DA5EC76364840	3	2017-10-31	\N	e43fc2d0-1657-497c-84b5-5a65c4b1f9c2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
773	713	Bob	0101000020E61000008C39B48752270DC08D78347776364840	3	2017-10-31	\N	dad72e28-8665-458e-90c0-04093f4c86e8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
774	714	Bob	0101000020E6100000DBC98C7671270DC004DDE0AD75364840	3	2017-10-31	\N	a089bc95-e12b-4255-a1d7-07fa5467c435	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
775	715	Bob	0101000020E61000005EFF5A1D95270DC07093D34075364840	3	2017-10-31	\N	e653a4b7-8c0e-4ff4-9242-4cd261960cb7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
776	716	Bob	0101000020E61000007A5ED683DE270DC0CF9B0C3075364840	3	2017-10-31	\N	62bb4900-c86f-42ba-b7f0-3a09ce9bf8d3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
777	717	Bob	0101000020E6100000299E5F537C280DC0654DAECB72364840	3	2017-10-31	\N	f83304fb-faac-4472-a6d3-8d02a0444c4b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
778	718	Bob	0101000020E6100000FB6306E9BE280DC01327791771364840	3	2017-10-31	\N	a1a190e2-398f-483e-9fd5-b55639a2737f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
779	719	Bob	0101000020E6100000AB2FF7882D290DC0AE9552396F364840	3	2017-10-31	\N	419e7da9-6d17-4130-af0a-7b6ca166aa61	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
780	720	Bob	0101000020E6100000EF45606B4B290DC0203DC7E96D364840	3	2017-10-31	\N	2b0f5e22-d2a9-4f9b-82c2-cebd1f3ae672	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
781	721	Bob	0101000020E6100000449370E06A290DC0B6BA1EEE6C364840	3	2017-10-31	\N	01f7b66a-2387-44ef-a3d9-084edda76e26	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
782	722	Bob	0101000020E6100000D8FFE51990290DC0B0FDE6676C364840	3	2017-10-31	\N	44cd1342-3251-430b-8646-9005641f0560	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
783	723	Bob	0101000020E6100000E3EDED55C0290DC039CD84C86B364840	3	2017-10-31	\N	9de9cc8a-1938-4b42-8c54-34b9fed5bf36	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
784	724	Bob	0101000020E61000004F2FDDE3E1290DC069856B576A364840	3	2017-10-31	\N	92fc5410-d88a-44da-8fb5-0d517dff47a9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
785	725	Bob	0101000020E6100000F98F3136092A0DC022D9A5AF69364840	3	2017-10-31	\N	01d0223a-7846-4eae-9a64-cc38102b6198	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
786	726	Bob	0101000020E6100000E892563B1F2A0DC0D66FA88168364840	3	2017-10-31	\N	53523cca-1843-4410-a1b0-f56ef60741cf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
787	727	Bob	0101000020E610000059917D4F412A0DC09B719C7D67364840	3	2017-10-31	\N	69437152-9489-4c96-965c-6922e12646b6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
788	728	Bob	0101000020E6100000A921563E602A0DC06C214A1D66364840	3	2017-10-31	\N	47bbbe4c-2aa4-4a83-8c88-3150615211a7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
789	729	Bob	0101000020E6100000CA3D092BAA2A0DC050A47D1562364840	3	2017-10-31	\N	89fdb28c-920a-4618-a914-4f5043fe6d5a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
790	730	Bob	0101000020E6100000AEC6BE23BF2A0DC092C755CE60364840	3	2017-10-31	\N	c3eed303-6cda-48a4-af35-0fc5f38cce81	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
791	731	Bob	0101000020E6100000CAB1A15AD92A0DC0874DE6C15F364840	3	2017-10-31	\N	9d7b59ce-0d47-44f5-a434-2df6d743417b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
792	732	Bob	0101000020E61000008B06D5C5022B0DC0FEB192F85E364840	3	2017-10-31	\N	ecc76296-9762-482c-833e-8ba091be16e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
793	733	Bob	0101000020E6100000C95F0622202B0DC076163F2F5E364840	3	2017-10-31	\N	13877211-2993-4d99-b056-0a861f375aaf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
794	734	Bob	0101000020E6100000EB0721DF3A2B0DC03B18332B5D364840	3	2017-10-31	\N	1cc2e19e-b1e6-488f-b9ab-4c1bdd5215f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
795	735	Bob	0101000020E610000024A41AB5572B0DC02F9EC31E5C364840	3	2017-10-31	\N	5ee27bda-416a-46de-b7e5-6babd2bbb648	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
796	736	Bob	0101000020E61000009B5F794F7A2B0DC0242454125B364840	3	2017-10-31	\N	359d2a1b-4be9-4705-975e-42b5afb9a19d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
797	737	Bob	0101000020E6100000BD07940C952B0DC0B9A1AB165A364840	3	2017-10-31	\N	4331d2d8-49d6-4cb8-9b78-baa6dc8d585d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
798	738	Bob	0101000020E6100000B7328DE5F22B0DC0DEDF229957364840	3	2017-10-31	\N	e6ec195f-3efb-47d0-ae7b-3d33d1d51860	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
799	739	Bob	0101000020E61000006193E1371A2C0DC0F63B96E056364840	3	2017-10-31	\N	b5ccc384-7e19-44ff-8fc0-49acd1a97718	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
800	740	Bob	0101000020E61000001D2BDD1C432C0DC06EA0421756364840	3	2017-10-31	\N	71ac73bb-18f7-41c1-9f37-49f7d2c0906d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
801	741	Bob	0101000020E6100000896CCCAA642C0DC086FCB55E55364840	3	2017-10-31	\N	5e10b6db-6b7b-4d40-beb8-fb7e7e6dc9d5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
802	742	Bob	0101000020E6100000398A58838C2C0DC03993B83054364840	3	2017-10-31	\N	6bf45637-5dd0-4f0b-9d39-9c81a9150175	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
803	743	Bob	0101000020E61000009494A07EAC2C0DC08173C86F53364840	3	2017-10-31	\N	9620e93b-b898-43d2-b8dd-4e9f42a6558c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
804	744	Bob	0101000020E61000000593C792CE2C0DC07BB690E952364840	3	2017-10-31	\N	b4e17150-58aa-4444-b909-540e0d091502	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
805	745	Bob	0101000020E61000000A3830782D2D0DC0E2E3958D50364840	3	2017-10-31	\N	549ceb2d-0c49-403c-a440-af8f918a0646	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
806	746	Bob	0101000020E61000005AC808674C2D0DC0FA3F09D54F364840	3	2017-10-31	\N	10a4625f-829b-423b-bf20-6d8631a555b9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
807	747	Bob	0101000020E61000001ACBA099BC2D0DC00165D5894D364840	3	2017-10-31	\N	648954c4-cb0a-4510-88a2-7e41508866f0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
808	748	Bob	0101000020E6100000B9B185DFE22D0DC0D8D1BAAF4C364840	3	2017-10-31	\N	3cd9cffa-7699-4fb3-8551-13bfa29ad229	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
809	749	Bob	0101000020E610000058986A25092E0DC020B2CAEE4B364840	3	2017-10-31	\N	49cc6690-17df-410e-9f8d-d23c3795ae8a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
810	750	Bob	0101000020E61000001FAAD516332E0DC0FCDBE79A4B364840	3	2017-10-31	\N	b534aa23-a018-45ae-b1db-00a775b1d824	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
811	751	Bob	0101000020E61000006EAE4635812E0DC0D9394FDE49364840	3	2017-10-31	\N	032c782b-29b8-4487-8c1c-301d3c803d46	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
812	752	Bob	0101000020E61000003B7DE9ACAB2E0DC03F330AEB48364840	3	2017-10-31	\N	13964b68-c733-45a6-b3eb-28e1788adb99	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
813	753	Bob	0101000020E61000002F7712D0D92E0DC075A8280048364840	3	2017-10-31	\N	6ec862b4-5acb-48a5-8247-5e90210df0d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
814	754	Bob	0101000020E61000006787A4D5252F0DC0B7CB00B946364840	3	2017-10-31	\N	4e409d43-707a-4739-a087-d3579fee0d6a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
815	755	Bob	0101000020E6100000D985CBE9472F0DC0409B9E1946364840	3	2017-10-31	\N	c2373b50-a08e-41b4-80b9-f6b610edabdb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
816	756	Bob	0101000020E610000050412A846A2F0DC065A5CB0445364840	3	2017-10-31	\N	aa718116-a4e9-49b3-b162-ac21eca8d686	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
817	757	Bob	0101000020E6100000443B53A7982F0DC0A0D721A044364840	3	2017-10-31	\N	c649df0f-8bf3-4b5f-9de7-ffdcf3cd817b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
818	758	Bob	0101000020E6100000933FC4C5E62F0DC0127F965043364840	3	2017-10-31	\N	f83889f3-a6aa-4534-934d-9d70152c6b6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
819	759	Bob	0101000020E61000004FD7BFAA0F300DC07E3589E342364840	3	2017-10-31	\N	77c0245b-c5f5-48a2-96bb-54ff4d0b7adb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
820	760	Bob	0101000020E610000021639AA83A300DC08AE3428742364840	3	2017-10-31	\N	883d7233-9acb-4449-a05b-a5c45e6f24c8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
821	761	Bob	0101000020E6100000C606B77461300DC0B4AAA7F841364840	3	2017-10-31	\N	a269f563-e016-46b3-881c-053e1d6b81be	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
822	762	Bob	0101000020E61000006BAAD34088300DC043377DDF41364840	3	2017-10-31	\N	ddb85100-fea0-469d-b968-7ae2a4286b3f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
823	763	Bob	0101000020E61000002CFF06ACB1300DC013B3E0E741364840	3	2017-10-31	\N	bac00d42-f76e-4b45-b031-0366ae078a02	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
824	764	Bob	0101000020E610000003BCB15F0C310DC03D7A455941364840	3	2017-10-31	\N	1002b160-91af-4831-9a10-d5117369a291	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
825	765	Bob	0101000020E61000001389EE18B3310DC04F19811A40364840	3	2017-10-31	\N	8dc0b846-833a-4f29-ab77-621fd8be0fbc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
826	766	Bob	0101000020E61000004B81B17D5D320DC07423AE053F364840	3	2017-10-31	\N	65dfc2bc-ce0f-4f3f-9119-d6d1b8810113	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
827	767	Bob	0101000020E610000050B281338D320DC0923C59D33E364840	3	2017-10-31	\N	90f5ba3c-b435-4cf4-8f1a-77518e2c3f44	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
828	768	Bob	0101000020E61000001107B59EB6320DC0BC03BE443E364840	3	2017-10-31	\N	01ef1c77-5504-4679-986a-0380261c7e79	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
829	769	Bob	0101000020E6100000CC4C154B26330DC0C1C0F5CA3E364840	3	2017-10-31	\N	dc4ad542-cd95-4498-9320-d1cfe8306cee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
830	770	Bob	0101000020E61000005AFC52FE4A330DC0858E9F2F3F364840	3	2017-10-31	\N	af5e8f3a-1879-4acc-bca1-0f94f967030c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
831	771	Bob	0101000020E610000021BC22B7BB330DC0F278DC593D364840	3	2017-10-31	\N	749876b0-7c71-480b-8abc-0fa1e99143bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
832	772	Bob	0101000020E610000020F6EE4ED3330DC0CD6EAF6E3E364840	3	2017-10-31	\N	4aa9f433-8477-472d-977d-9393d39fd9a1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
833	773	Bob	0101000020E61000007086C73DF2330DC07457F89C3D364840	3	2017-10-31	\N	866e0a5a-ff2e-43fa-84cc-1d459b155437	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
834	774	Bob	0101000020E6100000E1F8868143340DC087F6335E3C364840	3	2017-10-31	\N	92977581-7039-499c-8cb9-695212f1e0d7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
835	775	Bob	0101000020E610000030FDF79F91340DC05D2FCFEC3C364840	3	2017-10-31	\N	26c58ffa-459f-44ba-b097-a8f89db0ef79	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
836	776	Bob	0101000020E6100000C926A55FB7340DC00F9287273D364840	3	2017-10-31	\N	f176706b-545c-46af-a5a2-09d0a7a6c9f7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
837	777	Bob	0101000020E6100000469F3B80DA340DC0E00DEB2F3D364840	3	2017-10-31	\N	fe85706b-9055-4081-ba8f-fc2da7befd6b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
838	778	Bob	0101000020E610000067518493C9350DC021FD78513D364840	3	2017-10-31	\N	183278ef-05ff-4b14-8ee3-5067ced2ccee	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
839	779	Bob	0101000020E61000006C825449F9350DC06F9AC0163D364840	3	2017-10-31	\N	fa0f782d-ab2d-4960-820a-733a46c3f9db	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
840	780	Bob	0101000020E61000001CA0E02121360DC0F8695E773C364840	3	2017-10-31	\N	267fd7ca-ff47-4163-9170-d759588b310a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
841	781	Bob	0101000020E6100000B6C98DE146360DC00AD54FA13C364840	3	2017-10-31	\N	5bd63c2c-9171-46b8-a987-81c67ee1d024	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
842	782	Bob	0101000020E610000055B072276D360DC0AACC16B23C364840	3	2017-10-31	\N	b15b65ea-d3c8-4b0d-a0af-a39b54f4bcf5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
843	783	Bob	0101000020E610000010486E0C96360DC03959EC983C364840	3	2017-10-31	\N	012fce47-fc19-4499-b23a-5fc12869cfd9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
844	784	Bob	0101000020E61000003743567656370DC0573E4DCF3D364840	3	2017-10-31	\N	e278a88b-9ee9-42ce-aab6-2a2197ba5c29	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
845	785	Bob	0101000020E6100000A284450478370DC06F9AC0163D364840	3	2017-10-31	\N	885d21cc-56c4-4fdc-8f41-99e0cd0e2deb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
846	786	Bob	0101000020E610000075102002A3370DC02DAB32F53C364840	3	2017-10-31	\N	6d5e5345-3700-4870-a8c2-2d72712138cb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
847	787	Bob	0101000020E610000068B8ADEC17380DC02231C3E83B364840	3	2017-10-31	\N	da5920dc-a70c-472c-82f4-5e3212a68f08	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
848	788	Bob	0101000020E610000046BEF7F643380DC010C6D1BE3B364840	3	2017-10-31	\N	97790ab5-2795-4e8c-ba40-37670dd1dbe2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
849	789	Bob	0101000020E6100000BD79569166380DC0404A6EB63B364840	3	2017-10-31	\N	857558e5-1589-48cb-87ec-cecfefb4b34b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
850	790	Bob	0101000020E61000007ECE89FC8F380DC052B55FE03B364840	3	2017-10-31	\N	c8988bc8-6a2b-4ed9-a3ef-e6db12426c68	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
851	791	Bob	0101000020E6100000CE5E62EBAE380DC03959EC983C364840	3	2017-10-31	\N	b1416ab4-b7e1-4809-8724-58141dbb8ace	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
852	792	Bob	0101000020E610000061CBD724D4380DC00AD54FA13C364840	3	2017-10-31	\N	e461723e-e7fe-4d99-aa9c-d8982295ffc3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
853	793	Bob	0101000020E6100000A6E14007F2380DC02231C3E83B364840	3	2017-10-31	\N	65ac3ece-3a64-4085-9729-3875a21745d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
854	794	Bob	0101000020E610000017E0671B14390DC0E732B7E43A364840	3	2017-10-31	\N	ea64e94c-f00e-43c1-98d5-2b3c8ddf844c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
855	795	Bob	0101000020E6100000FAA2E9AB40390DC052E9A9773A364840	3	2017-10-31	\N	fa786f75-75fa-4f5a-9018-8bc665862d8e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
856	796	Bob	0101000020E6100000E244A0B9E3390DC094D837993A364840	3	2017-10-31	\N	660f5990-37b6-46ec-8211-4e2d511ee21f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
857	797	Bob	0101000020E6100000A9560BAB0D3A0DC02F13C7233A364840	3	2017-10-31	\N	0dd4d9ab-efdd-41cd-a689-9252e9da398c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
858	798	Bob	0101000020E61000005F31CF09363A0DC02F13C7233A364840	3	2017-10-31	\N	4326ba68-be3d-4223-ac67-5189d21a8db1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
859	799	Bob	0101000020E610000091F8C1B8B03A0DC0885EC88C39364840	3	2017-10-31	\N	c42d1ee5-ec0e-4817-8905-b62376c2f5d0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
860	800	Bob	0101000020E6100000F1A772992F3B0DC0BED3E6A138364840	3	2017-10-31	\N	be110a0c-0b36-434a-b682-fe366a63e4bd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
861	801	Bob	0101000020E6100000292C9DCEAA3B0DC0590E762C38364840	3	2017-10-31	\N	2391e002-7f8c-4665-99bf-cf10e3442365	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
862	802	Bob	0101000020E6100000B7DBDA81CF3B0DC00C712E6738364840	3	2017-10-31	\N	07e29aad-1dbc-4f5a-9c22-af4c141549ad	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
863	803	Bob	0101000020E61000004B4850BBF43B0DC0EE57839938364840	3	2017-10-31	\N	258599bf-c509-4766-8bef-8e7f97341f0a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
864	804	Bob	0101000020E6100000CDF1B691473C0DC0AC34ABE039364840	3	2017-10-31	\N	036a4339-d025-40dc-b4eb-0bcaa881a68a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
865	805	Bob	0101000020E6100000EF0D6A7E913C0DC0940C823039364840	3	2017-10-31	\N	44e7ce6c-c4f8-4e1c-ad48-c332bcd6a0c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
866	806	Bob	0101000020E61000003855A316DF3C0DC01EDC1F9138364840	3	2017-10-31	\N	7d635479-1df6-4bc7-99f3-8353c25fc59d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
867	807	Bob	0101000020E6100000A40A2BD42F3D0DC066BC2FD037364840	3	2017-10-31	\N	f7d28153-f87c-4ad6-af4d-1c708000091e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
868	808	Bob	0101000020E6100000A3B88F9B763D0DC01262B08437364840	3	2017-10-31	\N	3918a77d-6474-47d0-9333-f85223b0d948	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
869	809	Bob	0101000020E61000002BAB95C89A3D0DC03CF5CA5E38364840	3	2017-10-31	\N	847b8673-fc76-4e9d-a871-e0eb736a863a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
870	810	Bob	0101000020E6100000AEE0636FBE3D0DC0531DF40E39364840	3	2017-10-31	\N	f5c24889-0d32-4668-bc1e-0dd9ce715461	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
871	811	Bob	0101000020E6100000BFC56FC9063E0DC03504494139364840	3	2017-10-31	\N	c8450474-dd4c-4d15-9267-ef38a7392b89	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
872	812	Bob	0101000020E61000006926C41B2E3E0DC0A677735A39364840	3	2017-10-31	\N	9055dbe5-d7a1-4d80-984f-fb323de6c712	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
873	813	Bob	0101000020E6100000EC5B92C2513E0DC0C4901E2839364840	3	2017-10-31	\N	c31e13e0-0c24-48c7-867e-25f59fc7e95f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
874	814	Bob	0101000020E610000001946BC93F3F0DC02F13C7233A364840	3	2017-10-31	\N	7898785c-d618-42ee-a85f-65d56f67f22f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
875	815	Bob	0101000020E61000008F43A97C643F0DC0282245063B364840	3	2017-10-31	\N	928a6b51-9bff-4b6e-abac-b0adea0169d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
876	816	Bob	0101000020E610000039A4FDCE8B3F0DC09F52A7A53B364840	3	2017-10-31	\N	2b80c0a3-bfad-4cfd-974e-ec60c14ffe1e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
877	817	Bob	0101000020E610000017AA47D9B73F0DC0EDEFEE6A3B364840	3	2017-10-31	\N	ca7a5bb6-a21f-4bb9-8253-e093d9bdae06	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
878	818	Bob	0101000020E61000006CF7574ED73F0DC0349CB4123C364840	3	2017-10-31	\N	7344e1fe-6140-4dc9-87a5-e125578027c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
879	819	Bob	0101000020E6100000FAA69501FC3F0DC0D4937B233C364840	3	2017-10-31	\N	cb50ded5-13ce-4f63-a0d3-bccbe14c3851	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
880	820	Bob	0101000020E6100000AAC421DA23400DC087F6335E3C364840	3	2017-10-31	\N	8e98dd40-edc3-45f0-acbd-c3986b15eb7d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
881	821	Bob	0101000020E61000004EDCD6D579400DC052B55FE03B364840	3	2017-10-31	\N	bc2dc1f0-7164-4a37-b31e-6ad27f9a27f6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
882	822	Bob	0101000020E6100000F2DBBC302E410DC071369FDC38364840	3	2017-10-31	\N	7e788ead-707f-4542-9ef7-fe2b2dd3bc02	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
883	823	Bob	0101000020E610000075118BD751410DC0EE57839938364840	3	2017-10-31	\N	a0e27c8f-7536-4a8f-9f98-e3c22b4ecbec	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
884	824	Bob	0101000020E6100000F746597E75410DC01262B08437364840	3	2017-10-31	\N	00863468-4eab-4725-a71f-bbb2030306ab	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
885	825	Bob	0101000020E6100000082C65D8BD410DC090B7DED835364840	3	2017-10-31	\N	bcb75c3a-0ad9-4d19-acb8-2ed0fa331eef	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
886	826	Bob	0101000020E6100000E5F7E24AD2410DC0A3561A9A34364840	3	2017-10-31	\N	e9b48763-96d6-41bc-a5bd-17a4b701e624	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
887	827	Bob	0101000020E6100000C9809843E7410DC0E579F25233364840	3	2017-10-31	\N	1770f2cb-fa72-4d06-b951-029f28a95c94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
888	828	Bob	0101000020E6100000DAF10B6E00420DC0E6E1868130364840	3	2017-10-31	\N	04a3b5bd-735e-4758-a066-290d15816d85	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
889	829	Bob	0101000020E6100000F6DCEEA41A420DC0880D98292F364840	3	2017-10-31	\N	68f2cdaa-6ccf-45c8-9f41-7fa64714e256	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
890	830	Bob	0101000020E6100000848C2C583F420DC05E7A7D4F2E364840	3	2017-10-31	\N	c725c20f-ce8b-4940-b37b-1d4a09f7884e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
891	831	Bob	0101000020E61000003F24283D68420DC08841E2C02D364840	3	2017-10-31	\N	0d247924-d9ba-4392-b631-60fd67342972	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
892	832	Bob	0101000020E6100000CD0D3288A4420DC0E87D65472C364840	3	2017-10-31	\N	5facda5e-9278-4f32-a6e4-ea30344e6723	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
893	833	Bob	0101000020E61000009F990C86CF420DC0F52B1FEB2B364840	3	2017-10-31	\N	9ca6b645-98fa-445e-9f50-6b4d3830a328	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
894	834	Bob	0101000020E610000066AB7777F9420DC0EF6EE7642B364840	3	2017-10-31	\N	75d8d55b-3481-47cb-8bc9-9342118f8737	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
895	835	Bob	0101000020E6100000924BC8C618440DC0CE682D6E25364840	3	2017-10-31	\N	60b99bc6-7b41-4750-9e58-2af9bed12f88	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
896	836	Bob	0101000020E610000025B83D003E440DC0DA16E71125364840	3	2017-10-31	\N	7a26ec71-40ef-4d7a-8e1e-8ebb6402d821	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
897	837	Bob	0101000020E6100000F286E07768440DC004DE4B8324364840	3	2017-10-31	\N	846bcc77-1bb6-489f-af86-4de63c4c6aa0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
898	838	Bob	0101000020E610000069423F128B440DC081FF2F4024364840	3	2017-10-31	\N	6481aeca-254e-451e-a606-d81ea945311e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
899	839	Bob	0101000020E61000004C05C1A2B7440DC0BD3186DB23364840	3	2017-10-31	\N	aea1ff28-2d9b-474e-a827-caa7ff739b6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
900	840	Bob	0101000020E610000057A12DA62E450DC0E13BB3C622364840	3	2017-10-31	\N	820c07dc-bb99-4ab4-a552-43fd9a9309e3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
901	841	Bob	0101000020E6100000B2AB75A14E450DC09A8FED1E22364840	3	2017-10-31	\N	cd25a77c-022c-427c-afd5-a460d70e8f77	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
902	842	Bob	0101000020E6100000FB7E160A6D450DC0E26FFD5D21364840	3	2017-10-31	\N	97678a6d-1c1e-4886-b659-79c70ddf617b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
903	843	Bob	0101000020E610000094562891D9450DC09049C8A91F364840	3	2017-10-31	\N	6d36cd97-896e-4d02-96e0-f85a229b092d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
904	844	Bob	0101000020E610000022066644FE450DC0CB7B1E451F364840	3	2017-10-31	\N	24ca8db7-b4bc-44a6-abaa-d7e0134c3dcd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
905	845	Bob	0101000020E6100000EFD408BC28460DC02B8457341F364840	3	2017-10-31	\N	aba4f6e1-cfd3-4968-a6a8-5102b77572cd	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
906	846	Bob	0101000020E6100000D2D156E46C460DC0FC3305D41D364840	3	2017-10-31	\N	3c9fe853-404d-4e75-ba53-e779531af7f4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
907	847	Bob	0101000020E61000005407258B90460DC08503A3341D364840	3	2017-10-31	\N	22a02944-5465-4144-a2ed-f4fd79f13a28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
908	848	Bob	0101000020E6100000875A7F0ADC460DC050C2CEB61C364840	3	2017-10-31	\N	009e356a-158d-42f5-82fc-8d9eb1ea3d3c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
909	849	Bob	0101000020E6100000150ABDBD00470DC098A2DEF51B364840	3	2017-10-31	\N	da30c637-a8ac-4320-ae7d-371954af25e7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
910	850	Bob	0101000020E61000009D705B1A54470DC0AA411AB71A364840	3	2017-10-31	\N	e64f5227-9694-4749-9c9a-e3e4346d7dc4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
911	851	Bob	0101000020E6100000421478E67A470DC0A484E2301A364840	3	2017-10-31	\N	6bb0932d-2950-47f6-93db-60db05d864ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
912	852	Bob	0101000020E610000003A377E9BB470DC02E88CA2818364840	3	2017-10-31	\N	89925391-6925-4b7b-866b-9f1537171717	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
913	853	Bob	0101000020E6100000AD03CC3BE3470DC029CB92A217364840	3	2017-10-31	\N	bcb22fb6-97f0-429d-a378-c04f61629571	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
914	854	Bob	0101000020E61000005D2158140B480DC01D51239616364840	3	2017-10-31	\N	c87d90a5-8fe1-4cfa-87dc-1a261a0cd121	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
915	855	Bob	0101000020E6100000B26E68892A480DC0A163897015364840	3	2017-10-31	\N	7aa55fd4-5617-4f99-a042-de54e4af30a5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
916	856	Bob	0101000020E6100000246D8F9D4C480DC09BA651EA14364840	3	2017-10-31	\N	f16ed186-8ea2-466f-9674-91ff3dbae2d4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
917	857	Bob	0101000020E610000034C63327C4480DC0FD4A699F10364840	3	2017-10-31	\N	e354d354-6024-4007-a11e-1eb4120ac274	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
918	858	Bob	0101000020E610000061E8BDF0DF480DC0F1D0F9920F364840	3	2017-10-31	\N	0c1f4105-c0bb-4553-96a7-e3c7a8511c5e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
919	859	Bob	0101000020E6100000C86C75F800490DC06F2628E70D364840	3	2017-10-31	\N	e70c8365-f75b-4fad-a50f-f5839b55a5bf	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
920	860	Bob	0101000020E6100000286EC11139490DC09A21D7EF0B364840	3	2017-10-31	\N	8a16f90c-1d3b-41f8-bc04-ced01f95d251	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
921	861	Bob	0101000020E610000011B4AE904E490DC03B4DE8970A364840	3	2017-10-31	\N	e3b6d100-f80f-4cf9-85cb-c610570e0681	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
922	862	Bob	0101000020E610000055CA17736C490DC0B3B194CE09364840	3	2017-10-31	\N	2596768b-02c3-4fb7-8ff4-d608f28de46a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
923	863	Bob	0101000020E61000004972A55DE1490DC0258D531607364840	3	2017-10-31	\N	e61ae460-6554-43b6-ba73-48cf4d9e8e51	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
924	864	Bob	0101000020E610000026EC87973C4A0DC03994230603364840	3	2017-10-31	\N	71b8fd85-ae4e-4ac8-b604-6ffbbb54ebb4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
925	865	Bob	0101000020E6100000032C9E39804A0DC01DE30C6700364840	3	2017-10-31	\N	ac095b5e-5425-4946-aafb-219b795a6177	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
926	866	Bob	0101000020E6100000EC59BC17F44A0DC0BAB97AB7FB354840	3	2017-10-31	\N	ba83f24f-4e3d-4e83-b066-284e5c5c5e4a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
927	867	Bob	0101000020E61000006F8F8ABE174B0DC0A2915107FB354840	3	2017-10-31	\N	f03684ab-8ea2-46cc-aa41-439053e07505	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
928	868	Bob	0101000020E61000007A7D92FA474B0DC0A4F9E535F8354840	3	2017-10-31	\N	c95a9ba8-ba92-426a-a917-08102149f600	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
929	869	Bob	0101000020E61000002F1E8AC1584B0DC0A52D30CDF6354840	3	2017-10-31	\N	5198ad66-d16f-41be-8cbe-a6f7130e40f8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
930	870	Bob	0101000020E6100000FCB260A16B4B0DC0E7500886F5354840	3	2017-10-31	\N	67e06c1d-dce2-4bd3-86b6-c9a3547ae6b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
931	871	Bob	0101000020E6100000BD7B2C3CC44B0DC0E8B89CB4F2354840	3	2017-10-31	\N	0e0f7bd0-861b-4656-bcac-88561b10df8c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
932	872	Bob	0101000020E6100000D4A9D7ECDD4B0DC0DD3E2DA8F1354840	3	2017-10-31	\N	7c0e2e5b-530f-482d-99ca-92c882f742fe	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
933	873	Bob	0101000020E6100000F551F2A9F84B0DC07E6A3E50F0354840	3	2017-10-31	\N	17b3f5c9-ef4e-43f7-bcc3-fc82f39752c4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
934	874	Bob	0101000020E6100000D9DAA7A20D4C0DC0F011B300EF354840	3	2017-10-31	\N	72493a20-30ae-4f73-8587-4e2c8c92ee40	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
935	875	Bob	0101000020E6100000B7A62515224C0DC0C1C160A0ED354840	3	2017-10-31	\N	0fc34029-4f79-4b2c-b6a4-9233a2910dfb	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
936	876	Bob	0101000020E6100000CCF6CDBCB14C0DC0DBB9B2ADE8354840	3	2017-10-31	\N	0a4b4a90-7d6a-4699-9423-2fc781806334	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
937	877	Bob	0101000020E6100000E9E1B0F3CB4C0DC0EE58EE6EE7354840	3	2017-10-31	\N	6421c2ab-cd4a-4b23-9e28-fe4306ec9bd4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
938	878	John	0101000020E610000088FC9B65C2530DC032F546FF32394840	3	2017-10-31	\N	f602db8c-9249-45e0-84ad-5bfee8e0c9e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
939	879	John	0101000020E6100000D78C7454E1530DC0F7F63AFB31394840	3	2017-10-31	\N	0c3a07b4-cfbe-4828-ad51-649065dd46d9	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
940	880	John	0101000020E61000005AC242FB04540DC03FD74A3A31394840	3	2017-10-31	\N	49957d26-9162-4ba5-bd75-3b4fc6adb7d2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
941	881	John	0101000020E6100000F9A827412B540DC02326349B2E394840	3	2017-10-31	\N	e4577697-fd03-49ee-9cd3-b6db95ca07ed	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
942	882	John	0101000020E6100000928039C897540DC0389598B927394840	3	2017-10-31	\N	8c187837-490a-476a-ad7f-8c781128a59b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
943	883	John	0101000020E61000007B00F3DEC4540DC0AB70570125394840	3	2017-10-31	\N	243116a9-b9c0-44b9-a913-f3bd9f7ec506	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
944	884	John	0101000020E6100000E14ADE4ECE540DC0D24AAD491E394840	3	2017-10-31	\N	8ccffea4-56eb-4cde-abc3-850826d324a6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
945	885	John	0101000020E6100000CA90CBCDE3540DC0555D13241D394840	3	2017-10-31	\N	32b16caf-923b-423d-b5d1-677d0ea264b7	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
946	886	John	0101000020E6100000A85C4940F8540DC03878B2ED1B394840	3	2017-10-31	\N	64320747-3a99-4dd8-8437-0219bcc7f582	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
947	887	John	0101000020E6100000DB3B0B9014550DC0CDF509F21A394840	3	2017-10-31	\N	a1817136-4258-4e8a-a8f3-89a756231a9f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
948	888	John	0101000020E61000007FDF275C3B550DC07055653118394840	3	2017-10-31	\N	62cab96e-a23a-4a00-8988-1fd7d181852e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
949	889	John	0101000020E6100000C4BBC4A641550DC00BC43E5316394840	3	2017-10-31	\N	4ab7c107-ee86-4afc-a927-67ffdeecc697	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
950	890	John	0101000020E6100000F79A86F65D550DC0EEDEDD1C15394840	3	2017-10-31	\N	518fd76c-0eb7-4ccc-80ee-d1e4ebc18c3b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
951	891	John	0101000020E61000009B3EA3C284550DC0D1F97CE613394840	3	2017-10-31	\N	98b888c2-f02b-4cd3-9f9e-aebfc65fc16f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
952	892	John	0101000020E61000003A258808AB550DC0017E19DE13394840	3	2017-10-31	\N	5ddb0e95-26ac-4ad2-90e0-94829e25356d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
953	893	John	0101000020E6100000C8D4C5BBCF550DC0EF1228B413394840	3	2017-10-31	\N	edca722a-3956-4f0b-b092-e197d84917bc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
954	894	John	0101000020E61000003AD3ECCFF1550DC001B2637512394840	3	2017-10-31	\N	8cc317ca-d44d-4ee4-9e14-8115732d6960	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
955	895	John	0101000020E6100000BC08BB7615560DC06D68560812394840	3	2017-10-31	\N	2781b2d5-2ab3-4036-9d74-b9e9ed6fe624	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
956	896	John	0101000020E61000008F94957440560DC03136006D12394840	3	2017-10-31	\N	2bcb21b8-0ff1-465b-baac-1c4298082504	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
957	897	John	0101000020E61000002E7B7ABA66560DC0258846C912394840	3	2017-10-31	\N	2a231255-9c60-4510-a3db-e89767716de5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
958	898	John	0101000020E6100000F58CE5AB90560DC096FB70E212394840	3	2017-10-31	\N	63050595-bf3d-4f0f-bbf8-793e146aec6e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
959	899	John	0101000020E6100000EE7D12EDD6560DC04E1B61A313394840	3	2017-10-31	\N	7ade9821-b5fe-46c4-8cd7-1d7c413ba269	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
960	900	John	0101000020E610000066397187F9560DC0E3646E1014394840	3	2017-10-31	\N	f61fcb41-ec26-42cb-8d26-1617dc883361	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
961	901	John	0101000020E6100000F9A5E6C01E570DC095C7264B14394840	3	2017-10-31	\N	a22699df-2dc2-46e0-aef2-eb1c273d9307	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
962	902	John	0101000020E6100000A4063B1346570DC0063B516414394840	3	2017-10-31	\N	fcb55ef7-3403-4e0a-8245-0bfda81daf94	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
963	903	John	0101000020E61000004E678F656D570DC018A6428E14394840	3	2017-10-31	\N	0c091944-36bc-4713-9cfb-2bb235ffc0ff	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
964	904	John	0101000020E6100000A3B49FDA8C570DC0E230247915394840	3	2017-10-31	\N	52d46d72-336d-4786-89d0-174a5cff73d1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
965	905	John	0101000020E6100000598F6339B5570DC0777A31E615394840	3	2017-10-31	\N	a2df6985-1c8e-47b2-bab8-13bbbb1689b4	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
966	906	John	0101000020E6100000BF131B41D6570DC0B2AC878115394840	3	2017-10-31	\N	0890465d-1b27-44df-8bfe-e5727a97eaa3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
967	907	John	0101000020E6100000914D5A0648580DC0B2AC878115394840	3	2017-10-31	\N	bb7beeea-6412-4067-ad53-0c5b72412f73	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
968	908	John	0101000020E61000000809B9A06A580DC047F694EE15394840	3	2017-10-31	\N	a2fbc800-fd9a-4784-be0d-972187350505	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
969	909	John	0101000020E6100000A7EF9DE690580DC0FA584D2916394840	3	2017-10-31	\N	4fc0391d-8900-48fc-8469-4f6da9fab00d	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
970	910	John	0101000020E61000006E0109D8BA580DC04DB3CC7416394840	3	2017-10-31	\N	13117e68-a194-4674-bac2-45377802bed2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
971	911	John	0101000020E61000006D2306CF30590DC07089AFC816394840	3	2017-10-31	\N	ca760294-c092-491c-b92b-0bf02624aa10	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
972	912	John	0101000020E6100000FBD2438255590DC023EC670317394840	3	2017-10-31	\N	46b9e9b5-8888-4095-b747-76cfc69048c1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
973	913	John	0101000020E6100000728EA21C78590DC0173EAE5F17394840	3	2017-10-31	\N	2c718fa0-3305-432c-aee2-53cc9bf327a8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
974	914	John	0101000020E610000022AC2EF59F590DC08E6E10FF17394840	3	2017-10-31	\N	5c5c9e2e-ce30-4779-b339-0e8ab23f29dc	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
975	915	John	0101000020E61000009F24C515C3590DC0BDF2ACF617394840	3	2017-10-31	\N	d4910088-2e7a-414d-9a19-af850be4c777	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
976	916	John	0101000020E6100000A48F61630A5A0DC0E685C7D018394840	3	2017-10-31	\N	8e0dfae6-ddc6-4d0d-baad-8a7b839edd95	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
977	917	John	0101000020E61000006BA1CC54345A0DC0B7012BD918394840	3	2017-10-31	\N	49419206-ac44-452f-8368-51a1242a7963	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
978	918	John	0101000020E610000038706FCC5E5A0DC0C3AFE47C18394840	3	2017-10-31	\N	06d80396-98e2-4608-8eb7-e618921c5c24	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
979	919	John	0101000020E61000005FBDF26ED85A0DC099E87F0B19394840	3	2017-10-31	\N	ac398ece-52ef-48e9-99e1-fb38520afaa8	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
980	920	John	0101000020E6100000E1F2C015FC5A0DC0EC42FF5619394840	3	2017-10-31	\N	4ecfb0f7-10fa-4584-aa3b-c3edaf571015	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
981	921	John	0101000020E61000006EC4FBBF965B0DC0DAD70D2D19394840	3	2017-10-31	\N	f3e3096f-f859-4f1a-abd5-c2a60d58f4e2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
982	922	John	0101000020E61000002AD08FD4EE5B0DC04B4B384619394840	3	2017-10-31	\N	5d61bff4-0c68-4464-9b06-07358a80f746	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
983	923	John	0101000020E6100000C9B6741A155C0DC01CC79B4E19394840	3	2017-10-31	\N	e9b6ae0c-5cee-4d80-bcd2-c4fe452b0be0	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
984	924	John	0101000020E610000079D400F33C5C0DC0287555F218394840	3	2017-10-31	\N	e2f06be5-cb5e-492d-8593-64c955ba6613	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
985	925	John	0101000020E6100000F64C9713605C0DC0D51AD6A618394840	3	2017-10-31	\N	37fa7130-b1b0-4ccb-859c-a08a4fb4bf42	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
986	926	John	0101000020E610000050CB773EAF5C0DC05EEA730718394840	3	2017-10-31	\N	a39e31fd-60dc-421a-8a74-ed226e304651	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
987	927	John	0101000020E6100000DE7AB5F1D35C0DC0BDF2ACF617394840	3	2017-10-31	\N	dc44c740-4c56-46c8-bf05-33e43679d96c	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
988	928	John	0101000020E610000011CE0F711F5D0DC0DB0B58C417394840	3	2017-10-31	\N	1e6acbb1-5548-4318-a3fb-1725862f1413	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
989	929	John	0101000020E6100000439502209A5D0DC029DDE92016394840	3	2017-10-31	\N	421376d0-551e-4cb9-938b-33bd75311f0b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
990	930	John	0101000020E6100000CB87084DBE5D0DC0FA584D2916394840	3	2017-10-31	\N	a3f2abf5-4086-4d46-a4e7-f5d4f5cdaf5f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
991	931	John	0101000020E61000007BA59425E65D0DC0DC3FA25B16394840	3	2017-10-31	\N	e0aee4a6-2354-472f-af1d-7877673bcd50	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
992	932	John	0101000020E610000059ABDE2F125E0DC0FF1585AF16394840	3	2017-10-31	\N	aded1645-c93d-44a9-9301-14d4b650ca92	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
993	933	John	0101000020E61000007BC7911C5C5E0DC0E8ED5BFF15394840	3	2017-10-31	\N	d57791b6-7e15-42ec-b2cd-6e581563d2fa	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
994	934	John	0101000020E610000041D9FC0D865E0DC029DDE92016394840	3	2017-10-31	\N	85ef2639-592b-4a50-87cf-e7842644ab38	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
995	935	John	0101000020E610000080322E6AA35E0DC0BF5A412515394840	3	2017-10-31	\N	e82befe7-628f-42e4-a9e1-9574bc337778	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
996	936	John	0101000020E6100000D5F3D60EF25E0DC095C7264B14394840	3	2017-10-31	\N	7469fa7c-9445-4139-8c60-04a73107bc2a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
997	937	John	0101000020E61000004035C69C135F0DC0A175E0EE13394840	3	2017-10-31	\N	8098aa56-8e12-4e20-aca4-650f9c45042f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
998	938	John	0101000020E6100000C927CCC9375F0DC0017E19DE13394840	3	2017-10-31	\N	dda29a15-24ec-4504-90e1-c3b93baac8c5	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
999	939	John	0101000020E610000083E1C4A5D65F0DC02A1134B814394840	3	2017-10-31	\N	e85ce51e-9593-4286-b153-3cfd93f270a2	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1000	940	John	0101000020E6100000174E3ADFFB5F0DC0A732187514394840	3	2017-10-31	\N	4ba4c7dd-4f28-4949-be02-5ecdc738894b	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1001	941	John	0101000020E61000009E623D0396600DC0AE239A9213394840	3	2017-10-31	\N	418b9cdd-ec1e-4acc-8513-6d50775d6a95	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1002	942	John	0101000020E61000001BDBD323B9600DC0E955F02D13394840	3	2017-10-31	\N	f61267d4-9be7-43bc-b2d7-8b58be6e260a	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1003	943	John	0101000020E6100000E2EC3E15E3600DC019DA8C2513394840	3	2017-10-31	\N	a9a5a8d5-a9e6-4666-b57e-11279a8498b3	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1004	944	John	0101000020E61000005F65D53506610DC096FB70E212394840	3	2017-10-31	\N	db7057c3-3431-4aa2-bf05-ab60f320b487	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1005	945	John	0101000020E6100000C55D256D56610DC00E601D1912394840	3	2017-10-31	\N	45293730-16b5-448e-a7b6-96ad8cd48c28	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1006	946	John	0101000020E61000007B38E9CB7E610DC01A0ED7BC11394840	3	2017-10-31	\N	b54748b9-6cdd-42a8-929a-dcc2e5f089e1	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1007	947	John	0101000020E6100000F724181CD1610DC03E1804A810394840	3	2017-10-31	\N	5712225f-50bd-449e-b58b-03182b24d43f	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1008	948	John	0101000020E6100000FC8FB46918620DC08BB54B6D10394840	3	2017-10-31	\N	93b32737-59fc-4457-b023-120546b8bb54	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1009	949	John	0101000020E61000000D75C0C360620DC0440986C50F394840	3	2017-10-31	\N	c0ddd927-cffb-4c4e-a69d-6c1ba08bc579	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1010	950	John	0101000020E610000062366968AF620DC06ED0EA360F394840	3	2017-10-31	\N	7c85a78b-c982-4a46-8143-f35a95b6abf6	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
1011	951	John	0101000020E6100000A64CD24ACD620DC063567B2A0E394840	3	2017-10-31	\N	61c7a9ed-a29e-4296-a7ce-f6cc9e1e365e	2022-10-05 16:03:24.49695	2022-10-05 16:03:24.49695
\.


--
-- Data for Name: spatial_ref_sys; Type: TABLE DATA; Schema: public; Owner: -
--

COPY public.spatial_ref_sys (srid, auth_name, auth_srid, srtext, proj4text) FROM stdin;
\.


--
-- Name: actor_category_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.actor_category_id_seq', 3, true);


--
-- Name: actor_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.actor_id_seq', 8, true);


--
-- Name: application_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.application_id_seq', 1, false);


--
-- Name: document_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.document_id_seq', 2, true);


--
-- Name: glossary_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.glossary_id_seq', 26, true);


--
-- Name: graph_node_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.graph_node_id_seq', 16, true);


--
-- Name: import_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.import_id_seq', 8, true);


--
-- Name: indicator_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.indicator_id_seq', 4, true);


--
-- Name: metadata_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.metadata_id_seq', 1, true);


--
-- Name: observation_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.observation_id_seq', 3814, true);


--
-- Name: project_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.project_id_seq', 1, false);


--
-- Name: project_view_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.project_view_id_seq', 1, false);


--
-- Name: protocol_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.protocol_id_seq', 4, true);


--
-- Name: series_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.series_id_seq', 8, true);


--
-- Name: spatial_layer_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.spatial_layer_id_seq', 4, true);


--
-- Name: spatial_object_id_seq; Type: SEQUENCE SET; Schema: gobs; Owner: -
--

SELECT pg_catalog.setval('gobs.spatial_object_id_seq', 1011, true);


--
-- Name: actor actor_a_login_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.actor
    ADD CONSTRAINT actor_a_login_key UNIQUE (a_login);


--
-- Name: actor_category actor_category_ac_label_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.actor_category
    ADD CONSTRAINT actor_category_ac_label_key UNIQUE (ac_label);


--
-- Name: actor_category actor_category_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.actor_category
    ADD CONSTRAINT actor_category_pkey PRIMARY KEY (id);


--
-- Name: actor actor_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.actor
    ADD CONSTRAINT actor_pkey PRIMARY KEY (id);


--
-- Name: application application_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.application
    ADD CONSTRAINT application_pkey PRIMARY KEY (id);


--
-- Name: deleted_data_log deleted_data_log_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.deleted_data_log
    ADD CONSTRAINT deleted_data_log_pkey PRIMARY KEY (de_table, de_uid);


--
-- Name: document document_do_label_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.document
    ADD CONSTRAINT document_do_label_key UNIQUE (do_label, fk_id_indicator);


--
-- Name: document document_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.document
    ADD CONSTRAINT document_pkey PRIMARY KEY (id);


--
-- Name: glossary glossary_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.glossary
    ADD CONSTRAINT glossary_pkey PRIMARY KEY (id);


--
-- Name: graph_node graph_node_gn_name_unique; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.graph_node
    ADD CONSTRAINT graph_node_gn_name_unique UNIQUE (gn_label);


--
-- Name: graph_node graph_node_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.graph_node
    ADD CONSTRAINT graph_node_pkey PRIMARY KEY (id);


--
-- Name: import import_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.import
    ADD CONSTRAINT import_pkey PRIMARY KEY (id);


--
-- Name: indicator indicator_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.indicator
    ADD CONSTRAINT indicator_pkey PRIMARY KEY (id);


--
-- Name: metadata metadata_me_version_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.metadata
    ADD CONSTRAINT metadata_me_version_key UNIQUE (me_version);


--
-- Name: metadata metadata_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.metadata
    ADD CONSTRAINT metadata_pkey PRIMARY KEY (id);


--
-- Name: observation observation_data_unique; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.observation
    ADD CONSTRAINT observation_data_unique UNIQUE (fk_id_series, fk_id_spatial_object, ob_start_timestamp);


--
-- Name: observation observation_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.observation
    ADD CONSTRAINT observation_pkey PRIMARY KEY (id);


--
-- Name: project project_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project
    ADD CONSTRAINT project_pkey PRIMARY KEY (id);


--
-- Name: project project_pt_code_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project
    ADD CONSTRAINT project_pt_code_key UNIQUE (pt_code);


--
-- Name: project project_pt_label_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project
    ADD CONSTRAINT project_pt_label_key UNIQUE (pt_label);


--
-- Name: project_view project_view_fk_id_project_fk_id_spatial_layer_fk_so_unique_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project_view
    ADD CONSTRAINT project_view_fk_id_project_fk_id_spatial_layer_fk_so_unique_key UNIQUE (fk_id_project, fk_id_spatial_layer, fk_so_unique_id);


--
-- Name: project_view project_view_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project_view
    ADD CONSTRAINT project_view_pkey PRIMARY KEY (id);


--
-- Name: protocol protocol_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.protocol
    ADD CONSTRAINT protocol_pkey PRIMARY KEY (id);


--
-- Name: r_graph_edge r_graph_edge_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.r_graph_edge
    ADD CONSTRAINT r_graph_edge_pkey PRIMARY KEY (ge_parent_node, ge_child_node);


--
-- Name: r_indicator_node r_indicator_node_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.r_indicator_node
    ADD CONSTRAINT r_indicator_node_pkey PRIMARY KEY (fk_id_indicator, fk_id_node);


--
-- Name: series series_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.series
    ADD CONSTRAINT series_pkey PRIMARY KEY (id);


--
-- Name: spatial_layer spatial_layer_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.spatial_layer
    ADD CONSTRAINT spatial_layer_pkey PRIMARY KEY (id);


--
-- Name: spatial_object spatial_object_pkey; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.spatial_object
    ADD CONSTRAINT spatial_object_pkey PRIMARY KEY (id);


--
-- Name: spatial_object spatial_object_unique_key; Type: CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.spatial_object
    ADD CONSTRAINT spatial_object_unique_key UNIQUE (so_unique_id, fk_id_spatial_layer, so_valid_from);


--
-- Name: actor_a_name_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX actor_a_name_idx ON gobs.actor USING btree (a_label);


--
-- Name: glossary_gl_field_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX glossary_gl_field_idx ON gobs.glossary USING btree (gl_field);


--
-- Name: graph_node_gn_name_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX graph_node_gn_name_idx ON gobs.graph_node USING btree (gn_label);


--
-- Name: import_fk_id_series_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX import_fk_id_series_idx ON gobs.import USING btree (fk_id_series);


--
-- Name: indicator_id_label_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX indicator_id_label_idx ON gobs.indicator USING btree (id_code);


--
-- Name: observation_fk_id_import_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX observation_fk_id_import_idx ON gobs.observation USING btree (fk_id_import);


--
-- Name: observation_fk_id_series_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX observation_fk_id_series_idx ON gobs.observation USING btree (fk_id_series);


--
-- Name: observation_fk_id_spatial_object_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX observation_fk_id_spatial_object_idx ON gobs.observation USING btree (fk_id_spatial_object);


--
-- Name: observation_ob_timestamp_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX observation_ob_timestamp_idx ON gobs.observation USING btree (ob_start_timestamp);


--
-- Name: protocol_pr_code_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX protocol_pr_code_idx ON gobs.protocol USING btree (pr_code);


--
-- Name: series_fk_id_actor_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX series_fk_id_actor_idx ON gobs.series USING btree (fk_id_actor);


--
-- Name: series_fk_id_indicator_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX series_fk_id_indicator_idx ON gobs.series USING btree (fk_id_indicator);


--
-- Name: series_fk_id_protocol_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX series_fk_id_protocol_idx ON gobs.series USING btree (fk_id_protocol);


--
-- Name: series_fk_id_spatial_layer_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX series_fk_id_spatial_layer_idx ON gobs.series USING btree (fk_id_spatial_layer);


--
-- Name: spatial_layer_sl_code_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX spatial_layer_sl_code_idx ON gobs.spatial_layer USING btree (sl_code);


--
-- Name: spatial_object_fk_id_spatial_layer_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX spatial_object_fk_id_spatial_layer_idx ON gobs.spatial_object USING btree (fk_id_spatial_layer);


--
-- Name: spatial_object_geom_idx; Type: INDEX; Schema: gobs; Owner: -
--

CREATE INDEX spatial_object_geom_idx ON gobs.spatial_object USING gist (geom);


--
-- Name: import gobs_on_import_change; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER gobs_on_import_change AFTER UPDATE ON gobs.import FOR EACH ROW EXECUTE PROCEDURE gobs.trg_after_import_validation();


--
-- Name: indicator gobs_on_indicator_change; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER gobs_on_indicator_change AFTER INSERT OR UPDATE ON gobs.indicator FOR EACH ROW EXECUTE PROCEDURE gobs.trg_parse_indicator_paths();


--
-- Name: observation trg_log_deleted_object; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER trg_log_deleted_object AFTER DELETE ON gobs.observation FOR EACH ROW EXECUTE PROCEDURE gobs.log_deleted_object();


--
-- Name: document trg_manage_object_timestamps; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER trg_manage_object_timestamps BEFORE INSERT OR UPDATE ON gobs.document FOR EACH ROW EXECUTE PROCEDURE gobs.manage_object_timestamps();


--
-- Name: indicator trg_manage_object_timestamps; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER trg_manage_object_timestamps BEFORE INSERT OR UPDATE ON gobs.indicator FOR EACH ROW EXECUTE PROCEDURE gobs.manage_object_timestamps();


--
-- Name: observation trg_manage_object_timestamps; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER trg_manage_object_timestamps BEFORE INSERT OR UPDATE ON gobs.observation FOR EACH ROW EXECUTE PROCEDURE gobs.manage_object_timestamps();


--
-- Name: spatial_object trg_manage_object_timestamps; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER trg_manage_object_timestamps BEFORE INSERT OR UPDATE ON gobs.spatial_object FOR EACH ROW EXECUTE PROCEDURE gobs.manage_object_timestamps();


--
-- Name: spatial_object trg_update_observation_on_spatial_object_change; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER trg_update_observation_on_spatial_object_change AFTER UPDATE ON gobs.spatial_object FOR EACH ROW EXECUTE PROCEDURE gobs.update_observation_on_spatial_object_change();


--
-- Name: spatial_object trg_update_spatial_object_end_validity; Type: TRIGGER; Schema: gobs; Owner: -
--

CREATE TRIGGER trg_update_spatial_object_end_validity AFTER INSERT ON gobs.spatial_object FOR EACH ROW EXECUTE PROCEDURE gobs.update_spatial_object_end_validity();


--
-- Name: actor actor_id_category_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.actor
    ADD CONSTRAINT actor_id_category_fkey FOREIGN KEY (id_category) REFERENCES gobs.actor_category(id) ON DELETE RESTRICT;


--
-- Name: document document_fk_id_indicator_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.document
    ADD CONSTRAINT document_fk_id_indicator_fkey FOREIGN KEY (fk_id_indicator) REFERENCES gobs.indicator(id);


--
-- Name: import import_fk_id_series_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.import
    ADD CONSTRAINT import_fk_id_series_fkey FOREIGN KEY (fk_id_series) REFERENCES gobs.series(id) ON DELETE RESTRICT;


--
-- Name: observation observation_fk_id_import_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.observation
    ADD CONSTRAINT observation_fk_id_import_fkey FOREIGN KEY (fk_id_import) REFERENCES gobs.import(id) ON DELETE RESTRICT;


--
-- Name: observation observation_fk_id_series_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.observation
    ADD CONSTRAINT observation_fk_id_series_fkey FOREIGN KEY (fk_id_series) REFERENCES gobs.series(id) ON DELETE RESTRICT;


--
-- Name: observation observation_fk_id_spatial_object_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.observation
    ADD CONSTRAINT observation_fk_id_spatial_object_fkey FOREIGN KEY (fk_id_spatial_object) REFERENCES gobs.spatial_object(id) ON DELETE RESTRICT;


--
-- Name: project_view project_view_fk_id_project_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project_view
    ADD CONSTRAINT project_view_fk_id_project_fkey FOREIGN KEY (fk_id_project) REFERENCES gobs.project(id) ON DELETE CASCADE;


--
-- Name: project_view project_view_fk_id_spatial_layer_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.project_view
    ADD CONSTRAINT project_view_fk_id_spatial_layer_fkey FOREIGN KEY (fk_id_spatial_layer) REFERENCES gobs.spatial_layer(id) ON DELETE SET NULL;


--
-- Name: r_indicator_node r_indicator_node_fk_id_indicator_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.r_indicator_node
    ADD CONSTRAINT r_indicator_node_fk_id_indicator_fkey FOREIGN KEY (fk_id_indicator) REFERENCES gobs.indicator(id) ON DELETE CASCADE;


--
-- Name: r_indicator_node r_indicator_node_fk_id_node_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.r_indicator_node
    ADD CONSTRAINT r_indicator_node_fk_id_node_fkey FOREIGN KEY (fk_id_node) REFERENCES gobs.graph_node(id) ON DELETE CASCADE;


--
-- Name: series series_fk_id_actor_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.series
    ADD CONSTRAINT series_fk_id_actor_fkey FOREIGN KEY (fk_id_actor) REFERENCES gobs.actor(id) ON DELETE RESTRICT;


--
-- Name: series series_fk_id_indicator_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.series
    ADD CONSTRAINT series_fk_id_indicator_fkey FOREIGN KEY (fk_id_indicator) REFERENCES gobs.indicator(id) ON DELETE RESTRICT;


--
-- Name: series series_fk_id_protocol_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.series
    ADD CONSTRAINT series_fk_id_protocol_fkey FOREIGN KEY (fk_id_protocol) REFERENCES gobs.protocol(id) ON DELETE RESTRICT;


--
-- Name: series series_fk_id_spatial_layer_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.series
    ADD CONSTRAINT series_fk_id_spatial_layer_fkey FOREIGN KEY (fk_id_spatial_layer) REFERENCES gobs.spatial_layer(id) ON DELETE RESTRICT;


--
-- Name: spatial_layer spatial_layer_fk_id_actor_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.spatial_layer
    ADD CONSTRAINT spatial_layer_fk_id_actor_fkey FOREIGN KEY (fk_id_actor) REFERENCES gobs.actor(id) ON DELETE RESTRICT;


--
-- Name: spatial_object spatial_object_fk_id_spatial_layer_fkey; Type: FK CONSTRAINT; Schema: gobs; Owner: -
--

ALTER TABLE ONLY gobs.spatial_object
    ADD CONSTRAINT spatial_object_fk_id_spatial_layer_fkey FOREIGN KEY (fk_id_spatial_layer) REFERENCES gobs.spatial_layer(id) ON DELETE RESTRICT;


--
-- PostgreSQL database dump complete
--
