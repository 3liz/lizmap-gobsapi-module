<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class User
{
    /**
     * @var Repository
     */
    protected $login;

    /**
     * constructor.
     *
     * @param string $username: the user login
     * @param mixed  $login
     */
    public function __construct($login)
    {
        $this->login = $login;
    }

    /**
     * Get projects for the authenticated user.
     */
    public function getProjects()
    {
        $repositories = lizmap::getRepositoryList();
        $projects = array();

        foreach ($repositories as $repository) {

            // Check rights
            if (!jAcl2::check('lizmap.repositories.view', $repository)) {
                continue;
            }

            // Get repository and related projects
            $lrep = lizmap::getRepository($repository);
            $get_projects = $lrep->getProjects();
            foreach ($get_projects as $project) {

                // Check rights
                if (!$project->checkAcl()) {
                    continue;
                }

                // Compute bbox
                $bbox = $project->getData('bbox');
                $extent = explode(', ', $bbox);

                // Add project
                $projects[] = array(
                    'key' => $lrep->getKey().'_'.$project->getData('id'),
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
        }

        return $projects;
    }
}
