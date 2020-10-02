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
     */
    public function __construct($login)
    {
        $this->login = $login;
    }

    public function getProjects()
    {

        $projects = array();
        return $projects;
    }

}
