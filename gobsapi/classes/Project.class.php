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
     * @var array Array of project indicator codes
     */
    protected $indicators = array();

    /**
     * @var array G-Obs Project properties read from database
     */
    protected $properties = array();

    /**
     * @var string Name of the PostgreSQL connection
     */
    public $connectionName;

    /**
     * @var bool Validity of the service connection for the connection name
     */
    public $connectionValid;

    /**
     * @var string Jelix virtual jDb profile
     */
    protected $connectionProfile;

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

        // Get the project connection name and profile
        $this->setConnection();

        // Check connection to PostgreSQL database
        $this->connectionValid = $this->checkConnection();

        // Get indicators: do it before building Gobs project
        // to check if the project contains indicators
        if ($this->connectionValid) {
            // Get project properties
            $this->properties = $this->getProjectPropertiesFromDatabase();

            // Create Gobs projet expected data
            // only if there are some indicators
            if ($this->properties !== null) {
                $this->buildGobsProject();
            }
        } else {
            \jLog::log('Project "'.$project_key.'" connection name is not valid: "'.$this->connectionName.'"');
        }
    }

    /**
     * Set the connection name and profile.
     *
     * @return bool False if no connection has been found
     */
    private function setConnection()
    {
        // Get the ini file containing the projects connections
        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();
        $root_dir = $utils->getMediaRootDirectory();
        $projects_connections_file = '/gobsapi/projects_connections.ini';
        $projects_connections_file_path = $root_dir.$projects_connections_file;

        // No file
        if (!file_exists($projects_connections_file_path)) {
            return false;
        }
        $ini = parse_ini_file($projects_connections_file_path, true);

        // No content
        if (!$ini) {
            return false;
        }

        // The project key does not exists in the ini file
        if (!array_key_exists($this->project_key, $ini) || !array_key_exists('connection_name', $ini[$this->project_key])) {
            return false;
        }

        // The project connection is not empty
        $connectionName = trim($ini[$this->project_key]['connection_name']);
        if (empty($connectionName)) {
            return false;
        }

        // Set the project connection name
        $this->connectionName = $connectionName;
        $this->connectionProfile = $this->getConnectionProfile();

        return true;
    }

    /**
     * Get the connection virtual profile.
     */
    public function getConnectionProfile()
    {
        if (empty($this->connectionName)) {
            return null;
        }

        // Profile parameters
        $jdbParams = array(
            'driver' => 'pgsql',
            'service' => $this->connectionName,
        );
        $dbProfile = 'gobs_api_profile_'.sha1(json_encode($jdbParams));

        try {
            // try to get the profile, it may be already created for an other layer
            \jProfiles::get('jdb', $dbProfile, true);
        } catch (Exception $e) {
            // create the profile
            \jProfiles::createVirtualProfile('jdb', $dbProfile, $jdbParams);
        }

        // Set the project property
        $this->connectionProfile = $dbProfile;

        return $dbProfile;
    }

    /**
     * Check the project database connection.
     */
    public function checkConnection()
    {
        if (empty($this->connectionName)) {
            return false;
        }
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
                \jLog::log('Connection to the PostgreSQL service "'.$this->connectionName.'" failed', 'error');
                \jLog::log($errorCode, 'error');
                $status = false;
            }
        } catch (Exception $e) {
            $msg = $e->getMessage();
            \jLog::log('Connection to the PostgreSQL service "'.$this->connectionName.'" failed', 'error');
            \jLog::log($msg, 'error');
            $status = false;
        }

        // Revert the connection name and profile to null values
        if (!$status) {
            $this->connectionName = null;
            $this->connectionProfile = null;
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
                p.id, p.pt_code, p.pt_lizmap_project_key,
                p.pt_label, p.pt_description,
                array_to_string(p.pt_indicator_codes, ',') AS pt_indicator_codes,
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

            WHERE p.pt_code = ".$cnx->quote($projectCode).'
            LIMIT 1
        ';

        $resultset = null;

        try {

            $resultset = $cnx->prepare($sql);
            // We do not used prepared statement anymore because this feature seems broken
            $execute = $resultset->execute();

            $data = array();
            if ($resultset && $resultset->id() === false) {
                $errorCode = $cnx->errorCode();

                throw new Exception($errorCode);
            }

            if ($resultset !== null) {
                foreach ($resultset->fetchAll() as $record) {
                    $data['id'] = $record->id;
                    $data['code'] = $record->pt_code;
                    $data['lizmap_project_key'] = $record->pt_lizmap_project_key;
                    $data['label'] = $record->pt_label;
                    $data['description'] = $record->pt_description;
                    $data['indicator_codes'] = $record->pt_indicator_codes;
                    $data['allowed_polygon_wkt'] = $record->allowed_polygon_wkt;
                    $data['xmin'] = $record->xmin;
                    $data['ymin'] = $record->ymin;
                    $data['xmax'] = $record->xmax;
                    $data['ymax'] = $record->ymax;
                }
            }

            return $data;
        } catch (Exception $e) {
            $msg = $e->getMessage();
            \jLog::log('An error occurred while requesting the properties for the project "'.$this->project_key.'"', 'error');
            \jLog::log($msg, 'error');

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
     * Get Gobs project indicators.
     *
     * @return null|array The project indicators
     */
    public function getIndicators()
    {
        $indicators = null;

        if (is_array($this->properties) && array_key_exists('indicator_codes', $this->properties)
            && !empty($this->properties['indicator_codes'])
        ) {
            $indicators = array_map('trim', explode(',', $this->properties['indicator_codes']));
            if (count($indicators) == 0) {
                $indicators = null;
            }
        }

        $this->indicators = $indicators;

        return $indicators;
    }
}
