<?php
/**
 * @author    3liz
 * @copyright 2019 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */

namespace Gobs\User;

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
     *
     */
    public function getProjects()
    {
        //$repositories = lizmap::getRepositoryList();
        $projects = array();

        foreach ($repositories as $repository) {

            // Check rights
            if (!jAcl2::check('lizmap.repositories.view', $repository)) {
                continue;
            }

            // Get repository and related projects
            $lrep = lizmap::getRepository($repository);
            $mrep = new lizmapMainViewItem($repository, $lrep->getData('label'));
            $lprojects = $lrep->getProjects();

            foreach ($projects as $project) {

                // Check rights
                if (!$project->checkAcl()) {
                    continue;
                }

                // Add project
                $projects[] = array(
                    'key' => $project->getData('id'),
                    'label' => $project->getData('title'),
                    'description' => $project->getData('abstract'),
                    'media_url' => jUrl::get(
                        'view~media:illustration',
                        array(
                            'repository' => $project->getData('repository'),
                            'project' => $project->getData('id'),
                        )
                    ),
                    'geopackage_url' => null,
                    'extent' => $project->getData('bbox'),
                );
            }
        }
        return $projects;
    }
}
