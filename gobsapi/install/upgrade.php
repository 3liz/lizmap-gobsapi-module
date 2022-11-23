<?php
/**
 * @author    3liz
 * @copyright 2018-2024 3liz
 *
 * @see      http://3liz.com
 *
 * @license   GPL 3
 */
class gobsapiModuleUpgrader extends  \Jelix\Installer\Module\Installer
{
    public function install(Jelix\Installer\Module\API\InstallHelpers $helpers)
    {
        $helpers->updateEntryPointFile('gobsapi.php', 'gobsapi', 'classic');
    }
}
