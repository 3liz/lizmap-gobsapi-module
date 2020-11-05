<?php

class gobsapiLizmapProject
{

    /**
     * Check acl rights on the project by given user.
     *
     * @param mixed $login Login of the user to test access
     *
     * @return bool true if the current user as rights on the project
     *
     * @since Jelix 1.6.29
     */
    public function checkAclByUser($project, $login)
    {

        // Check right on repository
        if (!jAcl2::checkByUser($login, 'lizmap.repositories.view', $project->getData('repository'))) {
            return false;
        }

        // Check acl option is configured in project config
        if (!property_exists($project->getOptions(), 'acl') || !is_array($project->getOptions()->acl) || empty($project->getOptions()->acl)) {
            return true;
        }

        // Check user is admin -> ok, give permission
        if (jAcl2::checkByUser($login, 'lizmap.admin.repositories.delete')) {
            return true;
        }

        // Check if configured groups white list and authenticated user groups list intersects
        $aclGroups = $project->getOptions()->acl;
        $userGroups = jAcl2DbUserGroup::getGroupsIdByUser($login);
        if (array_intersect($aclGroups, $userGroups)) {
            return true;
        }

        return false;
    }

}
