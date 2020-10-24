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
     * @var data
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

    public function get()
    {
        return $this->data;
    }
}
