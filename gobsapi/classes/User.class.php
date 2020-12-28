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
     * @var User login
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
                if (!$project->checkAcl($this->login)) {
                    continue;
                }

                // Get project instance from Lizmap project
                jClasses::inc('gobsapi~Project');
                $gobs_project = new Project($project);

                // Add it only if project has gobs indicators
                if (!empty($gobs_project->getIndicators())) {
                    $projects[] = $gobs_project->get();
                }
            }
        }

        return $projects;
    }
}
