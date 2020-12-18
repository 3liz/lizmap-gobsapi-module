<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class Observation
{
    /**
     * @var observation_uid: Observation uuid
     */
    protected $observation_uid;

    /**
     * @var user: Authenticated user
     */
    protected $user;

    /**
     * @var observation_valid: Boolean telling the observation is valid or not
     */
    protected $observation_valid = false;

    /**
     * @var data G-Obs Representation of an observation or many observations
     */
    protected $data;

    /**
     * constructor.
     *
     * @param string $indicator_code: the code of the indicator
     * @param mixed  $project
     */
    public function __construct($user, $observation_uid=null, $data=null)
    {
        $this->observation_uid = $observation_uid;
        $this->data = $data;
        $this->user = $user;

        // Get data from database if uid is given
        if (!empty($observation_uid) && $this->isValidUuid($observation_uid)) {
            // Get observation by id
            $json = $this->getObservationFromDatabase($observation_uid);
            if ($this->observation_valid) {
                $this->data = $json;
            }
        }
    }

    // Check observation indicator code is valid
    public function checkIndicatorCode($indicator_code)
    {
        return (
            preg_match('/^[a-zA-Z0-9_\-]+$/', $indicator_code)
            and strlen($indicator_code) > 2
        );
    }

    /**
     * Check if a given string is a valid UUID
     *
     * @param   string  $uuid   The string to check
     * @return  boolean
     */
    public function isValidUuid($uuid) {

        if (!is_string($uuid) || (preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/', $uuid) !== 1)) {
            return false;
        }

        return true;
    }

    /**
     * Validate a string containing date
     * @param string date String to validate. Ex: "2020-12-12 08:34:45"
     * @param string format Format of the date to validate against. Default "Y-m-d H:i:s"
     *
     * @return boolean
     */
    private function isValidDate($date)
    {
        $tests = array();
        $formats = array('Y-m-d\TH:i:s', 'Y-m-d H:i:s', 'Y-m-d\TH:i:sP');
        $valid = false;
        foreach ($formats as $format) {
            $d = DateTime::createFromFormat($format, $date);
            $test = $d && $d->format($format) == $date;
            if ($test) {
                $valid = true;
                break;
            }
        }

        return $valid;
    }

    /**
     * Check observation JSON data
     *
     * @param   string  $action   create or update
     * @return  boolean
     */
    public function checkObservationJsonFormat($action='create') {
        $data = $this->data;
        if (empty($data)) {
            $this->observation_valid = false;
            return array(
                'error',
                'Observation JSON data is empty'
            );
        }
        $data = json_decode($data);

        // Check fields
        if (!property_exists($data, 'start_timestamp') || !$this->isValidDate($data->start_timestamp)) {
            $this->observation_valid = false;
            return array(
                'error',
                'Observation JSON data must have a valid start_timestamp'
            );
        }
        if (property_exists($data, 'end_timestamp') && !$this->isValidDate($data->end_timestamp)) {
            $this->observation_valid = false;
            return array(
                'error',
                'Observation JSON data must have a valid end_timestamp'
            );
        }
        if ($action == 'update') {
            // UPDATE
            // Check observation exists
            $db_obs = $this->getObservationFromDatabase($data->uuid);
            if (!$this->observation_valid) {
                return array(
                    'error',
                    'Observation JSON data does not correspond to an existing observation'
                );
            }
            $db_obs = json_decode($db_obs);

            // Do not allow to modify some fields
            $keys = array(
                'id', 'indicator', 'uuid', 'created_at', 'updated_at', 'actor_email'
            );
            foreach ($keys as $key) {
                $data->$key = $db_obs->$key;
            }
        } else {
            // CREATION
            // Check indicator
            if (!property_exists($data, 'indicator') || !$this->checkIndicatorCode($data->indicator)) {
                $this->observation_valid = false;
                return array(
                    'error',
                    'Observation JSON data must have a valid indicator'
                );
            }

            // Set data to null before inserting into database
            $data->id = null;
            $data->uuid = null;
            $data->photo = null;
            $data->created_at = null;
            $data->updated_at = null;
            $data->actor_email = $this->user['usr_email'];
        }

        $this->data  = json_encode($data);
        $this->observation_valid = true;

        return array(
            'success',
            'Observation JSON data is valid'
        );
    }

    // Check observation access capabilities by authenticated user
    public function capabilities() {

        // Observation reading: only for valid observations
        // todo: Observation - capabilities check observation validity
        $capabilities = array(
            'get'=>true,
            'edit'=>false
        );
        //$capabilities['edit'] = true;

        // Get obervation data
        $data = json_decode($this->data);

        // Observation editing: only for login author of a series of observation
        // For creation, we put the auth user email in actor_email, so this check is not enough
        // For update, we override actor_email from the database observation, so this check is enough
        if ($data->actor_email == $this->user['usr_email']) {
            $capabilities['edit'] = true;
        }

        // Check if authenticated user has a series for the given indicator
        $indicator_code = $data->indicator;

        // Check indicator
        // Todo: Observation - Check connected user has access to the indicator

        return $capabilities;
    }

    // Query database and return json data
    private function query($sql, $params) {
        $gobs_profile = 'gobsapi';
        $cnx = jDb::getConnection($gobs_profile);
        $json = null;
        $cnx->beginTransaction();
        try {
            $resultset = $cnx->prepare($sql);
            $resultset->execute($params);
            foreach ($resultset->fetchAll() as $record) {
                $json = $record->object_json;
            }
            $cnx->commit();
        } catch (Exception $e) {
            $cnx->rollback();
            throw $e;
        }

        return $json;
    }

    // Get JSON object of a observation stored in the database
    public function getObservationFromDatabase($uid) {
        $sql = "
        WITH obs AS (
            SELECT
                o.id, i.id_code AS indicator, o.ob_uid AS uuid,
                a.a_email AS actor_email,
                o.ob_start_timestamp AS start_timestamp,
                o.ob_end_timestamp AS end_timestamp,
                json_build_object(
                    'x', ST_X(ST_Centroid(so.geom)),
                    'y', ST_Y(ST_Centroid(so.geom))
                ) AS coordinates,
                ST_AsText(ST_Centroid(so.geom)) AS wkt,
                ob_value AS values,
                NULL AS photo,
                o.created_at::timestamp(0), o.updated_at::timestamp(0)
            FROM gobs.observation AS o
            JOIN gobs.series AS s
                ON s.id = o.fk_id_series
            JOIN gobs.actor AS a
                ON a.id = s.fk_id_actor
            JOIN gobs.indicator AS i
                ON i.id = s.fk_id_indicator
            JOIN gobs.spatial_object AS so
                ON so.id = o.fk_id_spatial_object
            WHERE True
        ";

        // Filter for given observation uid
        $sql.= "
            AND (
                o.ob_uid IN ($1)
            )
            LIMIT 1
        ";

        // Transform result into JSON for each row
        $sql.= "
        )
        SELECT
            row_to_json(obs.*) AS object_json
        FROM obs
        ";
        //jLog::log($sql, 'error');
        $params = array($uid);
        try {
            $json = $this->query($sql, $params);
        } catch (Exception $e) {
            $msg = $e->getMessage();
            $json = null;
        }
        $this->observation_valid = (!empty($json));

        return $json;
    }

    // Get Gobs representation of an observation object
    public function get()
    {
        if (!($this->observation_valid)) {
            return array(
                'error',
                'The given observation is not valid',
                null
            );
        }
        return array(
            'success',
            'Observation has been fetched',
            json_decode($this->data)
        );
    }

    // Get Gobs representation of an observation object
    public function delete()
    {
        // Check observation
        if (!($this->observation_valid)) {
            return array(
                'error',
                'The given observation is not valid',
                null
            );
        }

        // Delete observation
        $sql = "
        WITH del AS (
            DELETE
            FROM gobs.observation
            WHERE ob_uid = $1
            RETURNING id, ob_uid
        )
        SELECT
            row_to_json(del.*) AS object_json
        FROM del
        "
        ;
        $params = array($this->observation_uid);
        try {
            $json = $this->query($sql, $params);
        } catch (Exception $e) {
            $msg = $e->getMessage();
            $json = null;
        }
        if (empty($json)) {
            return array(
                'error',
                'An error occured while deleting the observation',
                null
            );
        }

        // Delete also orphan medias and documents
        // Todo Observation - delete medias and documents

        // Todo Observation - delete also spatial objects and imports

        return array(
            'success',
            'The observation has been sucessfully deleted',
            json_decode($json)
        );
    }



    // Create a new observation
    public function create()
    {
        // Check observation
        if (!($this->observation_valid)) {
            return array(
                'error',
                'The given observation is not valid',
                null
            );
        }

        // Create import, spatial object & observation
        $sql = "
            WITH source AS (
                SELECT $1::json AS o
            ),
            ind AS (
                SELECT
                    id, id_code, id_date_format
                FROM gobs.indicator
                JOIN source
                    ON o->>'indicator' = id_code
                LIMIT 1
            ),
            ser AS (
                SELECT
                    s.id, s.fk_id_spatial_layer
                FROM gobs.series AS s
                JOIN ind AS i
                    ON fk_id_indicator = i.id
                JOIN gobs.actor AS a
                    ON s.fk_id_actor = a.id
                WHERE a.a_email = $2
                ORDER BY s.id DESC
                LIMIT 1
            ),
            so AS (
                INSERT INTO gobs.spatial_object (
                    so_unique_id,
                    so_unique_label,
                    geom, fk_id_spatial_layer,
                    so_valid_from, so_valid_to
                )
                SELECT
                    md5(concat(
                        ser.id, ser.fk_id_spatial_layer, ind.id_code,
                        o->>'wkt',
                        date_trunc(ind.id_date_format, (o->>'start_timestamp')::timestamp),
                        $2
                    )) AS so_unique_id,
                    'api_gevent',
                    ST_GeomFromText(o->>'wkt', 4326), ser.fk_id_spatial_layer,
                    date_trunc(ind.id_date_format, (o->>'start_timestamp')::timestamp),  NULL
                FROM source, ser, ind
                LIMIT 1
                ON CONFLICT DO NOTHING
                RETURNING id
            ),
            imp AS (
                INSERT INTO gobs.import (
                    fk_id_series, im_status
                )
                SELECT
                    ser.id, 'P'
                FROM ser
                RETURNING id
            ),
            obs AS (
                INSERT INTO gobs.observation (
                    fk_id_series, fk_id_spatial_object, fk_id_import,
                    ob_value, ob_start_timestamp, ob_end_timestamp
                )
                SELECT
                    ser.id, so.id, imp.id,
                    (o->'values')::jsonb, (o->>'start_timestamp')::timestamp, (o->>'end_timestamp')::timestamp
                FROM
                    ser, so, imp, source
                RETURNING *
            )
            SELECT row_to_json(obs.*) AS object_json
            FROM obs
        ";

        $params = array(
            $this->data,
            $this->user['usr_email']
        );

        try {
            $json = $this->query($sql, $params);
        } catch (Exception $e) {
            $msg = $e->getMessage();
            $json = null;
            return array(
                'error',
                'A database error occured while creating the observation',
                null
            );
        }
        if (empty($json)) {
            return array(
                'error',
                'The observation has not been created',
                null
            );
        }

        // Get this observation as G-Obs format
        $created = json_decode($json);
        $db_obs = $this->getObservationFromDatabase($created->ob_uid);

        return array(
            'success',
            'The observation has been sucessfully created',
            json_decode($db_obs)
        );
    }

    // Update the observation
    public function update()
    {
        if (!($this->observation_valid)) {
            return null;
        }
        return null;
    }


}
