<?php
/**
 * @author    3liz
 * @copyright 2020 3liz
 *
 * @see      http://3liz.com
 *
 * @license Mozilla Public License : http://www.mozilla.org/MPL/
 */
class Indicator
{
    /**
     * @var indicator_code: Indicator code
     */
    protected $indicator_code;

    /**
     * @var data G-Obs Representation of a indicator
     */
    protected $data;

    /**
     * constructor.
     *
     * @param string $indicator_code: the code of the indicator
     * @param mixed  $project
     */
    public function __construct($indicator_code)
    {
        $this->indicator_code = $indicator_code;

        // Create Gobs projet expected data
        if ($this->checkCode()) {
            $this->buildGobsIndicator();
        }
    }

    // Check indicator code is valid
    public function checkCode()
    {
        $i = $this->indicator_code;

        return (
            preg_match('/^[a-zA-Z0-9_\-]+$/', $i)
            and strlen($i) > 2
        );
    }

    /**
     * Check if a given string is a valid UUID
     *
     * @param   string  $uuid   The string to check
     * @return  boolean
     */
    public function isValidUuid($uuid) {

        if (!is_string($uuid) || (preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/', $uuid) !== 1)) {
            return false;
        }

        return true;
    }

    // Create G-Obs project object from Lizmap project
    private function buildGobsIndicator()
    {
        $sql = "
        WITH decompose_values AS (
            SELECT
                i.*,
                array_position(id_value_code, unnest(id_value_code)) AS value_position
            FROM gobs.indicator AS i
            WHERE id_code = $1
        ),
        ind AS (
            SELECT
            decompose_values.id AS id,
            id_code AS code,
            id_label AS label,
            id_description AS description,
            id_category AS category,
            id_date_format AS date_format,

            -- values
            jsonb_agg(jsonb_build_object(
                'code', id_value_code[value_position],
                'name', id_value_name[value_position],
                'type', id_value_type[value_position],
                'unit', id_value_unit[value_position]
            )) AS values,

            decompose_values.created_at,
            decompose_values.updated_at

            FROM decompose_values
            GROUP BY
            decompose_values.id,
            id_code,
            id_label,
            id_description,
            id_date_format,
            id_value_code,
            id_value_name,
            id_value_type,
            id_value_unit,
            id_category,
            decompose_values.created_at,
            decompose_values.updated_at
            ORDER BY id
        ),
        consolidated AS (
            SELECT ind.*,

            -- documents
            json_agg(
            CASE
                WHEN d.id IS NOT NULL THEN json_build_object(
                    'id', d.id,
                    'indicator', ind.code,
                    'label', d.do_label,
                    'description', d.do_description,
                    'type', d.do_type,
                    'url', d.do_path,
                    'created_at', d.created_at,
                    'updated_at', d.updated_at
                )
                ELSE NULL
            END)  AS documents
            FROM ind
            LEFT JOIN gobs.document AS d
                ON d.fk_id_indicator = ind.id
            GROUP BY
            ind.id,
            ind.code,
            ind.label,
            ind.description,
            ind.date_format,
            ind.values,
            ind.category,
            ind.created_at,
            ind.updated_at

        ),
        last AS (
            SELECT
                id, code, label, description, category, date_format,
                values, documents,
                'avatar' AS avatar,
                'blue' AS color,
                created_at,
                updated_at
            FROM consolidated
        )
        SELECT
            row_to_json(last.*) AS object_json
        FROM last
        ";
        $gobs_profile = 'gobsapi';
        $cnx = jDb::getConnection($gobs_profile);
        $resultset = $cnx->prepare($sql);
        $resultset->execute(array($this->indicator_code));
        $json = null;
        foreach ($resultset->fetchAll() as $record) {
            $json = $record->object_json;
        }

        $this->data = json_decode($json);
    }

    // Get Gobs representation of a indicator object
    public function get()
    {
        return $this->data;
    }


    // Get indicator observations
    public function getObservations($requestSyncDate=null, $lastSyncDate=null, $uids=null)
    {
        $sql = "
        WITH ind AS (
            SELECT id, id_code
            FROM gobs.indicator
            WHERE id_code = $1
        ),
        ser AS (
            SELECT s.id
            FROM gobs.series AS s
            JOIN ind AS i
                ON fk_id_indicator = i.id
        ),
        obs AS (
            SELECT
                o.id, ind.id_code AS indicator, o.ob_uid AS uuid,
                o.ob_start_timestamp AS start_timestamp,
                o.ob_end_timestamp AS end_timestamp,
                json_build_object(
                    'x', ST_X(ST_Centroid(so.geom)),
                    'y', ST_Y(ST_Centroid(so.geom))
                ) AS coordinates,
                ST_AsText(ST_Centroid(so.geom)) AS wkt,
                ob_value AS values,
                NULL AS photo,
                o.created_at::timestamp(0), o.updated_at::timestamp(0)
            FROM gobs.observation AS o
            JOIN gobs.spatial_object AS so
                ON so.id = o.fk_id_spatial_object,
            ind
            WHERE fk_id_series IN (
                SELECT ser.id FROM ser
            )
        ";

        // Filter between last sync date & request sync date
        if ($requestSyncDate && $lastSyncDate) {
            // updated_at is always set (=created_at or last time object has been modified)
            $sql.= "
            AND (
                o.updated_at > $2 AND o.updated_at <= $3
            )
            ";
        }

        // Filter for given observation uids
        if (!empty($uids)) {
            $keep = array();
            foreach ($uuids as $uuid) {
                if ($this->isValidUuid($uuid)) {
                    $keep[] = $uuid;
                }
            }
            if (!empty($keep)) {
                $sql_uids = implode("', '", $keep);
                $sql.= "
                AND (
                    o.ob_uid IN ('" . $sql_uids. "')
                )
                ";
            }
        }

        // Transform result into JSON for each row
        $sql.= "
        )
        SELECT
            row_to_json(obs.*) AS object_json
        FROM obs
        ";
        //jLog::log($sql, 'error');

        $gobs_profile = 'gobsapi';
        $cnx = jDb::getConnection($gobs_profile);
        $resultset = $cnx->prepare($sql);
        $params = array($this->indicator_code);
        if ($requestSyncDate && $lastSyncDate) {
            $params[] = $lastSyncDate;
            $params[] = $requestSyncDate;
        }
        $resultset->execute($params);
        $data = [];
        foreach ($resultset->fetchAll() as $record) {
            $data[] = json_decode($record->object_json);
        }

        return $data;
    }

    // Get indicator deleted observations
    public function getDeletedObservations($requestSyncDate=null, $lastSyncDate=null)
    {
        $sql = "
        WITH
        del AS (
            SELECT
                de_uid AS uid
            FROM gobs.deleted_data_log
            WHERE True
            AND de_table = 'observation'
        ";
        if ($requestSyncDate && $lastSyncDate) {
            $sql.= "
            AND (
                de_timestamp BETWEEN $1 AND $2
            )
            ";
        }
        $sql.= "
        )
        SELECT
            uid
        FROM del
        ";
        //jLog::log($sql, 'error');

        $gobs_profile = 'gobsapi';
        $cnx = jDb::getConnection($gobs_profile);
        $resultset = $cnx->prepare($sql);
        $params = array();
        if ($requestSyncDate && $lastSyncDate) {
            $params[] = $lastSyncDate;
            $params[] = $requestSyncDate;
        }
        $resultset->execute($params);
        $data = [];
        foreach ($resultset->fetchAll() as $record) {
            $data[] = $record->uid;
        }

        return $data;
    }

}
