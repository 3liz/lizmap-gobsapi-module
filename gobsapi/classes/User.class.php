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
    public $login;

    /**
     * @var User email
     */
    public $email;

    /**
     * @var User firstname
     */
    public $firstname;

    /**
     * @var User lastname
     */
    public $lastname;

    /**
     * constructor.
     *
     * @param mixed $user       Jelix authenticated user
     * @param mixed $jelix_user
     */
    public function __construct($jelix_user)
    {
        $this->login = $jelix_user->login;
        foreach (array('email', 'firstname', 'lastname') as $item) {
            $this->{$item} = '';
            if ($jelix_user->{$item}) {
                $this->{$item} = $jelix_user->{$item};
            }
        }
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

    // Create actor and actor_category if needed
    public function createGobsActor()
    {

        // Check cache
        $cache_key = 'gobs_actor_'.$this->login;
        $cache = jCache::get($cache_key);
        if ($cache) {
            return $cache;
        }

        // Utils
        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();

        // actor_category
        $category_id = $utils->getOrAddObject(
            'actor_category',
            array('G-Events'),
            array(
                'G-Events',
                'Automatically created category of actors for G-Events',
            )
        );
        if (!$category_id) {
            return null;
        }

        // actor
        $actor_id = $utils->getOrAddObject(
            'actor',
            array($this->login),
            array(
                $this->login,
                $this->firstname,
                $this->lastname,
                $this->email,
                $category_id,
                'Automatically created actor for G-Events: ',
            )
        );
        if (!$actor_id) {
            return null;
        }

        // Set cache
        jCache::set($cache_key, $actor_id, 300);

        return $actor_id;
    }
}
