<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class Utils
{

    /**
     * @var string jDb connection profile
     */
    protected $connectionProfile = 'gobsapi';

    private $sql = array(
        'actor_category' => array(
            'get' => '
                SELECT id
                FROM gobs.actor_category
                WHERE ac_label = $1
            ',
            'add' => '
                INSERT INTO gobs.actor_category (
                    ac_label, ac_description
                )
                VALUES ($1, $2)
                RETURNING id
            ',
        ),
        'actor' => array(
            'get' => '
                SELECT id
                FROM gobs.actor
                WHERE a_login = $1::text
            ',
            'add' => '
                INSERT INTO gobs.actor (
                    a_login, a_label, a_description, a_email, id_category
                )
                VALUES (
                    $1::text,
                    coalesce(trim(concat($2::text, \' \', $3::text)), $1::text),
                    concat(
                        $6::text,
                        coalesce(trim(concat($2::text, \' \', $3::text)), $1::text)
                    ),
                    $4::text,
                    $5
                )
                RETURNING id
            ',
        ),
        'protocol' => array(
            'get' => '
                SELECT id
                FROM gobs.protocol
                WHERE pr_code = $1
            ',
            'add' => '
                INSERT INTO gobs.protocol (pr_code, pr_label, pr_description)
                VALUES ($1, $2, $3)
                RETURNING id
            ',
        ),
        'spatial_layer' => array(
            'get' => '
                SELECT id
                FROM gobs.spatial_layer
                WHERE sl_code = $1
            ',
            'add' => '
                INSERT INTO gobs.spatial_layer
                (sl_code, sl_label, sl_description, fk_id_actor, sl_geometry_type)
                VALUES ($1, $2, $3, $4, $5)
                RETURNING id
            ',
        ),
        'series' => array(
            'get' => '
                SELECT id
                FROM gobs.series
                WHERE TRUE
                AND fk_id_protocol = $1
                AND fk_id_project = $2
                AND fk_id_indicator = $3
                AND fk_id_spatial_layer = $4
            ',
            'add' => '
                INSERT INTO gobs.series
                (fk_id_protocol, fk_id_project, fk_id_indicator, fk_id_spatial_layer)
                VALUES ($1, $2, $3, $4)
                RETURNING id
            ',
        ),
    );

    // Query database and return json data
    public function query($sql, $params)
    {
        $cnx = jDb::getConnection($this->connectionProfile);
        $cnx->beginTransaction();

        try {
            $resultset = $cnx->prepare($sql);
            $resultset->execute($params);
            if ($resultset && $resultset->id() === false) {
                $cnx->rollback();
                $errorCode = $cnx->errorCode();
                \jLog::log($errorCode, 'error');

                return null;
            }
            $data = $resultset->fetchAll();
            $cnx->commit();
        } catch (Exception $e) {
            $cnx->rollback();
            $data = null;
        }

        return $data;
    }

    /**
     * Get or add a G-Obs object.
     *
     * @param string     $key                The object to create. It corresponds to the table name. Ex: actor_category
     * @param mixed      $get_params         Parameters needed for the get SQL
     * @param null|mixed $add_params         Parameters needed for the add SQL
     *
     * @return int Object id
     */
    public function getOrAddObject($key, $get_params, $add_params = null)
    {
        $id = null;

        // Check if object already exists
        $sql = $this->sql[$key]['get'];
        $data = $this->query($sql, $get_params);
        if (!is_array($data)) {
            return null;
        }

        // If not, create object
        if ($add_params && count($data) == 0) {
            $sql = $this->sql[$key]['add'];
            $data = $this->query($sql, $add_params);
            if (!is_array($data)) {
                return null;
            }
        }

        // Get id
        foreach ($data as $line) {
            $id = $line->id;
        }
        if (!$id) {
            return null;
        }

        return $id;
    }

    /**
     * Get the version of G-Obs structure as written
     * in the database metadata table.
     *
     * @return string $version Version of the database structure
     */
    public function getDatabaseStructureVersion()
    {
        $sql = 'SELECT me_version FROM gobs.metadata';
        $data = $this->query($sql, array());
        if (!is_array($data)) {
            return null;
        }
        $version = null;
        foreach ($data as $line) {
            $version = $line->me_version;
        }

        return $version;
    }

    /**
     * Get the Lizmap media root directory.
     *
     * @return string Path of Lizmap project root folder
     */
    public function getMediaRootDirectory()
    {
        $lizmapRootDirectory = lizmap::getServices()->getRootRepositories();

        return realpath($lizmapRootDirectory.'/media/');
    }
}
