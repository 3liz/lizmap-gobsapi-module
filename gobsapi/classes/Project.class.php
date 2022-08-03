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
     * @var lizmap_project: Lizmap project instance
     */
    protected $lizmap_project;

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
     * @var array QGIS Project custom variables
     */
    protected $variables = array();

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
     * constructor.
     *
     * @param mixed $lizmap_project
     */
    public function __construct($lizmap_project)
    {
        $this->lizmap_project = $lizmap_project;

        // Get simpleXmlElement representation
        $this->setProjectXml();

        // Get QGIS project custom variables
        $this->variables = $this->readCustomProjectVariables($this->xml);

        // Get the project connection name and profile
        $this->setConnection();

        // Check connection
        $connectionName = $this->connectionName;
        $this->connectionValid = $this->checkConnection();

        // Get indicators: do it before building Gobs project
        // to check if the project contains indicators
        if ($this->connectionValid) {
            $this->setIndicators();

            // Create Gobs projet expected data
            // only if there are some indicators
            if (!empty($this->indicators)) {
                $this->buildGobsProject();
            }
        } else {
            $key = $this->lizmap_project->getData('repository').'~'.$this->lizmap_project->getData('id');
            jLog::log('Project "'.$key.'" connection name is not valid: "'.$connectionName.'"', 'error');
        }
    }

    // Create G-Obs project object from Lizmap project
    private function buildGobsProject()
    {
        // Project key
        $key = $this->lizmap_project->getData('repository').'~'.$this->lizmap_project->getData('id');

        // Compute bbox
        $extent = array(
            'xmin' => -180,
            'ymin' => -90,
            'xmax' => 180,
            'ymax' => 90,
        );
        $bbox = $this->lizmap_project->getData('bbox');
        $bbox_exp = explode(', ', $bbox);
        $proj = $this->lizmap_project->getData('proj');
        $srid = explode(':', $proj)[1];
        $sql = "
            WITH a AS (
                SELECT ST_Transform(
                    ST_SetSRID('Box(
                        ".$bbox_exp[0].' '.$bbox_exp[1].',
                        '.$bbox_exp[2].' '.$bbox_exp[3]."
                    )'::box2d, ".$srid.'), 4326) AS b
            )
            SELECT
            ST_xmin(b) xmin,
            ST_ymin(b) ymin,
            ST_xmax(b) xmax,
            ST_ymax(b) ymax
            FROM a;
        ';
        $cnx = jDb::getConnection($this->connectionProfile);

        try {
            $resultset = $cnx->query($sql);
            $data = array();
            foreach ($resultset->fetchAll() as $record) {
                $extent = array(
                    'xmin' => $record->xmin,
                    'ymin' => $record->ymin,
                    'xmax' => $record->xmax,
                    'ymax' => $record->ymax,
                );
            }
        } catch (Exception $e) {
            $msg = $e->getMessage();
            jLog::log('Erreur de récupération des données du projet "'.$key.'"', 'error');
            jLog::log($msg, 'error');
        }

        // Add geopackage url if a file is present
        $gpkg_url = null;
        $gpkg_file_path = $this->lizmap_project->getQgisPath().'.gpkg';
        if (file_exists($gpkg_file_path)) {
            $gpkg_url = jUrl::getFull(
                'gobsapi~project:getProjectGeopackage',
                //array(
                //'projectKey' => $key,
                //)
            );
            $gpkg_url = str_replace(
                'index.php/gobsapi/project/getProjectGeopackage',
                'gobsapi.php/project/'.$key.'/geopackage',
                $gpkg_url
            );
        }

        // Media URL
        $media_url = jUrl::getFull(
            'view~media:illustration',
            array(
                'repository' => $this->lizmap_project->getData('repository'),
                'project' => $this->lizmap_project->getData('id'),
            )
        );

        // Build data
        $this->data = array(
            'key' => $key,
            'label' => $this->lizmap_project->getData('title'),
            'description' => $this->lizmap_project->getData('abstract'),
            'media_url' => $media_url,
            'geopackage_url' => $gpkg_url,
            'extent' => $extent,
        );
    }

    // Get Gobs representation of a project object
    public function get()
    {
        return $this->data;
    }

    /* Get QGIS project XML
     *
     * @param object $project Lizmap project
     *
     * @return XML of the QGIS project
     */
    private function setProjectXml()
    {
        $qgs_path = $this->lizmap_project->getQgisPath();
        if (
            !file_exists($qgs_path) ||
            !file_exists($qgs_path.'.cfg')
        ) {
            throw new Error('Files of project '.$this->key.' does not exists');
        }
        $xml = simplexml_load_file($qgs_path);
        if ($xml === false) {
            throw new Exception('Qgs File of project '.$this->key.' has invalid content');
        }

        $this->xml = $xml;
    }

    /**
     * @param \SimpleXMLElement $xml
     *
     * @return null|array[] array of custom variable name => variable value
     */
    protected function readCustomProjectVariables($xml)
    {
        $xmlCustomProjectVariables = $xml->xpath('//properties/Variables');
        $customProjectVariables = array();

        if ($xmlCustomProjectVariables && count($xmlCustomProjectVariables) === 1) {
            $variableIndex = 0;
            foreach ($xmlCustomProjectVariables[0]->variableNames->value as $variableName) {
                $customProjectVariables[(string) $variableName] = (string) $xmlCustomProjectVariables[0]->variableValues->value[$variableIndex];
                ++$variableIndex;
            }

            return $customProjectVariables;
        }

        return null;
    }

    /**
     * Set the connection name and profile.
     */
    private function setConnection()
    {
        $status = '';
        if (!empty($this->variables) && array_key_exists('gobs_connection_name', $this->variables)) {
            $connectionName = trim($this->variables['gobs_connection_name']);
            if (!empty($connectionName)) {
                $this->connectionName = $connectionName;
                $this->connectionProfile = $this->getConnectionProfile();
                $status = true;
            }
        }

        return $status;
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
            $resultset = $cnx->query($sql);
            foreach ($resultset->fetchAll() as $record) {
                $status = true;
            }
        } catch (Exception $e) {
            $msg = $e->getMessage();
            jLog::log('Connection to the PostgreSQL service "'.$this->connectionName.'" failed', 'error');
            jLog::log($msg, 'error');
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
     * Set project gobs indicators from the QGIS project variable
     * gobs_indicators.
     */
    private function setIndicators()
    {
        // Get Gobs special project variable gobs_indicators
        // The QGIS project needs to have a project variable, like
        // gobs_indicators -> gobs_indicators:indicator_a,indicator_b
        // TODO: no need to use the prefix "gobs_indicators:" anymore since
        // the use of the new method readCustomProjectVariables
        $status = false;

        if (!empty($this->variables) && array_key_exists('gobs_indicators', $this->variables)) {
            $indicators = str_replace('gobs_indicators:', '', trim($this->variables['gobs_indicators']));
            $indicators = array_map('trim', explode(',', $indicators));
            if (!empty($indicators)) {
                $this->indicators = $indicators;
                $status = true;
            }
        }

        return $status;
    }

    // Get Gobs project indicators
    public function getIndicators()
    {
        return $this->indicators;
    }
}
