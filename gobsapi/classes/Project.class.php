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
    protected $xml = null;

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
     * @param string $username: the user login
     * @param mixed  $lizmap_project
     */
    public function __construct($lizmap_project)
    {
        $this->lizmap_project = $lizmap_project;

        // Get simpleXmlElement representation
        $this->setProjectXml();

        // Create Gobs projet expected data
        $this->buildGobsProject();

        // Get indicators
        $this->setIndicators();
    }

    // Create G-Obs project object from Lizmap project
    private function buildGobsProject()
    {
        // Compute bbox
        $bbox = $this->lizmap_project->getData('bbox');
        $extent = explode(', ', $bbox);

        $this->data = array(
            'key' => $this->lizmap_project->getData('repository').'~'.$this->lizmap_project->getData('id'),
            'label' => $this->lizmap_project->getData('title'),
            'description' => $this->lizmap_project->getData('abstract'),
            'media_url' => jUrl::getFull(
                'view~media:illustration',
                array(
                    'repository' => $this->lizmap_project->getData('repository'),
                    'project' => $this->lizmap_project->getData('id'),
                )
            ),
            'geopackage_url' => null,
            'extent' => array(
                'xmin' => $extent[0],
                'ymin' => $extent[1],
                'xmax' => $extent[2],
                'ymax' => $extent[3],
            ),
        );
    }

    // Get Gobs representation of a project object
    public function get()
    {
        // Todo: Project - Add geopackage url if file present

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
        $xpath = '//properties/Variables/variableNames/value[.="gobs_indicators"]/parent::variableNames/following-sibling::variableValues/value';
        $data = $this->xml->xpath($xpath);

        if ($data) {
            $indicators = trim((string) $data[0]);
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

}
