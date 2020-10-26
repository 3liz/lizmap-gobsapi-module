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
     * @var project: Lizmap project instance
     */
    protected $project;

    /**
     * @var data G-Obs Representation of a project
     */
    protected $data;

    /**
     * constructor.
     *
     * @param string $username: the user login
     * @param mixed  $project
     */
    public function __construct($project)
    {
        $this->project = $project;

        // Compute bbox
        $bbox = $project->getData('bbox');
        $extent = explode(', ', $bbox);

        // Create Gobs projet expected data
        $this->data = array(
            'key' => $project->getData('repository').'~'.$project->getData('id'),
            'label' => $project->getData('title'),
            'description' => $project->getData('abstract'),
            'media_url' => jUrl::getFull(
                'view~media:illustration',
                array(
                    'repository' => $project->getData('repository'),
                    'project' => $project->getData('id'),
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
        return $this->data;
    }

    /* Get QGIS project XML
     *
     * @param object $project Lizmap project
     *
     * @return XML of the QGIS project
     */
    private function getProjectXml()
    {
        $qgs_path = $this->project->getQgisPath();
        if (!file_exists($qgs_path) ||
            !file_exists($qgs_path.'.cfg')) {
            throw new Error('Files of project '.$this->key.' does not exists');
        }
        $xml = simplexml_load_file($qgs_path);
        if ($xml === false) {
            throw new Exception('Qgs File of project '.$this->key.' has invalid content');
        }

        return $xml;
    }

    /* Get project gobs indicators
     *
     *
     * return Gobs list of indicators codes or null if none has been found
     */
    public function getProjectIndicators()
    {
        $xml = $this->getProjectXml($this->project);
        $xpath = '//properties/Variables/variableNames/value[.="gobs_indicators"]/parent::variableNames/following-sibling::variableValues/value';
        $data = $xml->xpath($xpath);

        if ($data) {
            $indicators = trim((string) $data[0]);
            $indicators = array_map('trim', explode(',', $indicators));
            jLog::log(json_encode($indicators), 'error');

            return $indicators;
        }

        return null;
    }
}
