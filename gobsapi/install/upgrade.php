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
            if (!file_exists(jApp::wwwPath('gobsapi.php'))) {
                $this->createEntryPoint('gobsapi.php', 'gobsapi/config.ini.php', 'gobsapi', 'classic');
            } else {
                $this->myUpdateEntryPointFile('gobsapi.php');
            }
        } else {
            // deprecated and not safe
            $overwrite = true;
            $this->copyFile('gobsapi.php', jApp::wwwPath('gobsapi.php'), $overwrite);
        }
    }

    /**
     * Update the entry point (overwrite the file
     * and adapt application init file.
     *
     * @param string $entryPointFile Entry point file
     */
    protected function myUpdateEntryPointFile($entryPointFile)
    {
        $entryPointFileName = basename($entryPointFile);
        $epPath = jApp::wwwPath($entryPointFileName);
        if (!file_exists($epPath)) {
            throw new \Exception('The entrypoint '.$entryPointFile.' cannot be updated, as it doesn\'t exist');
        }

        // copy the entrypoint and its configuration
        $this->copyFile($entryPointFile, $epPath, true);

        // change the path to application.init.php into the entrypoint
        // depending on the application, the path of www/ is not always at the same place, relatively to
        // application.init.php
        $appInitFile = jApp::applicationInitFile();
        $relativePath = \Jelix\FileUtilities\Path::shortestPath(jApp::wwwPath(), dirname($appInitFile).'/');

        $epCode = file_get_contents($epPath);
        $epCode = preg_replace('#(require\s*\(?\s*[\'"])(.*)(application\.init\.php)([\'"])#m', '\\1'.$relativePath.'/'.basename($appInitFile).'\\4', $epCode);
        file_put_contents($epPath, $epCode);
    }
}
