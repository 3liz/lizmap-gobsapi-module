<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license   All rights reserved
 */
class gobsapiListenerListener extends \jEventListener
{
    /**
     * @param \jEvent $event
     */
    public function onAuthLogin($event)
    {
        /** @var samlAuthDriver $driver */
        $driver = \jAuth::getDriver();
        if (get_class($driver) != 'samlAuthDriver') {
            return;
        }

        $attributes = $driver->getSAMLAttributes();
        // \jLog::dump($attributes, 'onAuthLogin: SAML attributes');
        // Do nothing if attributes is an empty array
        // to avoid emptying all rights for SAML users
        if (empty($attributes)) {
            return;
        }

        $allGroups = array();
        foreach (jAcl2DbUserGroup::getGroupList() as $group) {
            $allGroups[$group->id_aclgrp] = $group;
        }

        $login = $event->login;

        $groupsOfUser = array();
        if (isset($attributes['GOBS_ROLE'])) {
            // expect to have array having this kind of item:
            //  '{"id":"cn=ROLE_GOBS_ADMIN,ou=ROLE,cn=GOBS,ou=application,dc=pacte,dc=projet",  "code":"ROLE_GOBS_ADMIN",   "label":"Role admin pour G-Obs"}'

            if (!is_array($attributes['GOBS_ROLE'])) {
                $attributes['GOBS_ROLE'] = array($attributes['GOBS_ROLE']);
            }

            $groupsOfUser = $this->registerGroups($allGroups, $attributes['GOBS_ROLE'], 'GOBS_ROLE');
        }

        if (isset($attributes['GOBS_SI'])) {
            // expect to have array having this kind of item:
            // '{"id":null,     "code":"GOBS_ADMIN",    "label":"Administrateurs G-Obs",    "description":"Les adminstrateurs de G-Obs"}'
            if (!is_array($attributes['GOBS_SI'])) {
                $attributes['GOBS_SI'] = array($attributes['GOBS_SI']);
            }

            $groupsOfUser = array_merge($groupsOfUser, $this->registerGroups($allGroups, $attributes['GOBS_SI'], 'GOBS_SI'));
        }

        // \jLog::dump(array_keys($groupsOfUser), "onAuthLogin: Groupes de l'utilisateur {$login}");
        $groupToRemove = array();
        foreach (jAcl2DbUserGroup::getGroupList($login) as $group) {
            if ($group->id_aclgrp == 'admins') {
                // admins group, let's ignore
                continue;
            }
            if ($group->grouptype == 2) {
                // private group, let's ignore
                continue;
            }
            if (isset($groupsOfUser[$group->id_aclgrp])) {
                // the user is already in the group
                unset($groupsOfUser[$group->id_aclgrp]);
            } else {
                // the user is in a group that is not listed in roles given by SAML
                // let's remove him from it
                $groupToRemove[] = $group->id_aclgrp;
            }
        }

        $hasChanges = false;
        foreach ($groupToRemove as $grpId) {
            \jLog::log("onAuthLogin: Remove {$login} from {$grpId}");
            \jAcl2DbUserGroup::removeUserFromGroup($login, $grpId);
            $hasChanges = true;
        }

        foreach ($groupsOfUser as $grpId => $ok) {
            \jLog::log("onAuthLogin: Add {$login} into {$grpId}");
            \jAcl2DbUserGroup::addUserToGroup($login, $grpId);
            $hasChanges = true;
        }

        if ($hasChanges) {
            \jAcl2::clearCache();
        }
    }

    protected function registerGroups(&$allGroups, $samlGroups, $rolesName)
    {
        $groupsOfUser = array();
        $adminGroup = array();
        if (isset(jApp::config()->gobsapi['adminSAMLGobsRoleName'])) {
            $adminGroup = \jApp::config()->gobsapi['adminSAMLGobsRoleName'];
            if (!is_array($adminGroup)) {
                $adminGroup = array($adminGroup);
            }
        }

        foreach ($samlGroups as $roleAsJson) {
            $role = @json_decode($roleAsJson, true);
            if (!$role || !isset($role['code']) || $role['code'] == '') {
                \jLog::log('gobs login: bad role value into '.$rolesName.', not a json or code property missing: '.$roleAsJson, 'error');

                continue;
            }
            // Souci avec la commande interne de création de groupe
            // jAcl2DbUserGroup::createGroup() qui met le groupe en minuscule
            // On passe tout en minuscule ici pour éviter les problèmes
            // ERROR:  insert or update on table "jacl2_rights" violates foreign key constraint "jacl2_rights_id_aclgrp_fkey"
            $idGrp = strtolower($role['code']);
            $name = isset($role['label']) ? $role['label'] : $idGrp;
            if ($name == '') {
                $name = $idGrp;
            }
            if (!isset($allGroups[$idGrp])) {
                \jAcl2DbUserGroup::createGroup($name, $idGrp);
                if (in_array($idGrp, $adminGroup)) {
                    foreach (jAcl2DbManager::$ACL_ADMIN_RIGHTS as $role) {
                        \jAcl2DbManager::addRight($idGrp, $role);
                    }
                    \jAcl2DbManager::addRight($idGrp, 'acl.group.create');
                    \jAcl2DbManager::addRight($idGrp, 'auth.users.list');
                    \jAcl2DbManager::addRight($idGrp, 'auth.users.modify');
                    \jAcl2DbManager::addRight($idGrp, 'auth.users.view');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.access');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.repositories.create');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.repositories.delete');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.repositories.update');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.repositories.view');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.services.update');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.services.view');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.project.list.view');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.home.page.update');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.theme.update');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.theme.view');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.server.information.view');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.lizmap.log.view');
                    \jAcl2DbManager::addRight($idGrp, 'lizmap.admin.lizmap.log.delete');

                }
                // On enlève les droits liés à la création d'utilisateur, car SAML
                \jAcl2DbManager::removeRight($idGrp, 'auth.user.change.password', '-', true);
                \jAcl2DbManager::removeRight($idGrp, 'auth.users.change.password', '-', true);
                \jAcl2DbManager::addRight($idGrp, 'auth.user.view');
                \jAcl2DbManager::addRight($idGrp, 'auth.user.modify');
            }

            $groupsOfUser[$idGrp] = true;
        }

        return $groupsOfUser;
    }
}
