<?php
/**
 * @author    3liz
 * @copyright 2018-2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license   GPL 3
 */
class gobsModuleInstaller extends jInstallerModule
{
    public function install()
    {

        // Copy configuration file
        $gobsConfigPath = jApp::configPath('gobs.ini.php');
        if (!file_exists($gobsConfigPath)) {
            $this->copyFile('config/gobs.ini.php.dist', $gobsConfigPath);
        }
    }
}
