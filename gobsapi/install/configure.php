<?php
/**
 * @author    3liz
 * @copyright 2022 3liz
 *
 * @see      https://3liz.com
 *
 * @license    GPL 3
 */

use Jelix\Routing\UrlMapping\EntryPointUrlModifier;
use \Jelix\Routing\UrlMapping\MapEntry\MapInclude;

/**
 * Configurator for Lizmap 3.6+/Jelix 1.8+
 */
class gobsapiModuleConfigurator extends \Jelix\Installer\Module\Configurator {

    public function getDefaultParameters()
    {
        return array();
    }


    public function declareUrls(EntryPointUrlModifier $registerOnEntryPoint)
    {
        $registerOnEntryPoint->havingName(
            'gobsapi',
            array(
                new MapInclude('urls.xml')
            )
        )
        ;
    }

    public function getEntryPointsToCreate()
    {
        return array(
            new \Jelix\Installer\Module\EntryPointToInstall(
                'gobsapi.php',
                'gobsapi/config.ini.php',
                'gobsapi.php',
                'gobsapi/config.ini.php'
            )
        );
    }

    function configure(\Jelix\Installer\Module\API\ConfigurationHelpers $helpers)
    {
        $gobs_config_target = $helpers->configFilePath('gobsapi.ini.php');
        $helpers->copyFile('config/gobsapi.ini.php.dist', $gobs_config_target);
    }
}