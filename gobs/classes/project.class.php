<?php
/**
 * @author    3liz
 * @copyright 2019 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */

namespace Gobs\Project;

class Project
{
    /**
     * @var Repository
     */
    protected $project;

    /**
     * constructor.
     *
     * @param string $username: the user login
     * @param mixed  $project
     */
    public function __construct($project)
    {
        $this->project = $project;
    }
}
