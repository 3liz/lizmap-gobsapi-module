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
        if (method_exists($this, 'createEntryPoint')) {
            $this->createEntryPoint('gobsapi.php', 'gobsapi/config.ini.php', 'gobsapi', 'classic');
        } else {
            // Copy directory for Jelix configuration file related to new entry point
            $gobsapi_jelix_config_target = jApp::configPath('gobsapi/config.ini.php');
            $this->copyFile('gobsapi/config.ini.php', $gobsapi_jelix_config_target);

            // Copy the new entry point PHP file in Lizmap www folder
            // Deprecated and not safe !
            $this->copyFile('gobsapi.php', jApp::wwwPath('gobsapi.php'));
        }

        // Copy configuration file for user defined options
        // TODO: This file should be editable by the admin user in LWC admin panel
        $gobs_config_target = jApp::configPath('gobsapi.ini.php');
        if (!file_exists($gobs_config_target)) {
            $this->copyFile('config/gobsapi.ini.php.dist', $gobs_config_target);
        }
    }
}
