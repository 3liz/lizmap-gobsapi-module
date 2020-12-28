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
     * @var indicator: G-Obs indicator
     */
    protected $indicator;

    /**
     * @var observation_valid: Boolean telling the observation is valid or not
     */
    public $observation_valid = false;

    /**
     * @var json_data JSON G-Obs Representation of an observation
     */
    protected $json_data;

    /**
     * @var data Object G-Obs Representation of an observation
     */
    protected $raw_data;

    /**
     * @var media destination directory
     */
    protected $observation_media_directory = '';

    /**
     * @var media allowed mime types
     */
    protected $media_mimes = array('jpg', 'jpeg', 'png', 'gif');


    /**
     * constructor.
     *
     * @param string $indicator_code: the code of the indicator
     * @param mixed  $project
     */
    public function __construct($user, $indicator, $observation_uid=null, $data=null)
    {
        $this->observation_uid = $observation_uid;
        $this->json_data = $data;
        $this->raw_data = null;
        $this->user = $user;
        $this->indicator = $indicator;

        // Get data from database if uid is given
        if (!empty($observation_uid)) {
            if ($this->isValidUuid($observation_uid)) {
                // Get observation by id
                $this->getObservationFromDatabase($observation_uid);
                if ($this->observation_valid) {
                    // Check if indicator code is correct
                    if ($indicator->getCode() != $this->raw_data->indicator) {
                        $this->observation_valid = false;
                    }
                }
            }
        }

        // Check JSON given if body is passed
        if ($data) {
            // Do nothing
        }

        // Set observation media directory
        $this->observation_media_directory = jApp::varPath('uploads/gobsapi~media');
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
    public function checkObservationBodyJSONFormat($action='create') {
        $data = $this->json_data;
        if (empty($data)) {
            $this->observation_valid = false;
            return array(
                'error',
                'Observation JSON data is empty'
            );
        }
        $body_data = json_decode($data);

        // Check indicator given in body corresponds to the observation indicator instance
        if (!property_exists($body_data, 'indicator') || $body_data->indicator != $this->indicator->getCode()) {
            $this->observation_valid = false;
            return array(
                'error',
                'Observation JSON data must have a valid indicator'
            );
        }

        // Check fields
        if (!property_exists($body_data, 'start_timestamp') || !$this->isValidDate($body_data->start_timestamp)) {
            $this->observation_valid = false;
            return array(
                'error',
                'Observation JSON data must have a valid start_timestamp'
            );
        }
        if (property_exists($body_data, 'end_timestamp') && $body_data->end_timestamp && !$this->isValidDate($body_data->end_timestamp)) {
            $this->observation_valid = false;
            return array(
                'error',
                'Observation JSON data must have a valid end_timestamp'
            );
        }
        if ($action == 'update') {
            // UPDATE

            // Check observation exists
            $this->getObservationFromDatabase($body_data->uuid);
            if (!$this->observation_valid) {
                return array(
                    'error',
                    'Observation JSON data does not correspond to an existing observation'
                );
            }
            $db_obs = $this->raw_data;

            // Check database observation indicator is valid
            if ($db_obs->indicator != $this->indicator->getCode()) {
                $this->observation_valid = false;
                return array(
                    'error',
                    'Observation JSON data must have a valid indicator'
                );
            }

            // Do not allow to modify some fields
            $keys = array(
                'id', 'indicator', 'uuid', 'created_at', 'updated_at', 'actor_email'
            );
            foreach ($keys as $key) {
                $body_data->$key = $db_obs->$key;
            }

            // Set uid from data
            $this->observation_uid = $body_data->uuid;
        } else {
            // CREATION

            // Set data to null before inserting into database
            $body_data->id = null;
            $body_data->uuid = null;
            $body_data->media_url = null;
            $body_data->created_at = null;
            $body_data->updated_at = null;
            $body_data->actor_email = $this->user['usr_email'];
        }

        $this->json_data = json_encode($body_data);
        $this->raw_data = $body_data;
        $this->observation_valid = true;

        return array(
            'success',
            'Observation JSON data is valid'
        );
    }

    //

    /**
     * Check observation access capabilities for the authenticated user
     *
     * @param   string  $context Context of the check: read, create or modify
     * @return  boolean
     */
    public function getCapabilities($context='read') {

        // Set default capabilities
        $capabilities = array(
            'get'=>false,
            'edit'=>false
        );

        // Get: only for valid observations
        // todo: Observation - capabilities: reading only for valid observations ?
        $capabilities['get'] = true;

        // Do not check edit capabilities in read context
        if ($context == 'read') {
            return $capabilities;
        }

        // Edit
        // For creation, check that the authenticated user is author
        // of at least one series for this indicator
        if ($context == 'create') {
            $sql = "
                WITH
                ind AS (
                    SELECT
                        id, id_code, id_date_format
                    FROM gobs.indicator
                    WHERE True
                    AND id_code = $1
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
                    WHERE a.a_email = $2::text
                    ORDER BY s.id DESC
                    LIMIT 1
                )
                SELECT row_to_json(ser.*) AS object_json
                FROM ser
            ";
            $params = array(
                $this->indicator->getCode(),
                $this->user['usr_email']
            );
            try {
                $json = $this->query($sql, $params);
            } catch (Exception $e) {
                $msg = $e->getMessage();
                $json = null;
            }
            $capabilities['edit'] = (!empty($json));
        }

        // Modification
        if ($context == 'modify') {
            // For update, we just check if the authenticated user is the author of the observation series
            // NB: the previously called method checkObservationBodyJSONFormat
            // has replaced the actor_email property by the database value
            // We can check if it corresponds to the authenticated user
            if ($this->raw_data->actor_email == $this->user['usr_email']) {
                $capabilities['edit'] = true;
            }
        }

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
        // Check uid
        if (!$this->isValidUuid($uid)) {
            $this->observation_valid = false;
            return null;
        }

        // Get SQL for select
        $sql = $this->getSql('select');

        // Set parameters
        $params = array($uid);

        // Run query
        try {
            $json = $this->query($sql, $params);
        } catch (Exception $e) {
            $msg = $e->getMessage();
            $json = null;
        }
        $this->observation_valid = (!empty($json));

        if ($this->observation_valid) {
            $this->json_data = $json;
            $this->raw_data = json_decode($json);
        } else {
            $this->json_data = null;
            $this->raw_data = array();
        }
    }

    // Return the SQL for the creation of an observation
    private function getSql($action='select') {
        if (!in_array($action, array('select', 'insert', 'update', 'delete'))) {
            return null;
        }

        // SQL clause depends on the chosen action
        if ($action == 'select') {
            // SELECT
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
                    NULL AS media_url,
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
                AND (
                    o.ob_uid IN ($1)
                )
                LIMIT 1
            )
            SELECT
                row_to_json(obs.*) AS object_json
            FROM obs
            ";
        } elseif ($action == 'insert') {
            // INSERT
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
                WHERE a.a_email = $2::text
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
                        $2::text
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
        } elseif ($action == 'update') {
            // UPDATE
            $sql = "
            WITH source AS (
                SELECT $1::json AS o
            ),
            oldobs AS (
                SELECT a.*,
                b.so_unique_id, b.so_unique_label,
                b.fk_id_spatial_layer, b.geom
                FROM gobs.observation a
                JOIN gobs.spatial_object b
                    ON a.fk_id_spatial_object = b.id
                WHERE ob_uid = $3
                LIMIT 1
            ),
            ind AS (
                SELECT
                    id, id_code, id_date_format
                FROM gobs.indicator
                JOIN source
                    ON o->>'indicator' = id_code
                LIMIT 1
            ),
            so AS (
                UPDATE gobs.spatial_object gso SET (
                    so_unique_id,
                    geom,
                    so_valid_from,
                    so_valid_to
                ) = (
                    md5(concat(
                        oo.fk_id_series, oo.fk_id_spatial_layer, ind.id_code,
                        o->>'wkt',
                        date_trunc(ind.id_date_format, (o->>'start_timestamp')::timestamp),
                        $2::text
                    )),
                    ST_GeomFromText(o->>'wkt', 4326),
                    date_trunc(ind.id_date_format, (o->>'start_timestamp')::timestamp),
                    NULL
                )
                FROM source, oldobs AS oo, ind
                WHERE gso.id = oo.fk_id_spatial_object
                RETURNING gso.id
            ),
            imp AS (
                UPDATE gobs.import AS i SET
                    im_status = 'P'
                FROM oldobs AS oo
                WHERE i.id = oo.fk_id_import
                RETURNING i.id
            ),
            obs AS (
                UPDATE gobs.observation go SET (
                    ob_value,
                    ob_start_timestamp, ob_end_timestamp
                ) = (
                    (o->'values')::jsonb,
                    (o->>'start_timestamp')::timestamp, (o->>'end_timestamp')::timestamp
                )
                FROM
                    source, oldobs AS oo
                WHERE go.ob_uid = oo.ob_uid
                RETURNING go.*
            )
            SELECT row_to_json(obs.*) AS object_json
            FROM obs
            ";
        } else {
            // DELETE
            $sql = "
            WITH del AS (
                DELETE
                FROM gobs.observation
                WHERE ob_uid = $1
                RETURNING id, ob_uid, fk_id_spatial_object, fk_id_import
            ),
            delo AS (
                DELETE
                FROM gobs.spatial_object AS so
                WHERE True
                AND so.id IN (
                    SELECT fk_id_spatial_object
                    FROM del
                )
                AND NOT EXISTS (
                    SELECT o.id
                    FROM gobs.observation AS o
                    WHERE True
                    AND o.fk_id_spatial_object IN (
                        SELECT fk_id_spatial_object
                        FROM del
                    )
                    AND o.ob_uid != $1
                )
            ),
            deli AS (
                DELETE
                FROM gobs.import AS i
                WHERE True
                AND i.id IN (
                    SELECT fk_id_import
                    FROM del
                )
                AND NOT EXISTS (
                    SELECT o.id
                    FROM gobs.observation AS o
                    WHERE True
                    AND o.fk_id_import IN (
                        SELECT fk_id_import
                        FROM del
                    )
                    AND o.ob_uid != $1
                )
            )
            SELECT
                row_to_json(del.*) AS object_json
            FROM del
            ";
        }
        return $sql;
    }

    // Create a new observation
    private function runDatabaseAction($action='insert')
    {
        // Check observation
        if (!($this->observation_valid)) {
            return array(
                'error',
                'The given observation is not valid',
                null
            );
        }

        // Get SQL
        $sql = $this->getSql($action);

        // Set parameters
        $params = array();
        if ($action == 'insert') {
            $params[] = $this->json_data;
            $params[] = $this->user['usr_email'];
        } elseif ($action == 'update') {
            $params[] = $this->json_data;
            $params[] = $this->user['usr_email'];
            $params[] = $this->observation_uid;
        } elseif ($action == 'delete') {
            $params[] = $this->observation_uid;
        }

        // Set messages
        $messages = array(
            'insert' => array(
                'A database error occured while creating the observation',
                'The observation has not been created because one already exists with the same data',
                'created',
            ),
            'update' => array(
                'A database error occured while modifying the observation',
                'The observation has not been modified',
                'modified',
            ),
            'delete' => array(
                'A database error occured while deleting the observation',
                'The observation has not been deleted',
                'deleted',
            ),
        );

        // Run query
        try {
            $json = $this->query($sql, $params);
        } catch (Exception $e) {
            $msg = $e->getMessage();
            $json = null;
            return array(
                'error',
                $messages[$action][0],
                null
            );
        }
        if (empty($json)) {
            return array(
                'error',
                $messages[$action][1],
                null
            );
        }

        // For insert or update, get this observation as G-Obs format
        if (in_array($action, array('insert','update'))) {
            // Get data for publication
            $observation = json_decode($json);
            $uid = $observation->ob_uid;
            $this->getObservationFromDatabase($uid);
            $data = $this->getForPublication();

            // Return response
            return array(
                'success',
                'The observation has been sucessfully ' . $messages[$action][2],
                $data
            );
        }

        // For delete
        if ($action == 'delete') {
            // Delete also orphan medias
            $delete = $this->deleteMedia();
            if ($delete[0] == 'error') {
                return $delete;
            }

            // Return response
            return array(
                'success',
                'The observation has been sucessfully ' . $messages[$action][2],
                json_decode($json)
            );
        }
    }

    // Modify and return data for publication purpose
    private function getForPublication() {
        // Get observation instance data
        $data = $this->raw_data;

        // Remove login before sending back data
        unset($data->actor_email);

        // Check media exists
        // todo: use ROOT/media/gobsapi/indicator/observations/
        $destination_basename = $data->uuid;
        $destination_basepath = $this->observation_media_directory.'/'.$destination_basename;
        foreach ($this->media_mimes as $mime) {
            $path = $destination_basepath.'.'.$mime;
            if (file_exists($path)) {
                $data->media_url = $path;
                break;
            }
        }

        return $data;
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
        $data = $this->getForPublication();
        return array(
            'success',
            'Observation has been fetched',
            $data
        );
    }

    // Create the observation
    public function create()
    {
        return $this->runDatabaseAction('insert');
    }

    // Update the observation
    public function update()
    {
        return $this->runDatabaseAction('update');
    }

    // Get Gobs representation of an observation object
    public function delete()
    {
        return $this->runDatabaseAction('delete');

        // Delete also orphan medias and documents
        // Todo Observation - delete medias and documents
    }

    // Process upload
    public function processMediaForm() {
        // Create and initialize form
        $form = jForms::create('gobsapi~media', $this->observation_uid);
        $form->initFromRequest();

        // Check data
        if (!$form->check()) {
            jForms::destroy('gobsapi~media', $this->observation_uid);
            return array(
                'error',
                'An error occured while initializing the form: media mime type must be jpg, jpeg, png or gif and the media size must be under 10Mo',
                null
            );
        }

        // Get values
        $mediaFile = trim($form->getData('mediaFile'));
        $info = pathinfo($mediaFile);
        $extension = strtolower($info['extension']);

        // Destination folder and filename
        $destination_basename = $this->observation_uid;

        // Save file
        $delete = $this->deleteMedia();
        if ($delete[0] == 'error') {
            return $delete;
        }
        $save = $form->saveFile('mediaFile', $this->observation_media_directory, $destination_basename.'.'.$extension);
        if (!$save) {
            jForms::destroy('gobsapi~media', $this->observation_uid);
            return array(
                'error',
                'An error occured while saving the media file',
                null
            );
        }

        return array(
            'success',
            'Observation media has been sucessfully uploaded',
            null
        );
    }

    // Delete observation media from destination directory
    public function deleteMedia($uid=null) {
        // Delete existing file
        $destination_basename = $this->observation_uid;
        if ($this->isValidUuid($uid)) {
            $destination_basename = $uid;
        }
        $destination_basepath = $this->observation_media_directory.'/'.$destination_basename;
        $deleted = 0;
        foreach ($this->media_mimes as $mime) {
            $path = $destination_basepath.'.'.$mime;
            if (file_exists($path)) {
                try {
                    unlink($path);
                    $deleted++;
                } catch(Exception $e) {
                    $msg = $e->getMessage();
                    $deleted = -1;
                    break;
                }
            }
        }

        // Return response
        if ($deleted == -1) {
            return array(
                'error',
                'An error occured while deleting the observation media file',
                null
            );
        } elseif ($deleted == 0) {
            return array(
                'success',
                'No media file to delete has been found for this observation',
                null
            );
        } else {
            return array(
                'success',
                'The observation media file has been successfully deleted',
                null
            );
        }
    }

}
// todo: Observation - Remove coordinates and keep wkt
