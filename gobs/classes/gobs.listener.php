<?php

class gobsListener extends jEventListener
{
    protected function getGobsConfig()
    {
        $file = jApp::configPath('gobs.ini.php');

        return parse_ini_file($file, true);
    }

    private function getDockContent()
    {
        $tpl = new jTpl();
        $tpl->assign('foo', 'bar');

        return new lizmapMapDockItem(
            'gobs',
            jLocale::get('gobs~gobs.dock.title'),
            $tpl->fetch('gobs~gobs_dock'),
            5,
            '<span class="icon-gobs"></span>'
        );
    }

    public function onmapDockable($event)
    {
        if (empty($this->getGobsConfig())) {
            return null;
        }
        $dockable = $this->getDockContent();
        $event->add($dockable);
    }
}
