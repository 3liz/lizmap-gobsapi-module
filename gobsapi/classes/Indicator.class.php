<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class Indicator
{
    /**
     * @var code: Indicator code
     */
    protected $code;

    /**
     * @var user: Gobs authenticated user instance
     */
    protected $user;

    /**
     * @var lizmapProject: Indicator lizMap project
     */
    protected $lizmap_project;

    /**
     * @var string: Indicator lizMap project
     */
    protected $connection_profile;

    /**
     * @var data G-Obs Representation of a indicator
     */
    protected $raw_data;

    /**
     * @var document root directory
     */
    public $document_root_directory;

    /**
     * @var media destination directory
     */
    public $observation_media_directory;

    /**
     * @var media allowed mime types
     */
    protected $media_mimes = array('jpg', 'jpeg', 'png', 'gif');

    // Todo: Indicator - Ajouter nouvelle catégorie de document = icon

    /**
     * constructor.
     *
     * @param mixed         $user                Gobs user instance
     * @param string        $code:               the code of the indicator
     * @param lizmapProject $lizmap_project:     the lizMap project of the indicator
     * @param string        $connection_profile: the QGIS project corresponding jDb connection profile name
     */
    public function __construct($user, $code, $lizmap_project, $connection_profile)
    {
        $this->code = $code;
        $this->user = $user;
        $this->lizmap_project = $lizmap_project;
        $this->connection_profile = $connection_profile;

        // Create Gobs projet expected data
        if ($this->checkCode()) {
            $this->buildGobsIndicator();
        }

        // Set document and observation media directories
        $this->setDocumentDirectory();
        $this->setMediaDirectory();
    }

    // Get indicator code
    public function getCode()
    {
        return $this->code;
    }

    // Get indicator lizmap project
    public function getLizmapProject()
    {
        return $this->lizmap_project;
    }

    // Get the connection profile
    public function getConnectionProfile()
    {
        return $this->connection_profile;
    }

    // Check indicator code is valid
    public function checkCode()
    {
        $i = $this->code;

        return
            preg_match('/^[a-zA-Z0-9_\-]+$/', $i)
            and strlen($i) > 2
        ;
    }

    /**
     * Check if a given string is a valid UUID.
     *
     * @param string $uuid The string to check
     *
     * @return bool
     */
    public function isValidUuid($uuid)
    {
        if (!is_string($uuid) || (preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/', $uuid) !== 1)) {
            return false;
        }

        return true;
    }

    // Create G-Obs project object from Lizmap project
    private function buildGobsIndicator()
    {
        $sql = "
        WITH decompose_values AS (
            SELECT
                i.*,
                array_position(id_value_code, unnest(id_value_code)) AS value_position
            FROM gobs.indicator AS i
            WHERE id_code = $1
        ),
        ind AS (
            SELECT
            decompose_values.id AS id,
            id_code AS code,
            id_label AS label,
            id_description AS description,
            id_category AS category,
            id_date_format AS date_format,

            -- values
            jsonb_agg(jsonb_build_object(
                'code', id_value_code[value_position],
                'name', id_value_name[value_position],
                'type', id_value_type[value_position],
                'unit', id_value_unit[value_position]
            )) AS values,

            decompose_values.created_at,
            decompose_values.updated_at

            FROM decompose_values
            GROUP BY
            decompose_values.id,
            id_code,
            id_label,
            id_description,
            id_date_format,
            id_value_code,
            id_value_name,
            id_value_type,
            id_value_unit,
            id_category,
            decompose_values.created_at,
            decompose_values.updated_at
            ORDER BY id
        ),
        consolidated AS (
            SELECT ind.*,

            -- documents
            json_agg(
            CASE
                WHEN d.id IS NOT NULL THEN json_build_object(
                    'id', d.id,
                    'uid', d.do_uid,
                    'indicator', ind.code,
                    'label', d.do_label,
                    'description', d.do_description,
                    'type', d.do_type,
                    'url', d.do_path,
                    'created_at', d.created_at,
                    'updated_at', d.updated_at
                )
                ELSE NULL
            END)  AS documents
            FROM ind
            LEFT JOIN gobs.document AS d
                ON d.fk_id_indicator = ind.id
            GROUP BY
            ind.id,
            ind.code,
            ind.label,
            ind.description,
            ind.date_format,
            ind.values,
            ind.category,
            ind.created_at,
            ind.updated_at

        ),
        last AS (
            SELECT
                id, code, label, description, category, date_format,
                values, documents,
                NULL AS preview,
                NULL AS icon,
                created_at,
                updated_at
            FROM consolidated
        )
        SELECT
            row_to_json(last.*) AS object_json
        FROM last
        ";
        $cnx = jDb::getConnection($this->connection_profile);
        $resultset = $cnx->prepare($sql);
        $resultset->execute(array($this->code));
        $json = null;
        foreach ($resultset->fetchAll() as $record) {
            $json = $record->object_json;
        }

        $this->raw_data = json_decode($json);
    }

    // Get Gobs representation of a indicator object
    public function get($context = 'internal')
    {
        $data = $this->raw_data;

        if ($context == 'publication') {
            // Get data for publication
            $data = $this->getForPublication();
        }

        return $data;
    }

    // Modify and return data for publication purpose
    private function getForPublication()
    {
        // Get observation instance data
        $data = $this->raw_data;

        if (!empty($data)) {
            // Transform document paths into lizmap media URL
            $docs = array();
            if (count($data->documents) == 1 && !$data->documents[0]) {
                $docs = array();
            } else {
                foreach ($data->documents as $document) {
                    // Check if document is preview or icon
                    if (in_array($document->type, array('preview', 'icon'))) {
                        // We move the doc from documents to preview/icon property
                        $media_url = $this->setDocumentUrl($document);
                        if ($media_url) {
                            $dtype = $document->type;
                            $data->{$dtype} = $media_url;
                        }
                    } elseif ($document->type == 'url') {
                        $docs[] = $document;
                    } else {
                        $media_url = $this->setDocumentUrl($document);
                        if ($media_url) {
                            $document->url = $media_url;
                        }
                        $docs[] = $document;
                    }
                }
            }
            $data->documents = $docs;
        }

        return $data;
    }

    // Query database and return json data
    private function query($sql, $params)
    {
        $cnx = jDb::getConnection($this->connection_profile);

        try {
            $resultset = $cnx->prepare($sql);
            $resultset->execute($params);
            $data = $resultset->fetchAll();
            $cnx->commit();
        } catch (Exception $e) {
            $cnx->rollback();
            $data = null;
        }

        return $data;
    }

    /**
     * Create the needed G-Obs series
     *
     * If a spatial layer code is given, use this layer
     * and do not create a new spatial layer
     *
     * @param null|string $spatial_layer_code The spatial layer code to use.
     * @return integer $series_id The Series internal integer ID.
     */
    public function getOrAddGobsSeries($spatial_layer_code = null)
    {
        // Check cache
        $cache_key = 'gobs_series_'.$this->code.'_'.$this->user->login;
        $series_id = jCache::get($cache_key);
        if ($series_id) {
            return $series_id;
        }

        // Utils
        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();

        // protocol
        $protocol_id = $utils->getOrAddObject(
            $this->connection_profile,
            'protocol',
            array('g_events'),
            array(
                'g_events',
                'G-Events',
                'Automatically created protocol for G-Events',
            )
        );
        if (!$protocol_id) {
            return null;
        }

        // actor_category for actor
        $category_id = $utils->getOrAddObject(
            $this->connection_profile,
            'actor_category',
            array('G-Events'),
            array(
                'G-Events',
                'Automatically created category of actors for G-Events',
            )
        );
        if (!$category_id) {
            return null;
        }

        // actor for spatial layer
        $sl_actor_id = $utils->getOrAddObject(
            $this->connection_profile,
            'actor',
            array('g_events'),
            array(
                'g_events',
                'G-Events',
                'Application',
                'g_events@g_events.evt',
                $category_id,
                'Automatically created actor for G-Events: ',
            )
        );
        if (!$sl_actor_id) {
            return null;
        }

        // spatial_layer
        if ($spatial_layer_code === null) {
            $spatial_layer_code = 'g_events_'.$this->code;
        }
        $spatial_layer_id = $utils->getOrAddObject(
            $this->connection_profile,
            'spatial_layer',
            array($spatial_layer_code),
            array(
                'g_events_'.$this->code,
                'Observation points for the indicator '.$this->code,
                'Automatically created spatial layer for G-Events indicator '.$this->code,
                $sl_actor_id,
                'point',
            )
        );
        if (!$spatial_layer_id) {
            return null;
        }

        // indicator
        $indicator_id = $this->raw_data->id;

        // authenticated actor
        // it has already been created before hand (see User class)
        $actor_id = $utils->getOrAddObject(
            $this->connection_profile,
            'actor',
            array($this->user->login),
            null
        );
        if (!$actor_id) {
            return null;
        }

        // series
        $series_properties = array(
            $protocol_id,
            $actor_id,
            $indicator_id,
            $spatial_layer_id,
        );
        $series_id = $utils->getOrAddObject(
            $this->connection_profile,
            'series',
            $series_properties,
            $series_properties
        );
        if (!$series_id) {
            return null;
        }

        // Set cache
        jCache::set($cache_key, $series_id, 300);

        return $series_id;
    }

    // Set the root folder for the indicator document files
    public function setDocumentDirectory()
    {
        $this->document_root_directory = null;
        $repository_dir = $this->lizmap_project->getRepository()->getPath();
        $root_dir = realpath($repository_dir.'../media/');
        if (is_dir($root_dir)) {
            $document_dir = '/../media/gobsapi/documents/';
            $dest_dir = $repository_dir.$document_dir;
            $create_dir = jFile::createDir($dest_dir);
            if (is_dir($dest_dir)) {
                $this->document_root_directory = realpath($dest_dir);
            }
        }
    }

    // Set the root folder for the observation media files
    public function setMediaDirectory()
    {
        $this->observation_media_directory = null;
        $repository_dir = $this->lizmap_project->getRepository()->getPath();
        $root_dir = realpath($repository_dir.'../media/');
        if (is_dir($root_dir) && is_writable($root_dir)) {
            $observation_dir = '/../media/gobsapi/observations/';
            $dest_dir = $repository_dir.$observation_dir;
            $create_dir = jFile::createDir($dest_dir);
            if (is_dir($dest_dir)) {
                $this->observation_media_directory = realpath($dest_dir);
            }
        }
    }

    // Get indicator observations
    public function getObservations($requestSyncDate = null, $lastSyncDate = null, $uids = null)
    {
        $sql = "
        WITH ind AS (
            SELECT id, id_code
            FROM gobs.indicator
            WHERE id_code = $1
        ),
        ser AS (
            SELECT s.id
            FROM gobs.series AS s
            JOIN ind AS i
                ON fk_id_indicator = i.id
        ),
        obs AS (
            SELECT
                o.id, ind.id_code AS indicator, o.ob_uid AS uuid,
                o.ob_start_timestamp AS start_timestamp,
                o.ob_end_timestamp AS end_timestamp,
                a.a_email AS actor_email,
                a.a_login AS actor_login,
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
            JOIN gobs.spatial_object AS so
                ON so.id = o.fk_id_spatial_object,
            ind
            WHERE fk_id_series IN (
                SELECT ser.id FROM ser
            )
        ";

        // Filter between last sync date & request sync date
        if ($requestSyncDate && $lastSyncDate) {
            // updated_at is always set (=created_at or last time object has been modified)
            $sql .= '
            AND (
                o.updated_at > $2 AND o.updated_at <= $3
            )
            ';
        }

        // Filter for given observation uids
        if (!empty($uids)) {
            $keep = array();
            foreach ($uuids as $uuid) {
                if ($this->isValidUuid($uuid)) {
                    $keep[] = $uuid;
                }
            }
            if (!empty($keep)) {
                $sql_uids = implode("', '", $keep);
                $sql .= "
                AND (
                    o.ob_uid IN ('".$sql_uids."')
                )
                ";
            }
        }

        // Transform result into JSON for each row
        $sql .= '
        )
        SELECT
            row_to_json(obs.*) AS object_json
        FROM obs
        ';
        // jLog::log($sql, 'error');
        $cnx = jDb::getConnection($this->connection_profile);
        $resultset = $cnx->prepare($sql);
        $params = array($this->code);
        if ($requestSyncDate && $lastSyncDate) {
            $params[] = $lastSyncDate;
            $params[] = $requestSyncDate;
        }
        $resultset->execute($params);
        $data = array();

        // Process data
        foreach ($resultset->fetchAll() as $record) {
            $item = json_decode($record->object_json);

            // Add editable property to help clients know
            // if the observation can be modified or deleted
            // todo: replace test with login
            $item->editable = false;
            if ($this->user->email == $item->actor_email) {
                $item->editable = true;
            }
            if ($this->user->login == $item->actor_login) {
                $item->editable = true;
            }

            // Remove email before sending back data
            unset($item->actor_login, $item->actor_email);

            // Check media exists
            $media_url = $this->setObservationMediaUrl($item->uuid);
            if ($media_url) {
                $item->media_url = $media_url;
            }

            $data[] = $item;
        }

        return $data;
    }

    // Get indicator document by uid
    public function getDocumentByUid($uid)
    {
        $document = null;
        if (!$this->isValidUuid($uid)) {
            return null;
        }

        $documents = $this->raw_data->documents;
        foreach ($documents as $doc) {
            if ($doc->uid == $uid) {
                return $doc;
            }
        }

        return null;
    }

    // Get document full file path
    public function getDocumentPath($document)
    {
        if (empty($this->document_root_directory)) {
            return null;
        }

        // Indicator code and document type are already contained in the dabase document URL
        $destination_basename = $document->url;
        $document_dir = '/../media/gobsapi/documents/';
        $media_path = $document_dir.$destination_basename;
        $file_path = $this->document_root_directory.'/'.$destination_basename;
        if (!file_exists($file_path)) {
            return null;
        }

        return $file_path;
    }

    // Transform the indicator document file path into a public lizMap media URL
    public function setDocumentUrl($document)
    {
        $document_url = null;
        $file_path = $this->getDocumentPath($document);

        if ($file_path) {
            $document_url = jUrl::getFull(
                'gobsapi~indicator:getIndicatorDocument'
            );
            $pkey = $this->lizmap_project->getData('repository').'~'.$this->lizmap_project->getData('id');
            $document_url = str_replace(
                'index.php/gobsapi/indicator/getIndicatorDocument',
                'gobsapi.php/project/'.$pkey.'/indicator/'.$this->code.'/document/'.$document->uid,
                $document_url
            );
        }

        return $document_url;
    }

    // Transform the observation media file path into a public lizMap media URL
    public function setObservationMediaUrl($uid)
    {
        $media_url = null;
        if (empty($this->observation_media_directory)) {
            return null;
        }

        $destination_basename = $uid;
        $observation_dir = '/../media/gobsapi/observations/';
        $relative_path = $observation_dir.$destination_basename;
        $full_path = $this->observation_media_directory.'/'.$destination_basename;
        foreach ($this->media_mimes as $mime) {
            $file_path = $full_path.'.'.$mime;
            $media_path = $relative_path.'.'.$mime;
            if (file_exists($file_path)) {
                $media_url = jUrl::getFull(
                    'gobsapi~observation:getObservationMedia'
                );
                $pkey = $this->lizmap_project->getData('repository').'~'.$this->lizmap_project->getData('id');
                $media_url = str_replace(
                    'index.php/gobsapi/observation/getObservationMedia',
                    'gobsapi.php/project/'.$pkey.'/indicator/'.$this->code.'/observation/'.$uid.'/media',
                    $media_url
                );

                break;
            }
        }

        return $media_url;
    }

    // Get indicator deleted observations
    public function getDeletedObservations($requestSyncDate = null, $lastSyncDate = null)
    {
        $sql = "
        WITH
        del AS (
            SELECT
                de_uid AS uid
            FROM gobs.deleted_data_log
            WHERE True
            AND de_table = 'observation'
        ";
        if ($requestSyncDate && $lastSyncDate) {
            $sql .= '
            AND (
                de_timestamp BETWEEN $1 AND $2
            )
            ';
        }
        $sql .= '
        )
        SELECT
            uid
        FROM del
        ';
        // jLog::log($sql, 'error');

        $cnx = jDb::getConnection($this->connection_profile);
        $resultset = $cnx->prepare($sql);
        $params = array();
        if ($requestSyncDate && $lastSyncDate) {
            $params[] = $lastSyncDate;
            $params[] = $requestSyncDate;
        }
        $resultset->execute($params);
        $data = array();
        foreach ($resultset->fetchAll() as $record) {
            $data[] = $record->uid;
        }

        return $data;
    }
}
