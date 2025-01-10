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
        // Utils
        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();

        // Get the list of projects
        // At present, we must loop for each listed project
        // in the ini file, which is not very optimized.
        // We should create a new concept of "database" or "instance"
        // which will help to know which database to connect to

        // Get the ini file containing the projects connections
        jClasses::inc('gobsapi~Utils');
        $utils = new Utils();
        $root_dir = $utils->getMediaRootDirectory();
        $projects_connections_file = '/gobsapi/projects_connections.ini';
        $projects_connections_file_path = $root_dir.$projects_connections_file;

        // No file
        if (!file_exists($projects_connections_file_path)) {
            return array();
        }
        $ini = parse_ini_file($projects_connections_file_path, true);

        // No content
        if (!$ini) {
            return array();
        }

        $projects = array();
        foreach ($ini as $project_key => $project_config) {
            // Get project instance
            jClasses::inc('gobsapi~Project');
            $gobs_project = new Project($project_key, $this->login);

            // Add it only if project has a valid connection && contains gobs indicators
            if ($gobs_project->connectionValid && !empty($gobs_project->getIndicators())) {
                $projects[] = $gobs_project->get();
            }
        }

        return $projects;
    }

    // Create actor and actor_category if needed
    public function createGobsActor($connection_profile)
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
            $connection_profile,
            'actor_category',
            // Get actor with ac_label = platform_user
            array('platform_user'),
            // Create one if not found with following ac_label & ac_description
            array(
                'platform_user',
                'Platform users',
            )
        );
        if (!$category_id) {
            return null;
        }

        // actor
        $actor_id = $utils->getOrAddObject(
            $connection_profile,
            'actor',
            array($this->login),
            array(
                $this->login,
                $this->firstname,
                $this->lastname,
                $this->email,
                $category_id,
                'Automatically created platform user actor',
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
