<?php
/**
 * @author    3liz
 * @copyright 2022 3liz
 *
 * @see      https://3liz.com
 *
 * @license    GPL 3
 */

use jelix\Routing\UrlMapping\EntryPointUrlModifier;
use Jelix\Routing\UrlMapping\MapEntry\MapInclude;

/**
 * Configurator for Lizmap 3.6+/Jelix 1.8+.
 */
class gobsapiModuleConfigurator extends \Jelix\Installer\Module\Configurator
{
    public function getDefaultParameters()
    {
        return array();
    }

    public function declareUrls(EntryPointUrlModifier $registerOnEntryPoint)
    {
        $registerOnEntryPoint->havingName(
            'gobsapi',
            array(
                new MapInclude('urls.xml'),
            )
        );
    }

    public function getEntryPointsToCreate()
    {
        return array(
            new \Jelix\Installer\Module\EntryPointToInstall(
                'gobsapi.php',
                'gobsapi/config.ini.php',
                'gobsapi.php',
                'config/config.ini.php'
            ),
        );
    }

    public function configure(Jelix\Installer\Module\API\ConfigurationHelpers $helpers)
    {
        // Copy configuration file for user defined options
        // TODO: This file should be editable by the admin user in LWC admin panel
        $gobs_config_target = \jApp::varConfigPath('gobsapi.ini.php');
        if (!file_exists($gobs_config_target)) {
            $helpers->copyFile('config/gobsapi.ini.php.dist', $gobs_config_target);
        }

        // Adapt SAML configuration it is exists
        $authConfigfile = \jApp::varConfigPath('saml/saml.coord.ini.php');
        if (file_exists($authConfigfile)) {
            $authConfig = new \Jelix\IniFile\IniModifier($authConfigfile);
            $authConfig->setValue('userform', 'lizmap~account', 'saml');
            $authConfig->save();
        }

        $localConfigFile = \jApp::varConfigPath('localconfig.ini.php');
        $localConfig = new \Jelix\IniFile\IniModifier($localConfigFile);
        if (!isset(jApp::config()->gobsapi['adminSAMLGobsRoleName'])) {
            $localConfig->setValue('adminSAMLGobsRoleName', 'ROLE_GOBS_ADMIN', 'gobsapi', '');
            $localConfig->setValue('adminSAMLGobsRoleName', 'GOBS_ADMIN', 'gobsapi', '');
            $localConfig->save();
        }
    }
}
