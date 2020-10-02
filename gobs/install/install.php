<?php
/**
* @package   lizmap
* @subpackage gobs
* @author    3liz
* @copyright 2018-2020 3liz
* @link      http://3liz.com
* @license   GPL 3
*/

class gobsModuleInstaller extends jInstallerModule {

    function install() {

        // Copy configuration file
        $gobsConfigPath = jApp::configPath('gobs.ini.php');
        if (!file_exists($gobsConfigPath)) {
            $this->copyFile('config/gobs.ini.php.dist', $gobsConfigPath);
        }

    }
}
