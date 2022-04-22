<?php
/**
 * @author    3liz
 * @copyright 2018-2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license   GPL 3
 */
class gobsapiModuleUpgrader extends jInstallerModule
{
    public function install()
    {
        // Copy entry point
        // Needed in the upgrade process
        // if the variable $mapping has changed
        if (method_exists($this, 'createEntryPoint')) {
            $this->createEntryPoint('gobsapi.php', 'gobsapi/config.ini.php', 'gobsapi', 'classic');
        } else {
            //deprecated and not safe
            $this->copyFile('gobsapi.php', jApp::wwwPath('gobsapi.php'));
        }
    }
}
