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
     * @var indicators: Array of project indicator codes
     */
    protected $indicators = array();

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

        // Get indicators: do it before building Gobs project
        // to check if the project contains indicators
        $this->setIndicators();

        // Create Gobs projet expected data
        if (!empty($this->indicators)) {
            $this->buildGobsProject();
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
        $gobs_profile = 'gobsapi';
        $cnx = jDb::getConnection($gobs_profile);

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
        if (!file_exists($qgs_path) ||
            !file_exists($qgs_path.'.cfg')) {
            throw new Error('Files of project '.$this->key.' does not exists');
        }
        $xml = simplexml_load_file($qgs_path);
        if ($xml === false) {
            throw new Exception('Qgs File of project '.$this->key.' has invalid content');
        }

        $this->xml = $xml;
    }

    // Set project gobs indicators
    private function setIndicators()
    {
        // Get Gobs special project variable gobs_indicators
        // The QGIS project needs to have a project variable, like
        // gobs_indicators -> gobs_indicators:indicator_a,indicator_b
        $xpath = '//properties/Variables/variableValues/value[contains(text(),"gobs_indicators:")]';
        $data = $this->xml->xpath($xpath);
        if ($data) {
            $indicators = str_replace('gobs_indicators:', '', trim((string) $data[0]));
            $indicators = array_map('trim', explode(',', $indicators));
            //jLog::log(json_encode($indicators), 'error');
            if (!empty($indicators)) {
                $this->indicators = $indicators;
            }
        }
    }

    // Get Gobs project indicators
    public function getIndicators()
    {
        return $this->indicators;
    }

    // Get Gobs
}
