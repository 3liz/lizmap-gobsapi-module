<?php

/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class Project
{
    /**
     * @var project_key: Gobs project key
     */
    protected $project_key;

    /**
     * @var SimpleXMLElement QGIS project XML
     */
    protected $xml;

    /**
     * @var data: G-Obs Representation of a project
     */
    protected $data;

    /**
     * @var array Array of project series
     */
    protected $series = array();

    /**
     * @var array G-Obs Project properties read from database
     */
    protected $properties = array();

    /**
     * @var bool Validity of the service connection for the connection name
     */
    public $connectionValid;

    /**
     * @var string jDb connection profile
     */
    protected $connectionProfile = 'gobsapi';

    /**
     * @var string Authenticated user login
     */
    protected $login;

    /**
     * @var array Authenticated user groups
     */
    protected $userGroups;

    /**
     * constructor.
     *
     * @param string $project_key
     * @param mixed  $login
     */
    public function __construct($project_key, $login)
    {
        $this->project_key = $project_key;
        $this->login = $login;

        // Get the authenticated user groups
        $this->userGroups = jAcl2DbUserGroup::getGroupsIdByUser($this->login);

        // Check connection to PostgreSQL database
        $this->connectionValid = $this->checkConnection();

        // Get series: do it before building Gobs project
        // to check if the project contains series
        if ($this->connectionValid) {
            // Get project properties
            $this->properties = $this->getProjectPropertiesFromDatabase();

            // Create Gobs projet expected data
            // only if there are some series
            if ($this->properties !== null) {
                $this->buildGobsProject();
            }
        } else {
            jLog::log('The database cannot be reached with the given connection profile : "'.$this->connectionProfile.'" ');
        }
    }

    /**
     * Check the project database connection.
     */
    public function checkConnection()
    {
        $sql = 'SELECT 1 AS test;';
        $status = false;

        try {
            $cnx = jDb::getConnection($this->connectionProfile);
            $query = $cnx->query($sql);
            if ($query) {
                foreach ($query->fetchAll() as $record) {
                    $status = true;
                }
            } else {
                $errorCode = $cnx->errorCode();
                jLog::log('Connection to the PostgreSQL profile "'.$this->connectionProfile.'" failed', 'error');
                jLog::log($errorCode, 'error');
                $status = false;
            }
        } catch (Exception $e) {
            $msg = $e->getMessage();
            jLog::log('Connection to the PostgreSQL profile "'.$this->connectionProfile.'" failed', 'error');
            jLog::log($msg, 'error');
            $status = false;
        }

        return $status;
    }

    /**
     * Get the project properties from the database.
     *
     * @return null|array The project properties or null
     */
    public function getProjectPropertiesFromDatabase()
    {
        $project = null;
        $cnx = jDb::getConnection($this->connectionProfile);
        $projectCode = $this->project_key;
        $groups = implode('@@', $this->userGroups);
        $sql = '
            WITH
            proj AS (
                SELECT id
                FROM gobs.project
                WHERE pt_code = '.$cnx->quote($projectCode)."
                LIMIT 1
            ),
            global_view AS (
                SELECT
                    fk_id_project,
                    geom
                FROM gobs.project_view AS pv,
                proj
                WHERE fk_id_project = proj.id
                AND pv_type = 'global'
                LIMIT 1
            ),
            merged_views AS (
                SELECT
                    fk_id_project,
                    string_agg(pv_label, ',') AS labels,
                    CAST( ST_multi(ST_Union(geom)) AS geometry(MULTIPOLYGON, 4326) ) AS geom
                FROM proj, gobs.project_view AS pv
                WHERE fk_id_project = proj.id
                AND regexp_split_to_array(pv_groups, '[\\s,;]+')
                    && regexp_split_to_array(".$cnx->quote($groups).", '@@')
                GROUP BY fk_id_project
            )
            SELECT
                p.id, p.pt_code,
                p.pt_label, p.pt_description,
                string_agg(s.id::text, ',') AS series_ids,
                ST_AsText(mv.geom, 8) AS allowed_polygon_wkt,
                ST_xmin(gv.geom) AS xmin,
                ST_ymin(gv.geom) AS ymin,
                ST_xmax(gv.geom) AS xmax,
                ST_ymax(gv.geom) AS ymax
            FROM gobs.project AS p
            INNER JOIN global_view AS gv
                ON gv.fk_id_project = p.id
            INNER JOIN merged_views AS mv
                ON mv.fk_id_project = p.id
            LEFT JOIN gobs.series AS s
                ON s.fk_id_project = p.id
            WHERE p.pt_code = ".$cnx->quote($projectCode).'
            GROUP BY
                p.id, p.pt_code,
                p.pt_label, p.pt_description,
                allowed_polygon_wkt,
                gv.geom
            LIMIT 1
        ';

        $resultset = null;

        try {

            $resultset = $cnx->prepare($sql);
            // We do not used prepared statement anymore because this feature seems broken
            $execute = $resultset->execute();
            if ($resultset && $resultset->id() === false) {
                $errorCode = $cnx->errorCode();

                throw new Exception($errorCode);
            }

            if ($resultset !== null) {
                $data = array();
                foreach ($resultset->fetchAll() as $record) {
                    $data['id'] = $record->id;
                    $data['code'] = $record->pt_code;
                    $data['label'] = $record->pt_label;
                    $data['description'] = $record->pt_description;
                    $data['series_ids'] = $record->series_ids;
                    $data['allowed_polygon_wkt'] = $record->allowed_polygon_wkt;
                    $data['xmin'] = $record->xmin;
                    $data['ymin'] = $record->ymin;
                    $data['xmax'] = $record->xmax;
                    $data['ymax'] = $record->ymax;
                }

                if (count($data)) {
                    return $data;
                }

                return null;
            }

        } catch (Exception $e) {
            $msg = $e->getMessage();
            jLog::log('An error occurred while requesting the properties for the project "'.$this->project_key.'"', 'error');
            jLog::log($msg, 'error');

            return null;
        }

        return null;
    }

    /**
     * Check that the authenticated user has access to this project.
     *
     * @return bool $hasAccess True if the user can access this project
     */
    public function checkAcl()
    {
        return $this->properties !== null && count($this->properties) > 0;
    }

    // Create G-Obs project object from Lizmap project
    private function buildGobsProject()
    {
        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();

        // Add geopackage url if a file is present
        $gpkg_url = null;
        $root_dir = $utils->getMediaRootDirectory();
        $gpkg_dir = '/gobsapi/geopackage/'.$this->project_key.'.gpkg';
        $gpkg_file_path = $root_dir.$gpkg_dir;
        if (file_exists($gpkg_file_path)) {
            $gpkg_url = jUrl::getFull(
                'gobsapi~project:getProjectGeopackage',
            );
            $gpkg_url = str_replace(
                'gobsapi.php/gobsapi/project/getProjectGeopackage',
                'gobsapi.php/project/'.$this->project_key.'/geopackage',
                $gpkg_url
            );
        }

        // Project illustration
        $root_dir = $utils->getMediaRootDirectory();
        $media_dir = '/gobsapi/illustration/'.$this->project_key;
        $extensions = array('jpg', 'jpeg', 'png');
        $media_url = null;
        foreach ($extensions as $extension) {
            $media_file_path = $root_dir.$media_dir.'.'.$extension;
            if (file_exists($media_file_path)) {
                $media_url = jUrl::getFull(
                    'gobsapi~project:getProjectIllustration',
                );
                $media_url = str_replace(
                    'gobsapi.php/gobsapi/project/getProjectIllustration',
                    'gobsapi.php/project/'.$this->project_key.'/illustration',
                    $media_url
                );

                break;
            }
        }

        // Build data
        $this->data = array(
            'key' => $this->project_key,
            'label' => $this->properties['label'],
            'description' => $this->properties['description'],
            'media_url' => $media_url,
            'geopackage_url' => $gpkg_url,
            'extent' => array(
                'xmin' => $this->properties['xmin'],
                'ymin' => $this->properties['ymin'],
                'xmax' => $this->properties['xmax'],
                'ymax' => $this->properties['ymax'],
            ),
        );
    }

    /**
     *  Get Gobs representation of a project object.
     *
     * @return array The Gobs project data expected by the API
     */
    public function get()
    {
        return $this->data;
    }

    /**
     *  Get Gobs project key.
     *
     * @return string $project_key The project key
     */
    public function getKey()
    {
        return $this->project_key;
    }

    /**
     * Get Gobs project internal properties.
     *
     * @return null|array $properties The project properties
     */
    public function getProperties()
    {
        return $this->properties;
    }

    /**
     * Get Gobs project allowed polygon for the authenticated user
     * based on the accessible project views.
     *
     * @return null|string $wkt the WKT representing the allowed polygon
     */
    public function getAllowedPolygon()
    {
        $allowedPolygon = null;
        if (is_array($this->properties) && array_key_exists('allowed_polygon_wkt', $this->properties)) {
            $allowedPolygon = $this->properties['allowed_polygon_wkt'];
        }

        return $allowedPolygon;
    }

    /**
     * Get Gobs project series.
     *
     * @return null|array The project series of observations
     */
    public function getSeries()
    {
        $series = null;
        if (is_array($this->properties) && array_key_exists('series_ids', $this->properties)
            && !empty($this->properties['series_ids'])
        ) {
            $series = array_map('trim', explode(',', $this->properties['series_ids']));
            if (count($series) == 0) {
                $series = null;
            }
        }

        $this->series = $series;

        return $series;
    }
}
