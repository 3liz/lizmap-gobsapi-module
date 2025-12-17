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
     * @var string User login
     */
    public $login;

    /**
     * @var string User email
     */
    public $email;

    /**
     * @var string User firstname
     */
    public $firstname;

    /**
     * @var string User lastname
     */
    public $lastname;

    /**
     * @var string User connectionProfile
     */
    protected $connectionProfile = 'gobsapi';

    /**
     * constructor.
     *
     * @param object $jelix_user
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
        // We use the connection profile named gobsapi
        $projectKeys = array();
        $cnx = jDb::getConnection($this->connectionProfile);
        $userGroups = jAcl2DbUserGroup::getGroupsIdByUser($this->login);
        $groups = implode('@@', $userGroups);
        $sql = "
            SELECT DISTINCT
                p.id, p.pt_code, p.pt_label
            FROM gobs.project AS p
            JOIN gobs.project_view AS v
                ON v.fk_id_project = p.id
            WHERE True
            AND regexp_split_to_array(pv_groups, '[\\s,;]+')
                && regexp_split_to_array(".$cnx->quote($groups).", '@@')
        ";
        $status = false;
        try {
            $query = $cnx->query($sql);
            if ($query) {
                foreach ($query->fetchAll() as $record) {
                    $status = true;
                    $projectKeys[] = $record->pt_code;
                }
            } else {
                $errorCode = $cnx->errorCode();
                \jLog::log('Connection to the PostgreSQL service "'.$this->connectionName.'" failed', 'error');
                \jLog::log($errorCode, 'error');
                $status = false;
            }
        } catch (Exception $e) {
            $msg = $e->getMessage();
            \jLog::log('Connection to the PostgreSQL service "'.$this->connectionName.'" failed', 'error');
            \jLog::log($msg, 'error');
            $status = false;
        }

        // Get project instance
        jClasses::inc('gobsapi~Project');
        $projects = array();
        foreach($projectKeys as $project_key) {
            $gobs_project = new Project($project_key, $this->login);

            // Add it only if project contains gobs series
            if (!empty($gobs_project->getSeries())) {
                $projects[] = $gobs_project->get();
            }
        }

        return $projects;
    }

    /**
     * Create actor and actor_category if needed
     *
     * @return null|integer Database actor ID
     */
    public function createOrGetGobsActor()
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
