<?php
/**
 * @author    3liz
 * @copyright 2018-2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license   GPL 3
 */
class gobsapiModuleInstaller extends jInstallerModule
{
    public function install()
    {

        // Copy configuration file
        $gobs_config_target = jApp::configPath('gobsapi.ini.php');
        if (!file_exists($gobs_config_target)) {
            $this->copyFile('config/gobsapi.ini.php.dist', $gobs_config_target);
        }
    }
}
