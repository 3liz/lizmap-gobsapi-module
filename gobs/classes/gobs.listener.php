<?php
class gobsListener extends jEventListener{

    protected function getGobsConfig() {
        $file = jApp::configPath('gobs.ini.php');
        $config = parse_ini_file($file, True);
        return $config;
    }

    private function getDockContent() {
        $tpl = new jTpl();
        $tpl->assign("foo", "bar");
        $dockable = new lizmapMapDockItem(
            'gobs',
            jLocale::get('gobs~gobs.dock.title'),
            $tpl->fetch('gobs~gobs_dock'),
            5,
            '<span class="icon-gobs"></span>'
        );
        return $dockable;
    }

    function onmapDockable ( $event ) {
        if (empty($this->getGobsConfig())) {
            return Null;
        }
        $dockable = $this->getDockContent();
        $event->add($dockable);
    }

}
?>
